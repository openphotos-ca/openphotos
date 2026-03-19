package ca.openphotos.android.util;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;

import androidx.annotation.NonNull;
import androidx.fragment.app.Fragment;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Helper to guide the user to disable battery optimizations for reliable background uploads. */
public final class BatteryOptimizationHelper {
    private BatteryOptimizationHelper() {}

    public static boolean isIgnoringOptimizations(Context ctx) {
        if (Build.VERSION.SDK_INT < 23) return true;
        PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
        return pm.isIgnoringBatteryOptimizations(ctx.getPackageName());
    }

    public static Intent buildRequestIntent(Context ctx) {
        Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
        i.setData(Uri.parse("package:" + ctx.getPackageName()));
        return i;
    }

    public static Intent buildIgnoreOptimizationSettingsIntent() {
        return new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
    }

    public static Intent buildAppDetailsIntent(Context ctx) {
        Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
        i.setData(Uri.parse("package:" + ctx.getPackageName()));
        return i;
    }

    public static boolean openBatteryOptimizationSettings(@NonNull Fragment fragment) {
        Context ctx = fragment.requireContext();
        for (Intent vendorIntent : buildVendorBatteryIntents(ctx)) {
            if (tryStart(fragment, vendorIntent)) {
                return true;
            }
        }
        if (!isIgnoringOptimizations(ctx) && tryStart(fragment, buildRequestIntent(ctx))) {
            return true;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            if (tryStart(fragment, new Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS))) {
                return true;
            }
        }
        if (tryStart(fragment, buildIgnoreOptimizationSettingsIntent())) {
            return true;
        }
        return tryStart(fragment, buildAppDetailsIntent(ctx));
    }

    public static boolean openAppDetails(@NonNull Fragment fragment) {
        return tryStart(fragment, buildAppDetailsIntent(fragment.requireContext()));
    }

    @NonNull
    private static List<Intent> buildVendorBatteryIntents(@NonNull Context ctx) {
        String brand = safeLower(Build.BRAND);
        String manufacturer = safeLower(Build.MANUFACTURER);
        String appLabel = getAppLabel(ctx);
        List<Intent> intents = new ArrayList<>();

        if (isAnyOf(brand, manufacturer, "xiaomi", "redmi", "poco")) {
            intents.add(explicitIntent(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity",
                    ctx,
                    appLabel
            ));
            intents.add(explicitIntent(
                    "com.miui.securitycenter",
                    "com.miui.powercenter.PowerSettings",
                    ctx,
                    appLabel
            ));
            intents.add(explicitIntent(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                    ctx,
                    appLabel
            ));
        } else if (isAnyOf(brand, manufacturer, "oppo", "realme", "oneplus")) {
            intents.add(explicitIntent(
                    "com.coloros.oppoguardelf",
                    "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity",
                    ctx,
                    appLabel
            ));
            intents.add(explicitIntent(
                    "com.coloros.powermanager",
                    "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity",
                    ctx,
                    appLabel
            ));
            intents.add(explicitIntent(
                    "com.oplus.battery",
                    "com.oplus.battery.powerview.PowerConsumptionActivity",
                    ctx,
                    appLabel
            ));
        } else if (isAnyOf(brand, manufacturer, "vivo", "iqoo")) {
            intents.add(explicitIntent(
                    "com.vivo.abe",
                    "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity",
                    ctx,
                    appLabel
            ));
            intents.add(explicitIntent(
                    "com.vivo.abeui",
                    "com.vivo.abeui.highpower.ExcessivePowerManagerActivity",
                    ctx,
                    appLabel
            ));
            intents.add(explicitIntent(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
                    ctx,
                    appLabel
            ));
        } else if (isAnyOf(brand, manufacturer, "huawei", "honor")) {
            intents.add(explicitIntent(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity",
                    ctx,
                    appLabel
            ));
            intents.add(explicitIntent(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                    ctx,
                    appLabel
            ));
        }
        return intents;
    }

    @NonNull
    private static Intent explicitIntent(
            @NonNull String pkg,
            @NonNull String cls,
            @NonNull Context ctx,
            @NonNull String appLabel
    ) {
        Intent intent = new Intent();
        intent.setComponent(new ComponentName(pkg, cls));
        intent.putExtra("package_name", ctx.getPackageName());
        intent.putExtra("packageName", ctx.getPackageName());
        intent.putExtra("pkg_name", ctx.getPackageName());
        intent.putExtra("package_label", appLabel);
        intent.putExtra("app_name", appLabel);
        intent.putExtra("app_package", ctx.getPackageName());
        return intent;
    }

    private static boolean isAnyOf(
            @NonNull String brand,
            @NonNull String manufacturer,
            @NonNull String... values
    ) {
        for (String value : values) {
            if (value.equals(brand) || value.equals(manufacturer)) {
                return true;
            }
        }
        return false;
    }

    @NonNull
    private static String getAppLabel(@NonNull Context ctx) {
        try {
            CharSequence label = ctx.getApplicationInfo().loadLabel(ctx.getPackageManager());
            return label == null ? "OpenPhotos" : label.toString();
        } catch (Exception ignored) {
            return "OpenPhotos";
        }
    }

    @NonNull
    private static String safeLower(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.US);
    }

    private static boolean tryStart(@NonNull Fragment fragment, @NonNull Intent intent) {
        try {
            fragment.startActivity(intent);
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }
}
