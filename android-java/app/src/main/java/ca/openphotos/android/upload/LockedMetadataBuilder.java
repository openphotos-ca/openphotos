package ca.openphotos.android.upload;

import android.content.Context;
import android.database.Cursor;
import android.graphics.BitmapFactory;
import android.location.Location;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.provider.MediaStore;

import androidx.exifinterface.media.ExifInterface;

import java.io.File;

import org.json.JSONObject;

/** Builds locked metadata map and header JSON fields. */
public final class LockedMetadataBuilder {
    private LockedMetadataBuilder() {}

    public static class Result { public final JSONObject tusMeta; public final JSONObject headerMeta; public Result(JSONObject a, JSONObject b) { tusMeta = a; headerMeta = b; } }

    public static Result build(Context app, Uri uri, boolean isVideo, long createdAt, String mimeHint, boolean includeLocation) {
        try {
            int width = 0, height = 0; long sizeKB = 0; double durationS = 0.0;
            String[] proj = isVideo ? new String[]{MediaStore.Video.Media.WIDTH, MediaStore.Video.Media.HEIGHT, MediaStore.Video.Media.SIZE, MediaStore.Video.Media.DURATION}
                                    : new String[]{MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.SIZE};
            Cursor c = app.getContentResolver().query(uri, proj, null, null, null);
            if (c != null) {
                if (c.moveToFirst()) {
                    width = c.getInt(0);
                    height = c.getInt(1);
                    sizeKB = Math.max(1, Math.round((c.getLong(2) / 1024.0)));
                    if (isVideo) durationS = Math.max(0, c.getLong(3) / 1000.0);
                }
                c.close();
            }
            String ymd = ymd(createdAt);
            JSONObject tus = new JSONObject();
            tus.put("capture_ymd", ymd);
            tus.put("size_kb", String.valueOf(sizeKB));
            tus.put("width", String.valueOf(width));
            tus.put("height", String.valueOf(height));
            tus.put("orientation", "1");
            tus.put("is_video", isVideo ? "1" : "0");
            tus.put("duration_s", String.valueOf(isVideo ? durationS : 0));
            tus.put("mime_hint", mimeHint);
            tus.put("created_at", String.valueOf(createdAt));

            JSONObject header = new JSONObject();
            header.put("capture_ymd", ymd);
            header.put("size_kb", sizeKB);
            header.put("width", width);
            header.put("height", height);
            header.put("orientation", 1);
            header.put("is_video", isVideo ? 1 : 0);
            header.put("duration_s", isVideo ? durationS : 0);
            header.put("mime_hint", mimeHint);
            header.put("kind", "orig");

            if (includeLocation && !isVideo) {
                try {
                    androidx.exifinterface.media.ExifInterface exif = new androidx.exifinterface.media.ExifInterface(app.getContentResolver().openInputStream(uri));
                    float[] latlon = new float[2];
                    if (exif.getLatLong(latlon)) {
                        tus.put("latitude", String.valueOf(latlon[0]));
                        tus.put("longitude", String.valueOf(latlon[1]));
                        header.put("latitude", latlon[0]);
                        header.put("longitude", latlon[1]);
                    }
                } catch (Exception ignored) {}
            }

            return new Result(tus, header);
        } catch (Exception e) { return new Result(new JSONObject(), new JSONObject()); }
    }

    public static Result buildForFile(Context app, File file, boolean isVideo, long createdAt, String mimeHint, boolean includeLocation) {
        try {
            int width = 0, height = 0;
            long sizeKB = Math.max(1, Math.round(file.length() / 1024.0));
            double durationS = 0.0;
            if (isVideo) {
                try {
                    MediaMetadataRetriever mmr = new MediaMetadataRetriever();
                    mmr.setDataSource(file.getAbsolutePath());
                    String w = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH);
                    String h = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT);
                    String d = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
                    width = w != null ? Integer.parseInt(w) : 0;
                    height = h != null ? Integer.parseInt(h) : 0;
                    durationS = d != null ? Math.max(0.0, Long.parseLong(d) / 1000.0) : 0.0;
                    mmr.release();
                } catch (Exception ignored) {}
            } else {
                try {
                    BitmapFactory.Options o = new BitmapFactory.Options();
                    o.inJustDecodeBounds = true;
                    BitmapFactory.decodeFile(file.getAbsolutePath(), o);
                    width = Math.max(0, o.outWidth);
                    height = Math.max(0, o.outHeight);
                } catch (Exception ignored) {}
            }

            String ymd = ymd(createdAt);
            JSONObject tus = new JSONObject();
            tus.put("capture_ymd", ymd);
            tus.put("size_kb", String.valueOf(sizeKB));
            tus.put("width", String.valueOf(width));
            tus.put("height", String.valueOf(height));
            tus.put("orientation", "1");
            tus.put("is_video", isVideo ? "1" : "0");
            tus.put("duration_s", String.valueOf(isVideo ? durationS : 0));
            tus.put("mime_hint", mimeHint);
            tus.put("created_at", String.valueOf(createdAt));

            JSONObject header = new JSONObject();
            header.put("capture_ymd", ymd);
            header.put("size_kb", sizeKB);
            header.put("width", width);
            header.put("height", height);
            header.put("orientation", 1);
            header.put("is_video", isVideo ? 1 : 0);
            header.put("duration_s", isVideo ? durationS : 0);
            header.put("mime_hint", mimeHint);
            header.put("kind", "orig");

            if (includeLocation && !isVideo) {
                try {
                    ExifInterface exif = new ExifInterface(file.getAbsolutePath());
                    float[] latlon = new float[2];
                    if (exif.getLatLong(latlon)) {
                        tus.put("latitude", String.valueOf(latlon[0]));
                        tus.put("longitude", String.valueOf(latlon[1]));
                        header.put("latitude", latlon[0]);
                        header.put("longitude", latlon[1]);
                    }
                } catch (Exception ignored) {}
            }

            return new Result(tus, header);
        } catch (Exception e) {
            return new Result(new JSONObject(), new JSONObject());
        }
    }

    private static String ymd(long ts) {
        java.time.Instant ins = java.time.Instant.ofEpochSecond(ts);
        java.time.ZonedDateTime z = java.time.ZonedDateTime.ofInstant(ins, java.time.ZoneOffset.UTC);
        return String.format("%04d-%02d-%02d", z.getYear(), z.getMonthValue(), z.getDayOfMonth());
    }
}
