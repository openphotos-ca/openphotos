package ca.openphotos.android.data.db;

import android.content.Context;
import androidx.room.Database;
import androidx.room.Room;
import androidx.room.RoomDatabase;

import ca.openphotos.android.data.db.dao.*;
import ca.openphotos.android.data.db.entities.*;

@Database(
        entities = {
                PhotoEntity.class,
                UploadEntity.class,
                AlbumEntity.class,
                AlbumPhotoEntity.class,
                AlbumClosureEntity.class
        },
        version = 1,
        exportSchema = false
)
public abstract class AppDatabase extends RoomDatabase {
    public abstract PhotoDao photoDao();
    public abstract UploadDao uploadDao();
    public abstract AlbumDao albumDao();
    public abstract AlbumPhotoDao albumPhotoDao();
    public abstract AlbumClosureDao albumClosureDao();

    private static volatile AppDatabase INSTANCE;
    public static AppDatabase get(Context app) {
        if (INSTANCE == null) {
            synchronized (AppDatabase.class) {
                if (INSTANCE == null) {
                    INSTANCE = Room.databaseBuilder(app.getApplicationContext(), AppDatabase.class, "openphotos.db").build();
                }
            }
        }
        return INSTANCE;
    }
}

