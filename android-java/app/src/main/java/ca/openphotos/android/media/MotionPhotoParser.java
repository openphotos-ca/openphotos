package ca.openphotos.android.media;

import android.content.Context;
import android.net.Uri;
import android.util.Log;

import androidx.annotation.Nullable;

import java.io.File;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Detect Motion Photos (Pixel/Samsung) and extract the embedded MP4 as a temp file.
 */
public final class MotionPhotoParser {
    private static final String TAG = "OpenPhotosMotion";
    private static final int HEAD_TEXT_MAX = 1024 * 1024;
    private static final int TAIL_MAX = 64 * 1024;
    private static final byte[] FTYP = new byte[]{'f', 't', 'y', 'p'};
    private static final Pattern P_MOTION_LENGTH_SEMANTIC_FIRST = Pattern.compile(
            "Item:Semantic\\s*=\\s*\"MotionPhoto\"[\\s\\S]{0,400}?Item:Length\\s*=\\s*\"(\\d+)\""
    );
    private static final Pattern P_MOTION_LENGTH_LENGTH_FIRST = Pattern.compile(
            "Item:Length\\s*=\\s*\"(\\d+)\"[\\s\\S]{0,400}?Item:Semantic\\s*=\\s*\"MotionPhoto\""
    );
    private static final Pattern P_MOTION_DATALENGTH = Pattern.compile("Item:DataLength\\s*=\\s*\"(\\d+)\"");
    private static final Pattern P_MICROVIDEO_OFFSET_ATTR = Pattern.compile(
            "(?:GCamera|Camera):MicroVideoOffset\\s*=\\s*\"(\\d+)\""
    );
    private static final Pattern P_MICROVIDEO_OFFSET_TAG = Pattern.compile(
            "(?:GCamera|Camera):MicroVideoOffset>\\s*(\\d+)\\s*<"
    );

    public static class Result { public final boolean isMotion; public final @Nullable File mp4; public Result(boolean isMotion, @Nullable File mp4) { this.isMotion = isMotion; this.mp4 = mp4; } }

    private MotionPhotoParser() {}

    public static Result detectAndExtract(Context app, Uri jpegUri) {
        // Stream source to temp while capturing head-text (for XMP) and tail-bytes (for fallback heuristics).
        File tmp = null;
        try {
            java.io.InputStream is = app.getContentResolver().openInputStream(jpegUri);
            if (is == null) return new Result(false, null);
            tmp = java.io.File.createTempFile("jpeg_", ".bin", app.getCacheDir());
            StringBuilder headText = new StringBuilder(HEAD_TEXT_MAX);
            java.io.ByteArrayOutputStream tail = new java.io.ByteArrayOutputStream(TAIL_MAX + 4);
            byte[] buf = new byte[8192]; int r; long total = 0;
            try (java.io.FileOutputStream fos = new java.io.FileOutputStream(tmp)) {
                while ((r = is.read(buf)) > 0) {
                    fos.write(buf, 0, r);
                    total += r;
                    if (headText.length() < HEAD_TEXT_MAX) {
                        int remaining = HEAD_TEXT_MAX - headText.length();
                        int take = Math.min(remaining, r);
                        headText.append(new String(buf, 0, take, StandardCharsets.ISO_8859_1));
                    }
                    tail.write(buf, 0, r);
                    if (tail.size() > TAIL_MAX) {
                        byte[] t = tail.toByteArray();
                        tail.reset();
                        tail.write(t, t.length - TAIL_MAX, TAIL_MAX);
                    }
                }
            } finally { try { is.close(); } catch (Exception ignored) {} }

            int offset = findMotionOffsetFromXmp(headText.toString(), total);
            if (offset <= 0) {
                // Tail fallback for files where MP4 starts near file end.
                byte[] tailBytes = tail.toByteArray();
                int idx = lastIndexOf(tailBytes, FTYP);
                if (idx >= 4) {
                    long calc = (total - tailBytes.length) + (idx - 4); // include MP4 box size
                    if (isOffsetInRange(calc, total) && hasFtypAtOffset(tmp, (int) calc)) {
                        offset = (int) calc;
                        Log.i(TAG, "parser-tail-ftyp offset=" + offset + " total=" + total);
                    }
                }
            }
            if (offset <= 0) {
                offset = findMp4OffsetByScanning(tmp);
                if (offset > 0) {
                    Log.i(TAG, "parser-scan-ftyp offset=" + offset + " total=" + total);
                }
            }

            if (offset > 0 && tmp.length() > offset && hasFtypAtOffset(tmp, offset)) {
                File out = java.io.File.createTempFile("motion_", ".mp4", app.getCacheDir());
                try (java.io.RandomAccessFile raf = new java.io.RandomAccessFile(tmp, "r"); java.io.FileOutputStream fos = new java.io.FileOutputStream(out)) {
                    raf.seek(offset);
                    byte[] cbuf = new byte[64 * 1024]; int n;
                    while ((n = raf.read(cbuf)) > 0) fos.write(cbuf, 0, n);
                }
                try { tmp.delete(); } catch (Exception ignored) {}
                return new Result(true, out);
            }
            try { if (tmp != null) tmp.delete(); } catch (Exception ignored) {}
            return new Result(false, null);
        } catch (Exception e) {
            Log.w(TAG, "parser detectAndExtract failed: " + e.getMessage());
            try { if (tmp != null) tmp.delete(); } catch (Exception ignored) {}
            return new Result(false, null);
        }
    }

    private static int findMotionOffsetFromXmp(String xmpText, long totalBytes) {
        int fromLength = offsetFromLengthPattern(xmpText, totalBytes);
        if (fromLength > 0) {
            Log.i(TAG, "parser-xmp-length offset=" + fromLength + " total=" + totalBytes);
            return fromLength;
        }

        int fromMicroOffset = offsetFromMicroVideoOffset(xmpText, totalBytes);
        if (fromMicroOffset > 0) {
            Log.i(TAG, "parser-xmp-micro-offset offset=" + fromMicroOffset + " total=" + totalBytes);
            return fromMicroOffset;
        }
        return -1;
    }

    private static int offsetFromLengthPattern(String xmpText, long totalBytes) {
        Long length = firstLongMatch(P_MOTION_LENGTH_SEMANTIC_FIRST, xmpText);
        if (length == null) length = firstLongMatch(P_MOTION_LENGTH_LENGTH_FIRST, xmpText);
        if (length == null) length = firstLongMatch(P_MOTION_DATALENGTH, xmpText);
        if (length == null || length <= 0 || length >= totalBytes) return -1;
        long start = totalBytes - length;
        return isOffsetInRange(start, totalBytes) ? (int) start : -1;
    }

    private static int offsetFromMicroVideoOffset(String xmpText, long totalBytes) {
        Long offsetFromEnd = firstLongMatch(P_MICROVIDEO_OFFSET_ATTR, xmpText);
        if (offsetFromEnd == null) offsetFromEnd = firstLongMatch(P_MICROVIDEO_OFFSET_TAG, xmpText);
        if (offsetFromEnd == null || offsetFromEnd <= 0 || offsetFromEnd >= totalBytes) return -1;
        long start = totalBytes - offsetFromEnd;
        return isOffsetInRange(start, totalBytes) ? (int) start : -1;
    }

    private static Long firstLongMatch(Pattern pattern, String value) {
        Matcher m = pattern.matcher(value);
        if (!m.find()) return null;
        try {
            return Long.parseLong(m.group(1));
        } catch (Exception ignored) {
            return null;
        }
    }

    private static boolean isOffsetInRange(long offset, long totalBytes) {
        return offset >= 4 && offset < totalBytes - 8 && offset <= Integer.MAX_VALUE;
    }

    private static boolean hasFtypAtOffset(File file, int mp4StartOffset) {
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            long len = raf.length();
            if (mp4StartOffset < 0 || mp4StartOffset + 8 > len) return false;
            raf.seek(mp4StartOffset + 4L);
            byte[] tag = new byte[4];
            raf.readFully(tag);
            return tag[0] == FTYP[0] && tag[1] == FTYP[1] && tag[2] == FTYP[2] && tag[3] == FTYP[3];
        } catch (Exception ignored) {
            return false;
        }
    }

    private static int findMp4OffsetByScanning(File file) {
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            long total = raf.length();
            final int chunkSize = 64 * 1024;
            byte[] chunk = new byte[chunkSize + 3];
            int carry = 0;
            long filePos = 0;
            while (filePos < total) {
                int toRead = (int) Math.min(chunkSize, total - filePos);
                raf.seek(filePos);
                raf.readFully(chunk, carry, toRead);
                int window = carry + toRead;
                int from = 0;
                while (true) {
                    int idx = indexOf(chunk, window, FTYP, from);
                    if (idx < 0) break;
                    long ftypPos = (filePos - carry) + idx;
                    long mp4Start = ftypPos - 4;
                    if (isLikelyMp4Start(raf, mp4Start, total)) {
                        return (int) mp4Start;
                    }
                    from = idx + 1;
                }
                carry = Math.min(3, window);
                System.arraycopy(chunk, window - carry, chunk, 0, carry);
                filePos += toRead;
            }
        } catch (Exception ignored) {
        }
        return -1;
    }

    private static boolean isLikelyMp4Start(RandomAccessFile raf, long start, long total) {
        try {
            if (start < 0 || start + 8 > total) return false;
            raf.seek(start);
            long size = readUInt32(raf);
            if (size == 1) {
                if (start + 16 > total) return false;
                size = readUInt64(raf);
            } else if (size == 0) {
                size = total - start;
            }
            if (size < 8 || start + size > total) return false;
            byte[] tag = new byte[4];
            raf.readFully(tag);
            return tag[0] == FTYP[0] && tag[1] == FTYP[1] && tag[2] == FTYP[2] && tag[3] == FTYP[3];
        } catch (Exception ignored) {
            return false;
        }
    }

    private static long readUInt32(RandomAccessFile raf) throws java.io.IOException {
        long a = raf.readUnsignedByte();
        long b = raf.readUnsignedByte();
        long c = raf.readUnsignedByte();
        long d = raf.readUnsignedByte();
        return (a << 24) | (b << 16) | (c << 8) | d;
    }

    private static long readUInt64(RandomAccessFile raf) throws java.io.IOException {
        long hi = readUInt32(raf);
        long lo = readUInt32(raf);
        return (hi << 32) | lo;
    }

    private static int lastIndexOf(byte[] hay, byte[] needle) {
        for (int i = hay.length - needle.length; i >= 0; i--) {
            boolean ok = true;
            for (int j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) { ok = false; break; }
            }
            if (ok) return i;
        }
        return -1;
    }

    private static int indexOf(byte[] hay, int hayLength, byte[] needle, int start) {
        if (hayLength <= 0 || needle.length <= 0 || start < 0 || start >= hayLength) return -1;
        outer: for (int i = start; i <= hayLength - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) if (hay[i + j] != needle[j]) continue outer;
            return i;
        }
        return -1;
    }
}
