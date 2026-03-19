package ca.openphotos.android.prefs;

import android.content.Context;
import android.content.SharedPreferences;

/** Sync-related user preferences (Wi‑Fi only, per-media cellular, auto retry minutes, keep screen on). */
public final class SyncPreferences {
    private static final String PREF = "sync.prefs";
    private static final String K_WIFI_ONLY = "wifiOnly";
    private static final String K_CELL_PHOTOS = "cellularPhotos";
    private static final String K_CELL_VIDEOS = "cellularVideos";
    private static final String K_AUTO_RETRY_MIN = "autoRetryMinutes";
    private static final String K_KEEP_SCREEN_ON = "keepScreenOn";
    private static final String K_SCOPE = "scope"; // all | selected
    private static final String K_PRESERVE_ALBUM = "preserveAlbum";
    private static final String K_AUTO_START = "autoStartOnOpen";
    private static final String K_AUTO_START_WIFI_ONLY = "autoStartWifiOnly";
    private static final String K_SYNC_PHOTOS_ONLY = "syncPhotosOnly";
    private static final String K_INCLUDE_UNASSIGNED = "syncIncludeUnassigned";
    private static final String K_UNASSIGNED_LOCKED = "syncUnassignedLocked";
    private static final String K_SYNC_ENABLED_AFTER_MANUAL = "syncEnabledAfterManualStart";

    private final SharedPreferences sp;
    public SyncPreferences(Context app) {
        this.sp = app.getSharedPreferences(PREF, Context.MODE_PRIVATE);
        if (!sp.contains(K_WIFI_ONLY)) sp.edit().putBoolean(K_WIFI_ONLY, true).apply();
        if (!sp.contains(K_CELL_PHOTOS)) sp.edit().putBoolean(K_CELL_PHOTOS, false).apply();
        if (!sp.contains(K_CELL_VIDEOS)) sp.edit().putBoolean(K_CELL_VIDEOS, false).apply();
        if (!sp.contains(K_AUTO_RETRY_MIN)) sp.edit().putInt(K_AUTO_RETRY_MIN, 5).apply();
        if (!sp.contains(K_KEEP_SCREEN_ON)) sp.edit().putBoolean(K_KEEP_SCREEN_ON, true).apply();
        if (!sp.contains(K_SCOPE)) sp.edit().putString(K_SCOPE, "all").apply();
        if (!sp.contains(K_PRESERVE_ALBUM)) sp.edit().putBoolean(K_PRESERVE_ALBUM, true).apply();
        if (!sp.contains(K_AUTO_START)) sp.edit().putBoolean(K_AUTO_START, true).apply();
        if (!sp.contains(K_AUTO_START_WIFI_ONLY)) sp.edit().putBoolean(K_AUTO_START_WIFI_ONLY, true).apply();
        if (!sp.contains(K_SYNC_PHOTOS_ONLY)) sp.edit().putBoolean(K_SYNC_PHOTOS_ONLY, false).apply();
        if (!sp.contains(K_INCLUDE_UNASSIGNED)) sp.edit().putBoolean(K_INCLUDE_UNASSIGNED, false).apply();
        if (!sp.contains(K_UNASSIGNED_LOCKED)) sp.edit().putBoolean(K_UNASSIGNED_LOCKED, false).apply();
        if (!sp.contains(K_SYNC_ENABLED_AFTER_MANUAL)) sp.edit().putBoolean(K_SYNC_ENABLED_AFTER_MANUAL, false).apply();
    }
    public boolean wifiOnly() { return sp.getBoolean(K_WIFI_ONLY, true); }
    public void setWifiOnly(boolean v) { sp.edit().putBoolean(K_WIFI_ONLY, v).apply(); }
    public boolean allowCellularPhotos() { return sp.getBoolean(K_CELL_PHOTOS, false); }
    public void setAllowCellularPhotos(boolean v) { sp.edit().putBoolean(K_CELL_PHOTOS, v).apply(); }
    public boolean allowCellularVideos() { return sp.getBoolean(K_CELL_VIDEOS, false); }
    public void setAllowCellularVideos(boolean v) { sp.edit().putBoolean(K_CELL_VIDEOS, v).apply(); }
    public int autoRetryMinutes() { return sp.getInt(K_AUTO_RETRY_MIN, 5); }
    public void setAutoRetryMinutes(int m) { int clamped = Math.max(1, Math.min(240, m)); sp.edit().putInt(K_AUTO_RETRY_MIN, clamped).apply(); }
    public boolean keepScreenOn() { return sp.getBoolean(K_KEEP_SCREEN_ON, true); }
    public void setKeepScreenOn(boolean v) { sp.edit().putBoolean(K_KEEP_SCREEN_ON, v).apply(); }

    // Scope: "all" or "selected"
    public String scope() { return sp.getString(K_SCOPE, "all"); }
    public void setScope(String v) { sp.edit().putString(K_SCOPE, ("selected".equals(v) ? "selected" : "all")).apply(); }

    public boolean preserveAlbum() { return sp.getBoolean(K_PRESERVE_ALBUM, true); }
    public void setPreserveAlbum(boolean v) { sp.edit().putBoolean(K_PRESERVE_ALBUM, v).apply(); }

    public boolean autoStartOnOpen() { return sp.getBoolean(K_AUTO_START, true); }
    public void setAutoStartOnOpen(boolean v) { sp.edit().putBoolean(K_AUTO_START, v).apply(); }

    public boolean autoStartWifiOnly() { return sp.getBoolean(K_AUTO_START_WIFI_ONLY, true); }
    public void setAutoStartWifiOnly(boolean v) { sp.edit().putBoolean(K_AUTO_START_WIFI_ONLY, v).apply(); }

    public boolean syncPhotosOnly() { return sp.getBoolean(K_SYNC_PHOTOS_ONLY, false); }
    public void setSyncPhotosOnly(boolean v) { sp.edit().putBoolean(K_SYNC_PHOTOS_ONLY, v).apply(); }

    public boolean syncIncludeUnassigned() { return sp.getBoolean(K_INCLUDE_UNASSIGNED, false); }
    public void setSyncIncludeUnassigned(boolean v) { sp.edit().putBoolean(K_INCLUDE_UNASSIGNED, v).apply(); }

    public boolean syncUnassignedLocked() { return sp.getBoolean(K_UNASSIGNED_LOCKED, false); }
    public void setSyncUnassignedLocked(boolean v) { sp.edit().putBoolean(K_UNASSIGNED_LOCKED, v).apply(); }

    public boolean syncEnabledAfterManualStart() { return sp.getBoolean(K_SYNC_ENABLED_AFTER_MANUAL, false); }
    public void setSyncEnabledAfterManualStart(boolean v) { sp.edit().putBoolean(K_SYNC_ENABLED_AFTER_MANUAL, v).apply(); }
}
