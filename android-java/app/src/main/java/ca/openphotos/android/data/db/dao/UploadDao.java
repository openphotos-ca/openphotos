package ca.openphotos.android.data.db.dao;

import androidx.room.Dao;
import androidx.room.Insert;
import androidx.room.OnConflictStrategy;
import androidx.room.Query;
import androidx.room.Update;

import ca.openphotos.android.data.db.entities.UploadEntity;

import java.util.List;

@Dao
public interface UploadDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    long upsert(UploadEntity e);

    @Update
    void update(UploadEntity e);

    @Query("SELECT * FROM uploads WHERE contentId = :contentId")
    List<UploadEntity> listByContentId(String contentId);

    @Query("SELECT * FROM uploads ORDER BY id DESC")
    List<UploadEntity> listAll();

    @Query("SELECT * FROM uploads WHERE status = 3 ORDER BY id DESC LIMIT :limit")
    List<UploadEntity> listFailed(int limit);

    @Query("UPDATE uploads SET tusUrl = :url WHERE id = :id")
    void setTusUrl(long id, String url);

    @Query("SELECT * FROM uploads WHERE status = 0 ORDER BY id ASC LIMIT :limit")
    List<UploadEntity> listQueued(int limit);

    @Query("UPDATE uploads SET status = 1, sentBytes = 0 WHERE id = :id AND status = 0")
    int claimQueued(long id);

    @Query("SELECT COUNT(1) FROM uploads WHERE status = :status")
    int countByStatus(int status);

    @Query("SELECT COUNT(1) FROM uploads WHERE contentId = :contentId AND status <> 2")
    int countNotDoneByContentId(String contentId);

    @Query("UPDATE uploads SET status = 0, sentBytes = 0 WHERE contentId = :contentId AND status = 3")
    int requeueFailedByContentId(String contentId);

    @Query("UPDATE uploads SET status = :status, sentBytes = :sent WHERE id = :id")
    void updateStatus(long id, int status, long sent);

    @Query("UPDATE uploads SET status = 0 WHERE status = 1")
    int requeueUploading();

    @Query("UPDATE uploads SET tempFilePath = :path WHERE id = :id")
    void setTempFilePath(long id, String path);
}
