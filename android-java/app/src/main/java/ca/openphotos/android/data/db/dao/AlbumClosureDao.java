package ca.openphotos.android.data.db.dao;

import androidx.room.Dao;
import androidx.room.Insert;
import androidx.room.OnConflictStrategy;
import androidx.room.Query;

import ca.openphotos.android.data.db.entities.AlbumClosureEntity;

import java.util.List;

@Dao
public interface AlbumClosureDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    long upsert(AlbumClosureEntity e);

    @Query("SELECT descendantId FROM album_closure WHERE ancestorId = :ancestor")
    List<Long> descendantsOf(long ancestor);
}

