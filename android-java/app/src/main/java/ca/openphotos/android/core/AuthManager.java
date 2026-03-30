package ca.openphotos.android.core;

import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.net.LinkAddress;
import android.net.LinkProperties;
import androidx.annotation.Nullable;
import androidx.security.crypto.EncryptedSharedPreferences;
import androidx.security.crypto.MasterKey;

import org.json.JSONObject;
import org.json.JSONArray;

import java.io.IOException;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.security.GeneralSecurityException;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

/**
 * AuthManager stores tokens securely and provides login/register/refresh APIs
 * mirroring the iOS behavior. Tokens are stored in EncryptedSharedPreferences.
 */
public class AuthManager {
    private static final String DEMO_EMAIL = "demo@openphotos.ca";
    public static final String DEFAULT_SERVER_SCHEME = "http";
    public static final int DEFAULT_SERVER_PORT = 3003;
    private static final String PREFS = "auth.secure";
    private static final String KEY_TOKEN = "token";
    private static final String KEY_REFRESH = "refresh";
    private static final String KEY_EXPIRES_AT = "expires_at";
    private static final String KEY_USER_ID = "user_id";
    private static final String KEY_USER_EMAIL = "user_email";
    private static final String KEY_USER_NAME = "user_name";
    private static final String KEY_SERVER_URL = "server_url";
    private static final String KEY_PUBLIC_SERVER_URL = "network_public_server_url";
    private static final String KEY_LOCAL_SERVER_URL = "network_local_server_url";
    private static final String KEY_AUTO_SWITCH = "network_auto_switch";
    private static final String KEY_MANUAL_PREFERRED = "network_manual_preferred";
    private static final String KEY_RECENT_SERVERS = "recent_servers";
    private static final String KEY_LOGIN_EMAIL = "login_email";
    private static final String KEY_LOGIN_PASSWORD = "login_password";
    private static final long AUTO_LOGIN_RETRY_INTERVAL_MS = 30_000L;
    private static final long ROUTE_DECISION_TTL_MS = 30_000L;
    private static final long LOCAL_PROBE_FAILURE_BACKOFF_MS = 60_000L;

    public enum ManualPreferredEndpoint {
        PUBLIC,
        LOCAL
    }

    public enum ActiveEndpoint {
        NONE,
        PUBLIC,
        LOCAL
    }

    public enum NetworkTransportKind {
        OFFLINE,
        WIFI,
        ETHERNET,
        CELLULAR,
        OTHER
    }

    private static volatile AuthManager INSTANCE;

    private final Context app;
    private final SharedPreferences prefs;
    private final OkHttpClient http;
    private final ConnectivityManager connectivityManager;
    private final Object routeLock = new Object();
    private final ConnectivityManager.NetworkCallback networkCallback;

    private String serverUrl;
    private String publicServerUrl;
    private String localServerUrl;
    private boolean autoSwitchEnabled;
    private ManualPreferredEndpoint manualPreferredEndpoint;
    private volatile boolean hasManualServerOverride = false;
    private volatile String manualServerOverrideBaseUrl = "";
    private volatile ActiveEndpoint activeEndpoint = ActiveEndpoint.NONE;
    private volatile NetworkTransportKind networkTransport = NetworkTransportKind.OFFLINE;
    private volatile boolean currentUsesWifiOrEthernet = false;
    private volatile boolean currentHasPrivateOrLoopbackLanAddress = false;
    private volatile Boolean lastLocalProbeSucceeded = null;
    private volatile String lastLocalProbeMessage = null;
    private volatile long lastLocalProbeAtElapsedMs = 0L;
    private volatile int networkGeneration = 0;
    private volatile int lastProbeNetworkGeneration = -1;
    private volatile long lastRefreshSuccessElapsedMs = 0L;
    private volatile long lastAutoLoginAttemptElapsedMs = 0L;

    private AuthManager(Context app) {
        this.app = app.getApplicationContext();
        SharedPreferences candidate;
        try {
            MasterKey mk = new MasterKey.Builder(this.app)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build();
            candidate = EncryptedSharedPreferences.create(
                    this.app,
                    PREFS,
                    mk,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            );
        } catch (GeneralSecurityException | IOException e) {
            // Fallback to regular SharedPreferences to avoid hard crash on devices
            // where EncryptedSharedPreferences cannot be initialized (e.g. keystore issues).
            candidate = this.app.getSharedPreferences(PREFS + ".fallback", Context.MODE_PRIVATE);
        }
        this.prefs = candidate;
        this.http = new OkHttpClient.Builder()
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .build();
        this.connectivityManager = (ConnectivityManager) this.app.getSystemService(Context.CONNECTIVITY_SERVICE);

        String legacyBaseUrl = normalizeStoredServerUrl(prefs.getString(KEY_SERVER_URL, null));
        ConfiguredBaseUrls configuredBaseUrls = repartitionConfiguredBaseUrls(
                normalizeStoredServerUrl(prefs.getString(KEY_PUBLIC_SERVER_URL, null)).isEmpty()
                        ? legacyBaseUrl
                        : normalizeStoredServerUrl(prefs.getString(KEY_PUBLIC_SERVER_URL, null)),
                normalizeStoredServerUrl(prefs.getString(KEY_LOCAL_SERVER_URL, null))
        );
        this.publicServerUrl = configuredBaseUrls.publicBaseUrl;
        this.localServerUrl = configuredBaseUrls.localBaseUrl;
        this.autoSwitchEnabled = prefs.getBoolean(KEY_AUTO_SWITCH, true);
        String manualPreferredRaw = prefs.getString(KEY_MANUAL_PREFERRED, ManualPreferredEndpoint.PUBLIC.name());
        try {
            this.manualPreferredEndpoint = ManualPreferredEndpoint.valueOf(manualPreferredRaw);
        } catch (Exception ignored) {
            this.manualPreferredEndpoint = ManualPreferredEndpoint.PUBLIC;
        }
        this.serverUrl = initialResolvedBaseUrl(publicServerUrl, localServerUrl, autoSwitchEnabled, manualPreferredEndpoint);
        this.activeEndpoint = endpointType(serverUrl, publicServerUrl, localServerUrl);
        persistNetworkProfile();
        updateNetworkState();
        this.networkCallback = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network network) {
                handleConnectivityChanged();
            }

            @Override public void onLost(Network network) {
                handleConnectivityChanged();
            }

            @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities networkCapabilities) {
                handleConnectivityChanged();
            }
        };
        if (this.connectivityManager != null) {
            try {
                this.connectivityManager.registerDefaultNetworkCallback(this.networkCallback);
            } catch (Exception ignored) {
            }
        }
        new Thread(() -> resolveServerUrl(true, "startup")).start();
    }

    public static AuthManager get(Context app) {
        if (INSTANCE == null) {
            synchronized (AuthManager.class) {
                if (INSTANCE == null) INSTANCE = new AuthManager(app);
            }
        }
        return INSTANCE;
    }

    public String getServerUrl() { return serverUrl; }
    public String getEffectiveServerUrl() { return serverUrl; }
    public String getPublicServerUrl() { return publicServerUrl; }
    public String getLocalServerUrl() { return localServerUrl; }
    public boolean isAutoSwitchEnabled() { return autoSwitchEnabled; }
    public ManualPreferredEndpoint getManualPreferredEndpoint() { return manualPreferredEndpoint; }
    public ActiveEndpoint getActiveEndpoint() { return activeEndpoint; }
    public NetworkTransportKind getNetworkTransport() { return networkTransport; }
    @Nullable public Boolean getLastLocalProbeSucceeded() { return lastLocalProbeSucceeded; }
    @Nullable public String getLastLocalProbeMessage() { return lastLocalProbeMessage; }
    public long getLastLocalProbeAtElapsedMs() { return lastLocalProbeAtElapsedMs; }

    public void setServerUrl(String url) {
        updateSingleConfiguredBaseUrl(url);
    }

    public void setPublicServerUrl(String url) {
        updateSingleConfiguredBaseUrl(url);
    }

    public void setLocalServerUrl(String url) {
        updateConfiguredBaseUrls(publicServerUrl, url);
    }

    public void saveConfiguredBaseUrlsWithoutRefreshing(@Nullable String publicUrl, @Nullable String localUrl) {
        applyConfiguredBaseUrls(publicUrl, localUrl, false, null);
    }

    public void updateSingleConfiguredBaseUrl(@Nullable String rawUrl) {
        String normalized = normalizeStoredServerUrl(rawUrl);
        hasManualServerOverride = false;
        manualServerOverrideBaseUrl = "";
        if (normalized.isEmpty()) {
            this.publicServerUrl = "";
            this.localServerUrl = "";
        } else if (isLocalEndpointUrl(normalized)) {
            ConfiguredBaseUrls configuredBaseUrls = repartitionConfiguredBaseUrls(publicServerUrl, normalized);
            this.publicServerUrl = configuredBaseUrls.publicBaseUrl;
            this.localServerUrl = configuredBaseUrls.localBaseUrl;
        } else {
            ConfiguredBaseUrls configuredBaseUrls = repartitionConfiguredBaseUrls(normalized, localServerUrl);
            this.publicServerUrl = configuredBaseUrls.publicBaseUrl;
            this.localServerUrl = configuredBaseUrls.localBaseUrl;
        }
        applyImmediateResolvedBaseUrl();
        persistNetworkProfile();
        if (!normalized.isEmpty()) {
            addRecentServer(normalized);
        }
        try {
            android.util.Log.i(
                    "OpenPhotos",
                    "[NET] single-url-update raw=" + normalized + " public=" + publicServerUrl + " local=" + localServerUrl + " effective=" + serverUrl
            );
        } catch (Exception ignored) {
        }
        new Thread(() -> resolveServerUrl(true, "single-url-change")).start();
    }

    public void updateConfiguredBaseUrls(@Nullable String publicUrl, @Nullable String localUrl) {
        applyConfiguredBaseUrls(publicUrl, localUrl, true, "configured-urls-change");
    }

    public void setAutoSwitchEnabled(boolean enabled) {
        this.autoSwitchEnabled = enabled;
        persistNetworkProfile();
        new Thread(() -> resolveServerUrl(true, "auto-switch-change")).start();
    }

    public void setManualPreferredEndpoint(ManualPreferredEndpoint endpoint) {
        this.manualPreferredEndpoint = endpoint != null ? endpoint : ManualPreferredEndpoint.PUBLIC;
        persistNetworkProfile();
        new Thread(() -> resolveServerUrl(true, "manual-endpoint-change")).start();
    }

    public void useCurrentConnection() {
        if (activeEndpoint == ActiveEndpoint.LOCAL) {
            autoSwitchEnabled = false;
            manualPreferredEndpoint = ManualPreferredEndpoint.LOCAL;
        } else if (activeEndpoint == ActiveEndpoint.PUBLIC) {
            autoSwitchEnabled = false;
            manualPreferredEndpoint = ManualPreferredEndpoint.PUBLIC;
        }
        persistNetworkProfile();
        new Thread(() -> resolveServerUrl(true, "use-current-connection")).start();
    }

    public void refreshNetworkRouting() {
        new Thread(() -> resolveServerUrl(true, "manual-refresh")).start();
    }

    public ProbeResult testConfiguredEndpoint(ManualPreferredEndpoint endpoint) {
        String baseUrl = endpoint == ManualPreferredEndpoint.LOCAL ? localServerUrl : publicServerUrl;
        if (baseUrl == null || baseUrl.trim().isEmpty()) {
            return new ProbeResult(false, endpoint == ManualPreferredEndpoint.LOCAL
                    ? "Local URL is not configured."
                    : "Public URL is not configured.");
        }
        ProbeResult result = pingBaseUrl(baseUrl);
        if (endpoint == ManualPreferredEndpoint.LOCAL) {
            lastLocalProbeSucceeded = result.success;
            lastLocalProbeMessage = result.message;
            lastLocalProbeAtElapsedMs = SystemClock.elapsedRealtime();
            lastProbeNetworkGeneration = networkGeneration;
        }
        return result;
    }

    public ServerConfig currentServerConfig() {
        if (hasManualServerOverride) {
            ParsedBaseUrl parsedOverride = parseBaseUrl(
                    manualServerOverrideBaseUrl != null && !manualServerOverrideBaseUrl.trim().isEmpty()
                            ? manualServerOverrideBaseUrl
                            : serverUrl
            );
            if (parsedOverride != null) {
                return new ServerConfig(
                        parsedOverride.scheme,
                        parsedOverride.host,
                        parsedOverride.port != null ? parsedOverride.port : DEFAULT_SERVER_PORT
                );
            }
        }
        ParsedBaseUrl parsed = parseBaseUrl(preferredConfiguredBaseUrl());
        if (parsed == null) {
            return new ServerConfig(DEFAULT_SERVER_SCHEME, "", DEFAULT_SERVER_PORT);
        }
        return new ServerConfig(parsed.scheme, parsed.host, parsed.port != null ? parsed.port : DEFAULT_SERVER_PORT);
    }

    public boolean setServerConfig(String scheme, String host, @Nullable Integer port) {
        if (host == null || host.trim().isEmpty()) {
            hasManualServerOverride = true;
            manualServerOverrideBaseUrl = "";
            applyResolvedBaseUrl("", ActiveEndpoint.NONE);
            return true;
        }
        String built = buildBaseUrl(scheme, host, port);
        if (built == null) return false;
        hasManualServerOverride = true;
        manualServerOverrideBaseUrl = built;
        applyResolvedBaseUrl(built, endpointType(built, publicServerUrl, localServerUrl));
        return true;
    }

    public void commitManualServerOverride() {
        if (!hasManualServerOverride) return;
        String submittedBaseUrl = normalizeStoredServerUrl(manualServerOverrideBaseUrl);
        hasManualServerOverride = false;
        manualServerOverrideBaseUrl = "";
        if (submittedBaseUrl.isEmpty()) {
            applyImmediateResolvedBaseUrl();
            return;
        }
        updateSingleConfiguredBaseUrl(submittedBaseUrl);
    }

    public void clearManualServerOverride() {
        if (!hasManualServerOverride) return;
        hasManualServerOverride = false;
        manualServerOverrideBaseUrl = "";
        applyImmediateResolvedBaseUrl();
    }

    public List<String> recentServers() {
        ArrayList<String> out = new ArrayList<>();
        String raw = prefs.getString(KEY_RECENT_SERVERS, null);
        if (raw == null || raw.trim().isEmpty()) return out;
        try {
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length(); i++) {
                String url = normalizeStoredServerUrl(arr.optString(i, ""));
                if (!url.isEmpty() && !out.contains(url)) out.add(url);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    public void addRecentServer(@Nullable String rawUrl) {
        String normalized = normalizeStoredServerUrl(rawUrl);
        if (normalized.isEmpty()) return;
        ArrayList<String> next = new ArrayList<>();
        next.add(normalized);
        for (String existing : recentServers()) {
            if (!normalized.equals(existing) && next.size() < 6) next.add(existing);
        }
        saveRecentServers(next);
    }

    public void clearRecentServers() {
        prefs.edit().remove(KEY_RECENT_SERVERS).apply();
    }

    @Nullable public String getToken() { return normalizeToken(prefs.getString(KEY_TOKEN, null)); }
    @Nullable public String getRefreshToken() { return normalizeToken(prefs.getString(KEY_REFRESH, null)); }
    @Nullable public String getUserId() { return prefs.getString(KEY_USER_ID, null); }
    @Nullable public String getUserEmail() { return normalizeEmail(prefs.getString(KEY_USER_EMAIL, null)); }
    @Nullable public String getUserName() { return normalizeName(prefs.getString(KEY_USER_NAME, null)); }
    @Nullable public String getLastLoginEmail() { return normalizeEmail(prefs.getString(KEY_LOGIN_EMAIL, null)); }
    public boolean isDemoUser() {
        String email = getUserEmail();
        return email != null && DEMO_EMAIL.equalsIgnoreCase(email);
    }

    private void clearSession(boolean clearRememberedCredentials) {
        SharedPreferences.Editor e = prefs.edit()
                .remove(KEY_TOKEN)
                .remove(KEY_REFRESH)
                .remove(KEY_EXPIRES_AT)
                .remove(KEY_USER_ID)
                .remove(KEY_USER_NAME)
                .remove(KEY_USER_EMAIL);
        if (clearRememberedCredentials) {
            e.remove(KEY_LOGIN_EMAIL).remove(KEY_LOGIN_PASSWORD);
        }
        e.apply();
    }

    public void logout() {
        // Session clear (used for auth expiry and recovery paths).
        clearSession(false);
    }

    public void logoutPreservingLoginEmail() {
        SharedPreferences.Editor e = prefs.edit()
                .remove(KEY_TOKEN)
                .remove(KEY_REFRESH)
                .remove(KEY_EXPIRES_AT)
                .remove(KEY_USER_ID)
                .remove(KEY_USER_NAME)
                .remove(KEY_USER_EMAIL)
                .remove(KEY_LOGIN_PASSWORD);
        e.apply();
    }

    public void logoutAndForgetCredentials() {
        // Manual sign-out: clear both session and remembered credentials.
        clearSession(true);
    }

    public void saveTokens(String token, @Nullable String refresh, @Nullable Long expiresIn, @Nullable String userId) {
        saveTokens(token, refresh, expiresIn, userId, null, null);
    }

    public void saveTokens(
            String token,
            @Nullable String refresh,
            @Nullable Long expiresIn,
            @Nullable String userId,
            @Nullable String userEmail
    ) {
        saveTokens(token, refresh, expiresIn, userId, userEmail, null);
    }

    public void saveTokens(
            String token,
            @Nullable String refresh,
            @Nullable Long expiresIn,
            @Nullable String userId,
            @Nullable String userEmail,
            @Nullable String userName
    ) {
        SharedPreferences.Editor e = prefs.edit();
        String tokenNorm = normalizeToken(token);
        if (tokenNorm != null) e.putString(KEY_TOKEN, tokenNorm);
        else e.remove(KEY_TOKEN);

        String refreshNorm = normalizeToken(refresh);
        // Keep existing refresh token when response omits/empties the field.
        if (refreshNorm != null) e.putString(KEY_REFRESH, refreshNorm);

        if (expiresIn != null) {
            long ts = System.currentTimeMillis() + TimeUnit.SECONDS.toMillis(expiresIn);
            e.putLong(KEY_EXPIRES_AT, ts);
        }
        if (userId != null) e.putString(KEY_USER_ID, userId);
        String nameNorm = normalizeName(userName);
        if (nameNorm != null) e.putString(KEY_USER_NAME, nameNorm);
        String emailNorm = normalizeEmail(userEmail);
        if (emailNorm != null) e.putString(KEY_USER_EMAIL, emailNorm);
        // Use commit for auth durability across abrupt process death after refresh/login.
        // Best effort fallback to apply if commit returns false.
        if (!e.commit()) e.apply();
    }

    public boolean isAuthenticated() { return getToken() != null && !getToken().isEmpty(); }

    public JSONObject authHeader() {
        JSONObject obj = new JSONObject();
        String t = getToken();
        if (t != null && !t.isEmpty()) {
            try { obj.put("Authorization", "Bearer " + t); } catch (Exception ignored) {}
        }
        return obj;
    }

    private void saveRememberedLogin(@Nullable String email, @Nullable String password) {
        String emailNorm = normalizeEmail(email);
        if (emailNorm == null || password == null || password.isEmpty()) return;
        SharedPreferences.Editor e = prefs.edit()
                .putString(KEY_LOGIN_EMAIL, emailNorm)
                .putString(KEY_LOGIN_PASSWORD, password);
        if (!e.commit()) e.apply();
    }

    private boolean tryAutoLoginWithSavedCredentials() throws IOException {
        if (serverUrl == null || serverUrl.trim().isEmpty()) return false;
        long nowElapsed = SystemClock.elapsedRealtime();
        if (nowElapsed - lastAutoLoginAttemptElapsedMs < AUTO_LOGIN_RETRY_INTERVAL_MS) {
            return false;
        }
        lastAutoLoginAttemptElapsedMs = nowElapsed;

        String email = normalizeEmail(prefs.getString(KEY_LOGIN_EMAIL, null));
        String password = prefs.getString(KEY_LOGIN_PASSWORD, null);
        if (email == null || password == null || password.isEmpty()) return false;
        try { android.util.Log.i("OpenPhotos", "[AUTH] auto-login attempt user=" + email); } catch (Exception ignored) {}

        JSONObject body = new JSONObject();
        try { body.put("email", email).put("password", password); } catch (Exception ignored) {}
        try (Response r = postJson("/api/auth/login", body)) {
            if (!r.isSuccessful()) {
                try { android.util.Log.w("OpenPhotos", "[AUTH] auto-login failed code=" + r.code()); } catch (Exception ignored) {}
                return false;
            }
            try {
                JSONObject json = new JSONObject(r.body().string());
                String token = normalizeToken(json.optString("token", null));
                String refresh = normalizeToken(json.optString("refresh_token", null));
                Long expiresIn = json.has("expires_in") ? json.getLong("expires_in") : null;
                JSONObject user = json.optJSONObject("user");
                String userId = user != null ? user.optString("user_id", null) : null;
                String userEmail = extractEmail(json, email);
                String userName = extractUserName(json, null);
                if (token == null || token.isEmpty()) return false;
                saveTokens(token, refresh, expiresIn, userId, userEmail, userName);
                lastRefreshSuccessElapsedMs = SystemClock.elapsedRealtime();
                try { android.util.Log.i("OpenPhotos", "[AUTH] auto-login success"); } catch (Exception ignored) {}
                return true;
            } catch (Exception e) {
                return false;
            }
        }
    }

    // --- HTTP helpers ---
    private Response postJson(String path, JSONObject body) throws IOException {
        return postJson(path, body, null);
    }

    private Response postJson(String path, JSONObject body, @Nullable String bearerToken) throws IOException {
        String baseUrl = resolveServerUrl(false, path);
        if (baseUrl == null || baseUrl.trim().isEmpty()) {
            throw new IOException("Server URL not set");
        }
        if (isLoopbackEndpointUrl(baseUrl)) {
            throw new IOException("On Android, localhost points to this device. Use the server's LAN IP or public URL.");
        }
        try {
            android.util.Log.i(
                    "OpenPhotos",
                    "[AUTH] POST path=" + path + " base=" + baseUrl + " public=" + publicServerUrl + " local=" + localServerUrl + " active=" + activeEndpoint
            );
        } catch (Exception ignored) {
        }
        String url = baseUrl + path;
        Request.Builder rb = new Request.Builder()
                .url(url)
                .post(RequestBody.create(body.toString(), MediaType.parse("application/json")));
        String bearer = normalizeToken(bearerToken);
        if (bearer != null) rb.header("Authorization", "Bearer " + bearer);
        Request rq = rb.build();
        return executeWithFallback(rq);
    }

    // --- Public API ---
    public void register(String name, String email, String password) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("name", name).put("email", email).put("password", password); } catch (Exception ignored) {}
        try (Response r = postJson("/api/auth/register", body)) {
            if (!r.isSuccessful()) throw new IOException("Register failed: " + r.code());
            try {
                JSONObject json = new JSONObject(r.body().string());
                String token = normalizeToken(json.optString("token", null));
                String refresh = normalizeToken(json.optString("refresh_token", null));
                Long expiresIn = json.has("expires_in") ? json.getLong("expires_in") : null;
                JSONObject user = json.optJSONObject("user");
                String userId = user != null ? user.optString("user_id", null) : null;
                String userEmail = extractEmail(json, normalizeEmail(email));
                String userName = extractUserName(json, name);
                if (token == null) throw new IOException("Bad register response: missing token");
                saveTokens(token, refresh, expiresIn, userId, userEmail, userName);
                saveRememberedLogin(userEmail != null ? userEmail : email, password);
            } catch (Exception e) { throw new IOException("Bad register response", e); }
        }
    }

    public void login(String email, String password) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("email", email).put("password", password); } catch (Exception ignored) {}
        try (Response r = postJson("/api/auth/login", body)) {
            if (!r.isSuccessful()) throw new IOException("Login failed: " + r.code());
            try {
                JSONObject json = new JSONObject(r.body().string());
                String token = normalizeToken(json.optString("token", null));
                String refresh = normalizeToken(json.optString("refresh_token", null));
                Long expiresIn = json.has("expires_in") ? json.getLong("expires_in") : null;
                JSONObject user = json.optJSONObject("user");
                String userId = user != null ? user.optString("user_id", null) : null;
                String userEmail = extractEmail(json, normalizeEmail(email));
                String userName = extractUserName(json, null);
                if (token == null) throw new IOException("Bad login response: missing token");
                saveTokens(token, refresh, expiresIn, userId, userEmail, userName);
                saveRememberedLogin(userEmail != null ? userEmail : email, password);
            } catch (Exception e) { throw new IOException("Bad login response", e); }
        }
    }

    public void changePassword(String newPassword, @Nullable String currentPassword) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("new_password", newPassword); if (currentPassword != null) body.put("current_password", currentPassword); } catch (Exception ignored) {}
        try (Response r = postJson("/api/auth/password/change", body)) {
            if (!r.isSuccessful()) throw new IOException("Password change failed: " + r.code());
            logoutAndForgetCredentials();
        }
    }

    private boolean shouldRefreshByExpiry() {
        long exp = prefs.getLong(KEY_EXPIRES_AT, 0L);
        long now = System.currentTimeMillis();
        return exp != 0L && now >= exp - TimeUnit.SECONDS.toMillis(30);
    }

    private boolean refreshInternal(boolean force, @Nullable String tokenUsedOnFailedRequest) throws IOException {
        // Another request may have already refreshed while this request was in-flight.
        // If token changed since the failed request was sent, caller can safely retry.
        String currentToken = normalizeToken(getToken());
        String failedToken = normalizeToken(tokenUsedOnFailedRequest);
        if (failedToken != null
                && currentToken != null
                && !currentToken.isEmpty()
                && !failedToken.equals(currentToken)) {
            return true;
        }
        // If another request just refreshed successfully, allow retry immediately
        // even when token text remains unchanged.
        if (failedToken != null
                && (SystemClock.elapsedRealtime() - lastRefreshSuccessElapsedMs) < 10_000L) {
            return true;
        }

        if (!force && !shouldRefreshByExpiry()) return false;

        String rt = normalizeToken(getRefreshToken());
        JSONObject body = new JSONObject();
        if (rt != null) {
            try { body.put("refresh_token", rt); } catch (Exception ignored) {}
        }
        String bearer = normalizeToken(currentToken);
        if (bearer == null) bearer = failedToken;
        if (rt == null && bearer == null) {
            // Session may already be cleared; attempt silent credential login fallback.
            return tryAutoLoginWithSavedCredentials();
        }
        try {
            android.util.Log.i(
                    "OpenPhotos",
                    "[AUTH] refresh force=" + force + " has_rt=" + (rt != null) + " has_bearer=" + (bearer != null)
            );
        } catch (Exception ignored) {}
        try (Response r = postJson("/api/auth/refresh", body, bearer)) {
            if (!r.isSuccessful()) {
                int code = r.code();
                try { android.util.Log.w("OpenPhotos", "[AUTH] refresh failed code=" + code); } catch (Exception ignored) {}
                if (code == 401) {
                    // Refresh token may be stale; try silent re-login with remembered credentials.
                    if (tryAutoLoginWithSavedCredentials()) {
                        return true;
                    }
                    // Keep remembered credentials for future retry, but clear active session tokens.
                    clearSession(false);
                    try { android.util.Log.w("OpenPhotos", "[AUTH] refresh unauthorized; session cleared"); } catch (Exception ignored) {}
                }
                return false;
            }
            try {
                JSONObject json = new JSONObject(r.body().string());
                String token = normalizeToken(json.optString("token", null));
                String refresh = normalizeToken(json.optString("refresh_token", null));
                Long expiresIn = json.has("expires_in") ? json.getLong("expires_in") : null;
                String userEmail = extractEmail(json, null);
                String userName = extractUserName(json, null);
                if (token == null || token.isEmpty()) return false;
                saveTokens(token, refresh, expiresIn, null, userEmail, userName);
                lastRefreshSuccessElapsedMs = SystemClock.elapsedRealtime();
                try { android.util.Log.i("OpenPhotos", "[AUTH] refresh success"); } catch (Exception ignored) {}
                return true;
            } catch (Exception e) { return false; }
        }
    }

    public boolean refreshIfNeeded() throws IOException {
        synchronized (this) {
            return refreshInternal(false, null);
        }
    }

    /**
     * Handles a 401 from an authenticated request.
     * Forces refresh when possible and also succeeds when another request has
     * already rotated token since this request was sent.
     */
    public boolean refreshAfterUnauthorized(@Nullable String tokenUsedOnFailedRequest) throws IOException {
        synchronized (this) {
            return refreshInternal(true, tokenUsedOnFailedRequest);
        }
    }

    private void handleConnectivityChanged() {
        updateNetworkState();
        new Thread(() -> resolveServerUrl(true, "connectivity-change")).start();
    }

    private void updateNetworkState() {
        boolean wifiOrEthernet = false;
        boolean hasPrivateOrLoopbackLanAddress = false;
        NetworkTransportKind nextTransport = NetworkTransportKind.OFFLINE;
        try {
            if (connectivityManager != null) {
                Network active = connectivityManager.getActiveNetwork();
                NetworkCapabilities nc = active != null ? connectivityManager.getNetworkCapabilities(active) : null;
                if (nc != null) {
                    boolean wifi = nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
                    boolean ethernet = nc.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET);
                    boolean cellular = nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR);
                    wifiOrEthernet = wifi || ethernet;
                    if (wifiOrEthernet) {
                        LinkProperties linkProperties = connectivityManager.getLinkProperties(active);
                        hasPrivateOrLoopbackLanAddress = linkPropertiesHasPrivateOrLoopbackAddress(linkProperties);
                    }
                    if (wifi) nextTransport = NetworkTransportKind.WIFI;
                    else if (ethernet) nextTransport = NetworkTransportKind.ETHERNET;
                    else if (cellular) nextTransport = NetworkTransportKind.CELLULAR;
                    else nextTransport = NetworkTransportKind.OTHER;
                }
            }
        } catch (Exception ignored) {
            nextTransport = NetworkTransportKind.OTHER;
        }
        currentUsesWifiOrEthernet = wifiOrEthernet;
        currentHasPrivateOrLoopbackLanAddress = wifiOrEthernet && hasPrivateOrLoopbackLanAddress;
        networkTransport = nextTransport;
        networkGeneration++;
    }

    private void persistNetworkProfile() {
        String persistedServerUrl = hasManualServerOverride
                ? initialResolvedBaseUrl(publicServerUrl, localServerUrl, autoSwitchEnabled, manualPreferredEndpoint)
                : serverUrl;
        prefs.edit()
                .putString(KEY_PUBLIC_SERVER_URL, publicServerUrl)
                .putString(KEY_LOCAL_SERVER_URL, localServerUrl)
                .putBoolean(KEY_AUTO_SWITCH, autoSwitchEnabled)
                .putString(KEY_MANUAL_PREFERRED, manualPreferredEndpoint.name())
                .putString(KEY_SERVER_URL, normalizeStoredServerUrl(persistedServerUrl))
                .apply();
    }

    private void applyConfiguredBaseUrls(
            @Nullable String publicUrl,
            @Nullable String localUrl,
            boolean refreshCurrentConnection,
            @Nullable String refreshReason
    ) {
        ConfiguredBaseUrls configuredBaseUrls = repartitionConfiguredBaseUrls(publicUrl, localUrl);
        hasManualServerOverride = false;
        manualServerOverrideBaseUrl = "";
        this.publicServerUrl = configuredBaseUrls.publicBaseUrl;
        this.localServerUrl = configuredBaseUrls.localBaseUrl;
        if (refreshCurrentConnection) {
            applyImmediateResolvedBaseUrl();
        }
        persistNetworkProfile();
        String preferredBaseUrl = configuredPreferredBaseUrl(configuredBaseUrls.publicBaseUrl, configuredBaseUrls.localBaseUrl);
        if (preferredBaseUrl != null && !preferredBaseUrl.isEmpty()) {
            addRecentServer(preferredBaseUrl);
        }
        try {
            android.util.Log.i(
                    "OpenPhotos",
                    "[NET] configured-urls-update public=" + publicServerUrl + " local=" + localServerUrl + " effective=" + serverUrl + " refresh=" + refreshCurrentConnection
            );
        } catch (Exception ignored) {
        }
        if (refreshCurrentConnection && refreshReason != null) {
            new Thread(() -> resolveServerUrl(true, refreshReason)).start();
        }
    }

    private void applyImmediateResolvedBaseUrl() {
        String immediate = initialResolvedBaseUrl(publicServerUrl, localServerUrl, autoSwitchEnabled, manualPreferredEndpoint);
        applyResolvedBaseUrl(immediate, endpointType(immediate, publicServerUrl, localServerUrl));
    }

    private void applyResolvedBaseUrl(@Nullable String baseUrl, ActiveEndpoint endpoint) {
        this.serverUrl = normalizeStoredServerUrl(baseUrl);
        this.activeEndpoint = endpoint;
        if (!hasManualServerOverride) {
            prefs.edit().putString(KEY_SERVER_URL, this.serverUrl).apply();
        }
    }

    private String preferredConfiguredBaseUrl() {
        if (publicServerUrl != null && !publicServerUrl.isEmpty()) return publicServerUrl;
        if (localServerUrl != null && !localServerUrl.isEmpty()) return localServerUrl;
        return serverUrl != null ? serverUrl : "";
    }

    private String resolveServerUrl(boolean forceProbe, @Nullable String reason) {
        synchronized (routeLock) {
            if (hasManualServerOverride) {
                return manualServerOverrideBaseUrl != null ? manualServerOverrideBaseUrl : "";
            }
            String configuredPublic = publicServerUrl != null ? publicServerUrl : "";
            String configuredLocal = localServerUrl != null ? localServerUrl : "";

            if (configuredPublic.isEmpty() && configuredLocal.isEmpty()) {
                applyResolvedBaseUrl("", ActiveEndpoint.NONE);
                return "";
            }

            if (!autoSwitchEnabled) {
                String resolved = manualResolvedBaseUrl(configuredPublic, configuredLocal, manualPreferredEndpoint);
                applyResolvedBaseUrl(resolved, endpointType(resolved, configuredPublic, configuredLocal));
                return serverUrl;
            }

            if (configuredLocal.isEmpty()) {
                applyResolvedBaseUrl(configuredPublic, ActiveEndpoint.PUBLIC);
                return serverUrl;
            }

            if (configuredPublic.isEmpty()) {
                applyResolvedBaseUrl(configuredLocal, ActiveEndpoint.LOCAL);
                return serverUrl;
            }

            if (!currentUsesWifiOrEthernet || !currentHasPrivateOrLoopbackLanAddress) {
                applyResolvedBaseUrl(configuredPublic, ActiveEndpoint.PUBLIC);
                return serverUrl;
            }

            long nowElapsed = SystemClock.elapsedRealtime();
            if (!forceProbe && lastProbeNetworkGeneration == networkGeneration && lastLocalProbeAtElapsedMs > 0L) {
                long ageMs = nowElapsed - lastLocalProbeAtElapsedMs;
                if (Boolean.TRUE.equals(lastLocalProbeSucceeded) && ageMs < ROUTE_DECISION_TTL_MS) {
                    applyResolvedBaseUrl(configuredLocal, ActiveEndpoint.LOCAL);
                    return serverUrl;
                }
                if (Boolean.FALSE.equals(lastLocalProbeSucceeded) && ageMs < LOCAL_PROBE_FAILURE_BACKOFF_MS) {
                    applyResolvedBaseUrl(configuredPublic, ActiveEndpoint.PUBLIC);
                    return serverUrl;
                }
            }

            ProbeResult probe = pingBaseUrl(configuredLocal);
            lastLocalProbeSucceeded = probe.success;
            lastLocalProbeMessage = (reason != null ? reason + ": " : "") + probe.message;
            lastLocalProbeAtElapsedMs = nowElapsed;
            lastProbeNetworkGeneration = networkGeneration;
            applyResolvedBaseUrl(probe.success ? configuredLocal : configuredPublic, probe.success ? ActiveEndpoint.LOCAL : ActiveEndpoint.PUBLIC);
            return serverUrl;
        }
    }

    private ProbeResult pingBaseUrl(@Nullable String baseUrl) {
        String normalized = normalizeStoredServerUrl(baseUrl);
        if (normalized.isEmpty()) {
            return new ProbeResult(false, "Invalid URL");
        }
        if (isLoopbackEndpointUrl(normalized)) {
            return new ProbeResult(false, "On Android, localhost points to this device. Use the server's LAN IP or public URL.");
        }
        OkHttpClient probeClient = http.newBuilder()
                .connectTimeout(1500, TimeUnit.MILLISECONDS)
                .readTimeout(1500, TimeUnit.MILLISECONDS)
                .writeTimeout(1500, TimeUnit.MILLISECONDS)
                .callTimeout(1500, TimeUnit.MILLISECONDS)
                .build();
        Request request = new Request.Builder().url(normalized + "/ping").get().build();
        try (Response response = probeClient.newCall(request).execute()) {
            String body = response.body() != null ? response.body().string() : "";
            if (response.isSuccessful()) {
                String message = body == null || body.trim().isEmpty()
                        ? "Success (" + response.code() + ")"
                        : "Success (" + response.code() + "): " + body.trim();
                return new ProbeResult(true, message);
            }
            String message = body == null || body.trim().isEmpty()
                    ? "HTTP " + response.code()
                    : "HTTP " + response.code() + ": " + body.trim();
            return new ProbeResult(false, message);
        } catch (IOException e) {
            return new ProbeResult(false, e.getMessage() != null ? e.getMessage() : "Connection failed");
        }
    }

    Response executeWithFallback(Request request) throws IOException {
        try {
            return http.newCall(request).execute();
        } catch (IOException e) {
            Request fallback = buildFallbackRequest(request, e);
            if (fallback == null) throw e;
            return http.newCall(fallback).execute();
        }
    }

    @Nullable
    Request buildFallbackRequest(Request request, IOException error) {
        if (!shouldFallbackToPublic(error)) return null;
        String localPrefix = normalizeStoredServerUrl(localServerUrl);
        String publicPrefix = normalizeStoredServerUrl(publicServerUrl);
        if (localPrefix.isEmpty() || publicPrefix.isEmpty()) return null;
        String requestUrl = request.url().toString();
        if (!requestUrl.startsWith(localPrefix)) return null;
        String suffix = requestUrl.substring(localPrefix.length());
        Request fallback = request.newBuilder().url(publicPrefix + suffix).build();
        lastLocalProbeSucceeded = false;
        lastLocalProbeMessage = error.getMessage() != null ? error.getMessage() : "Connection failed";
        lastLocalProbeAtElapsedMs = SystemClock.elapsedRealtime();
        lastProbeNetworkGeneration = networkGeneration;
        applyResolvedBaseUrl(publicPrefix, ActiveEndpoint.PUBLIC);
        return fallback;
    }

    private boolean shouldFallbackToPublic(IOException error) {
        return error.getMessage() != null || error instanceof IOException;
    }

    public static final class ProbeResult {
        public final boolean success;
        public final String message;

        public ProbeResult(boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }

    @Nullable
    private static String normalizeToken(@Nullable String value) {
        if (value == null) return null;
        String t = value.trim();
        if (t.isEmpty()) return null;
        if ("null".equalsIgnoreCase(t)) return null;
        return t;
    }

    @Nullable
    private static String normalizeEmail(@Nullable String value) {
        if (value == null) return null;
        String t = value.trim().toLowerCase(Locale.US);
        if (t.isEmpty() || "null".equals(t)) return null;
        return t;
    }

    @Nullable
    private static String normalizeName(@Nullable String value) {
        if (value == null) return null;
        String t = value.trim();
        if (t.isEmpty() || "null".equalsIgnoreCase(t)) return null;
        return t;
    }

    @Nullable
    private static String extractEmail(JSONObject response, @Nullable String fallback) {
        try {
            JSONObject user = response.optJSONObject("user");
            if (user != null) {
                String e1 = normalizeEmail(user.optString("email", null));
                if (e1 != null) return e1;
                String e2 = normalizeEmail(user.optString("user_email", null));
                if (e2 != null) return e2;
            }
            String top = normalizeEmail(response.optString("email", null));
            if (top != null) return top;
        } catch (Exception ignored) {
        }
        return fallback;
    }

    @Nullable
    private static String extractUserName(JSONObject response, @Nullable String fallback) {
        try {
            JSONObject user = response.optJSONObject("user");
            if (user != null) {
                String n1 = normalizeName(user.optString("name", null));
                if (n1 != null) return n1;
                String n2 = normalizeName(user.optString("display_name", null));
                if (n2 != null) return n2;
                String n3 = normalizeName(user.optString("user_name", null));
                if (n3 != null) return n3;
            }
            String top = normalizeName(response.optString("name", null));
            if (top != null) return top;
        } catch (Exception ignored) {
        }
        return normalizeName(fallback);
    }

    public static final class ParsedBaseUrl {
        public final String scheme;
        public final String host;
        @Nullable public final Integer port;

        public ParsedBaseUrl(String scheme, String host, @Nullable Integer port) {
            this.scheme = scheme;
            this.host = host;
            this.port = port;
        }
    }

    public static final class ConfiguredBaseUrls {
        public final String publicBaseUrl;
        public final String localBaseUrl;

        public ConfiguredBaseUrls(String publicBaseUrl, String localBaseUrl) {
            this.publicBaseUrl = publicBaseUrl;
            this.localBaseUrl = localBaseUrl;
        }
    }

    public static final class ServerConfig {
        public final String scheme;
        public final String host;
        public final int port;

        public ServerConfig(String scheme, String host, int port) {
            this.scheme = scheme;
            this.host = host;
            this.port = port;
        }
    }

    public static String normalizeHost(@Nullable String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.startsWith("[") && trimmed.endsWith("]") && trimmed.length() > 2) {
            return trimmed.substring(1, trimmed.length() - 1);
        }
        return trimmed;
    }

    @Nullable
    public static ParsedBaseUrl parseBaseUrl(@Nullable String raw) {
        if (raw == null) return null;
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return null;
        String withScheme = trimmed.contains("://") ? trimmed : (DEFAULT_SERVER_SCHEME + "://" + trimmed);
        try {
            URI uri = new URI(withScheme);
            String scheme = uri.getScheme() != null ? uri.getScheme().toLowerCase(Locale.US) : DEFAULT_SERVER_SCHEME;
            String host = uri.getHost();
            if (host == null || host.trim().isEmpty() || !isValidParsedHost(host)) return null;
            Integer port = uri.getPort() > 0 ? uri.getPort() : null;
            return new ParsedBaseUrl(scheme, host, port);
        } catch (URISyntaxException e) {
            return null;
        }
    }

    @Nullable
    public static String buildBaseUrl(@Nullable String scheme, @Nullable String host, @Nullable Integer port) {
        String schemeNorm = scheme == null ? "" : scheme.toLowerCase(Locale.US).replace("://", "").trim();
        if (schemeNorm.isEmpty()) schemeNorm = DEFAULT_SERVER_SCHEME;
        String hostNorm = normalizeHost(host);
        if (hostNorm.isEmpty() || !isValidParsedHost(hostNorm)) return null;
        try {
            URI uri = new URI(schemeNorm, null, hostNorm, port != null ? port : -1, null, null, null);
            String out = uri.toString();
            while (out.endsWith("/")) out = out.substring(0, out.length() - 1);
            return out;
        } catch (URISyntaxException e) {
            return null;
        }
    }

    public static String initialResolvedBaseUrl(
            @Nullable String publicBaseUrl,
            @Nullable String localBaseUrl,
            boolean autoSwitchEnabled,
            @Nullable ManualPreferredEndpoint manualPreferredEndpoint
    ) {
        String normalizedPublic = normalizeStoredServerUrlStatic(publicBaseUrl);
        String normalizedLocal = normalizeStoredServerUrlStatic(localBaseUrl);
        if (autoSwitchEnabled) {
            return !normalizedPublic.isEmpty() ? normalizedPublic : normalizedLocal;
        }
        return manualResolvedBaseUrl(normalizedPublic, normalizedLocal, manualPreferredEndpoint);
    }

    @Nullable
    public static String configuredPreferredBaseUrl(@Nullable String publicBaseUrl, @Nullable String localBaseUrl) {
        String normalizedPublic = normalizeStoredServerUrlStatic(publicBaseUrl);
        if (!normalizedPublic.isEmpty()) return normalizedPublic;
        return normalizeStoredServerUrlStatic(localBaseUrl);
    }

    public static ConfiguredBaseUrls repartitionConfiguredBaseUrls(
            @Nullable String publicBaseUrl,
            @Nullable String localBaseUrl
    ) {
        String normalizedPublic = normalizeStoredServerUrlStatic(publicBaseUrl);
        String normalizedLocal = normalizeStoredServerUrlStatic(localBaseUrl);

        String resolvedPublic = !normalizedPublic.isEmpty() && !isLocalEndpointUrl(normalizedPublic)
                ? normalizedPublic
                : "";
        String resolvedLocal = !normalizedLocal.isEmpty() && isLocalEndpointUrl(normalizedLocal)
                ? normalizedLocal
                : "";

        if (resolvedPublic.isEmpty() && !normalizedLocal.isEmpty() && !isLocalEndpointUrl(normalizedLocal)) {
            resolvedPublic = normalizedLocal;
        }
        if (resolvedLocal.isEmpty() && !normalizedPublic.isEmpty() && isLocalEndpointUrl(normalizedPublic)) {
            resolvedLocal = normalizedPublic;
        }

        return new ConfiguredBaseUrls(resolvedPublic, resolvedLocal);
    }

    public static boolean isLocalEndpointUrl(@Nullable String baseUrl) {
        ParsedBaseUrl parsed = parseBaseUrl(baseUrl);
        return parsed != null && isLocalHost(parsed.host);
    }

    public static boolean isLoopbackEndpointUrl(@Nullable String baseUrl) {
        ParsedBaseUrl parsed = parseBaseUrl(baseUrl);
        return parsed != null && isLoopbackHost(parsed.host);
    }

    public static boolean isLocalHost(@Nullable String rawHost) {
        if (rawHost == null) return false;
        String host = normalizeHost(rawHost).toLowerCase(Locale.US);
        if (host.isEmpty()) return false;
        if ("localhost".equals(host)
                || "::1".equals(host)
                || "0:0:0:0:0:0:0:1".equals(host)
                || host.endsWith(".local")) {
            return true;
        }

        int[] ipv4 = ipv4Octets(host);
        if (ipv4 != null) {
            int first = ipv4[0];
            int second = ipv4[1];
            if (first == 10 || first == 127 || (first == 192 && second == 168)) {
                return true;
            }
            if (first == 172 && second >= 16 && second <= 31) {
                return true;
            }
            if (first == 169 && second == 254) {
                return true;
            }
        }

        if (host.contains(":")) {
            return host.startsWith("fe80:")
                    || host.startsWith("fc")
                    || host.startsWith("fd");
        }

        return false;
    }

    public static boolean isLoopbackHost(@Nullable String rawHost) {
        if (rawHost == null) return false;
        String host = normalizeHost(rawHost).toLowerCase(Locale.US);
        if (host.isEmpty()) return false;
        if ("localhost".equals(host)
                || "::1".equals(host)
                || "0:0:0:0:0:0:0:1".equals(host)) {
            return true;
        }
        int[] ipv4 = ipv4Octets(host);
        return ipv4 != null && ipv4[0] == 127;
    }

    @Nullable
    private static int[] ipv4Octets(String host) {
        String[] parts = host.split("\\.", -1);
        if (parts.length != 4) return null;
        int[] octets = new int[4];
        for (int i = 0; i < parts.length; i++) {
            try {
                int octet = Integer.parseInt(parts[i]);
                if (octet < 0 || octet > 255) return null;
                octets[i] = octet;
            } catch (NumberFormatException e) {
                return null;
            }
        }
        return octets;
    }

    private static boolean isValidParsedHost(@Nullable String rawHost) {
        if (rawHost == null) return false;
        String host = normalizeHost(rawHost);
        if (host.isEmpty()) return false;
        if (host.contains(":")) return true;
        boolean numericOrDotsOnly = true;
        for (int i = 0; i < host.length(); i++) {
            char c = host.charAt(i);
            if (!(Character.isDigit(c) || c == '.')) {
                numericOrDotsOnly = false;
                break;
            }
        }
        if (numericOrDotsOnly) {
            return ipv4Octets(host) != null;
        }
        return isValidDnsHost(host);
    }

    private static boolean isValidDnsHost(String host) {
        String[] labels = host.split("\\.", -1);
        if (labels.length == 0) return false;
        for (String label : labels) {
            if (label.isEmpty() || label.length() > 63) return false;
            char first = label.charAt(0);
            char last = label.charAt(label.length() - 1);
            if (!Character.isLetterOrDigit(first) || !Character.isLetterOrDigit(last)) {
                return false;
            }
            for (int i = 0; i < label.length(); i++) {
                char c = label.charAt(i);
                if (!(Character.isLetterOrDigit(c) || c == '-')) {
                    return false;
                }
            }
        }
        return true;
    }

    private static boolean linkPropertiesHasPrivateOrLoopbackAddress(@Nullable LinkProperties linkProperties) {
        if (linkProperties == null) return false;
        for (LinkAddress linkAddress : linkProperties.getLinkAddresses()) {
            InetAddress address = linkAddress.getAddress();
            if (isPrivateOrLoopbackAddress(address)) {
                return true;
            }
        }
        return false;
    }

    private static boolean isPrivateOrLoopbackAddress(@Nullable InetAddress address) {
        if (address == null) return false;
        if (address.isLoopbackAddress() || address.isSiteLocalAddress() || address.isLinkLocalAddress()) {
            return true;
        }
        if (address instanceof Inet6Address) {
            byte[] bytes = address.getAddress();
            return bytes.length > 0 && (((bytes[0] & 0xff) & 0xfe) == 0xfc);
        }
        return false;
    }

    public static String manualResolvedBaseUrl(
            @Nullable String publicBaseUrl,
            @Nullable String localBaseUrl,
            @Nullable ManualPreferredEndpoint manualPreferredEndpoint
    ) {
        String normalizedPublic = normalizeStoredServerUrlStatic(publicBaseUrl);
        String normalizedLocal = normalizeStoredServerUrlStatic(localBaseUrl);
        ManualPreferredEndpoint preferred = manualPreferredEndpoint != null ? manualPreferredEndpoint : ManualPreferredEndpoint.PUBLIC;
        if (preferred == ManualPreferredEndpoint.LOCAL) {
            return !normalizedLocal.isEmpty() ? normalizedLocal : normalizedPublic;
        }
        return !normalizedPublic.isEmpty() ? normalizedPublic : normalizedLocal;
    }

    public static ActiveEndpoint endpointType(
            @Nullable String baseUrl,
            @Nullable String publicBaseUrl,
            @Nullable String localBaseUrl
    ) {
        String normalizedBase = normalizeStoredServerUrlStatic(baseUrl);
        if (normalizedBase.isEmpty()) return ActiveEndpoint.NONE;
        if (normalizedBase.equals(normalizeStoredServerUrlStatic(localBaseUrl))) return ActiveEndpoint.LOCAL;
        if (normalizedBase.equals(normalizeStoredServerUrlStatic(publicBaseUrl))) return ActiveEndpoint.PUBLIC;
        return ActiveEndpoint.NONE;
    }

    private String normalizeStoredServerUrl(@Nullable String raw) {
        return normalizeStoredServerUrlStatic(raw);
    }

    private static String normalizeStoredServerUrlStatic(@Nullable String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return "";
        ParsedBaseUrl parsed = parseBaseUrl(trimmed);
        if (parsed == null) return "";
        String built = buildBaseUrl(parsed.scheme, parsed.host, parsed.port);
        return built != null ? built : "";
    }

    public static boolean shouldRejectLoopbackServer(@Nullable String raw) {
        return isLoopbackEndpointUrl(raw);
    }

    private void saveRecentServers(List<String> urls) {
        JSONArray arr = new JSONArray();
        for (String url : urls) arr.put(url);
        prefs.edit().putString(KEY_RECENT_SERVERS, arr.toString()).apply();
    }
}
