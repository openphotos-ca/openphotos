package ca.openphotos.android.prefs;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.HashSet;
import java.util.Set;

/** Stores selected folders for sync and those to upload as locked. */
public final class SyncFoldersPreferences {
    private static final String PREF = "sync.folders";
    private static final String K_SYNC = "folders.sync";
    private static final String K_LOCKED = "folders.locked";
    private final SharedPreferences sp;
    public SyncFoldersPreferences(Context app) { sp = app.getSharedPreferences(PREF, Context.MODE_PRIVATE); }
    public Set<String> getSyncFolders() { return new HashSet<>(sp.getStringSet(K_SYNC, new HashSet<>())); }
    public Set<String> getLockedFolders() { return new HashSet<>(sp.getStringSet(K_LOCKED, new HashSet<>())); }
    public void setSyncFolders(Set<String> paths) { sp.edit().putStringSet(K_SYNC, new HashSet<>(paths)).apply(); }
    public void setLockedFolders(Set<String> paths) { sp.edit().putStringSet(K_LOCKED, new HashSet<>(paths)).apply(); }
}

