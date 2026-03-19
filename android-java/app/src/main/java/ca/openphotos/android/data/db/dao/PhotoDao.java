package ca.openphotos.android.data.db.dao;

import androidx.room.Dao;
import androidx.room.Insert;
import androidx.room.OnConflictStrategy;
import androidx.room.Query;
import androidx.room.Update;

import ca.openphotos.android.data.db.entities.PhotoEntity;

import java.util.List;

@Dao
public interface PhotoDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    long insertIgnore(PhotoEntity e);

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    long upsert(PhotoEntity e);

    @Update
    void update(PhotoEntity e);

    @Query("SELECT * FROM photos WHERE contentId = :contentId LIMIT 1")
    PhotoEntity getByContentId(String contentId);

    @Query("UPDATE photos SET syncState = :state, lastAttemptAt = :ts WHERE contentId = :contentId")
    void setState(String contentId, int state, long ts);

    @Query("UPDATE photos SET syncState = 1, lastAttemptAt = :ts WHERE contentId = :contentId AND syncState <> 2")
    void markUploading(String contentId, long ts);

    @Query("UPDATE photos SET syncState = 4, lastAttemptAt = :ts WHERE contentId = :contentId AND syncState <> 2")
    void markBackgroundQueued(String contentId, long ts);

    @Query("UPDATE photos SET syncState = 4, attempts = attempts + 1, lastError = :error, lastAttemptAt = :ts WHERE contentId = :contentId AND syncState <> 2")
    void markRetryQueued(String contentId, String error, long ts);

    @Query("UPDATE photos SET syncState = 4, lastAttemptAt = :ts WHERE syncState = 1")
    int markUploadingAsBackgroundQueued(long ts);

    @Query("UPDATE photos SET syncState = 2, syncAt = :ts WHERE contentId = :contentId")
    void markSynced(String contentId, long ts);

    @Query("UPDATE photos SET syncState = 0, lastError = NULL, lastAttemptAt = :ts WHERE contentId = :contentId AND syncState <> 2")
    void markPending(String contentId, long ts);

    @Query("UPDATE photos SET syncState = 3, attempts = attempts + 1, lastError = :error, lastAttemptAt = :ts WHERE contentId = :contentId AND syncState <> 2")
    void markFailed(String contentId, String error, long ts);

    // --- Aggregates and maintenance for Sync Status ---

    @Query("SELECT COUNT(1) FROM photos WHERE syncState = 0")
    int countPending();

    @Query("SELECT COUNT(1) FROM photos WHERE syncState = 1")
    int countUploading();

    @Query("SELECT COUNT(1) FROM photos WHERE syncState = 4")
    int countBgQueued();

    @Query("SELECT COUNT(1) FROM photos WHERE syncState = 3")
    int countFailed();

    @Query("SELECT COUNT(1) FROM photos WHERE syncState = 2")
    int countSynced();

    @Query("SELECT MAX(COALESCE(lastAttemptAt, syncAt, 0)) FROM photos")
    long maxSyncOrAttemptTs();

    @Query("UPDATE photos SET syncState=0, attempts=0, lastError=NULL, lastAttemptAt=NULL, syncAt=NULL")
    int resetAllToPending();

    @Query("UPDATE photos SET syncState=0, attempts=0, lastError=NULL, lastAttemptAt=NULL WHERE syncState IN (3,4)")
    int retryStuckAndFailed();

    @Query("UPDATE photos SET syncState=0 WHERE syncState=4")
    int markBgQueuedAsPending();

    @Query("SELECT * FROM photos")
    java.util.List<PhotoEntity> listAll();
}
