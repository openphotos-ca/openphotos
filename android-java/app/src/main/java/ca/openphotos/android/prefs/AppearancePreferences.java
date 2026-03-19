package ca.openphotos.android.prefs;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatDelegate;

/** Stores and applies the app appearance mode. */
public final class AppearancePreferences {
    public static final String MODE_SYSTEM = "system";
    public static final String MODE_LIGHT = "light";
    public static final String MODE_DARK = "dark";

    private static final String PREF = "appearance.prefs";
    private static final String K_MODE = "appearance.mode";

    private final SharedPreferences sp;

    public AppearancePreferences(@NonNull Context app) {
        sp = app.getApplicationContext().getSharedPreferences(PREF, Context.MODE_PRIVATE);
    }

    @NonNull
    public String mode() {
        return normalize(sp.getString(K_MODE, MODE_SYSTEM));
    }

    public void setMode(@NonNull String mode) {
        sp.edit().putString(K_MODE, normalize(mode)).apply();
    }

    public int nightMode() {
        return toNightMode(mode());
    }

    public static void apply(@NonNull Context context) {
        AppCompatDelegate.setDefaultNightMode(new AppearancePreferences(context).nightMode());
    }

    public static int toNightMode(@NonNull String mode) {
        String normalized = normalize(mode);
        if (MODE_LIGHT.equals(normalized)) return AppCompatDelegate.MODE_NIGHT_NO;
        if (MODE_DARK.equals(normalized)) return AppCompatDelegate.MODE_NIGHT_YES;
        return AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM;
    }

    @NonNull
    public static String label(@NonNull String mode) {
        String normalized = normalize(mode);
        if (MODE_LIGHT.equals(normalized)) return "Light";
        if (MODE_DARK.equals(normalized)) return "Dark";
        return "System";
    }

    @NonNull
    private static String normalize(String mode) {
        if (MODE_LIGHT.equals(mode)) return MODE_LIGHT;
        if (MODE_DARK.equals(mode)) return MODE_DARK;
        return MODE_SYSTEM;
    }
}
