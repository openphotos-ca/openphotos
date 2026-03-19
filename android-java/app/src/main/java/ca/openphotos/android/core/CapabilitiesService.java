package ca.openphotos.android.core;

import android.content.Context;
import org.json.JSONObject;
import java.io.IOException;
import okhttp3.Request;
import okhttp3.Response;

/** Fetch server capabilities (EE gating). Missing endpoint => ee=false. */
public class CapabilitiesService {
    public static class Caps { public final boolean ee; public Caps(boolean ee) { this.ee = ee; } }

    public static Caps get(Context app) {
        AuthManager auth = AuthManager.get(app);
        String url = auth.getServerUrl() + "/api/capabilities";
        Request req = new Request.Builder().url(url).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) return new Caps(false);
            String body = r.body() != null ? r.body().string() : "{}";
            JSONObject json = new JSONObject(body);
            return new Caps(json.optBoolean("ee", false));
        } catch (IOException e) {
            return new Caps(false);
        } catch (Exception e) {
            return new Caps(false);
        }
    }
}

