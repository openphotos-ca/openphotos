package ca.openphotos.android.upload;

import androidx.annotation.NonNull;

import java.io.EOFException;
import java.io.IOException;
import java.net.ConnectException;
import java.net.ProtocolException;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.util.Locale;

import javax.net.ssl.SSLException;

/** Classifies upload failures into retryable vs terminal and produces compact error summaries. */
public final class UploadFailurePolicy {
    private UploadFailurePolicy() {}

    public static boolean isRetryable(@NonNull Throwable error) {
        Throwable cur = error;
        while (cur != null) {
            String msg = safeMessage(cur);
            if (looksPermanent(msg)) return false;
            if (cur instanceof SocketTimeoutException
                    || cur instanceof ConnectException
                    || cur instanceof UnknownHostException
                    || cur instanceof SocketException
                    || cur instanceof SSLException
                    || cur instanceof EOFException) {
                return true;
            }
            if (cur instanceof ProtocolException) {
                return looksRetryable(msg);
            }
            if (cur instanceof IOException) {
                return true;
            }
            cur = cur.getCause();
        }
        return looksRetryable(safeMessage(error));
    }

    @NonNull
    public static String summarize(@NonNull Throwable error) {
        Throwable root = error;
        while (root.getCause() != null && root.getCause() != root) {
            root = root.getCause();
        }
        String name = root.getClass().getSimpleName();
        String message = root.getMessage();
        if (message == null || message.trim().isEmpty()) return name;
        String compact = name + ": " + message.trim().replace('\n', ' ').replace('\r', ' ');
        return compact.length() > 180 ? compact.substring(0, 180) : compact;
    }

    private static boolean looksPermanent(@NonNull String message) {
        return containsAny(message,
                " 400", " 401", " 403", " 404", " 409", " 410", " 422",
                "bad request", "unauthorized", "forbidden", "not found",
                "conflict", "precondition", "invalid metadata", "unsupported media type");
    }

    private static boolean looksRetryable(@NonNull String message) {
        return containsAny(message,
                "timeout", "timed out", "connection reset", "broken pipe",
                "eof", "enodata", "no data available", "connection refused",
                "stream was reset", "unexpected end", "temporarily unavailable",
                " 429", " 500", " 502", " 503", " 504");
    }

    private static boolean containsAny(@NonNull String haystack, @NonNull String... needles) {
        for (String needle : needles) {
            if (haystack.contains(needle)) return true;
        }
        return false;
    }

    @NonNull
    private static String safeMessage(@NonNull Throwable error) {
        String msg = error.getMessage();
        return msg == null ? "" : msg.toLowerCase(Locale.US);
    }
}
