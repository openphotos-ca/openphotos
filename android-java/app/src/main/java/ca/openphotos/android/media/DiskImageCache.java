package ca.openphotos.android.media;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.util.Log;

import ca.openphotos.android.core.AuthManager;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * DiskImageCache provides a simple, production‑ready disk cache for image/video bytes on Android.
 *
 * Parity with iOS (DiskImageCache.swift):
 * - Root: context.getCacheDir()/OpenPhotos/{server_hash}/{user_id}/
 * - Buckets: thumbs/, images/, faces/, videos/
 * - LRU: Touch on read; prune oldest by lastModified when exceeding per-bucket caps
 * - Keying: Stable by SHA-256(key) with 2-level shard (aa/bb/hex[64][.ext])
 * - Server Hash: First 10 hex chars of SHA-256("scheme://host:port")
 */
public final class DiskImageCache {
    public enum Bucket { THUMBS, IMAGES, FACES, VIDEOS }

    /** Byte caps for individual buckets. */
    public static final class Caps {
        public final long thumbsBytes;
        public final long imagesBytes;
        public final long videosBytes;
        public Caps(long thumbsBytes, long imagesBytes, long videosBytes) {
            this.thumbsBytes = thumbsBytes; this.imagesBytes = imagesBytes; this.videosBytes = videosBytes;
        }
        public static final Caps DEFAULTS = new Caps(
                200L * 1024L * 1024L,   // 200 MB thumbs
                1024L * 1024L * 1024L,  // 1 GB images
                2L * 1024L * 1024L * 1024L // 2 GB videos
        );
    }

    private static final String TAG = "OpenPhotos";
    private static final String PREFS = "cache.caps";
    private static final String K_THUMBS = "cache.cap.thumbs";
    private static final String K_IMAGES = "cache.cap.images";
    private static final String K_VIDEOS = "cache.cap.videos";

    private static volatile DiskImageCache INSTANCE;
    private final Context app;

    private DiskImageCache(Context app) { this.app = app.getApplicationContext(); }

    /** Singleton accessor. */
    public static DiskImageCache get(Context app) {
        if (INSTANCE == null) {
            synchronized (DiskImageCache.class) {
                if (INSTANCE == null) INSTANCE = new DiskImageCache(app);
            }
        }
        return INSTANCE;
    }

    /**
     * Read cached bytes for a key/bucket, touching LRU on hit.
     * Note: Intended for small objects only; prefer {@link #readFile} or {@link #readStream}
     * for large media to avoid high memory usage.
     */
    public byte[] readBytes(Bucket bucket, String key) {
        File f = fileFor(bucket, key, null);
        if (!f.exists()) { return null; }
        // Touch LRU by updating mtime
        //noinspection ResultOfMethodCallIgnored
        f.setLastModified(System.currentTimeMillis());
        try (BufferedInputStream bis = new BufferedInputStream(new FileInputStream(f))) {
            java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream((int) Math.min(f.length(), Integer.MAX_VALUE));
            byte[] buf = new byte[8192]; int r; while ((r = bis.read(buf)) > 0) baos.write(buf, 0, r);
            return baos.toByteArray();
        } catch (IOException e) {
            try { Log.w(TAG, "[CACHE] readBytes failed " + f.getAbsolutePath() + " err=" + e.getMessage()); } catch (Exception ignored) {}
            return null;
        }
    }

    /** Return cached file URL for a key/bucket, touching LRU on hit. */
    public File readFile(Bucket bucket, String key) {
        File f = fileFor(bucket, key, null);
        if (!f.exists()) return null;
        //noinspection ResultOfMethodCallIgnored
        f.setLastModified(System.currentTimeMillis());
        return f;
    }

    /**
     * Open a streaming InputStream for a cached item (touching LRU on hit).
     * Caller is responsible for closing the returned stream.
     */
    public java.io.InputStream readStream(Bucket bucket, String key) {
        File f = fileFor(bucket, key, null);
        if (!f.exists()) return null;
        //noinspection ResultOfMethodCallIgnored
        f.setLastModified(System.currentTimeMillis());
        try {
            return new BufferedInputStream(new FileInputStream(f));
        } catch (IOException e) { return null; }
    }

    /** Write bytes atomically to cache. Optional extension improves OS interop (e.g. webp/jpg/mov). */
    public File write(Bucket bucket, String key, byte[] data, String ext) {
        File f = fileFor(bucket, key, ext);
        try {
            // Ensure directories exist (including sharded parents)
            File dir = f.getParentFile();
            if (dir != null && !dir.exists()) {
                if (!dir.mkdirs() && !dir.exists()) throw new IOException("mkdirs failed: " + dir.getAbsolutePath());
            }
            // Write atomically via temp + rename
            File tmp = File.createTempFile("ab_cache_", ".tmp", dir != null ? dir : app.getCacheDir());
            try (BufferedOutputStream bos = new BufferedOutputStream(new FileOutputStream(tmp))) {
                bos.write(data);
            }
            if (!tmp.renameTo(f)) {
                // Fallback to copy and delete
                try (FileInputStream is = new FileInputStream(tmp); FileOutputStream os = new FileOutputStream(f)) {
                    byte[] buf = new byte[8192]; int r; while ((r = is.read(buf)) > 0) os.write(buf, 0, r);
                }
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
            // Touch
            //noinspection ResultOfMethodCallIgnored
            f.setLastModified(System.currentTimeMillis());
            pruneIfNeeded(bucket);
            try { Log.i(TAG, "[CACHE] wrote " + data.length + " bytes to " + rel(f)); } catch (Exception ignored) {}
            return f;
        } catch (IOException e) {
            try { Log.w(TAG, "[CACHE] write failed key=" + key + " err=" + e.getMessage()); } catch (Exception ignored) {}
            return null;
        }
    }

    /**
     * Stream-write to cache from an InputStream. The stream is consumed and not closed by this method.
     * Optional extension improves OS interop (e.g. webp/jpg/mov).
     */
    public File write(Bucket bucket, String key, java.io.InputStream in, long length, String ext) {
        File f = fileFor(bucket, key, ext);
        try {
            File dir = f.getParentFile();
            if (dir != null && !dir.exists()) {
                if (!dir.mkdirs() && !dir.exists()) throw new IOException("mkdirs failed: " + dir.getAbsolutePath());
            }
            File tmp = File.createTempFile("ab_cache_", ".tmp", dir != null ? dir : app.getCacheDir());
            try (BufferedOutputStream bos = new BufferedOutputStream(new FileOutputStream(tmp))) {
                byte[] buf = new byte[8192]; int r; while ((r = in.read(buf)) > 0) bos.write(buf, 0, r);
            }
            if (!tmp.renameTo(f)) {
                try (FileInputStream is = new FileInputStream(tmp); FileOutputStream os = new FileOutputStream(f)) {
                    byte[] buf = new byte[8192]; int r; while ((r = is.read(buf)) > 0) os.write(buf, 0, r);
                }
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
            //noinspection ResultOfMethodCallIgnored
            f.setLastModified(System.currentTimeMillis());
            pruneIfNeeded(bucket);
            try { Log.i(TAG, "[CACHE] wrote (stream) to " + rel(f)); } catch (Exception ignored) {}
            return f;
        } catch (IOException e) {
            try { Log.w(TAG, "[CACHE] write(stream) failed key=" + key + " err=" + e.getMessage()); } catch (Exception ignored) {}
            return null;
        }
    }

    /** Compute on-disk usage for a bucket (bytes). */
    public long usageBytes(Bucket bucket) {
        File dir = bucketDir(bucket);
        return dirSize(dir);
    }

    /** Get effective caps (bytes), reading from SharedPreferences with defaults. */
    public Caps getCaps() {
        SharedPreferences sp = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long t = sp.getLong(K_THUMBS, Caps.DEFAULTS.thumbsBytes);
        long i = sp.getLong(K_IMAGES, Caps.DEFAULTS.imagesBytes);
        long v = sp.getLong(K_VIDEOS, Caps.DEFAULTS.videosBytes);
        return new Caps(t, i, v);
    }

    /** Persist new caps. */
    public void setCaps(Caps caps) {
        SharedPreferences sp = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        sp.edit()
                .putLong(K_THUMBS, caps.thumbsBytes)
                .putLong(K_IMAGES, caps.imagesBytes)
                .putLong(K_VIDEOS, caps.videosBytes)
                .apply();
    }

    /** Clear all cached buckets under current server/user namespace. */
    public void clearAll() {
        File root = baseRoot();
        deleteRecursively(root);
    }

    // ---- Internals ----

    private File baseRoot() {
        String serverHash = serverHash10();
        String uid = AuthManager.get(app).getUserId();
        if (uid == null || uid.isEmpty()) uid = "anon";
        File root = new File(app.getCacheDir(), "OpenPhotos");
        return new File(new File(root, serverHash), uid);
    }

    private File bucketDir(Bucket bucket) {
        String name;
        switch (bucket) {
            case THUMBS: name = "thumbs"; break;
            case IMAGES: name = "images"; break;
            case FACES: name = "faces"; break;
            case VIDEOS: name = "videos"; break;
            default: name = "misc"; break;
        }
        return new File(baseRoot(), name);
    }

    private File fileFor(Bucket bucket, String key, String ext) {
        String hex = sha256Hex(key);
        String a = hex.substring(0, 2);
        String b = hex.substring(2, 4);
        String name = hex + (ext != null && !ext.isEmpty() ? ("." + ext) : "");
        return new File(new File(new File(bucketDir(bucket), a), b), name);
    }

    private void pruneIfNeeded(Bucket bucket) {
        long cap;
        Caps caps = getCaps();
        switch (bucket) {
            case THUMBS: case FACES: cap = caps.thumbsBytes; break; // faces share thumbs cap
            case IMAGES: cap = caps.imagesBytes; break;
            case VIDEOS: default: cap = caps.videosBytes; break;
        }
        File dir = bucketDir(bucket);
        long total = dirSize(dir);
        if (total <= cap) return;
        List<File> files = listFilesRecursively(dir);
        // Oldest first by lastModified
        Collections.sort(files, Comparator.comparingLong(File::lastModified));
        for (File f : files) {
            long sz = f.length();
            //noinspection ResultOfMethodCallIgnored
            f.delete();
            total -= sz;
            if (total <= cap) break;
        }
        try { Log.i(TAG, "[CACHE] prune complete bucket=" + bucket + " total=" + total + " cap=" + cap); } catch (Exception ignored) {}
    }

    private static long dirSize(File dir) {
        if (dir == null || !dir.exists()) return 0L;
        long size = 0;
        File[] files = dir.listFiles();
        if (files == null) return 0L;
        for (File f : files) {
            if (f.isDirectory()) size += dirSize(f);
            else size += f.length();
        }
        return size;
    }

    private static List<File> listFilesRecursively(File dir) {
        List<File> out = new ArrayList<>();
        if (dir == null || !dir.exists()) return out;
        File[] files = dir.listFiles();
        if (files == null) return out;
        for (File f : files) {
            if (f.isDirectory()) out.addAll(listFilesRecursively(f));
            else out.add(f);
        }
        return out;
    }

    private static void deleteRecursively(File f) {
        if (f == null || !f.exists()) return;
        if (f.isDirectory()) {
            File[] kids = f.listFiles();
            if (kids != null) for (File k : kids) deleteRecursively(k);
        }
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }

    private String serverHash10() {
        try {
            String raw = AuthManager.get(app).getServerUrl();
            Uri u = Uri.parse(raw);
            String scheme = u.getScheme() != null ? u.getScheme() : "http";
            String host = u.getHost() != null ? u.getHost() : "";
            int port = u.getPort();
            String base = scheme + "://" + host + (port > 0 ? (":" + port) : "");
            String hex = sha256Hex(base);
            return hex.substring(0, 10);
        } catch (Exception e) {
            return "unknown";
        }
    }

    private static String sha256Hex(String s) {
        try {
            MessageDigest d = MessageDigest.getInstance("SHA-256");
            byte[] h = d.digest(s.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : h) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            // Should never happen on Android
            return "";
        }
    }

    private String rel(File f) {
        try { return f.getAbsolutePath().replace(app.getCacheDir().getAbsolutePath(), "<cache>"); } catch (Exception e) { return f.getAbsolutePath(); }
    }
}
