package ca.openphotos.android.media;

import android.database.Cursor;
import android.provider.MediaStore;

import org.json.JSONArray;

/** Build nested album path arrays from RELATIVE_PATH segments. */
public final class AlbumPathUtil {
    private AlbumPathUtil() {}

    /** Returns a JSON array string like [["DCIM","Camera"]] for a single path. */
    public static String pathsJsonFromRelativePath(String relPath) {
        if (relPath == null || relPath.isEmpty()) return null;
        String[] parts = relPath.split("/");
        JSONArray arr = new JSONArray();
        JSONArray path = new JSONArray();
        for (String p : parts) {
            if (p == null || p.isEmpty()) continue;
            String clean = sanitize(p);
            if (!clean.isEmpty()) path.put(clean);
        }
        if (path.length() > 0) arr.put(path);
        return arr.length() > 0 ? arr.toString() : null;
    }

    private static String sanitize(String s) {
        // Keep Unicode; remove control chars
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (Character.isISOControl(c)) continue;
            b.append(c);
        }
        return b.toString().trim();
    }
}

