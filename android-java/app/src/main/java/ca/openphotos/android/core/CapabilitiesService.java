package ca.openphotos.android.core;

import android.content.Context;
import androidx.annotation.Nullable;
import org.json.JSONObject;
import java.io.IOException;
import okhttp3.Request;
import okhttp3.Response;

/** Fetch server capabilities (EE gating). Missing endpoint => ee=false. */
public class CapabilitiesService {
    public static class Caps {
        public final boolean ee;
        @Nullable public final String version;

        public Caps(boolean ee, @Nullable String version) {
            this.ee = ee;
            this.version = version;
        }
    }

    public static Caps get(Context app) {
        AuthManager auth = AuthManager.get(app);
        String url = auth.getServerUrl() + "/api/capabilities";
        Request req = new Request.Builder().url(url).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) return new Caps(false, null);
            String body = r.body() != null ? r.body().string() : "{}";
            JSONObject json = new JSONObject(body);
            String version = null;
            if (json.has("version") && !json.isNull("version")) {
                String rawVersion = json.optString("version", null);
                if (rawVersion != null) {
                    rawVersion = rawVersion.trim();
                    if (!rawVersion.isEmpty()) {
                        version = rawVersion;
                    }
                }
            }
            return new Caps(json.optBoolean("ee", false), version);
        } catch (IOException e) {
            return new Caps(false, null);
        } catch (Exception e) {
            return new Caps(false, null);
        }
    }
}
