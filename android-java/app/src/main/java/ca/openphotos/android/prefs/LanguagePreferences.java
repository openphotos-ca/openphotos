package ca.openphotos.android.prefs;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatDelegate;
import androidx.core.os.LocaleListCompat;

/** Stores and applies the app language override. */
public final class LanguagePreferences {
    public static final String MODE_SYSTEM = "system";
    public static final String MODE_EN = "en";
    public static final String MODE_ZH_HANS = "zh-Hans";
    public static final String MODE_FR = "fr";
    public static final String MODE_ES = "es";

    private static final String PREF = "language.prefs";
    private static final String K_MODE = "language.mode";

    private final SharedPreferences sp;

    public LanguagePreferences(@NonNull Context app) {
        sp = app.getApplicationContext().getSharedPreferences(PREF, Context.MODE_PRIVATE);
    }

    @NonNull
    public String mode() {
        return normalize(sp.getString(K_MODE, MODE_SYSTEM));
    }

    public void setMode(@NonNull String mode) {
        sp.edit().putString(K_MODE, normalize(mode)).apply();
    }

    public static void apply(@NonNull Context context) {
        String mode = new LanguagePreferences(context).mode();
        String tags = MODE_SYSTEM.equals(mode) ? "" : mode;
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(tags));
    }

    @NonNull
    public static String label(@NonNull String mode) {
        String normalized = normalize(mode);
        if (MODE_EN.equals(normalized)) return "English";
        if (MODE_ZH_HANS.equals(normalized)) return "简体中文";
        if (MODE_FR.equals(normalized)) return "Français";
        if (MODE_ES.equals(normalized)) return "Español";
        return "System";
    }

    @NonNull
    private static String normalize(String mode) {
        if (MODE_EN.equals(mode)) return MODE_EN;
        if (MODE_ZH_HANS.equals(mode)) return MODE_ZH_HANS;
        if (MODE_FR.equals(mode)) return MODE_FR;
        if (MODE_ES.equals(mode)) return MODE_ES;
        return MODE_SYSTEM;
    }
}
