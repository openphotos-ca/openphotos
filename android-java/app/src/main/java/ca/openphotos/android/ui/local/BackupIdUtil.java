package ca.openphotos.android.ui.local;

import android.content.Context;
import android.net.Uri;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import ca.openphotos.android.media.Transforms;
import ca.openphotos.android.util.Base58;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** backup_id helpers matching server/iOS cloud-check hashing semantics. */
public final class BackupIdUtil {
    private BackupIdUtil() {}

    @NonNull
    public static String fingerprint(@NonNull LocalMediaItem item) {
        String raw = "v1|"
                + item.localId + "|"
                + item.mimeType + "|"
                + item.displayName + "|"
                + item.sizeBytes + "|"
                + item.createdAtSec + "|"
                + item.dateModifiedSec + "|"
                + item.width + "x" + item.height + "|"
                + item.durationMs;
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] out = md.digest(raw.getBytes(StandardCharsets.UTF_8));
            return Base58.encode(out);
        } catch (Exception ignored) {
            return raw;
        }
    }

    @NonNull
    public static List<String> computeBackupIdCandidates(
            @NonNull Context app,
            @NonNull LocalMediaItem item,
            @NonNull String userId
    ) {
        Set<String> out = new LinkedHashSet<>();
        Uri uri = Uri.parse(item.uri);

        String mime = item.mimeType.toLowerCase(Locale.US);
        String lowerName = item.displayName.toLowerCase(Locale.US);
        boolean likelyJpeg = mime.contains("jpeg") || mime.contains("jpg") || lowerName.endsWith(".jpg") || lowerName.endsWith(".jpeg");
        boolean likelyHeic = !item.isVideo && (mime.contains("heic") || mime.contains("heif") || lowerName.endsWith(".heic") || lowerName.endsWith(".heif"));

        String primary = computeBackupIdForUri(app, uri, userId, likelyJpeg);
        if (primary != null && !primary.isEmpty()) out.add(primary);

        if (likelyHeic) {
            File conv = null;
            try {
                conv = Transforms.heicToJpeg(app, uri, 0.90f);
                String alt = computeBackupIdForFile(conv, userId, true);
                if (alt != null && !alt.isEmpty()) out.add(alt);
            } catch (Exception ignored) {
            } finally {
                if (conv != null) {
                    try { conv.delete(); } catch (Exception ignored) {}
                }
            }
        }

        return new ArrayList<>(out);
    }

    @Nullable
    private static String computeBackupIdForUri(@NonNull Context app, @NonNull Uri uri, @NonNull String userId, boolean likelyJpeg) {
        try {
            if (likelyJpeg) {
                byte[] bytes = readAll(app.getContentResolver().openInputStream(uri));
                if (bytes == null || bytes.length == 0) return null;
                byte[] stable = stripJpegExifXmpApp1(bytes);
                return hmacFirst16B58(userId, stable);
            }
            try (InputStream is = app.getContentResolver().openInputStream(uri)) {
                if (is == null) return null;
                return hmacFirst16B58(userId, is);
            }
        } catch (Exception ignored) {
            return null;
        }
    }

    @Nullable
    private static String computeBackupIdForFile(@Nullable File file, @NonNull String userId, boolean jpeg) {
        if (file == null || !file.exists()) return null;
        try {
            if (jpeg) {
                byte[] bytes = readAll(new FileInputStream(file));
                if (bytes == null || bytes.length == 0) return null;
                return hmacFirst16B58(userId, stripJpegExifXmpApp1(bytes));
            }
            try (InputStream is = new FileInputStream(file)) {
                return hmacFirst16B58(userId, is);
            }
        } catch (Exception ignored) {
            return null;
        }
    }

    @Nullable
    private static byte[] readAll(@Nullable InputStream is) {
        if (is == null) return null;
        try (InputStream in = is; ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        } catch (Exception ignored) {
            return null;
        }
    }

    @Nullable
    private static String hmacFirst16B58(@NonNull String userId, @NonNull byte[] bytes) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(userId.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            mac.update(bytes);
            byte[] full = mac.doFinal();
            byte[] first16 = new byte[16];
            System.arraycopy(full, 0, first16, 0, 16);
            return Base58.encode(first16);
        } catch (Exception ignored) {
            return null;
        }
    }

    @Nullable
    private static String hmacFirst16B58(@NonNull String userId, @NonNull InputStream is) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(userId.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            byte[] buf = new byte[1024 * 1024];
            int n;
            while ((n = is.read(buf)) > 0) mac.update(buf, 0, n);
            byte[] full = mac.doFinal();
            byte[] first16 = new byte[16];
            System.arraycopy(full, 0, first16, 0, 16);
            return Base58.encode(first16);
        } catch (Exception ignored) {
            return null;
        }
    }

    /** For JPEG data, strip APP1 Exif/XMP segments before hashing (same stability rule as iOS/server). */
    @NonNull
    private static byte[] stripJpegExifXmpApp1(@NonNull byte[] bytes) {
        if (bytes.length < 2 || (bytes[0] & 0xFF) != 0xFF || (bytes[1] & 0xFF) != 0xD8) return bytes;

        byte[] exifPrefix = new byte[]{0x45, 0x78, 0x69, 0x66, 0x00, 0x00}; // Exif\0\0
        byte[] xmpPrefix = "http://ns.adobe.com/xap/1.0/\0".getBytes(StandardCharsets.UTF_8);

        ByteArrayOutputStream out = new ByteArrayOutputStream(bytes.length);
        out.write(bytes, 0, 2); // SOI

        int i = 2;
        while (i + 4 <= bytes.length) {
            if ((bytes[i] & 0xFF) != 0xFF) return bytes;
            int j = i;
            while (j < bytes.length && (bytes[j] & 0xFF) == 0xFF) j++;
            if (j >= bytes.length) return bytes;

            int marker = bytes[j] & 0xFF;
            if (marker == 0xD9) {
                out.write(bytes, i, (j + 1) - i);
                return out.toByteArray();
            }
            if (marker == 0xDA) {
                out.write(bytes, i, bytes.length - i);
                return out.toByteArray();
            }
            if (j + 2 >= bytes.length) return bytes;

            int segLen = ((bytes[j + 1] & 0xFF) << 8) | (bytes[j + 2] & 0xFF);
            int segEnd = j + 1 + segLen;
            if (segEnd > bytes.length) return bytes;

            int payloadOff = j + 3;
            boolean keep = true;
            if (marker == 0xE1) {
                int payloadLen = segEnd - payloadOff;
                if (payloadLen >= exifPrefix.length && startsWith(bytes, payloadOff, exifPrefix)) {
                    keep = false;
                } else if (payloadLen >= xmpPrefix.length && startsWith(bytes, payloadOff, xmpPrefix)) {
                    keep = false;
                }
            }
            if (keep) out.write(bytes, i, segEnd - i);
            i = segEnd;
        }

        return bytes;
    }

    private static boolean startsWith(byte[] src, int off, byte[] prefix) {
        if (off < 0 || off + prefix.length > src.length) return false;
        for (int i = 0; i < prefix.length; i++) {
            if (src[off + i] != prefix[i]) return false;
        }
        return true;
    }
}
