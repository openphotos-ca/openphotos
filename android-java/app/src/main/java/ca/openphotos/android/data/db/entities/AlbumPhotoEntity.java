package ca.openphotos.android.data.db.entities;

import androidx.room.Entity;
import androidx.room.Index;
import androidx.room.PrimaryKey;

@Entity(tableName = "album_photos", indices = {@Index("albumId"), @Index("assetId")})
public class AlbumPhotoEntity {
    @PrimaryKey(autoGenerate = true) public long id;
    public long albumId;
    public String assetId; // contentUri or contentId (we use contentUri for membership)
    public String photoId; // stable per album membership (e.g., hash)
    public long addedAt;
}

