package ca.openphotos.android.core;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.IOException;
import java.util.Locale;

import okhttp3.Interceptor;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

/**
 * AuthorizedHttpClient wraps OkHttp and attaches Authorization headers,
 * retrying once on 401 by triggering a token refresh.
 */
public class AuthorizedHttpClient {
    private static volatile AuthorizedHttpClient INSTANCE;

    private final OkHttpClient client;
    private final AuthManager auth;

    private AuthorizedHttpClient(Context app) {
        this.auth = AuthManager.get(app);
        this.client = new OkHttpClient.Builder()
                // Server can take time on first query (cold caches, index warmup).
                // Relax timeouts to avoid premature failures during initial loads.
                .connectTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
                .readTimeout(45, java.util.concurrent.TimeUnit.SECONDS)
                .writeTimeout(45, java.util.concurrent.TimeUnit.SECONDS)
                .callTimeout(60, java.util.concurrent.TimeUnit.SECONDS)
                .addInterceptor(new Interceptor() {
                    @NonNull @Override public Response intercept(@NonNull Chain chain) throws IOException {
                        Request req = applyAuth(chain.request());
                        String tokenUsed = extractBearerToken(req.header("Authorization"));
                        try { android.util.Log.i("OpenPhotos", "[HTTP] -> " + req.method() + " " + req.url() + " auth=" + (req.header("Authorization")!=null)); } catch (Exception ignored) {}

                        Response resp = chain.proceed(req);

                        try {
                            android.util.Log.i("OpenPhotos", "[HTTP] <- " + resp.code() + " " + req.method() + " " + req.url() + " success=" + resp.isSuccessful());
                        } catch (Exception ignored) {}

                        if (resp.code() == 401) {
                            resp.close();
                            try { android.util.Log.w("OpenPhotos", "[HTTP] 401 for " + req.url() + ", attempting refresh"); } catch (Exception ignored) {}
                            if (auth.refreshAfterUnauthorized(tokenUsed)) {
                                Request retry = applyAuth(chain.request());
                                try { android.util.Log.i("OpenPhotos", "[HTTP] retry auth=" + (retry.header("Authorization")!=null)); } catch (Exception ignored) {}
                                Response retryResp = chain.proceed(retry);
                                try {
                                    android.util.Log.i("OpenPhotos", "[HTTP] <- (retry) " + retryResp.code() + " " + retry.method() + " " + retry.url() + " success=" + retryResp.isSuccessful());
                                } catch (Exception ignored) {}
                                return retryResp;
                            }
                            try { android.util.Log.w("OpenPhotos", "[HTTP] 401 refresh/retry unavailable for " + req.url()); } catch (Exception ignored) {}
                        }
                        return resp;
                    }
                })
                .build();
    }

    public static AuthorizedHttpClient get(Context app) {
        if (INSTANCE == null) {
            synchronized (AuthorizedHttpClient.class) {
                if (INSTANCE == null) INSTANCE = new AuthorizedHttpClient(app.getApplicationContext());
            }
        }
        return INSTANCE;
    }

    private Request applyAuth(Request req) {
        String t = auth.getToken();
        if (t == null || t.isEmpty()) return req;
        return req.newBuilder().header("Authorization", "Bearer " + t).build();
    }

    @Nullable
    private static String extractBearerToken(@Nullable String authorization) {
        if (authorization == null) return null;
        if (!authorization.toLowerCase(Locale.US).startsWith("bearer ")) return null;
        String token = authorization.substring(7).trim();
        return token.isEmpty() ? null : token;
    }

    public OkHttpClient raw() { return client; }
}
