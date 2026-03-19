package ca.openphotos.android.core;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import androidx.annotation.Nullable;
import androidx.security.crypto.EncryptedSharedPreferences;
import androidx.security.crypto.MasterKey;

import org.json.JSONObject;
import org.json.JSONArray;

import java.io.IOException;
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
    private static final String KEY_RECENT_SERVERS = "recent_servers";
    private static final String KEY_LOGIN_EMAIL = "login_email";
    private static final String KEY_LOGIN_PASSWORD = "login_password";
    private static final long AUTO_LOGIN_RETRY_INTERVAL_MS = 30_000L;

    private static volatile AuthManager INSTANCE;

    private final Context app;
    private final SharedPreferences prefs;
    private final OkHttpClient http;

    private String serverUrl;
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
        String saved = prefs.getString(KEY_SERVER_URL, null);
        if (saved != null) {
            this.serverUrl = normalizeStoredServerUrl(saved);
        } else {
            this.serverUrl = "";
        }
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
    public void setServerUrl(String url) {
        String normalized = normalizeStoredServerUrl(url);
        this.serverUrl = normalized;
        prefs.edit().putString(KEY_SERVER_URL, normalized).apply();
    }

    public ServerConfig currentServerConfig() {
        ParsedBaseUrl parsed = parseBaseUrl(serverUrl);
        if (parsed == null) {
            return new ServerConfig(DEFAULT_SERVER_SCHEME, "", DEFAULT_SERVER_PORT);
        }
        return new ServerConfig(parsed.scheme, parsed.host, parsed.port != null ? parsed.port : DEFAULT_SERVER_PORT);
    }

    public boolean setServerConfig(String scheme, String host, @Nullable Integer port) {
        if (host == null || host.trim().isEmpty()) {
            setServerUrl("");
            return true;
        }
        String built = buildBaseUrl(scheme, host, port);
        if (built == null) return false;
        setServerUrl(built);
        return true;
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
        if (serverUrl == null || serverUrl.trim().isEmpty()) {
            throw new IOException("Server URL not set");
        }
        String url = serverUrl + path;
        Request.Builder rb = new Request.Builder()
                .url(url)
                .post(RequestBody.create(body.toString(), MediaType.parse("application/json")));
        String bearer = normalizeToken(bearerToken);
        if (bearer != null) rb.header("Authorization", "Bearer " + bearer);
        Request rq = rb.build();
        return http.newCall(rq).execute();
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
            if (host == null || host.trim().isEmpty()) return null;
            int port = uri.getPort() > 0 ? uri.getPort() : DEFAULT_SERVER_PORT;
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
        if (hostNorm.isEmpty()) return null;
        int resolvedPort = port != null ? port : DEFAULT_SERVER_PORT;
        try {
            URI uri = new URI(schemeNorm, null, hostNorm, resolvedPort, null, null, null);
            String out = uri.toString();
            while (out.endsWith("/")) out = out.substring(0, out.length() - 1);
            return out;
        } catch (URISyntaxException e) {
            return null;
        }
    }

    private String normalizeStoredServerUrl(@Nullable String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return "";
        ParsedBaseUrl parsed = parseBaseUrl(trimmed);
        if (parsed == null) return trimmed;
        String built = buildBaseUrl(parsed.scheme, parsed.host, parsed.port);
        return built != null ? built : trimmed;
    }

    private void saveRecentServers(List<String> urls) {
        JSONArray arr = new JSONArray();
        for (String url : urls) arr.put(url);
        prefs.edit().putString(KEY_RECENT_SERVERS, arr.toString()).apply();
    }
}
