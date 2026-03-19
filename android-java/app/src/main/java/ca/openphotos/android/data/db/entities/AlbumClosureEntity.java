package ca.openphotos.android.data.db.entities;

import androidx.room.Entity;
import androidx.room.Index;
import androidx.room.PrimaryKey;

@Entity(tableName = "album_closure", indices = {@Index("ancestorId"), @Index("descendantId")})
public class AlbumClosureEntity {
    @PrimaryKey(autoGenerate = true) public long id;
    public long ancestorId;
    public long descendantId;
    public int depth;
}

