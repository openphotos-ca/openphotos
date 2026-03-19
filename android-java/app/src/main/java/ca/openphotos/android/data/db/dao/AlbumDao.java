package ca.openphotos.android.data.db.dao;

import androidx.room.Dao;
import androidx.room.Insert;
import androidx.room.OnConflictStrategy;
import androidx.room.Query;
import androidx.room.Update;

import ca.openphotos.android.data.db.entities.AlbumEntity;

import java.util.List;

@Dao
public interface AlbumDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    long upsert(AlbumEntity e);

    @Update
    void update(AlbumEntity e);

    @Query("SELECT * FROM albums WHERE parentId IS NULL ORDER BY position, name")
    List<AlbumEntity> getRootAlbums();

    @Query("SELECT * FROM albums WHERE parentId = :parent ORDER BY position, name")
    List<AlbumEntity> getChildAlbums(long parent);
}

