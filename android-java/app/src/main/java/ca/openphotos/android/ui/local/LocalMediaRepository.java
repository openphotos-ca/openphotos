package ca.openphotos.android.ui.local;

import android.content.ContentResolver;
import android.content.Context;
import android.database.ContentObserver;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;

import androidx.annotation.NonNull;

import ca.openphotos.android.media.MotionPhotoSupport;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/**
 * Loads local media from MediaStore and supports change observation for live refresh.
 */
public final class LocalMediaRepository {
    private final Context app;
    private final ContentResolver resolver;
    private ContentObserver observer;

    public LocalMediaRepository(@NonNull Context app) {
        this.app = app.getApplicationContext();
        this.resolver = this.app.getContentResolver();
    }

    public void startObserving(final Runnable onChanged) {
        if (observer != null) return;
        observer = new ContentObserver(new Handler(Looper.getMainLooper())) {
            @Override
            public void onChange(boolean selfChange, Uri uri) {
                if (onChanged != null) onChanged.run();
            }
        };
        resolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer);
        resolver.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, observer);
    }

    public void stopObserving() {
        if (observer == null) return;
        resolver.unregisterContentObserver(observer);
        observer = null;
    }

    @NonNull
    public List<LocalMediaItem> loadAll() {
        ArrayList<LocalMediaItem> out = new ArrayList<>();
        out.addAll(queryImages());
        out.addAll(queryVideos());
        Collections.sort(out, Comparator.comparingLong((LocalMediaItem it) -> it.createdAtSec).reversed());
        return out;
    }

    @NonNull
    private List<LocalMediaItem> queryImages() {
        ArrayList<LocalMediaItem> list = new ArrayList<>();
        String[] proj = new String[]{
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.DATE_MODIFIED,
                MediaStore.Images.Media.WIDTH,
                MediaStore.Images.Media.HEIGHT,
                MediaStore.Images.Media.SIZE,
                MediaStore.Images.Media.MIME_TYPE,
                MediaStore.Images.Media.RELATIVE_PATH,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
                MediaStore.Images.Media.IS_FAVORITE
        };

        try (Cursor c = resolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                proj,
                null,
                null,
                MediaStore.Images.Media.DATE_TAKEN + " DESC"
        )) {
            if (c == null) return list;
            int iId = c.getColumnIndex(MediaStore.Images.Media._ID);
            int iDateTaken = c.getColumnIndex(MediaStore.Images.Media.DATE_TAKEN);
            int iDateAdded = c.getColumnIndex(MediaStore.Images.Media.DATE_ADDED);
            int iDateModified = c.getColumnIndex(MediaStore.Images.Media.DATE_MODIFIED);
            int iW = c.getColumnIndex(MediaStore.Images.Media.WIDTH);
            int iH = c.getColumnIndex(MediaStore.Images.Media.HEIGHT);
            int iSize = c.getColumnIndex(MediaStore.Images.Media.SIZE);
            int iMime = c.getColumnIndex(MediaStore.Images.Media.MIME_TYPE);
            int iRel = c.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH);
            int iName = c.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME);
            int iBucket = c.getColumnIndex(MediaStore.Images.Media.BUCKET_DISPLAY_NAME);
            int iFav = c.getColumnIndex(MediaStore.Images.Media.IS_FAVORITE);

            while (c.moveToNext()) {
                long id = iId >= 0 ? c.getLong(iId) : 0L;
                String uri = Uri.withAppendedPath(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, String.valueOf(id)).toString();
                String name = iName >= 0 ? nonNull(c.getString(iName)) : "";
                String mime = iMime >= 0 ? nonNull(c.getString(iMime)) : "image/*";
                String rel = iRel >= 0 ? nonNull(c.getString(iRel)) : "";
                String bucket = iBucket >= 0 ? nonNull(c.getString(iBucket)) : "";
                long dateTakenMs = iDateTaken >= 0 ? c.getLong(iDateTaken) : 0L;
                long dateAddedSec = iDateAdded >= 0 ? c.getLong(iDateAdded) : 0L;
                long createdAtSec = dateTakenMs > 0 ? (dateTakenMs / 1000L) : dateAddedSec;
                long modifiedSec = iDateModified >= 0 ? c.getLong(iDateModified) : 0L;
                int w = iW >= 0 ? c.getInt(iW) : 0;
                int h = iH >= 0 ? c.getInt(iH) : 0;
                long size = iSize >= 0 ? c.getLong(iSize) : 0L;
                boolean favorite = iFav >= 0 && c.getInt(iFav) == 1;
                boolean screenshot = isScreenshot(rel, bucket, name);
                boolean motion = MotionPhotoSupport.isLikelyMotionPhoto(name, mime);

                list.add(new LocalMediaItem(
                        uri,
                        uri,
                        name,
                        mime,
                        rel,
                        false,
                        createdAtSec,
                        modifiedSec,
                        size,
                        0L,
                        w,
                        h,
                        favorite,
                        screenshot,
                        motion
                ));
            }
        } catch (Exception ignored) {
        }
        return list;
    }

    @NonNull
    private List<LocalMediaItem> queryVideos() {
        ArrayList<LocalMediaItem> list = new ArrayList<>();
        String[] proj = new String[]{
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.DATE_TAKEN,
                MediaStore.Video.Media.DATE_ADDED,
                MediaStore.Video.Media.DATE_MODIFIED,
                MediaStore.Video.Media.WIDTH,
                MediaStore.Video.Media.HEIGHT,
                MediaStore.Video.Media.SIZE,
                MediaStore.Video.Media.DURATION,
                MediaStore.Video.Media.MIME_TYPE,
                MediaStore.Video.Media.RELATIVE_PATH,
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.BUCKET_DISPLAY_NAME,
                MediaStore.Video.Media.IS_FAVORITE
        };

        try (Cursor c = resolver.query(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                proj,
                null,
                null,
                MediaStore.Video.Media.DATE_TAKEN + " DESC"
        )) {
            if (c == null) return list;
            int iId = c.getColumnIndex(MediaStore.Video.Media._ID);
            int iDateTaken = c.getColumnIndex(MediaStore.Video.Media.DATE_TAKEN);
            int iDateAdded = c.getColumnIndex(MediaStore.Video.Media.DATE_ADDED);
            int iDateModified = c.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED);
            int iW = c.getColumnIndex(MediaStore.Video.Media.WIDTH);
            int iH = c.getColumnIndex(MediaStore.Video.Media.HEIGHT);
            int iSize = c.getColumnIndex(MediaStore.Video.Media.SIZE);
            int iDuration = c.getColumnIndex(MediaStore.Video.Media.DURATION);
            int iMime = c.getColumnIndex(MediaStore.Video.Media.MIME_TYPE);
            int iRel = c.getColumnIndex(MediaStore.Video.Media.RELATIVE_PATH);
            int iName = c.getColumnIndex(MediaStore.Video.Media.DISPLAY_NAME);
            int iBucket = c.getColumnIndex(MediaStore.Video.Media.BUCKET_DISPLAY_NAME);
            int iFav = c.getColumnIndex(MediaStore.Video.Media.IS_FAVORITE);

            while (c.moveToNext()) {
                long id = iId >= 0 ? c.getLong(iId) : 0L;
                String uri = Uri.withAppendedPath(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, String.valueOf(id)).toString();
                String name = iName >= 0 ? nonNull(c.getString(iName)) : "";
                String mime = iMime >= 0 ? nonNull(c.getString(iMime)) : "video/*";
                String rel = iRel >= 0 ? nonNull(c.getString(iRel)) : "";
                String bucket = iBucket >= 0 ? nonNull(c.getString(iBucket)) : "";
                long dateTakenMs = iDateTaken >= 0 ? c.getLong(iDateTaken) : 0L;
                long dateAddedSec = iDateAdded >= 0 ? c.getLong(iDateAdded) : 0L;
                long createdAtSec = dateTakenMs > 0 ? (dateTakenMs / 1000L) : dateAddedSec;
                long modifiedSec = iDateModified >= 0 ? c.getLong(iDateModified) : 0L;
                int w = iW >= 0 ? c.getInt(iW) : 0;
                int h = iH >= 0 ? c.getInt(iH) : 0;
                long size = iSize >= 0 ? c.getLong(iSize) : 0L;
                long durationMs = iDuration >= 0 ? c.getLong(iDuration) : 0L;
                boolean favorite = iFav >= 0 && c.getInt(iFav) == 1;
                boolean screenshot = isScreenshot(rel, bucket, name);

                list.add(new LocalMediaItem(
                        uri,
                        uri,
                        name,
                        mime,
                        rel,
                        true,
                        createdAtSec,
                        modifiedSec,
                        size,
                        durationMs,
                        w,
                        h,
                        favorite,
                        screenshot,
                        false
                ));
            }
        } catch (Exception ignored) {
        }
        return list;
    }

    private static String nonNull(String v) {
        return v == null ? "" : v;
    }

    private static boolean isScreenshot(String relativePath, String bucket, String name) {
        String rel = relativePath == null ? "" : relativePath.toLowerCase(Locale.US);
        String b = bucket == null ? "" : bucket.toLowerCase(Locale.US);
        String n = name == null ? "" : name.toLowerCase(Locale.US);
        return rel.contains("/screenshots/") || b.contains("screenshot") || n.startsWith("screenshot");
    }

}
