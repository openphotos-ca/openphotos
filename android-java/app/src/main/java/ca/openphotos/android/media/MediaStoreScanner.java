package ca.openphotos.android.media;

import android.content.ContentResolver;
import android.content.Context;
import android.database.ContentObserver;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;

import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.entities.PhotoEntity;

import java.util.ArrayList;
import java.util.List;

/**
 * MediaStoreScanner loads device media and observes changes.
 * It persists/update basic rows in Room for sync candidate selection.
 */
public class MediaStoreScanner {
    private final Context app;
    private final AppDatabase db;
    private final ContentResolver resolver;
    private ContentObserver observer;

    public MediaStoreScanner(Context app) {
        this.app = app.getApplicationContext();
        this.db = AppDatabase.get(app);
        this.resolver = app.getContentResolver();
    }

    public void startObserving(Runnable onChange) {
        if (observer != null) return;
        observer = new ContentObserver(new Handler(Looper.getMainLooper())) {
            @Override
            public void onChange(boolean selfChange, Uri uri) { if (onChange != null) onChange.run(); }
        };
        resolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer);
        resolver.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, observer);
    }

    public void stopObserving() {
        if (observer != null) {
            resolver.unregisterContentObserver(observer);
            observer = null;
        }
    }

    public List<PhotoEntity> loadAll() {
        List<PhotoEntity> out = new ArrayList<>();
        out.addAll(queryImages());
        out.addAll(queryVideos());
        return out;
    }

    private List<PhotoEntity> queryImages() {
        List<PhotoEntity> list = new ArrayList<>();
        String[] proj = {
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.WIDTH,
                MediaStore.Images.Media.HEIGHT
        };
        try (Cursor c = resolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, proj, null, null, MediaStore.Images.Media.DATE_TAKEN + " DESC")) {
            if (c == null) return list;
            while (c.moveToNext()) {
                long id = c.getLong(0);
                long ts = c.getLong(1) / 1000L;
                int w = c.getInt(2);
                int h = c.getInt(3);
                Uri uri = Uri.withAppendedPath(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, String.valueOf(id));

                PhotoEntity p = new PhotoEntity();
                p.contentUri = uri.toString();
                p.mediaType = 0;
                p.creationTs = ts;
                p.pixelWidth = w;
                p.pixelHeight = h;
                p.syncState = 0;
                list.add(p);
            }
        }
        return list;
    }

    private List<PhotoEntity> queryVideos() {
        List<PhotoEntity> list = new ArrayList<>();
        String[] proj = {
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.DATE_TAKEN,
                MediaStore.Video.Media.WIDTH,
                MediaStore.Video.Media.HEIGHT
        };
        try (Cursor c = resolver.query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, proj, null, null, MediaStore.Video.Media.DATE_TAKEN + " DESC")) {
            if (c == null) return list;
            while (c.moveToNext()) {
                long id = c.getLong(0);
                long ts = c.getLong(1) / 1000L;
                int w = c.getInt(2);
                int h = c.getInt(3);
                Uri uri = Uri.withAppendedPath(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, String.valueOf(id));

                PhotoEntity p = new PhotoEntity();
                p.contentUri = uri.toString();
                p.mediaType = 1;
                p.creationTs = ts;
                p.pixelWidth = w;
                p.pixelHeight = h;
                p.syncState = 0;
                list.add(p);
            }
        }
        return list;
    }
}

