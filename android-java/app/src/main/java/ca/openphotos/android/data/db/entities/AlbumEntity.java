package ca.openphotos.android.data.db.entities;

import androidx.room.Entity;
import androidx.room.PrimaryKey;

@Entity(tableName = "albums")
public class AlbumEntity {
    @PrimaryKey(autoGenerate = true) public long id;
    public String name;
    public String description;
    public Long parentId; // nullable
    public int position;
    public boolean isSystem;
    public boolean isLive;
    public String liveCriteria; // JSON (server-compatible)
    public Long createdAt; // seconds
    public Long updatedAt; // seconds

    // Sync & Locked flags (per-folder tree)
    public Boolean syncEnabled;
    public Boolean locked;
}

