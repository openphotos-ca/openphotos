package ca.openphotos.android.prefs;

import android.content.Context;
import android.content.SharedPreferences;

/** Security-related user preferences (include location/caption/description; UMK TTL). */
public final class SecurityPreferences {
    private static final String PREF = "security.prefs";
    private static final String K_LOC = "includeLocation";
    private static final String K_CAP = "includeCaption";
    private static final String K_DES = "includeDescription";
    private static final String K_TTL = "rememberUnlockSeconds";

    private final SharedPreferences sp;

    public SecurityPreferences(Context app) {
        this.sp = app.getSharedPreferences(PREF, Context.MODE_PRIVATE);
        if (!sp.contains(K_LOC)) sp.edit().putBoolean(K_LOC, true).apply();
        if (!sp.contains(K_CAP)) sp.edit().putBoolean(K_CAP, true).apply();
        if (!sp.contains(K_DES)) sp.edit().putBoolean(K_DES, true).apply();
        if (!sp.contains(K_TTL)) sp.edit().putInt(K_TTL, 3600).apply();
    }

    public boolean includeLocation() { return sp.getBoolean(K_LOC, true); }
    public void setIncludeLocation(boolean v) { sp.edit().putBoolean(K_LOC, v).apply(); }
    public boolean includeCaption() { return sp.getBoolean(K_CAP, true); }
    public void setIncludeCaption(boolean v) { sp.edit().putBoolean(K_CAP, v).apply(); }
    public boolean includeDescription() { return sp.getBoolean(K_DES, true); }
    public void setIncludeDescription(boolean v) { sp.edit().putBoolean(K_DES, v).apply(); }
    public int rememberUnlockSeconds() { return sp.getInt(K_TTL, 3600); }
    public void setRememberUnlockSeconds(int s) { sp.edit().putInt(K_TTL, s).apply(); }
}

