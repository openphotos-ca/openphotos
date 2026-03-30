package ca.openphotos.android.ui;

import android.content.res.ColorStateList;
import android.graphics.Color;
import android.os.Bundle;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.KeyEvent;
import android.view.LayoutInflater;
import android.view.Menu;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.PopupMenu;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.navigation.NavController;
import androidx.navigation.fragment.NavHostFragment;

import com.google.android.material.bottomnavigation.BottomNavigationView;
import com.google.android.material.button.MaterialButton;

import java.io.IOException;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

public class ServerLoginFragment extends Fragment {
    private enum AuthMode { LOGIN, REGISTER }

    private static final String DEMO_HOST = "demo.openphotos.ca";

    private AuthManager auth;
    private OkHttpClient httpClient;

    private ImageButton btnClose;
    private TextView tvTitle;
    private MaterialButton btnModeLogin;
    private MaterialButton btnModeRegister;
    private MaterialButton btnScheme;
    private MaterialButton btnRecentServers;
    private MaterialButton btnTestConnection;
    private EditText etHost;
    private EditText etPort;
    private View rowFullName;
    private EditText etFullName;
    private EditText etEmail;
    private EditText etPassword;
    private TextView tvServerFeedback;
    private TextView tvError;
    private ProgressBar progress;
    private MaterialButton btnSubmit;

    private AuthMode mode = AuthMode.LOGIN;
    private String selectedScheme = AuthManager.DEFAULT_SERVER_SCHEME;
    private boolean suppressFieldCallbacks = false;
    @Nullable private String serverValidationMessage;
    @Nullable private String serverTestMessage;
    private boolean serverTestSuccess = false;
    private boolean isLoading = false;
    private boolean isTesting = false;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_server_login, container, false);
        auth = AuthManager.get(requireContext());
        httpClient = new OkHttpClient.Builder()
                .readTimeout(8, TimeUnit.SECONDS)
                .writeTimeout(8, TimeUnit.SECONDS)
                .build();

        bindViews(root);
        bindActions();
        loadFromAuth();
        updateModeUi();
        validateAndPersistServer();
        updateFormState();
        return root;
    }

    private void bindViews(@NonNull View root) {
        btnClose = root.findViewById(R.id.btn_login_close);
        tvTitle = root.findViewById(R.id.tv_login_title);
        btnModeLogin = root.findViewById(R.id.btn_login_mode_login);
        btnModeRegister = root.findViewById(R.id.btn_login_mode_register);
        btnScheme = root.findViewById(R.id.btn_login_scheme);
        btnRecentServers = root.findViewById(R.id.btn_login_recent_servers);
        btnTestConnection = root.findViewById(R.id.btn_login_test_connection);
        etHost = root.findViewById(R.id.et_login_host);
        etPort = root.findViewById(R.id.et_login_port);
        rowFullName = root.findViewById(R.id.row_login_full_name);
        etFullName = root.findViewById(R.id.et_login_full_name);
        etEmail = root.findViewById(R.id.et_login_email);
        etPassword = root.findViewById(R.id.et_login_password);
        tvServerFeedback = root.findViewById(R.id.tv_login_server_feedback);
        tvError = root.findViewById(R.id.tv_login_error);
        progress = root.findViewById(R.id.progress_login);
        btnSubmit = root.findViewById(R.id.btn_login_submit);

        etPassword.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        btnRecentServers.setText("Advanced Network");
        btnTestConnection.setText("Refresh Route");
    }

    private void bindActions() {
        btnClose.setOnClickListener(v -> closeScreen());
        btnModeLogin.setOnClickListener(v -> setMode(AuthMode.LOGIN));
        btnModeRegister.setOnClickListener(v -> setMode(AuthMode.REGISTER));
        btnScheme.setOnClickListener(v -> showSchemeMenu());
        btnRecentServers.setOnClickListener(v -> {
            auth.clearManualServerOverride();
            NavHostFragment.findNavController(this).navigate(R.id.networkSettingsFragment);
        });
        btnTestConnection.setOnClickListener(v -> {
            if (!validateAndPersistServer()) {
                updateFormState();
                return;
            }
            auth.refreshNetworkRouting();
            loadFromAuth();
            testConnection();
        });
        btnSubmit.setOnClickListener(v -> submitAuth());

        etHost.addTextChangedListener(new SimpleTextWatcher() {
            @Override
            public void afterTextChanged(Editable s) {
                if (suppressFieldCallbacks) return;
                clearAuthError();
                clearServerTestMessage();
                String hostValue = s == null ? "" : s.toString();
                if (hostValue.contains("://")) {
                    AuthManager.ParsedBaseUrl parsed = AuthManager.parseBaseUrl(hostValue);
                    if (parsed != null) {
                        applyParsedBaseUrl(parsed);
                        return;
                    }
                }
                if (fieldText(etPort).trim().isEmpty()) {
                    HostPort split = splitHostPort(hostValue);
                    if (split != null) {
                        applyHostPortSplit(split);
                        return;
                    }
                }
                applyDemoDefaultsIfNeeded();
                validateAndPersistServer();
                updateFormState();
            }
        });

        etPort.addTextChangedListener(new SimpleTextWatcher() {
            @Override
            public void afterTextChanged(Editable s) {
                if (suppressFieldCallbacks) return;
                clearAuthError();
                clearServerTestMessage();
                applyDemoDefaultsIfNeeded();
                validateAndPersistServer();
                updateFormState();
            }
        });

        TextWatcher userWatcher = new SimpleTextWatcher() {
            @Override
            public void afterTextChanged(Editable s) {
                clearAuthError();
                updateFormState();
            }
        };
        etFullName.addTextChangedListener(userWatcher);
        etEmail.addTextChangedListener(userWatcher);
        etPassword.addTextChangedListener(userWatcher);
        etPassword.setOnEditorActionListener((v, actionId, event) -> {
            boolean enter = event != null && event.getAction() == KeyEvent.ACTION_DOWN && event.getKeyCode() == KeyEvent.KEYCODE_ENTER;
            if (actionId == EditorInfo.IME_ACTION_DONE || enter) {
                if (btnSubmit.isEnabled()) submitAuth();
                return true;
            }
            return false;
        });
    }

    private void loadFromAuth() {
        AuthManager.ServerConfig cfg = auth.currentServerConfig();
        suppressFieldCallbacks = true;
        selectedScheme = cfg.scheme != null && !cfg.scheme.trim().isEmpty()
                ? cfg.scheme
                : AuthManager.DEFAULT_SERVER_SCHEME;
        String displayHost = cfg.host;
        int displayPort = cfg.port;
        if ((displayHost == null || displayHost.trim().isEmpty()) && auth.getServerUrl() != null) {
            AuthManager.ParsedBaseUrl effective = AuthManager.parseBaseUrl(auth.getServerUrl());
            if (effective != null) {
                if (effective.scheme != null && !effective.scheme.trim().isEmpty()) {
                    selectedScheme = effective.scheme;
                }
                displayHost = effective.host;
                displayPort = effective.port != null ? effective.port : AuthManager.DEFAULT_SERVER_PORT;
            }
        }
        etHost.setText(displayHost);
        etPort.setText(String.valueOf(displayPort));
        if (fieldText(etEmail).trim().isEmpty()) {
            String lastLoginEmail = auth.getLastLoginEmail();
            if (lastLoginEmail != null && !lastLoginEmail.trim().isEmpty()) {
                etEmail.setText(lastLoginEmail);
                etEmail.setSelection(etEmail.getText() != null ? etEmail.getText().length() : 0);
            }
        }
        suppressFieldCallbacks = false;
        updateSchemeButton();
        applyDemoDefaultsIfNeeded();
    }

    private void setMode(@NonNull AuthMode nextMode) {
        mode = nextMode;
        clearAuthError();
        applyDemoDefaultsIfNeeded();
        updateModeUi();
        updateFormState();
    }

    private void updateModeUi() {
        boolean register = mode == AuthMode.REGISTER;
        tvTitle.setText(register ? "Create Account" : "Log In");
        rowFullName.setVisibility(register ? View.VISIBLE : View.GONE);
        btnSubmit.setText(isLoading ? "Working…" : (register ? "Create Account" : "Log In"));
        applySegmentedState(btnModeLogin, !register);
        applySegmentedState(btnModeRegister, register);
    }

    private void applySegmentedState(@NonNull MaterialButton button, boolean selected) {
        button.setTextColor(ContextCompat.getColor(requireContext(), selected ? R.color.app_text_primary : R.color.app_text_secondary));
        button.setBackgroundTintList(ColorStateList.valueOf(selected
                ? ContextCompat.getColor(requireContext(), R.color.app_segmented_indicator)
                : Color.TRANSPARENT));
        button.setStrokeWidth(selected ? dpToPx(1) : 0);
        if (selected) {
            button.setStrokeColor(ColorStateList.valueOf(ContextCompat.getColor(requireContext(), R.color.app_card_stroke)));
        } else {
            button.setStrokeColor(ColorStateList.valueOf(Color.TRANSPARENT));
        }
    }

    private void updateSchemeButton() {
        String label = (selectedScheme == null || selectedScheme.trim().isEmpty() ? AuthManager.DEFAULT_SERVER_SCHEME : selectedScheme) + "://";
        btnScheme.setText(label);
    }

    private void showSchemeMenu() {
        PopupMenu menu = new PopupMenu(requireContext(), btnScheme);
        menu.getMenu().add(Menu.NONE, 1, 1, "http://");
        menu.getMenu().add(Menu.NONE, 2, 2, "https://");
        menu.setOnMenuItemClickListener(item -> {
            selectedScheme = item.getItemId() == 2 ? "https" : "http";
            applyDefaultPortForSchemeChange(selectedScheme);
            updateSchemeButton();
            clearServerTestMessage();
            validateAndPersistServer();
            updateFormState();
            return true;
        });
        menu.show();
    }

    private void showRecentServersMenu() {
        List<String> recents = auth.recentServers();
        PopupMenu menu = new PopupMenu(requireContext(), btnRecentServers);
        if (recents.isEmpty()) {
            menu.getMenu().add(Menu.NONE, 1, 1, "No recent servers").setEnabled(false);
        } else {
            int id = 100;
            for (String url : recents) {
                menu.getMenu().add(Menu.NONE, id++, id, url);
            }
            menu.getMenu().add(Menu.NONE, 2, id + 1, "Clear Recents");
        }
        menu.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == 2) {
                auth.clearRecentServers();
                Toast.makeText(requireContext(), "Recent servers cleared", Toast.LENGTH_SHORT).show();
                return true;
            }
            String title = item.getTitle() != null ? item.getTitle().toString() : "";
            if (title.isEmpty() || "No recent servers".equals(title)) return true;
            AuthManager.ParsedBaseUrl parsed = AuthManager.parseBaseUrl(title);
            if (parsed != null) {
                applyParsedBaseUrl(parsed);
            }
            return true;
        });
        menu.show();
    }

    private void applyParsedBaseUrl(@NonNull AuthManager.ParsedBaseUrl parsed) {
        suppressFieldCallbacks = true;
        selectedScheme = parsed.scheme;
        etHost.setText(parsed.host);
        int port = parsed.port != null ? parsed.port : AuthManager.DEFAULT_SERVER_PORT;
        etPort.setText(String.valueOf(port));
        suppressFieldCallbacks = false;
        updateSchemeButton();
        clearServerTestMessage();
        applyDemoDefaultsIfNeeded();
        validateAndPersistServer();
        updateFormState();
    }

    private void applyHostPortSplit(@NonNull HostPort split) {
        suppressFieldCallbacks = true;
        etHost.setText(split.host);
        etHost.setSelection(etHost.getText() != null ? etHost.getText().length() : 0);
        etPort.setText(split.port);
        etPort.setSelection(etPort.getText() != null ? etPort.getText().length() : 0);
        suppressFieldCallbacks = false;
        applyDemoDefaultsIfNeeded();
        validateAndPersistServer();
        updateFormState();
    }

    private void applyDefaultPortForSchemeChange(@NonNull String nextScheme) {
        if (!"https".equalsIgnoreCase(nextScheme)) return;
        if (!fieldText(etPort).trim().isEmpty()) return;
        suppressFieldCallbacks = true;
        etPort.setText("443");
        etPort.setSelection(etPort.getText() != null ? etPort.getText().length() : 0);
        suppressFieldCallbacks = false;
    }

    private void applyDemoDefaultsIfNeeded() {
        String normalizedHost = AuthManager.normalizeHost(fieldText(etHost)).toLowerCase(Locale.US);
        if (!DEMO_HOST.equals(normalizedHost)) return;

        suppressFieldCallbacks = true;
        selectedScheme = "https";
        updateSchemeButton();
        if (!"443".equals(fieldText(etPort))) {
            etPort.setText("443");
            etPort.setSelection(etPort.getText() != null ? etPort.getText().length() : 0);
        }
        if (!"demo@openphotos.ca".equalsIgnoreCase(fieldText(etEmail))) {
            etEmail.setText("demo@openphotos.ca");
            etEmail.setSelection(etEmail.getText() != null ? etEmail.getText().length() : 0);
        }
        if (!"demo".equals(fieldText(etPassword))) {
            etPassword.setText("demo");
            etPassword.setSelection(etPassword.getText() != null ? etPassword.getText().length() : 0);
        }
        suppressFieldCallbacks = false;

        if (mode != AuthMode.LOGIN) {
            mode = AuthMode.LOGIN;
            updateModeUi();
        }
    }

    private boolean validateAndPersistServer() {
        String hostTrim = fieldText(etHost).trim();
        String portTrim = fieldText(etPort).trim();
        String message = null;
        Integer portInt = null;

        if (hostTrim.isEmpty()) {
            message = "Enter an IP/hostname/IPv6 address.";
        } else if (containsWhitespace(hostTrim)) {
            message = "Host cannot contain spaces.";
        }

        if (message == null && !portTrim.isEmpty()) {
            try {
                int parsedPort = Integer.parseInt(portTrim);
                if (parsedPort < 1 || parsedPort > 65535) {
                    message = "Port must be between 1 and 65535.";
                } else {
                    portInt = parsedPort;
                }
            } catch (NumberFormatException ignored) {
                message = "Port must be a number.";
            }
        }

        String normalizedHost = AuthManager.normalizeHost(hostTrim).toLowerCase(Locale.US);
        boolean isDemoHost = DEMO_HOST.equals(normalizedHost);
        String effectiveScheme = isDemoHost ? "https" : (selectedScheme == null || selectedScheme.trim().isEmpty()
                ? AuthManager.DEFAULT_SERVER_SCHEME
                : selectedScheme);
        int effectivePort = isDemoHost ? 443 : (portInt != null ? portInt : AuthManager.DEFAULT_SERVER_PORT);
        String builtBaseUrl = AuthManager.buildBaseUrl(effectiveScheme, hostTrim, effectivePort);

        if (message == null && AuthManager.shouldRejectLoopbackServer(builtBaseUrl)) {
            message = "On Android, localhost points to this device. Use the server's LAN IP or public URL.";
        }

        if (message == null) {
            if (isDemoHost) {
                suppressFieldCallbacks = true;
                selectedScheme = "https";
                updateSchemeButton();
                if (!"443".equals(portTrim)) {
                    etPort.setText("443");
                    etPort.setSelection(etPort.getText() != null ? etPort.getText().length() : 0);
                }
                suppressFieldCallbacks = false;
            }
            boolean saved = builtBaseUrl != null && auth.setServerConfig(effectiveScheme, hostTrim, effectivePort);
            if (!saved) {
                message = "Invalid server address.";
            }
        }

        serverValidationMessage = message;
        updateServerFeedback();
        return serverValidationMessage == null;
    }

    private void updateServerFeedback() {
        String text = serverValidationMessage != null ? serverValidationMessage : serverTestMessage;
        if (text == null || text.trim().isEmpty()) {
            tvServerFeedback.setVisibility(View.GONE);
            tvServerFeedback.setText("");
            return;
        }
        tvServerFeedback.setVisibility(View.VISIBLE);
        tvServerFeedback.setText(text);
        int color = serverValidationMessage != null
                ? R.color.app_error
                : (serverTestSuccess ? R.color.app_success : R.color.app_error);
        tvServerFeedback.setTextColor(ContextCompat.getColor(requireContext(), color));
    }

    private void clearServerTestMessage() {
        serverTestMessage = null;
        serverTestSuccess = false;
        updateServerFeedback();
    }

    private void clearAuthError() {
        tvError.setVisibility(View.GONE);
        tvError.setText("");
    }

    private void showAuthError(@Nullable String message) {
        String text = message == null || message.trim().isEmpty()
                ? (mode == AuthMode.REGISTER ? "Create Account failed" : "Log In failed")
                : message.trim();
        tvError.setText(text);
        tvError.setVisibility(View.VISIBLE);
    }

    private void updateFormState() {
        boolean register = mode == AuthMode.REGISTER;
        boolean hasServer = auth.getServerUrl() != null && !auth.getServerUrl().trim().isEmpty();
        boolean hasEmail = !fieldText(etEmail).trim().isEmpty();
        boolean hasPassword = !fieldText(etPassword).isEmpty();
        boolean hasName = !fieldText(etFullName).trim().isEmpty();
        boolean canSubmit = !isLoading && !isTesting && serverValidationMessage == null && hasServer && hasEmail && hasPassword && (!register || hasName);

        progress.setVisibility(isLoading ? View.VISIBLE : View.GONE);
        btnSubmit.setEnabled(canSubmit);
        btnSubmit.setText(isLoading ? "Working…" : (register ? "Create Account" : "Log In"));

        btnClose.setEnabled(!isLoading);
        btnModeLogin.setEnabled(!isLoading);
        btnModeRegister.setEnabled(!isLoading);
        btnScheme.setEnabled(!isLoading && !isTesting);
        btnRecentServers.setEnabled(!isLoading);
        btnTestConnection.setEnabled(!isLoading && !isTesting);
        btnTestConnection.setText(isTesting ? "Refreshing…" : "Refresh Route");
        etHost.setEnabled(!isLoading && !isTesting);
        etPort.setEnabled(!isLoading && !isTesting);
        etFullName.setEnabled(!isLoading);
        etEmail.setEnabled(!isLoading);
        etPassword.setEnabled(!isLoading);
    }

    private void testConnection() {
        clearAuthError();
        clearServerTestMessage();
        if (!validateAndPersistServer()) {
            updateFormState();
            return;
        }
        final String baseUrl = auth.getServerUrl();
        if (baseUrl == null || baseUrl.trim().isEmpty()) {
            serverTestMessage = "Fix the server address and try again.";
            serverTestSuccess = false;
            updateServerFeedback();
            updateFormState();
            return;
        }
        isTesting = true;
        updateFormState();
        new Thread(() -> {
            String message;
            boolean success = false;
            try {
                Request req = new Request.Builder().url(baseUrl + "/ping").get().build();
                try (Response response = httpClient.newCall(req).execute()) {
                    String body = response.body() != null ? response.body().string() : "";
                    if (response.isSuccessful()) {
                        auth.addRecentServer(baseUrl);
                        message = body == null || body.trim().isEmpty()
                                ? "Success (" + response.code() + ")"
                                : "Success (" + response.code() + "): " + body.trim();
                        success = true;
                    } else {
                        message = "HTTP " + response.code() + (body == null || body.trim().isEmpty() ? "" : ": " + body.trim());
                    }
                }
            } catch (Exception e) {
                message = e.getMessage() != null ? e.getMessage() : "Connection failed";
            }
            final boolean ok = success;
            final String finalMessage = message;
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> {
                isTesting = false;
                serverTestMessage = finalMessage;
                serverTestSuccess = ok;
                updateServerFeedback();
                updateFormState();
            });
        }).start();
    }

    private void submitAuth() {
        clearAuthError();
        clearServerTestMessage();
        if (!validateAndPersistServer()) {
            updateFormState();
            return;
        }

        final String serverUrl = auth.getServerUrl();
        final String fullName = fieldText(etFullName).trim();
        final String email = fieldText(etEmail).trim();
        final String password = fieldText(etPassword);
        final boolean doRegister = mode == AuthMode.REGISTER;

        if (serverUrl == null || serverUrl.trim().isEmpty() || email.isEmpty() || password.isEmpty() || (doRegister && fullName.isEmpty())) {
            showAuthError("Fill all required fields.");
            updateFormState();
            return;
        }

        isLoading = true;
        updateModeUi();
        updateFormState();

        new Thread(() -> {
            try {
                if (doRegister) {
                    auth.register(fullName, email, password);
                } else {
                    auth.login(email, password);
                }
                auth.commitManualServerOverride();
                auth.addRecentServer(auth.getServerUrl());
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    isLoading = false;
                    updateModeUi();
                    updateFormState();
                    Toast.makeText(requireContext(), doRegister ? "Account created" : "Authenticated", Toast.LENGTH_SHORT).show();
                    openServerHome();
                });
            } catch (Exception e) {
                try {
                    android.util.Log.e("OpenPhotos", "[AUTH] submit failed", e);
                } catch (Exception ignored) {
                }
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    isLoading = false;
                    updateModeUi();
                    updateFormState();
                    showAuthError(e.getMessage());
                });
            }
        }).start();
    }

    private void openServerHome() {
        BottomNavigationView bottom = requireActivity().findViewById(R.id.bottom_nav);
        if (bottom != null && bottom.getSelectedItemId() != R.id.nav_server) {
            bottom.setSelectedItemId(R.id.nav_server);
            return;
        }
        try {
            NavHostFragment.findNavController(this).navigate(R.id.serverHostFragment);
        } catch (Exception ignored) {
        }
    }

    private void closeScreen() {
        auth.clearManualServerOverride();
        NavController nav = NavHostFragment.findNavController(this);
        boolean popped = nav.popBackStack();
        if (popped) {
            if (nav.getCurrentDestination() != null) {
                syncBottomNavSelection(nav.getCurrentDestination().getId());
            }
            return;
        }
        BottomNavigationView bottom = requireActivity().findViewById(R.id.bottom_nav);
        if (bottom != null) {
            bottom.setSelectedItemId(R.id.nav_local);
        } else {
            try {
                nav.navigate(R.id.localFragment);
            } catch (Exception ignored) {
            }
        }
    }

    @Override
    public void onResume() {
        super.onResume();
        loadFromAuth();
        validateAndPersistServer();
        updateFormState();
    }

    private void syncBottomNavSelection(int destinationId) {
        BottomNavigationView bottom = requireActivity().findViewById(R.id.bottom_nav);
        if (bottom == null) return;
        if (destinationId == R.id.localFragment || destinationId == R.id.viewerFragment || destinationId == R.id.albumDetailFragment) {
            bottom.setSelectedItemId(R.id.nav_local);
            return;
        }
        if (destinationId == R.id.syncFragment || destinationId == R.id.syncAlbumsFragment || destinationId == R.id.uploadsFragment) {
            bottom.setSelectedItemId(R.id.nav_sync);
            return;
        }
        if (destinationId == R.id.settingsFragment || destinationId == R.id.securitySettingsFragment || destinationId == R.id.changePasswordFragment) {
            bottom.setSelectedItemId(R.id.nav_settings);
            return;
        }
        bottom.setSelectedItemId(R.id.nav_server);
    }

    private int dpToPx(int dp) {
        return Math.round(dp * requireContext().getResources().getDisplayMetrics().density);
    }

    private boolean containsWhitespace(@NonNull String value) {
        for (int i = 0; i < value.length(); i++) {
            if (Character.isWhitespace(value.charAt(i))) return true;
        }
        return false;
    }

    @NonNull
    private String fieldText(@NonNull EditText editText) {
        Editable editable = editText.getText();
        return editable == null ? "" : editable.toString();
    }

    @Nullable
    private HostPort splitHostPort(@NonNull String raw) {
        String s = raw.trim();
        if (s.isEmpty() || s.contains("://")) return null;

        if (s.startsWith("[") && s.contains("]")) {
            int close = s.indexOf(']');
            if (close <= 0 || close + 2 > s.length() || s.charAt(close + 1) != ':') return null;
            String hostPart = s.substring(0, close + 1);
            String portPart = s.substring(close + 2);
            if (portPart.isEmpty() || !digitsOnly(portPart)) return null;
            return new HostPort(hostPart, portPart);
        }

        int colonCount = 0;
        int lastColon = -1;
        for (int i = 0; i < s.length(); i++) {
            if (s.charAt(i) == ':') {
                colonCount++;
                lastColon = i;
            }
        }
        if (colonCount != 1 || lastColon <= 0 || lastColon >= s.length() - 1) return null;
        String hostPart = s.substring(0, lastColon);
        String portPart = s.substring(lastColon + 1);
        if (!digitsOnly(portPart)) return null;
        return new HostPort(hostPart, portPart);
    }

    private boolean digitsOnly(@NonNull String value) {
        for (int i = 0; i < value.length(); i++) {
            if (!Character.isDigit(value.charAt(i))) return false;
        }
        return true;
    }

    private static final class HostPort {
        final String host;
        final String port;

        HostPort(String host, String port) {
            this.host = host;
            this.port = port;
        }
    }

    private abstract static class SimpleTextWatcher implements TextWatcher {
        @Override
        public void beforeTextChanged(CharSequence s, int start, int count, int after) { }

        @Override
        public void onTextChanged(CharSequence s, int start, int before, int count) { }
    }
}
