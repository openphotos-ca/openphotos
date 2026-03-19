package ca.openphotos.android.e2ee;

import android.content.Context;

import ca.openphotos.android.core.AuthorizedHttpClient;
import ca.openphotos.android.core.AuthManager;

import org.json.JSONObject;

import java.io.IOException;

import okhttp3.MediaType;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

/** Simple envelope GET/POST client. */
public final class CryptoAPI {
    private CryptoAPI() {}

    public static JSONObject fetchEnvelope(Context app) throws IOException {
        String url = AuthManager.get(app).getServerUrl() + "/api/crypto/envelope";
        try { android.util.Log.i("OpenPhotos", "[E2EE-API] Fetching envelope from: " + url); } catch (Exception ignored) {}

        Request req = new Request.Builder().url(url).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            int code = r.code();
            String body = r.body() != null ? r.body().string() : "";

            try {
                android.util.Log.i("OpenPhotos", "[E2EE-API] GET /crypto/envelope code=" + code + " len=" + body.length() + " success=" + r.isSuccessful());
            } catch (Exception ignored) {}

            if (!r.isSuccessful()) {
                try {
                    android.util.Log.w("OpenPhotos", "[E2EE-API] Request failed with code " + code + ", body: " + (body.length() > 200 ? body.substring(0, 200) + "..." : body));
                } catch (Exception ignored) {}
                return null;
            }

            try {
                JSONObject obj = new JSONObject(body);
                JSONObject envelope = obj.optJSONObject("envelope");

                if (envelope == null) {
                    try {
                        android.util.Log.w("OpenPhotos", "[E2EE-API] Response has no 'envelope' field. Keys: " + obj.keys().toString() + ", body: " + body);
                    } catch (Exception ignored) {}
                    return null;
                }

                try {
                    android.util.Log.i("OpenPhotos", "[E2EE-API] Successfully parsed envelope, fields: " + envelope.keys().toString());
                } catch (Exception ignored) {}

                return envelope;
            } catch (Exception e) {
                try {
                    android.util.Log.e("OpenPhotos", "[E2EE-API] Envelope parse failed: " + e.getClass().getSimpleName() + ": " + e.getMessage() + ", body: " + body, e);
                } catch (Exception ignored) {}
                return null;
            }
        }
    }

    public static boolean saveEnvelope(Context app, JSONObject envelope) throws IOException {
        String url = AuthManager.get(app).getServerUrl() + "/api/crypto/envelope";
        Request req = new Request.Builder()
                .url(url)
                .post(RequestBody.create(envelope.toString(), MediaType.parse("application/json")))
                .build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            return r.isSuccessful();
        }
    }
}
