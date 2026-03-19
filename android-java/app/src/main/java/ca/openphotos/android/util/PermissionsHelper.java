package ca.openphotos.android.util;

import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

import androidx.annotation.RequiresApi;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

/** Helpers to request runtime permissions. */
public final class PermissionsHelper {
    private PermissionsHelper() {}

    public static boolean hasMediaRead(Context context) {
        if (Build.VERSION.SDK_INT >= 33) {
            return ContextCompat.checkSelfPermission(context, android.Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
                    && ContextCompat.checkSelfPermission(context, android.Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED;
        }
        return ContextCompat.checkSelfPermission(context, android.Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED;
    }

    public static String[] mediaReadPermissions() {
        if (Build.VERSION.SDK_INT >= 33) {
            return new String[]{
                    android.Manifest.permission.READ_MEDIA_IMAGES,
                    android.Manifest.permission.READ_MEDIA_VIDEO
            };
        }
        return new String[]{android.Manifest.permission.READ_EXTERNAL_STORAGE};
    }

    public static boolean hasMediaLocation(Activity a) {
        if (Build.VERSION.SDK_INT < 29) return false;
        return ContextCompat.checkSelfPermission(a, android.Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    @RequiresApi(29)
    public static void requestMediaLocation(Activity a, int reqCode) {
        ActivityCompat.requestPermissions(a, new String[]{android.Manifest.permission.ACCESS_MEDIA_LOCATION}, reqCode);
    }
}
