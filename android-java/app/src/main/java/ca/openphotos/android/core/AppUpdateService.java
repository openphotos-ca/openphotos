package ca.openphotos.android.core;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

public final class AppUpdateService {
    static final long CACHE_TTL_MS = 24L * 60L * 60L * 1000L;
    public static final String STATUS_NEVER_CHECKED = "never_checked";
    public static final String STATUS_OK = "ok";
    public static final String STATUS_CHECK_FAILED = "check_failed";
    public static final String STATUS_ASSET_MISSING = "asset_missing";

    private static final String PREFS = "app.update";
    private static final String KEY_LATEST_VERSION = "latest_version";
    private static final String KEY_AVAILABLE = "available";
    private static final String KEY_STATUS = "status";
    private static final String KEY_CHECKED_AT_EPOCH_MS = "checked_at_epoch_ms";
    private static final String KEY_RELEASE_NOTES_URL = "release_notes_url";
    private static final String KEY_DOWNLOAD_URL = "download_url";
    private static final String KEY_LAST_ERROR = "last_error";
    private static final String ANDROID_APK_ASSET_NAME = "openphotos-android-release.apk";
    private static final Pattern SEMVER_LIKE =
            Pattern.compile("^(\\d+)\\.(\\d+)\\.(\\d+)(?:-([0-9A-Za-z.-]+))?$");
    private static final Object LOCK = new Object();
    private static final OkHttpClient HTTP = new OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .build();

    private static boolean checkInProgress = false;

    public static final class Status {
        @NonNull public final String currentVersion;
        @Nullable public final String latestVersion;
        public final boolean available;
        @NonNull public final String status;
        public final long checkedAtEpochMs;
        @Nullable public final String releaseNotesUrl;
        @Nullable public final String downloadUrl;
        @Nullable public final String lastError;

        public Status(@NonNull String currentVersion,
                      @Nullable String latestVersion,
                      boolean available,
                      @NonNull String status,
                      long checkedAtEpochMs,
                      @Nullable String releaseNotesUrl,
                      @Nullable String downloadUrl,
                      @Nullable String lastError) {
            this.currentVersion = currentVersion;
            this.latestVersion = latestVersion;
            this.available = available;
            this.status = status;
            this.checkedAtEpochMs = checkedAtEpochMs;
            this.releaseNotesUrl = releaseNotesUrl;
            this.downloadUrl = downloadUrl;
            this.lastError = lastError;
        }
    }

    private static final class ParsedVersion {
        final int major;
        final int minor;
        final int patch;
        @Nullable final String prerelease;

        ParsedVersion(int major, int minor, int patch, @Nullable String prerelease) {
            this.major = major;
            this.minor = minor;
            this.patch = patch;
            this.prerelease = prerelease;
        }
    }

    static final class ReleaseAsset {
        @Nullable final String name;
        @Nullable final String downloadUrl;

        ReleaseAsset(@Nullable String name, @Nullable String downloadUrl) {
            this.name = name;
            this.downloadUrl = downloadUrl;
        }
    }

    private AppUpdateService() {}

    public static void maybeCheckIfStale(@NonNull Context context) {
        final Context app = context.getApplicationContext();
        new Thread(() -> {
            getStatus(app, false);
        }, "app-update-check").start();
    }

    @NonNull
    public static Status getCachedStatus(@NonNull Context context) {
        synchronized (LOCK) {
            return readStatus(context.getApplicationContext());
        }
    }

    @NonNull
    public static Status getStatus(@NonNull Context context, boolean forceRefresh) {
        final Context app = context.getApplicationContext();
        boolean waitedForInFlight = false;

        synchronized (LOCK) {
            while (checkInProgress) {
                waitedForInFlight = true;
                try {
                    LOCK.wait();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return readStatus(app);
                }
            }

            Status cached = readStatus(app);
            if (waitedForInFlight) {
                return cached;
            }
            if (!forceRefresh && isCacheFresh(cached.checkedAtEpochMs, System.currentTimeMillis())) {
                return cached;
            }
            checkInProgress = true;
        }

        try {
            final Status previous;
            synchronized (LOCK) {
                previous = readStatus(app);
            }
            Status fresh = fetchLatestRelease(app, previous);
            synchronized (LOCK) {
                writeStatus(app, fresh);
                return fresh;
            }
        } finally {
            synchronized (LOCK) {
                checkInProgress = false;
                LOCK.notifyAll();
            }
        }
    }

    @NonNull
    private static Status fetchLatestRelease(@NonNull Context app, @Nullable Status previous) {
        final long checkedAt = System.currentTimeMillis();
        final String currentVersion = installedVersionName(app);
        try {
            parseVersion(currentVersion);
        } catch (IllegalArgumentException e) {
            return mergeFailure(previous, currentVersion, checkedAt, e.getMessage());
        }

        Request request = new Request.Builder()
                .url(AppLinks.GITHUB_LATEST_RELEASE_API)
                .get()
                .header("Accept", "application/vnd.github+json")
                .header("X-GitHub-Api-Version", "2022-11-28")
                .header("User-Agent", "openphotos-android/" + currentVersion)
                .header("Cache-Control", "no-cache")
                .header("Pragma", "no-cache")
                .build();

        try (Response response = HTTP.newCall(request).execute()) {
            String body = response.body() != null ? response.body().string() : "";
            if (!response.isSuccessful()) {
                return mergeFailure(previous, currentVersion, checkedAt, formatEndpointError(response.code(), body));
            }

            JSONObject json = new JSONObject(body);
            String latestVersion = normalizeReleaseVersion(json.optString("tag_name", null));
            int comparison = compareVersions(latestVersion, currentVersion);
            boolean available = comparison > 0;
            String releaseNotesUrl = normalizeNonEmpty(json.optString("html_url", null));
            if (releaseNotesUrl == null) {
                releaseNotesUrl = AppLinks.GITHUB_RELEASES;
            }
            String downloadUrl = selectAndroidApkDownloadUrl(json.optJSONArray("assets"));
            String status = STATUS_OK;
            if (!available) {
                downloadUrl = null;
            } else if (downloadUrl == null) {
                status = STATUS_ASSET_MISSING;
            }

            return new Status(
                    currentVersion,
                    latestVersion,
                    available,
                    status,
                    checkedAt,
                    releaseNotesUrl,
                    downloadUrl,
                    null
            );
        } catch (IOException e) {
            return mergeFailure(previous, currentVersion, checkedAt, errorMessageOrDefault(e, "Failed to load Android app update status."));
        } catch (Exception e) {
            return mergeFailure(previous, currentVersion, checkedAt, errorMessageOrDefault(e, "Failed to parse Android app update status."));
        }
    }

    @NonNull
    private static Status mergeFailure(@Nullable Status previous,
                                       @NonNull String currentVersion,
                                       long checkedAt,
                                       @Nullable String message) {
        String error = normalizeNonEmpty(message);
        if (error == null) {
            error = "Failed to load Android app update status.";
        }
        if (previous != null && previous.checkedAtEpochMs > 0L) {
            return new Status(
                    currentVersion,
                    previous.latestVersion,
                    previous.available,
                    STATUS_CHECK_FAILED,
                    checkedAt,
                    previous.releaseNotesUrl,
                    previous.downloadUrl,
                    error
            );
        }
        return new Status(
                currentVersion,
                null,
                false,
                STATUS_CHECK_FAILED,
                checkedAt,
                null,
                null,
                error
        );
    }

    @NonNull
    private static Status readStatus(@NonNull Context app) {
        SharedPreferences prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String currentVersion = installedVersionName(app);
        long checkedAt = prefs.getLong(KEY_CHECKED_AT_EPOCH_MS, 0L);
        String status = normalizeNonEmpty(prefs.getString(KEY_STATUS, null));
        if (status == null) {
            status = STATUS_NEVER_CHECKED;
        }
        return new Status(
                currentVersion,
                normalizeNonEmpty(prefs.getString(KEY_LATEST_VERSION, null)),
                prefs.getBoolean(KEY_AVAILABLE, false),
                status,
                checkedAt,
                normalizeNonEmpty(prefs.getString(KEY_RELEASE_NOTES_URL, null)),
                normalizeNonEmpty(prefs.getString(KEY_DOWNLOAD_URL, null)),
                normalizeNonEmpty(prefs.getString(KEY_LAST_ERROR, null))
        );
    }

    private static void writeStatus(@NonNull Context app, @NonNull Status status) {
        SharedPreferences prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        prefs.edit()
                .putString(KEY_LATEST_VERSION, status.latestVersion)
                .putBoolean(KEY_AVAILABLE, status.available)
                .putString(KEY_STATUS, status.status)
                .putLong(KEY_CHECKED_AT_EPOCH_MS, status.checkedAtEpochMs)
                .putString(KEY_RELEASE_NOTES_URL, status.releaseNotesUrl)
                .putString(KEY_DOWNLOAD_URL, status.downloadUrl)
                .putString(KEY_LAST_ERROR, status.lastError)
                .apply();
    }

    @NonNull
    static String normalizeReleaseVersion(@Nullable String tagName) {
        String raw = normalizeNonEmpty(tagName);
        if (raw == null) {
            throw new IllegalArgumentException("GitHub release tag_name is missing.");
        }
        String normalized = raw;
        if (normalized.startsWith("v") || normalized.startsWith("V")) {
            normalized = normalized.substring(1).trim();
        }
        parseVersion(normalized);
        return normalized;
    }

    static int compareVersions(@NonNull String left, @NonNull String right) {
        ParsedVersion a = parseVersion(left);
        ParsedVersion b = parseVersion(right);
        if (a.major != b.major) return Integer.compare(a.major, b.major);
        if (a.minor != b.minor) return Integer.compare(a.minor, b.minor);
        if (a.patch != b.patch) return Integer.compare(a.patch, b.patch);
        return comparePrerelease(a.prerelease, b.prerelease);
    }

    @Nullable
    static String selectAndroidApkDownloadUrl(@Nullable JSONArray assets) {
        if (assets == null) {
            return null;
        }
        List<ReleaseAsset> parsedAssets = new ArrayList<>();
        for (int i = 0; i < assets.length(); i++) {
            JSONObject asset = assets.optJSONObject(i);
            if (asset == null) continue;
            parsedAssets.add(new ReleaseAsset(
                    normalizeNonEmpty(asset.optString("name", null)),
                    normalizeNonEmpty(asset.optString("browser_download_url", null))
            ));
        }
        return selectAndroidApkDownloadUrlFromAssets(parsedAssets);
    }

    @Nullable
    static String selectAndroidApkDownloadUrlFromAssets(@Nullable Iterable<ReleaseAsset> assets) {
        if (assets == null) {
            return null;
        }
        for (ReleaseAsset asset : assets) {
            if (asset == null) continue;
            if (asset.name == null || !ANDROID_APK_ASSET_NAME.equalsIgnoreCase(asset.name)) continue;
            if (asset.downloadUrl != null) {
                return asset.downloadUrl;
            }
        }
        return null;
    }

    static boolean isCacheFresh(long checkedAtEpochMs, long nowEpochMs) {
        return checkedAtEpochMs > 0L
                && nowEpochMs >= checkedAtEpochMs
                && nowEpochMs - checkedAtEpochMs < CACHE_TTL_MS;
    }

    @NonNull
    private static ParsedVersion parseVersion(@NonNull String version) {
        String raw = version.trim();
        Matcher matcher = SEMVER_LIKE.matcher(raw);
        if (!matcher.matches()) {
            throw new IllegalArgumentException("Invalid semver-like version: " + version);
        }
        return new ParsedVersion(
                Integer.parseInt(matcher.group(1)),
                Integer.parseInt(matcher.group(2)),
                Integer.parseInt(matcher.group(3)),
                normalizeNonEmpty(matcher.group(4))
        );
    }

    private static int comparePrerelease(@Nullable String left, @Nullable String right) {
        if (left == null && right == null) return 0;
        if (left == null) return 1;
        if (right == null) return -1;

        String[] leftParts = left.split("\\.");
        String[] rightParts = right.split("\\.");
        int count = Math.max(leftParts.length, rightParts.length);
        for (int i = 0; i < count; i++) {
            if (i >= leftParts.length) return -1;
            if (i >= rightParts.length) return 1;
            String a = leftParts[i];
            String b = rightParts[i];
            boolean aNumeric = isNumericIdentifier(a);
            boolean bNumeric = isNumericIdentifier(b);
            if (aNumeric && bNumeric) {
                int compare = Integer.compare(Integer.parseInt(a), Integer.parseInt(b));
                if (compare != 0) return compare;
                continue;
            }
            if (aNumeric != bNumeric) {
                return aNumeric ? -1 : 1;
            }
            int compare = a.compareTo(b);
            if (compare != 0) return compare;
        }
        return 0;
    }

    private static boolean isNumericIdentifier(@NonNull String value) {
        if (value.isEmpty()) return false;
        for (int i = 0; i < value.length(); i++) {
            if (!Character.isDigit(value.charAt(i))) {
                return false;
            }
        }
        return true;
    }

    @NonNull
    private static String formatEndpointError(int code, @Nullable String body) {
        String message = extractGitHubMessage(body);
        if (code == 403 || code == 429) {
            return message != null
                    ? "GitHub rate limit or access error (" + code + "): " + message
                    : "GitHub rate limit or access error (" + code + ").";
        }
        if (code == 404) {
            return message != null
                    ? "GitHub latest release endpoint returned 404: " + message
                    : "GitHub latest release endpoint returned 404.";
        }
        return message != null
                ? "GitHub latest release request failed (" + code + "): " + message
                : "GitHub latest release request failed (" + code + ").";
    }

    @Nullable
    private static String extractGitHubMessage(@Nullable String body) {
        String raw = normalizeNonEmpty(body);
        if (raw == null) {
            return null;
        }
        try {
            JSONObject json = new JSONObject(raw);
            String message = normalizeNonEmpty(json.optString("message", null));
            if (message != null) return message;
        } catch (Exception ignored) {
        }
        return raw;
    }

    @NonNull
    private static String installedVersionName(@NonNull Context app) {
        try {
            PackageInfo packageInfo = app.getPackageManager().getPackageInfo(app.getPackageName(), 0);
            String version = normalizeNonEmpty(packageInfo.versionName);
            return version != null ? version : "Unavailable";
        } catch (Exception ignored) {
            return "Unavailable";
        }
    }

    @NonNull
    private static String errorMessageOrDefault(@NonNull Throwable error, @NonNull String fallback) {
        String message = normalizeNonEmpty(error.getMessage());
        return message != null ? message : fallback;
    }

    @Nullable
    private static String normalizeNonEmpty(@Nullable String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
