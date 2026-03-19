package ca.openphotos.android.util;

import android.util.Log;

/** Minimal log helper to standardize prefixes across modules. */
public final class Logx {
    private static final String TAG = "OpenPhotos";
    private Logx() {}

    public static void EXPORT(String msg) { Log.i(TAG, "[EXPORT] " + msg); }
    public static void EXIF(String msg) { Log.i(TAG, "[EXIF] " + msg); }
    public static void UPLOAD(String msg) { Log.i(TAG, "[UPLOAD] " + msg); }
    public static void TUS(String msg) { Log.i(TAG, "[TUS] " + msg); }
}

