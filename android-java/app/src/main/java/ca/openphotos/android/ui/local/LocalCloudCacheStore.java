package ca.openphotos.android.ui.local;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.json.JSONArray;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** Lightweight persisted cache for cloud-check fingerprints/candidates/results. */
public final class LocalCloudCacheStore {
    private static final String PREF = "local.cloud.cache.v1";
    private static final String PREFIX = "item.";

    public static final class Entry {
        @NonNull public final String fingerprint;
        @NonNull public final List<String> candidates;
        public final boolean backedUp;
        public final long checkedAtSec;

        public Entry(@NonNull String fingerprint, @NonNull List<String> candidates, boolean backedUp, long checkedAtSec) {
            this.fingerprint = fingerprint;
            this.candidates = candidates;
            this.backedUp = backedUp;
            this.checkedAtSec = checkedAtSec;
        }
    }

    private final SharedPreferences sp;

    public LocalCloudCacheStore(@NonNull Context app) {
        this.sp = app.getApplicationContext().getSharedPreferences(PREF, Context.MODE_PRIVATE);
    }

    @Nullable
    public Entry get(@NonNull String localId) {
        String raw = sp.getString(key(localId), null);
        if (raw == null || raw.isEmpty()) return null;
        try {
            JSONObject j = new JSONObject(raw);
            String fp = j.optString("fingerprint", "");
            JSONArray arr = j.optJSONArray("candidates");
            ArrayList<String> out = new ArrayList<>();
            if (arr != null) {
                for (int i = 0; i < arr.length(); i++) {
                    String v = arr.optString(i, "");
                    if (!v.isEmpty()) out.add(v);
                }
            }
            boolean backed = j.optBoolean("backed_up", false);
            long checked = j.optLong("checked_at", 0L);
            if (fp.isEmpty()) return null;
            return new Entry(fp, out, backed, checked);
        } catch (Exception ignored) {
            return null;
        }
    }

    public void put(@NonNull String localId, @NonNull Entry entry) {
        try {
            JSONObject j = new JSONObject();
            j.put("fingerprint", entry.fingerprint);
            JSONArray arr = new JSONArray();
            for (String c : entry.candidates) arr.put(c);
            j.put("candidates", arr);
            j.put("backed_up", entry.backedUp);
            j.put("checked_at", entry.checkedAtSec);
            sp.edit().putString(key(localId), j.toString()).apply();
        } catch (Exception ignored) {
        }
    }

    public void remove(@NonNull String localId) {
        sp.edit().remove(key(localId)).apply();
    }

    private static String key(@NonNull String localId) {
        byte[] b = localId.getBytes(StandardCharsets.UTF_8);
        return PREFIX + Base64.encodeToString(b, Base64.NO_WRAP | Base64.URL_SAFE);
    }
}
