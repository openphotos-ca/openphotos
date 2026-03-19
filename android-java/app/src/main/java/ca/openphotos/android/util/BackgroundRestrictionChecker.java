package ca.openphotos.android.util;

import android.app.ActivityManager;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.net.ConnectivityManager;
import android.os.Build;
import android.os.PowerManager;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/** Best-effort detector for Android background restrictions and vendor-specific risk. */
public final class BackgroundRestrictionChecker {
    private static final Set<String> AGGRESSIVE_VENDORS = new HashSet<>(Arrays.asList(
            "xiaomi", "redmi", "poco", "oppo", "vivo", "huawei", "honor", "realme", "oneplus", "iqoo"
    ));

    private BackgroundRestrictionChecker() {}

    public enum Status {
        CLEAR,
        AT_RISK,
        RESTRICTED
    }

    public static final class Result {
        public final Status status;
        public final boolean backgroundRestricted;
        public final boolean ignoringBatteryOptimizations;
        public final boolean powerSaveMode;
        public final int standbyBucket;
        public final int restrictBackgroundStatus;
        public final boolean aggressiveVendor;
        public final String vendorLabel;
        public final String title;
        public final String summary;
        public final String details;
        public final String vendorHint;

        private Result(
                @NonNull Status status,
                boolean backgroundRestricted,
                boolean ignoringBatteryOptimizations,
                boolean powerSaveMode,
                int standbyBucket,
                int restrictBackgroundStatus,
                boolean aggressiveVendor,
                @NonNull String vendorLabel,
                @NonNull String title,
                @NonNull String summary,
                @NonNull String details,
                @NonNull String vendorHint
        ) {
            this.status = status;
            this.backgroundRestricted = backgroundRestricted;
            this.ignoringBatteryOptimizations = ignoringBatteryOptimizations;
            this.powerSaveMode = powerSaveMode;
            this.standbyBucket = standbyBucket;
            this.restrictBackgroundStatus = restrictBackgroundStatus;
            this.aggressiveVendor = aggressiveVendor;
            this.vendorLabel = vendorLabel;
            this.title = title;
            this.summary = summary;
            this.details = details;
            this.vendorHint = vendorHint;
        }
    }

    @NonNull
    public static Result evaluate(@NonNull Context context) {
        Context appContext = context.getApplicationContext();
        ActivityManager am = (ActivityManager) appContext.getSystemService(Context.ACTIVITY_SERVICE);
        PowerManager pm = (PowerManager) appContext.getSystemService(Context.POWER_SERVICE);
        ConnectivityManager cm = (ConnectivityManager) appContext.getSystemService(Context.CONNECTIVITY_SERVICE);
        UsageStatsManager usm = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                ? (UsageStatsManager) appContext.getSystemService(Context.USAGE_STATS_SERVICE)
                : null;

        boolean backgroundRestricted = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                && am != null
                && am.isBackgroundRestricted();
        boolean ignoringBatteryOptimizations = pm == null
                || Build.VERSION.SDK_INT < Build.VERSION_CODES.M
                || pm.isIgnoringBatteryOptimizations(appContext.getPackageName());
        boolean powerSaveMode = pm != null && pm.isPowerSaveMode();

        int standbyBucket = UsageStatsManager.STANDBY_BUCKET_ACTIVE;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && usm != null) {
            try {
                standbyBucket = usm.getAppStandbyBucket();
            } catch (Exception ignored) {
                standbyBucket = UsageStatsManager.STANDBY_BUCKET_ACTIVE;
            }
        }

        int restrictBackgroundStatus = ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED;
        if (cm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                restrictBackgroundStatus = cm.getRestrictBackgroundStatus();
            } catch (Exception ignored) {
                restrictBackgroundStatus = ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED;
            }
        }

        String vendorLabel = firstNonBlank(Build.BRAND, Build.MANUFACTURER, Build.MODEL);
        String vendorNormalized = vendorLabel.toLowerCase(Locale.US);
        boolean aggressiveVendor = AGGRESSIVE_VENDORS.contains(vendorNormalized)
                || AGGRESSIVE_VENDORS.contains(safeLower(Build.MANUFACTURER))
                || AGGRESSIVE_VENDORS.contains(safeLower(Build.BRAND));

        List<String> details = new ArrayList<>();
        Status status = Status.CLEAR;
        String title = "No standard Android restriction detected";
        String summary = "Android does not currently report a standard background restriction for this app.";

        if (backgroundRestricted) {
            status = Status.RESTRICTED;
            title = "Background sync is restricted";
            summary = "Android reports this app is background restricted.";
            details.add("Background restriction is enabled for this app.");
        }

        if (restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED) {
            if (status != Status.RESTRICTED) {
                status = Status.RESTRICTED;
                title = "Background data is restricted";
                summary = "Data Saver is limiting background network access for this app.";
            }
            details.add("Data Saver is enabled for background data.");
        } else if (restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED) {
            details.add("Data Saver is enabled, but this app is currently whitelisted.");
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            if (standbyBucket == UsageStatsManager.STANDBY_BUCKET_RESTRICTED) {
                if (status != Status.RESTRICTED) {
                    status = Status.RESTRICTED;
                    title = "App standby is restricted";
                    summary = "Android placed this app in the restricted standby bucket.";
                }
                details.add("App standby bucket: Restricted.");
            } else if (standbyBucket == UsageStatsManager.STANDBY_BUCKET_RARE) {
                if (status == Status.CLEAR) {
                    status = Status.AT_RISK;
                    title = "Background sync may be interrupted";
                    summary = "Android placed this app in a low-priority standby bucket.";
                }
                details.add("App standby bucket: " + standbyBucketLabel(standbyBucket) + ".");
            }
        }

        if (!ignoringBatteryOptimizations) {
            if (status == Status.CLEAR) {
                status = Status.AT_RISK;
                title = "Battery optimization is still enabled";
                summary = "Standard battery optimization can delay or pause long-running background sync.";
            }
            details.add("Battery optimization is still enabled for this app.");
        } else {
            details.add("Battery optimization ignore request has already been granted.");
        }

        if (powerSaveMode) {
            if (status == Status.CLEAR) {
                status = Status.AT_RISK;
                title = "Power saver is on";
                summary = "Power saver can reduce background processing and network activity.";
            }
            details.add("System power saver is currently enabled.");
        }

        String vendorHint = "";
        if (aggressiveVendor) {
            if (status == Status.CLEAR) {
                status = Status.AT_RISK;
                title = "Vendor power management may still interfere";
                summary = vendorLabel + " devices often apply extra background limits beyond standard Android settings.";
            }
            vendorHint = vendorSpecificHint(vendorNormalized, vendorLabel);
            details.add(vendorHint);
        }

        if (details.isEmpty()) {
            details.add("No background restriction signal was detected from Android's standard APIs.");
        }

        return new Result(
                status,
                backgroundRestricted,
                ignoringBatteryOptimizations,
                powerSaveMode,
                standbyBucket,
                restrictBackgroundStatus,
                aggressiveVendor,
                vendorLabel,
                title,
                summary,
                joinDetails(details),
                vendorHint
        );
    }

    @NonNull
    private static String vendorSpecificHint(@NonNull String vendorNormalized, @NonNull String vendorLabel) {
        if ("xiaomi".equals(vendorNormalized) || "redmi".equals(vendorNormalized) || "poco".equals(vendorNormalized)) {
            return "On " + vendorLabel + ", open Battery settings and set this app to Unrestricted for reliable background sync.";
        }
        if ("oppo".equals(vendorNormalized) || "realme".equals(vendorNormalized) || "oneplus".equals(vendorNormalized)) {
            return "On " + vendorLabel + ", also check Auto-launch and battery manager settings if background sync still stops.";
        }
        if ("vivo".equals(vendorNormalized) || "iqoo".equals(vendorNormalized)) {
            return "On " + vendorLabel + ", confirm background activity and battery protection settings allow this app to stay active.";
        }
        if ("huawei".equals(vendorNormalized) || "honor".equals(vendorNormalized)) {
            return "On " + vendorLabel + ", verify launch management and battery settings allow background activity.";
        }
        return vendorLabel + " devices may apply extra background limits outside standard Android APIs.";
    }

    @NonNull
    private static String joinDetails(@NonNull List<String> details) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < details.size(); i++) {
            if (i > 0) sb.append('\n');
            sb.append("• ").append(details.get(i));
        }
        return sb.toString();
    }

    @NonNull
    private static String standbyBucketLabel(int bucket) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return "Unknown";
        switch (bucket) {
            case UsageStatsManager.STANDBY_BUCKET_ACTIVE:
                return "Active";
            case UsageStatsManager.STANDBY_BUCKET_WORKING_SET:
                return "Working set";
            case UsageStatsManager.STANDBY_BUCKET_FREQUENT:
                return "Frequent";
            case UsageStatsManager.STANDBY_BUCKET_RARE:
                return "Rare";
            case UsageStatsManager.STANDBY_BUCKET_RESTRICTED:
                return "Restricted";
            default:
                return "Bucket " + bucket;
        }
    }

    @NonNull
    private static String firstNonBlank(String... values) {
        if (values == null) return "Android";
        for (String value : values) {
            if (value != null && !value.trim().isEmpty()) {
                return value.trim();
            }
        }
        return "Android";
    }

    @NonNull
    private static String safeLower(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.US);
    }
}
