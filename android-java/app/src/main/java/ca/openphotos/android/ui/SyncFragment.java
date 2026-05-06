package ca.openphotos.android.ui;

import android.content.res.ColorStateList;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.navigation.fragment.NavHostFragment;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.i18n.AndroidI18n;
import ca.openphotos.android.prefs.SyncPreferences;
import ca.openphotos.android.sync.SyncService;
import ca.openphotos.android.util.BackgroundRestrictionChecker;
import ca.openphotos.android.util.BatteryOptimizationHelper;
import ca.openphotos.android.util.ForegroundUploadScreenController;
import com.google.android.material.card.MaterialCardView;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.button.MaterialButtonToggleGroup;
import com.google.android.material.switchmaterial.SwitchMaterial;
import com.google.android.material.textfield.TextInputEditText;

import java.text.DateFormat;
import java.util.Date;
import java.util.Locale;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

/** Sync tab screen aligned to iOS structure: Server / Sync / Status / Actions. */
public class SyncFragment extends Fragment {
    private SyncPreferences prefs;

    private TextInputEditText etServerUrl;
    private TextView tvServerRoute;
    private TextView tvAccountStatus;
    private MaterialButton btnLoginLogout;

    private MaterialButtonToggleGroup toggleScope;
    private MaterialButton btnScopeAll;
    private MaterialButton btnScopeSelected;
    private MaterialButton btnManageAlbums;

    private SwitchMaterial swAutoStart;
    private SwitchMaterial swAutoWifi;
    private SwitchMaterial swKeepScreen;
    private SwitchMaterial swCellPhotos;
    private SwitchMaterial swCellVideos;
    private SwitchMaterial swPreserveAlbum;
    private SwitchMaterial swPhotosOnly;

    private MaterialCardView cardBackgroundRestrictions;
    private TextView tvRestrictionStatus;
    private TextView tvRestrictionSummary;
    private TextView tvRestrictionDetails;
    private TextView tvRestrictionVendorHint;
    private MaterialButton btnRestrictionBatterySettings;
    private MaterialButton btnRestrictionAppInfo;
    private MaterialButton btnRestrictionRefresh;

    private TextView tvPending;
    private TextView tvUploading;
    private TextView tvBg;
    private TextView tvFailed;
    private TextView tvSynced;
    private TextView tvLast;
    private MaterialButton btnSyncNow;
    private MaterialButton btnResync;
    private MaterialButton btnRetry;
    private ColorStateList btnSyncNowDefaultBackgroundTint;
    private ColorStateList btnSyncNowDefaultTextColors;
    private volatile long forceBusyUntilMs = 0L;
    private volatile boolean syncActionBusy = false;

    private final android.os.Handler uiHandler = new android.os.Handler(android.os.Looper.getMainLooper());
    private final Runnable statsPoll = new Runnable() {
        @Override
        public void run() {
            refreshStats();
            uiHandler.postDelayed(this, 2000L);
        }
    };

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_sync, container, false);
        prefs = new SyncPreferences(requireContext().getApplicationContext());

        etServerUrl = root.findViewById(R.id.et_sync_server_url);
        tvServerRoute = root.findViewById(R.id.tv_sync_server_route);
        tvAccountStatus = root.findViewById(R.id.tv_sync_account_status);
        btnLoginLogout = root.findViewById(R.id.btn_sync_login_logout);

        toggleScope = root.findViewById(R.id.toggle_sync_scope);
        btnScopeAll = root.findViewById(R.id.btn_sync_scope_all);
        btnScopeSelected = root.findViewById(R.id.btn_sync_scope_selected);
        btnManageAlbums = root.findViewById(R.id.btn_sync_manage_albums);

        swAutoStart = root.findViewById(R.id.sw_sync_auto_start);
        swAutoWifi = root.findViewById(R.id.sw_sync_auto_wifi);
        swKeepScreen = root.findViewById(R.id.sw_sync_keep_screen);
        swCellPhotos = root.findViewById(R.id.sw_sync_cell_photos);
        swCellVideos = root.findViewById(R.id.sw_sync_cell_videos);
        swPreserveAlbum = root.findViewById(R.id.sw_sync_preserve_album);
        swPhotosOnly = root.findViewById(R.id.sw_sync_photos_only);

        cardBackgroundRestrictions = root.findViewById(R.id.card_sync_background_restrictions);
        tvRestrictionStatus = root.findViewById(R.id.tv_sync_bg_restriction_status);
        tvRestrictionSummary = root.findViewById(R.id.tv_sync_bg_restriction_summary);
        tvRestrictionDetails = root.findViewById(R.id.tv_sync_bg_restriction_details);
        tvRestrictionVendorHint = root.findViewById(R.id.tv_sync_bg_restriction_vendor_hint);
        btnRestrictionBatterySettings = root.findViewById(R.id.btn_sync_bg_open_settings);
        btnRestrictionAppInfo = root.findViewById(R.id.btn_sync_bg_open_app_info);
        btnRestrictionRefresh = root.findViewById(R.id.btn_sync_bg_refresh);

        tvPending = root.findViewById(R.id.tv_sync_pending);
        tvUploading = root.findViewById(R.id.tv_sync_uploading);
        tvBg = root.findViewById(R.id.tv_sync_bg);
        tvFailed = root.findViewById(R.id.tv_sync_failed);
        tvSynced = root.findViewById(R.id.tv_sync_synced);
        tvLast = root.findViewById(R.id.tv_sync_last);

        bindStaticActions(root);
        bindToggles();
        bindScopeControls();

        applyPrefsToUi();
        refreshAuthState();
        refreshBackgroundRestrictionState();
        refreshStats();
        return root;
    }

    @Override
    public void onResume() {
        super.onResume();
        refreshAuthState();
        refreshBackgroundRestrictionState();
        refreshStats();
        uiHandler.removeCallbacks(statsPoll);
        uiHandler.postDelayed(statsPoll, 2000L);
    }

    @Override
    public void onPause() {
        super.onPause();
        uiHandler.removeCallbacks(statsPoll);
    }

    private void bindStaticActions(@NonNull View root) {
        root.findViewById(R.id.btn_sync_save_url).setOnClickListener(v -> {
            NavHostFragment.findNavController(this).navigate(R.id.networkSettingsFragment);
        });

        root.findViewById(R.id.btn_sync_test).setOnClickListener(v -> {
            AuthManager.get(requireContext()).refreshNetworkRouting();
            Toast.makeText(requireContext(), AndroidI18n.t("Refreshing network route"), Toast.LENGTH_SHORT).show();
            refreshAuthState();
        });

        btnRestrictionBatterySettings.setOnClickListener(v -> {
            if (!BatteryOptimizationHelper.openBatteryOptimizationSettings(this)) {
                Toast.makeText(requireContext(), AndroidI18n.t("Unable to open battery settings"), Toast.LENGTH_SHORT).show();
            }
        });

        btnRestrictionAppInfo.setOnClickListener(v -> {
            if (!BatteryOptimizationHelper.openAppDetails(this)) {
                Toast.makeText(requireContext(), AndroidI18n.t("Unable to open app info"), Toast.LENGTH_SHORT).show();
            }
        });

        btnRestrictionRefresh.setOnClickListener(v -> refreshBackgroundRestrictionState());

        btnLoginLogout.setOnClickListener(v -> {
            AuthManager auth = AuthManager.get(requireContext());
            if (auth.isAuthenticated()) {
                auth.logoutPreservingLoginEmail();
                refreshAuthState();
                Toast.makeText(requireContext(), AndroidI18n.t("Logged out"), Toast.LENGTH_SHORT).show();
                try {
                    NavHostFragment.findNavController(this).navigate(R.id.serverLoginFragment);
                } catch (Exception ignored) {
                }
            } else {
                NavHostFragment.findNavController(this).navigate(R.id.serverLoginFragment);
            }
        });

        root.findViewById(R.id.btn_sync_uploads).setOnClickListener(v ->
                NavHostFragment.findNavController(this).navigate(R.id.uploadsFragment));

        root.findViewById(R.id.btn_sync_refresh).setOnClickListener(v -> refreshStats());

        btnSyncNow = root.findViewById(R.id.btn_sync_now);
        btnResync = root.findViewById(R.id.btn_sync_resync);
        btnRetry = root.findViewById(R.id.btn_sync_retry);
        btnSyncNowDefaultBackgroundTint = btnSyncNow.getBackgroundTintList();
        btnSyncNowDefaultTextColors = btnSyncNow.getTextColors();

        btnSyncNow.setOnClickListener(v -> {
            if (syncActionBusy) {
                forceBusyUntilMs = 0L;
                new Thread(() -> {
                    boolean stopped = SyncService.get(requireContext()).stopCurrentSync();
                    requireActivity().runOnUiThread(() -> {
                        Toast.makeText(requireContext(), AndroidI18n.t(stopped ? "Stopping sync" : "Nothing to stop"), Toast.LENGTH_SHORT).show();
                        refreshStatsSoon();
                        refreshStats();
                    });
                }).start();
                return;
            }
            SyncService.SyncStartResult result = SyncService.get(requireContext()).syncNow(true, true);
            if (result == SyncService.SyncStartResult.STARTED) {
                forceBusyUntilMs = System.currentTimeMillis() + 1200L;
            }
            Toast.makeText(requireContext(), syncStartMessage(result), Toast.LENGTH_SHORT).show();
            refreshStatsSoon();
            refreshStats();
        });

        btnResync.setOnClickListener(v ->
                new androidx.appcompat.app.AlertDialog.Builder(requireContext())
                        .setTitle(AndroidI18n.t("ReSync Entire Library?"))
                        .setMessage(AndroidI18n.t("This marks all local items as pending and starts syncing immediately."))
                        .setNegativeButton(AndroidI18n.t("Cancel"), null)
                        .setPositiveButton(AndroidI18n.t("ReSync"), (d, w) -> {
                            new Thread(() -> {
                                int n = SyncService.get(requireContext()).resetAllForResync();
                                SyncService.get(requireContext()).syncNow(false, true);
                                requireActivity().runOnUiThread(() -> {
                                    Toast.makeText(requireContext(), AndroidI18n.t("Marked") + " " + n + " " + AndroidI18n.t("item(s) as pending"), Toast.LENGTH_SHORT).show();
                                    refreshStatsSoon();
                                    refreshStats();
                                });
                            }).start();
                        })
                        .show());

        btnRetry.setOnClickListener(v ->
                new androidx.appcompat.app.AlertDialog.Builder(requireContext())
                        .setTitle(AndroidI18n.t("Retry Stuck/Failed?"))
                        .setMessage(AndroidI18n.t("Requeues failed and background-queued items, then starts sync."))
                        .setNegativeButton(AndroidI18n.t("Cancel"), null)
                        .setPositiveButton(AndroidI18n.t("Retry"), (d, w) -> {
                            new Thread(() -> {
                                int n = SyncService.get(requireContext()).retryStuckAndFailed();
                                SyncService.get(requireContext()).syncNow(false, true);
                                requireActivity().runOnUiThread(() -> {
                                    Toast.makeText(requireContext(), AndroidI18n.t("Requeued") + " " + n + " " + AndroidI18n.t("item(s)"), Toast.LENGTH_SHORT).show();
                                    refreshStatsSoon();
                                    refreshStats();
                                });
                            }).start();
                        })
                        .show());

        btnManageAlbums.setOnClickListener(v ->
                NavHostFragment.findNavController(this).navigate(R.id.syncAlbumsFragment));
    }

    private void bindToggles() {
        swAutoStart.setOnCheckedChangeListener((b, on) -> {
            prefs.setAutoStartOnOpen(on);
            swAutoWifi.setVisibility(on ? View.VISIBLE : View.GONE);
        });
        swAutoWifi.setOnCheckedChangeListener((b, on) -> prefs.setAutoStartWifiOnly(on));
        swKeepScreen.setOnCheckedChangeListener((b, on) -> {
            prefs.setKeepScreenOn(on);
            if (isAdded()) ForegroundUploadScreenController.applyTo(requireActivity());
        });
        swCellPhotos.setOnCheckedChangeListener((b, on) -> prefs.setAllowCellularPhotos(on));
        swCellVideos.setOnCheckedChangeListener((b, on) -> prefs.setAllowCellularVideos(on));
        swPreserveAlbum.setOnCheckedChangeListener((b, on) -> prefs.setPreserveAlbum(on));
        swPhotosOnly.setOnCheckedChangeListener((b, on) -> prefs.setSyncPhotosOnly(on));
    }

    private void bindScopeControls() {
        toggleScope.addOnButtonCheckedListener((group, checkedId, isChecked) -> {
            if (!isChecked) return;
            boolean selected = checkedId == R.id.btn_sync_scope_selected;
            prefs.setScope(selected ? "selected" : "all");
            updateScopeUi(selected);
            refreshStats();
        });
    }

    private void applyPrefsToUi() {
        etServerUrl.setText(AuthManager.get(requireContext()).getServerUrl());
        etServerUrl.setEnabled(false);
        if (tvServerRoute != null) {
            AuthManager auth = AuthManager.get(requireContext());
            setLocalizedText(tvServerRoute, auth.getActiveEndpoint() == AuthManager.ActiveEndpoint.LOCAL
                    ? "Using Local Network"
                    : (auth.getActiveEndpoint() == AuthManager.ActiveEndpoint.PUBLIC ? "Using External Network" : "Not Configured"));
        }

        boolean selectedScope = "selected".equals(prefs.scope());
        if (selectedScope) toggleScope.check(btnScopeSelected.getId());
        else toggleScope.check(btnScopeAll.getId());
        updateScopeUi(selectedScope);

        swAutoStart.setChecked(prefs.autoStartOnOpen());
        swAutoWifi.setChecked(prefs.autoStartWifiOnly());
        swAutoWifi.setVisibility(prefs.autoStartOnOpen() ? View.VISIBLE : View.GONE);
        swKeepScreen.setChecked(prefs.keepScreenOn());
        swCellPhotos.setChecked(prefs.allowCellularPhotos());
        swCellVideos.setChecked(prefs.allowCellularVideos());
        swPreserveAlbum.setChecked(prefs.preserveAlbum());
        swPhotosOnly.setChecked(prefs.syncPhotosOnly());
    }

    private void updateScopeUi(boolean selectedScope) {
        int selectedTextColor = ContextCompat.getColor(requireContext(), R.color.colorOnPrimary);
        int unselectedTextColor = ContextCompat.getColor(requireContext(), R.color.app_text_primary);
        int selectedBackgroundColor = ContextCompat.getColor(requireContext(), R.color.app_accent);
        int unselectedBackgroundColor = ContextCompat.getColor(requireContext(), R.color.app_surface);
        int unselectedStrokeColor = ContextCompat.getColor(requireContext(), R.color.app_card_stroke);
        btnScopeAll.setTextColor(selectedScope ? unselectedTextColor : selectedTextColor);
        btnScopeSelected.setTextColor(selectedScope ? selectedTextColor : unselectedTextColor);
        btnScopeAll.setBackgroundTintList(ColorStateList.valueOf(selectedScope ? unselectedBackgroundColor : selectedBackgroundColor));
        btnScopeSelected.setBackgroundTintList(ColorStateList.valueOf(selectedScope ? selectedBackgroundColor : unselectedBackgroundColor));
        btnScopeAll.setStrokeColor(ColorStateList.valueOf(selectedScope ? unselectedStrokeColor : selectedBackgroundColor));
        btnScopeSelected.setStrokeColor(ColorStateList.valueOf(selectedScope ? selectedBackgroundColor : unselectedStrokeColor));
        btnManageAlbums.setVisibility(selectedScope ? View.VISIBLE : View.GONE);
    }

    private void refreshBackgroundRestrictionState() {
        BackgroundRestrictionChecker.Result result = BackgroundRestrictionChecker.evaluate(requireContext());
        setDynamicText(tvRestrictionStatus, localizeBackgroundRestrictionText(result.title));
        setDynamicText(tvRestrictionSummary, localizeBackgroundRestrictionText(result.summary));
        setDynamicText(tvRestrictionDetails, localizeDetailBlock(result.details));

        boolean hasVendorHint = result.vendorHint != null && !result.vendorHint.trim().isEmpty();
        tvRestrictionVendorHint.setVisibility(hasVendorHint ? View.VISIBLE : View.GONE);
        if (hasVendorHint) {
            setDynamicText(tvRestrictionVendorHint, localizeBackgroundRestrictionText(result.vendorHint));
        }

        int statusColor;
        int strokeColor;
        switch (result.status) {
            case RESTRICTED:
                statusColor = ContextCompat.getColor(requireContext(), R.color.app_error);
                strokeColor = ContextCompat.getColor(requireContext(), R.color.app_error);
                break;
            case AT_RISK:
                statusColor = ContextCompat.getColor(requireContext(), R.color.app_warning_text);
                strokeColor = ContextCompat.getColor(requireContext(), R.color.app_warning_stroke);
                break;
            default:
                statusColor = ContextCompat.getColor(requireContext(), R.color.app_success);
                strokeColor = ContextCompat.getColor(requireContext(), R.color.app_success);
                break;
        }
        tvRestrictionStatus.setTextColor(statusColor);
        cardBackgroundRestrictions.setStrokeColor(strokeColor);
    }

    @NonNull
    private String localizeDetailBlock(@Nullable String details) {
        if (details == null || details.isEmpty()) return "";
        String[] lines = details.split("\\n", -1);
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < lines.length; i++) {
            if (i > 0) out.append('\n');
            String line = lines[i];
            String prefix = "";
            String source = line;
            if (line.startsWith("• ")) {
                prefix = "• ";
                source = line.substring(2);
            }
            out.append(prefix).append(localizeBackgroundRestrictionText(source));
        }
        return out.toString();
    }

    @NonNull
    private String localizeBackgroundRestrictionText(@Nullable String source) {
        if (source == null || source.isEmpty()) return "";
        String translated = AndroidI18n.t(source);
        String locale = AndroidI18n.currentMessageLocale();
        if (!translated.equals(source) || "en".equals(locale)) {
            return translated;
        }

        String batterySuffix = ", open Battery settings and set this app to Unrestricted for reliable background sync.";
        if (source.startsWith("On ") && source.endsWith(batterySuffix)) {
            String vendor = source.substring(3, source.length() - batterySuffix.length());
            if ("fr".equals(locale)) return "Sur " + vendor + ", ouvrez les paramètres de batterie et définissez cette app sur Sans restriction pour une synchronisation fiable en arrière-plan.";
            if ("es".equals(locale)) return "En " + vendor + ", abre los ajustes de batería y configura esta app como Sin restricciones para una sincronización en segundo plano fiable.";
            return "在 " + vendor + " 上，打开电池设置，并将此应用设为不受限制，以确保后台同步可靠。";
        }

        String launchSuffix = ", also check Auto-launch and battery manager settings if background sync still stops.";
        if (source.startsWith("On ") && source.endsWith(launchSuffix)) {
            String vendor = source.substring(3, source.length() - launchSuffix.length());
            if ("fr".equals(locale)) return "Sur " + vendor + ", vérifiez aussi les réglages de lancement automatique et de gestion de la batterie si la synchronisation en arrière-plan s’arrête encore.";
            if ("es".equals(locale)) return "En " + vendor + ", revisa también los ajustes de inicio automático y gestor de batería si la sincronización en segundo plano sigue deteniéndose.";
            return "在 " + vendor + " 上，如果后台同步仍会停止，请同时检查自启动和电池管理设置。";
        }

        String activitySuffix = ", confirm background activity and battery protection settings allow this app to stay active.";
        if (source.startsWith("On ") && source.endsWith(activitySuffix)) {
            String vendor = source.substring(3, source.length() - activitySuffix.length());
            if ("fr".equals(locale)) return "Sur " + vendor + ", vérifiez que les réglages d’activité en arrière-plan et de protection de la batterie autorisent cette app à rester active.";
            if ("es".equals(locale)) return "En " + vendor + ", confirma que los ajustes de actividad en segundo plano y protección de batería permiten que esta app siga activa.";
            return "在 " + vendor + " 上，请确认后台活动和电池保护设置允许此应用保持运行。";
        }

        String managementSuffix = ", verify launch management and battery settings allow background activity.";
        if (source.startsWith("On ") && source.endsWith(managementSuffix)) {
            String vendor = source.substring(3, source.length() - managementSuffix.length());
            if ("fr".equals(locale)) return "Sur " + vendor + ", vérifiez que la gestion du lancement et les réglages de batterie autorisent l’activité en arrière-plan.";
            if ("es".equals(locale)) return "En " + vendor + ", verifica que la gestión de inicio y los ajustes de batería permitan la actividad en segundo plano.";
            return "在 " + vendor + " 上，请确认启动管理和电池设置允许后台活动。";
        }

        String devicesSuffix = " devices may apply extra background limits outside standard Android APIs.";
        if (source.endsWith(devicesSuffix)) {
            String vendor = source.substring(0, source.length() - devicesSuffix.length());
            if ("fr".equals(locale)) return "Les appareils " + vendor + " peuvent appliquer des limites supplémentaires en arrière-plan en dehors des API Android standard.";
            if ("es".equals(locale)) return "Los dispositivos " + vendor + " pueden aplicar límites adicionales en segundo plano fuera de las API estándar de Android.";
            return vendor + " 设备可能会在标准 Android API 之外施加额外的后台限制。";
        }

        String oftenSuffix = " devices often apply extra background limits beyond standard Android settings.";
        if (source.endsWith(oftenSuffix)) {
            String vendor = source.substring(0, source.length() - oftenSuffix.length());
            if ("fr".equals(locale)) return "Les appareils " + vendor + " appliquent souvent des limites supplémentaires en arrière-plan au-delà des réglages Android standard.";
            if ("es".equals(locale)) return "Los dispositivos " + vendor + " suelen aplicar límites adicionales en segundo plano más allá de los ajustes estándar de Android.";
            return vendor + " 设备经常会在标准 Android 设置之外施加额外的后台限制。";
        }

        return source;
    }

    private void setLocalizedText(@NonNull TextView view, @NonNull String source) {
        view.setTag(R.id.tag_i18n_text_source, source);
        view.setText(AndroidI18n.t(source));
    }

    private void setDynamicText(@NonNull TextView view, @NonNull String text) {
        view.setTag(R.id.tag_i18n_text_source, text);
        view.setText(text);
    }

    private void refreshAuthState() {
        AuthManager auth = AuthManager.get(requireContext());
        boolean authed = auth.isAuthenticated();
        setLocalizedText(tvAccountStatus, authed ? "Logged in" : "Logged out");
        tvAccountStatus.setTextColor(ContextCompat.getColor(requireContext(),
                authed ? R.color.app_success : R.color.app_text_secondary));
        setLocalizedText(btnLoginLogout, authed ? "Log Out" : "Log In");
        etServerUrl.setText(auth.getServerUrl());
        if (tvServerRoute != null) {
            setLocalizedText(tvServerRoute, auth.getActiveEndpoint() == AuthManager.ActiveEndpoint.LOCAL
                    ? "Using Local Network"
                    : (auth.getActiveEndpoint() == AuthManager.ActiveEndpoint.PUBLIC ? "Using External Network" : "Not Configured"));
        }
    }

    private void refreshStatsSoon() {
        uiHandler.postDelayed(this::refreshStats, 400L);
        uiHandler.postDelayed(this::refreshStats, 1400L);
    }

    private void refreshStats() {
        new Thread(() -> {
            SyncService.Stats s = SyncService.get(requireContext())
                    .getStats(prefs.scope(), prefs.syncIncludeUnassigned());
            boolean busy = SyncService.get(requireContext()).isSyncBusy();
            boolean visualBusy = busy || System.currentTimeMillis() < forceBusyUntilMs;
            requireActivity().runOnUiThread(() -> {
                setDynamicText(tvPending, AndroidI18n.t("Pending:") + " " + s.pending);
                setDynamicText(tvUploading, AndroidI18n.t("Uploading:") + " " + s.uploading + (busy ? " (" + AndroidI18n.t("running") + ")" : ""));
                setDynamicText(tvBg, AndroidI18n.t("Queued (background):") + " " + s.bgQueued);
                setDynamicText(tvFailed, AndroidI18n.t("Failed:") + " " + s.failed);
                tvFailed.setTextColor(ContextCompat.getColor(requireContext(),
                        s.failed > 0 ? R.color.app_error : R.color.app_text_primary));
                setDynamicText(tvSynced, AndroidI18n.t("Synced:") + " " + s.synced);
                if (s.lastSyncAt > 0) {
                    setDynamicText(tvLast, AndroidI18n.t("Last sync:") + " " + formatLastSyncDate(s.lastSyncAt));
                } else {
                    setDynamicText(tvLast, AndroidI18n.t("Last sync:") + " -");
                }
                updateActionButtonsState(visualBusy);
            });
        }).start();
    }

    @NonNull
    private String formatLastSyncDate(long epochSeconds) {
        Locale locale;
        switch (AndroidI18n.currentMessageLocale()) {
            case "zh-Hans":
                locale = Locale.SIMPLIFIED_CHINESE;
                break;
            case "fr":
                locale = Locale.FRANCE;
                break;
            case "es":
                locale = new Locale("es", "ES");
                break;
            default:
                locale = Locale.US;
                break;
        }
        DateFormat formatter = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.MEDIUM, locale);
        return formatter.format(new Date(epochSeconds * 1000L));
    }

    private void updateActionButtonsState(boolean syncInProgress) {
        if (btnSyncNow == null || btnResync == null || btnRetry == null) return;
        if (!syncInProgress) {
            forceBusyUntilMs = 0L;
        }
        syncActionBusy = syncInProgress;
        btnSyncNow.setEnabled(!isDemoReadOnly());
        btnSyncNow.setAlpha(isDemoReadOnly() ? 0.55f : 1.0f);
        setLocalizedText(btnSyncNow, syncInProgress ? "Stop Syncing" : "Sync Now");
        if (syncInProgress) {
            btnSyncNow.setBackgroundTintList(ColorStateList.valueOf(
                    ContextCompat.getColor(requireContext(), R.color.app_error)));
            btnSyncNow.setTextColor(ContextCompat.getColor(requireContext(), android.R.color.white));
        } else {
            btnSyncNow.setBackgroundTintList(btnSyncNowDefaultBackgroundTint);
            if (btnSyncNowDefaultTextColors != null) {
                btnSyncNow.setTextColor(btnSyncNowDefaultTextColors);
            }
        }

        btnResync.setEnabled(!syncInProgress);
        btnRetry.setEnabled(!syncInProgress);
        btnResync.setAlpha(syncInProgress ? 0.55f : 1.0f);
        btnRetry.setAlpha(syncInProgress ? 0.55f : 1.0f);
    }

    private boolean isDemoReadOnly() {
        return AuthManager.get(requireContext()).isDemoUser();
    }

    private String syncStartMessage(SyncService.SyncStartResult result) {
        if (result == null) return AndroidI18n.t("Unable to start sync");
        switch (result) {
            case STARTED:
                return AndroidI18n.t("Sync started");
            case ALREADY_RUNNING:
                return AndroidI18n.t("Sync is already running");
            case NOT_AUTHENTICATED:
                return AndroidI18n.t("Please log in first");
            case MISSING_MEDIA_PERMISSION:
                return AndroidI18n.t("Grant photo/media permission first");
            case MISSING_SERVER_URL:
                return AndroidI18n.t("Set server URL first");
            default:
                return AndroidI18n.t("Unable to start sync");
        }
    }

}
