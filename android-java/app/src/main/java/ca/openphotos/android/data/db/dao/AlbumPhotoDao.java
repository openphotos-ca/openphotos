package ca.openphotos.android.data.db.dao;

import androidx.room.Dao;
import androidx.room.Insert;
import androidx.room.OnConflictStrategy;
import androidx.room.Query;

import ca.openphotos.android.data.db.entities.AlbumPhotoEntity;

import java.util.List;

@Dao
public interface AlbumPhotoDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    long insert(AlbumPhotoEntity e);

    @Query("SELECT DISTINCT assetId FROM album_photos WHERE albumId = :albumId")
    List<String> getAssetsForAlbum(long albumId);
}

