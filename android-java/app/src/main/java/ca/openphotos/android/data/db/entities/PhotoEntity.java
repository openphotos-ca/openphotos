package ca.openphotos.android.data.db.entities;

import androidx.annotation.NonNull;
import androidx.room.Entity;
import androidx.room.Index;
import androidx.room.PrimaryKey;

/** Tracks local media and sync state (mirrors iOS SyncRepository). */
@Entity(tableName = "photos", indices = {@Index(value = {"contentId"}, unique = true)})
public class PhotoEntity {
    @PrimaryKey(autoGenerate = true)
    public long id;

    @NonNull public String contentId;     // Base58(MD5(file bytes))
    @NonNull public String contentUri;    // content:// URI
    public int mediaType;                 // 0=image, 1=video
    public long creationTs;               // seconds
    public int pixelWidth;
    public int pixelHeight;
    public long estimatedBytes;

    // Sync state: 0=pending, 1=uploading, 2=synced, 3=failed, 4=bgQueued
    public int syncState;
    public int attempts;
    public String lastError;
    public Long lastAttemptAt;
    public Long syncAt;

    // Optional per-photo lock override (nullable)
    public Boolean lockOverride;
}

