package ca.openphotos.android.ui;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.os.Bundle;
import android.text.format.Formatter;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.pm.PackageInfoCompat;
import androidx.fragment.app.Fragment;
import androidx.navigation.fragment.NavHostFragment;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AppLinks;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.core.CapabilitiesService;
import ca.openphotos.android.media.DiskImageCache;
import ca.openphotos.android.prefs.AppearancePreferences;
import com.bumptech.glide.Glide;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import com.google.android.material.textfield.TextInputEditText;
import com.google.android.material.textfield.TextInputLayout;

import java.io.File;
import java.util.Locale;

/** Settings screen with grouped Appearance/Cache/Security/Account/About sections. */
public class SettingsFragment extends Fragment {
    private static final int THUMBS_MIN_MB = 50;
    private static final int THUMBS_MAX_MB = 4096;
    private static final int IMAGES_MIN_MB = 200;
    private static final int IMAGES_MAX_MB = 8192;
    private static final int VIDEOS_MIN_MB = 500;
    private static final int VIDEOS_MAX_MB = 20480;

    private AuthManager auth;
    private AppearancePreferences appearancePrefs;
    private DiskImageCache cache;
    private Context appContext;

    private View cardDemoReadonly;
    private View rowAppearance;
    private TextView tvAppearanceValue;
    private TextView tvCacheUsageThumbs;
    private TextView tvCacheUsageImages;
    private TextView tvCacheUsageVideos;
    private TextInputLayout tilThumbs;
    private TextInputLayout tilImages;
    private TextInputLayout tilVideos;
    private TextInputEditText etThumbs;
    private TextInputEditText etImages;
    private TextInputEditText etVideos;
    private MaterialButton btnApplyCaps;
    private MaterialButton btnClearCache;
    private MaterialButton btnRefreshUsage;
    private View rowSecurity;
    private View rowChangePassword;
    private TextView tvAccountName;
    private TextView tvAccountEmail;
    private TextView tvAccountServerUrl;
    private TextView tvAccountServerVersion;
    private TextView tvAboutVersion;
    private View rowAboutSupport;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        return inflater.inflate(R.layout.fragment_settings, container, false);
    }

    @Override
    public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        appContext = requireContext().getApplicationContext();
        auth = AuthManager.get(appContext);
        appearancePrefs = new AppearancePreferences(appContext);
        cache = DiskImageCache.get(appContext);

        cardDemoReadonly = view.findViewById(R.id.card_demo_readonly);
        rowAppearance = view.findViewById(R.id.row_appearance);
        tvAppearanceValue = view.findViewById(R.id.tv_appearance_value);
        tvCacheUsageThumbs = view.findViewById(R.id.tv_cache_usage_thumbs);
        tvCacheUsageImages = view.findViewById(R.id.tv_cache_usage_images);
        tvCacheUsageVideos = view.findViewById(R.id.tv_cache_usage_videos);
        tilThumbs = view.findViewById(R.id.til_cache_thumbs);
        tilImages = view.findViewById(R.id.til_cache_images);
        tilVideos = view.findViewById(R.id.til_cache_videos);
        etThumbs = view.findViewById(R.id.et_cache_cap_thumbs);
        etImages = view.findViewById(R.id.et_cache_cap_images);
        etVideos = view.findViewById(R.id.et_cache_cap_videos);
        btnApplyCaps = view.findViewById(R.id.btn_cache_apply_caps);
        btnClearCache = view.findViewById(R.id.btn_cache_clear);
        btnRefreshUsage = view.findViewById(R.id.btn_cache_refresh_usage);
        rowSecurity = view.findViewById(R.id.row_security);
        rowChangePassword = view.findViewById(R.id.row_change_password);
        tvAccountName = view.findViewById(R.id.tv_account_name);
        tvAccountEmail = view.findViewById(R.id.tv_account_email);
        tvAccountServerUrl = view.findViewById(R.id.tv_account_server_url);
        tvAccountServerVersion = view.findViewById(R.id.tv_account_server_version);
        tvAboutVersion = view.findViewById(R.id.tv_about_version);
        rowAboutSupport = view.findViewById(R.id.row_about_support);

        loadCapsIntoUi();
        refreshCacheUsage();

        btnApplyCaps.setOnClickListener(v -> applyCaps());
        btnRefreshUsage.setOnClickListener(v -> refreshCacheUsage());
        btnClearCache.setOnClickListener(v -> confirmAndClearCache());
        rowAppearance.setOnClickListener(v -> showAppearanceDialog());

        rowSecurity.setOnClickListener(v -> NavHostFragment.findNavController(this).navigate(R.id.securitySettingsFragment));
        rowChangePassword.setOnClickListener(v -> NavHostFragment.findNavController(this).navigate(R.id.changePasswordFragment));

        bindAccountSummary();
        refreshServerVersion();
        tvAboutVersion.setText(getVersionString());
        view.findViewById(R.id.btn_about_website).setOnClickListener(v -> openExternalUrl(AppLinks.WEBSITE));
        view.findViewById(R.id.btn_about_privacy).setOnClickListener(v -> openExternalUrl(AppLinks.PRIVACY_POLICY));
        view.findViewById(R.id.btn_about_terms).setOnClickListener(v -> openExternalUrl(AppLinks.TERMS));
        view.findViewById(R.id.btn_about_github).setOnClickListener(v -> openExternalUrl(AppLinks.GITHUB));
        rowAboutSupport.setOnClickListener(v -> openSupportEmail());
        view.findViewById(R.id.btn_about_support_copy)
                .setOnClickListener(v -> copyToClipboard("support_email", AppLinks.SUPPORT_EMAIL, "Support email copied"));
        refreshAppearanceSummary();

        boolean demoReadOnly = auth.isDemoUser();
        cardDemoReadonly.setVisibility(demoReadOnly ? View.VISIBLE : View.GONE);
        setMutatingEnabled(!demoReadOnly);
    }

    @Override
    public void onResume() {
        super.onResume();
        refreshCacheUsage();
        refreshAppearanceSummary();
        bindAccountSummary();
        refreshServerVersion();
        boolean demoReadOnly = auth != null && auth.isDemoUser();
        cardDemoReadonly.setVisibility(demoReadOnly ? View.VISIBLE : View.GONE);
        setMutatingEnabled(!demoReadOnly);
    }

    private void setMutatingEnabled(boolean enabled) {
        if (etThumbs != null) etThumbs.setEnabled(enabled);
        if (etImages != null) etImages.setEnabled(enabled);
        if (etVideos != null) etVideos.setEnabled(enabled);
        if (btnApplyCaps != null) btnApplyCaps.setEnabled(enabled);
        if (btnClearCache != null) btnClearCache.setEnabled(enabled);
        setRowEnabled(rowSecurity, enabled);
        setRowEnabled(rowChangePassword, enabled);
    }

    private void setRowEnabled(@Nullable View row, boolean enabled) {
        if (row == null) return;
        row.setEnabled(enabled);
        row.setClickable(enabled);
        row.setAlpha(enabled ? 1f : 0.45f);
    }

    private void loadCapsIntoUi() {
        DiskImageCache.Caps caps = cache.getCaps();
        etThumbs.setText(String.valueOf(caps.thumbsBytes / (1024L * 1024L)));
        etImages.setText(String.valueOf(caps.imagesBytes / (1024L * 1024L)));
        etVideos.setText(String.valueOf(caps.videosBytes / (1024L * 1024L)));
    }

    private void bindAccountSummary() {
        if (tvAccountName == null || tvAccountEmail == null || tvAccountServerUrl == null || auth == null) return;
        String email = auth.getUserEmail();
        tvAccountName.setText(resolveAccountName(email));
        tvAccountEmail.setText(email != null ? email : "-");
        String serverUrl = auth.getServerUrl();
        tvAccountServerUrl.setText(serverUrl != null && !serverUrl.trim().isEmpty() ? serverUrl : "-");
    }

    private void refreshServerVersion() {
        if (tvAccountServerVersion == null || auth == null) return;
        final String requestedServerUrl = auth.getServerUrl() != null ? auth.getServerUrl().trim() : "";
        if (requestedServerUrl.isEmpty()) {
            tvAccountServerVersion.setText("Unavailable");
            return;
        }
        tvAccountServerVersion.setText("Loading…");
        new Thread(() -> {
            CapabilitiesService.Caps caps = CapabilitiesService.get(appContext);
            final String resolvedVersion = caps.version != null && !caps.version.trim().isEmpty()
                    ? caps.version.trim()
                    : "Unavailable";
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> {
                if (!isAdded() || tvAccountServerVersion == null || auth == null) return;
                String currentServerUrl = auth.getServerUrl() != null ? auth.getServerUrl().trim() : "";
                if (!requestedServerUrl.equals(currentServerUrl)) return;
                tvAccountServerVersion.setText(resolvedVersion);
            });
        }).start();
    }

    private void refreshCacheUsage() {
        long thumbs = cache.usageBytes(DiskImageCache.Bucket.THUMBS) + cache.usageBytes(DiskImageCache.Bucket.FACES);
        long images = cache.usageBytes(DiskImageCache.Bucket.IMAGES);
        long videos = cache.usageBytes(DiskImageCache.Bucket.VIDEOS);
        tvCacheUsageThumbs.setText("Thumbnails usage: " + Formatter.formatShortFileSize(requireContext(), thumbs));
        tvCacheUsageImages.setText("Images usage: " + Formatter.formatShortFileSize(requireContext(), images));
        tvCacheUsageVideos.setText("Videos usage: " + Formatter.formatShortFileSize(requireContext(), videos));
    }

    private void applyCaps() {
        Integer thumbsMb = parseCap(tilThumbs, etThumbs, THUMBS_MIN_MB, THUMBS_MAX_MB, "Thumbnails cap");
        Integer imagesMb = parseCap(tilImages, etImages, IMAGES_MIN_MB, IMAGES_MAX_MB, "Images cap");
        Integer videosMb = parseCap(tilVideos, etVideos, VIDEOS_MIN_MB, VIDEOS_MAX_MB, "Videos cap");
        if (thumbsMb == null || imagesMb == null || videosMb == null) return;

        cache.setCaps(new DiskImageCache.Caps(
                thumbsMb * 1024L * 1024L,
                imagesMb * 1024L * 1024L,
                videosMb * 1024L * 1024L
        ));
        Toast.makeText(requireContext(), "Cache caps updated", Toast.LENGTH_SHORT).show();
        loadCapsIntoUi();
        refreshCacheUsage();
    }

    @Nullable
    private Integer parseCap(
            @NonNull TextInputLayout til,
            @NonNull EditText et,
            int min,
            int max,
            @NonNull String label
    ) {
        String raw = et.getText() != null ? et.getText().toString().trim() : "";
        if (raw.isEmpty()) {
            til.setError(label + " is required");
            return null;
        }
        try {
            int value = Integer.parseInt(raw);
            if (value < min || value > max) {
                til.setError(label + " must be between " + min + " and " + max + " MB");
                return null;
            }
            til.setError(null);
            return value;
        } catch (NumberFormatException e) {
            til.setError(label + " must be a number");
            return null;
        }
    }

    private void confirmAndClearCache() {
        new MaterialAlertDialogBuilder(requireContext())
                .setTitle("Clear cache?")
                .setMessage("This clears thumbnails, images, videos, and stale temp upload files.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Clear", (d, w) -> clearCacheNow())
                .show();
    }

    private void refreshAppearanceSummary() {
        if (tvAppearanceValue == null || appearancePrefs == null) return;
        tvAppearanceValue.setText(AppearancePreferences.label(appearancePrefs.mode()));
    }

    private void showAppearanceDialog() {
        final String[] modes = new String[]{
                AppearancePreferences.MODE_LIGHT,
                AppearancePreferences.MODE_DARK,
                AppearancePreferences.MODE_SYSTEM
        };
        final String[] labels = new String[]{"Light", "Dark", "System"};
        String current = appearancePrefs.mode();
        int checked = 2;
        for (int i = 0; i < modes.length; i++) {
            if (modes[i].equals(current)) {
                checked = i;
                break;
            }
        }
        final int[] selected = new int[]{checked};
        new MaterialAlertDialogBuilder(requireContext())
                .setTitle("Appearance")
                .setSingleChoiceItems(labels, checked, (dialog, which) -> selected[0] = which)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Apply", (dialog, which) -> applyAppearanceMode(modes[selected[0]]))
                .show();
    }

    private void applyAppearanceMode(@NonNull String mode) {
        String current = appearancePrefs.mode();
        if (current.equals(mode)) return;
        appearancePrefs.setMode(mode);
        AppearancePreferences.apply(requireContext());
        refreshAppearanceSummary();
    }

    private void clearCacheNow() {
        cache.clearAll();
        try {
            Glide.get(requireContext()).clearMemory();
        } catch (Exception ignored) {
        }
        new Thread(() -> {
            try {
                Glide.get(appContext).clearDiskCache();
            } catch (Exception ignored) {
            }
            pruneUploadTempArtifacts();
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> {
                refreshCacheUsage();
                Toast.makeText(requireContext(), "Cache cleared", Toast.LENGTH_SHORT).show();
            });
        }).start();
    }

    /** Best-effort cleanup of stale upload temp artifacts in app cache. */
    private void pruneUploadTempArtifacts() {
        try {
            File dir = appContext.getCacheDir();
            File[] files = dir.listFiles();
            if (files == null) return;
            long cutoffMs = System.currentTimeMillis() - (10L * 60L * 1000L);
            for (File f : files) {
                if (f == null || !f.isFile()) continue;
                String n = f.getName().toLowerCase(Locale.US);
                if (!isKnownUploadTempPrefix(n)) continue;
                long last = f.lastModified();
                if (last > 0 && last > cutoffMs) continue;
                //noinspection ResultOfMethodCallIgnored
                f.delete();
            }
        } catch (Exception ignored) {
        }
    }

    private boolean isKnownUploadTempPrefix(@NonNull String filename) {
        return filename.startsWith("orig_")
                || filename.startsWith("thumb_")
                || filename.startsWith("inp_")
                || filename.startsWith("conv_")
                || filename.startsWith("raw_thumb_")
                || filename.startsWith("ux_")
                || filename.startsWith("dl_")
                || filename.startsWith("dec_");
    }

    private void copyToClipboard(@NonNull String label, @Nullable String value, @NonNull String doneMessage) {
        if (value == null || value.trim().isEmpty()) {
            Toast.makeText(requireContext(), "No value", Toast.LENGTH_SHORT).show();
            return;
        }
        ClipboardManager cm = (ClipboardManager) requireContext().getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) cm.setPrimaryClip(ClipData.newPlainText(label, value));
        Toast.makeText(requireContext(), doneMessage, Toast.LENGTH_SHORT).show();
    }

    private void openExternalUrl(@Nullable String url) {
        if (url == null || url.trim().isEmpty()) {
            Toast.makeText(requireContext(), "Invalid URL", Toast.LENGTH_SHORT).show();
            return;
        }
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (Exception e) {
            Toast.makeText(requireContext(), "Unable to open link", Toast.LENGTH_SHORT).show();
        }
    }

    private void openSupportEmail() {
        try {
            Uri uri = Uri.parse("mailto:" + Uri.encode(AppLinks.SUPPORT_EMAIL)
                    + "?subject=" + Uri.encode(AppLinks.SUPPORT_SUBJECT));
            Intent i = new Intent(Intent.ACTION_SENDTO, uri);
            startActivity(i);
        } catch (Exception e) {
            Toast.makeText(requireContext(), "No email app found", Toast.LENGTH_SHORT).show();
        }
    }

    @NonNull
    private String resolveAccountName(@Nullable String email) {
        String explicit = auth != null ? auth.getUserName() : null;
        if (explicit != null && !explicit.trim().isEmpty()) return explicit;
        if (email == null || email.trim().isEmpty()) return "-";
        int at = email.indexOf('@');
        String local = at > 0 ? email.substring(0, at) : email;
        local = local.replace('.', ' ').replace('_', ' ').replace('-', ' ').trim();
        if (local.isEmpty()) return email;
        return toTitleCase(local);
    }

    @NonNull
    private String toTitleCase(@NonNull String raw) {
        String[] parts = raw.split("\\s+");
        StringBuilder out = new StringBuilder(raw.length());
        for (String part : parts) {
            if (part.isEmpty()) continue;
            if (out.length() > 0) out.append(' ');
            out.append(Character.toUpperCase(part.charAt(0)));
            if (part.length() > 1) out.append(part.substring(1));
        }
        return out.length() > 0 ? out.toString() : raw;
    }

    @NonNull
    private String getVersionString() {
        try {
            PackageInfo pi = requireContext().getPackageManager().getPackageInfo(requireContext().getPackageName(), 0);
            long code = PackageInfoCompat.getLongVersionCode(pi);
            String name = pi.versionName != null ? pi.versionName : "-";
            return name + " (" + code + ")";
        } catch (Exception e) {
            return "-";
        }
    }
}
