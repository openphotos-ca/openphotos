package ca.openphotos.android.core;

import android.content.Context;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.json.JSONObject;

import java.io.IOException;

import okhttp3.Request;
import okhttp3.Response;

public final class ServerUpdateService {
    public static final class Status {
        @NonNull public final String currentVersion;
        @Nullable public final String latestVersion;
        public final boolean available;
        @NonNull public final String status;
        @Nullable public final String lastError;

        public Status(@NonNull String currentVersion,
                      @Nullable String latestVersion,
                      boolean available,
                      @NonNull String status,
                      @Nullable String lastError) {
            this.currentVersion = currentVersion;
            this.latestVersion = latestVersion;
            this.available = available;
            this.status = status;
            this.lastError = lastError;
        }
    }

    public static final class Result {
        public final boolean forbidden;
        @Nullable public final Status status;
        @Nullable public final String error;

        public Result(boolean forbidden, @Nullable Status status, @Nullable String error) {
            this.forbidden = forbidden;
            this.status = status;
            this.error = error;
        }
    }

    private ServerUpdateService() {}

    @NonNull
    public static Result get(@NonNull Context app) {
        AuthManager auth = AuthManager.get(app);
        String baseUrl = auth.getServerUrl();
        if (baseUrl == null || baseUrl.trim().isEmpty()) {
            return new Result(false, null, "Server URL is not configured.");
        }

        String url = baseUrl + "/api/server/update-status?_=" + System.currentTimeMillis();
        Request req = new Request.Builder()
                .url(url)
                .get()
                .header("Cache-Control", "no-cache")
                .header("Pragma", "no-cache")
                .build();

        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (r.code() == 403) {
                return new Result(true, null, null);
            }
            String body = r.body() != null ? r.body().string() : "";
            if (!r.isSuccessful()) {
                return new Result(false, null, body == null || body.trim().isEmpty()
                        ? "Failed to load update status (" + r.code() + ")."
                        : body);
            }

            JSONObject json = new JSONObject(body);
            String currentVersion = json.optString("current_version", "").trim();
            String latestVersion = null;
            if (json.has("latest_version") && !json.isNull("latest_version")) {
                String value = json.optString("latest_version", "").trim();
                if (!value.isEmpty()) latestVersion = value;
            }
            String status = json.optString("status", "").trim();
            String lastError = null;
            if (json.has("last_error") && !json.isNull("last_error")) {
                String value = json.optString("last_error", "").trim();
                if (!value.isEmpty()) lastError = value;
            }

            return new Result(false, new Status(
                    currentVersion.isEmpty() ? "Unavailable" : currentVersion,
                    latestVersion,
                    json.optBoolean("available", false),
                    status.isEmpty() ? "never_checked" : status,
                    lastError
            ), null);
        } catch (IOException e) {
            return new Result(false, null, e.getMessage() != null ? e.getMessage() : "Failed to load update status.");
        } catch (Exception e) {
            return new Result(false, null, e.getMessage() != null ? e.getMessage() : "Failed to load update status.");
        }
    }
}
