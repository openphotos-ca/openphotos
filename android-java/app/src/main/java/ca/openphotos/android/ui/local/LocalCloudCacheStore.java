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

    public static final int STATE_UNKNOWN = 0;
    public static final int STATE_BACKED_UP = 1;
    public static final int STATE_DELETED_IN_CLOUD = 2;
    public static final int STATE_MISSING = 3;

    public static final class Entry {
        @NonNull public final String fingerprint;
        @NonNull public final List<String> candidates;
        public final int cloudState;
        public final long checkedAtSec;

        public Entry(@NonNull String fingerprint, @NonNull List<String> candidates, int cloudState, long checkedAtSec) {
            this.fingerprint = fingerprint;
            this.candidates = candidates;
            this.cloudState = cloudState;
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
            long checked = j.optLong("checked_at", 0L);
            int cloudState;
            if (j.has("cloud_state")) {
                cloudState = j.optInt("cloud_state", STATE_UNKNOWN);
            } else {
                boolean backed = j.optBoolean("backed_up", false);
                if (backed) cloudState = STATE_BACKED_UP;
                else if (checked > 0) cloudState = STATE_MISSING;
                else cloudState = STATE_UNKNOWN;
            }
            if (fp.isEmpty()) return null;
            return new Entry(fp, out, cloudState, checked);
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
            j.put("cloud_state", entry.cloudState);
            j.put("backed_up", entry.cloudState == STATE_BACKED_UP);
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
