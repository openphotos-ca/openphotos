package ca.openphotos.android.data.db.entities;

import androidx.room.Entity;
import androidx.room.PrimaryKey;

/**
 * Tracks individual upload items (plain/locked, orig/thumb) for foreground/background TUS.
 */
@Entity(tableName = "uploads")
public class UploadEntity {
    @PrimaryKey(autoGenerate = true)
    public long id;

    public String itemId;           // UUID string for UI/tracking
    public String contentId;
    public String filename;
    public String tempFilePath;     // local temp file path for upload body
    public String mimeType;
    public boolean isVideo;
    public long totalBytes;
    public long sentBytes;
    public String tusUrl;           // persisted for resume
    public int status;              // 0=queued,1=uploading,2=done,3=failed

    // Locked fields
    public boolean isLocked;
    public String lockedKind;       // orig|thumb
    public String assetIdB58;
    public String outerHeaderB64Url;
    public String albumPathsJson;
    public String lockedMetadataJson; // serialized TUS locked metadata (string values)
}
