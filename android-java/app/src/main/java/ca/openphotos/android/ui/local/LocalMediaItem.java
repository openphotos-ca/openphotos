package ca.openphotos.android.ui.local;

import androidx.annotation.NonNull;

/** Immutable model for one local MediaStore item rendered in the Photos tab. */
public final class LocalMediaItem {
    @NonNull public final String localId;      // stable selection key (content:// uri string)
    @NonNull public final String uri;
    @NonNull public final String displayName;
    @NonNull public final String mimeType;
    @NonNull public final String relativePath;

    public final boolean isVideo;
    public final long createdAtSec;
    public final long dateModifiedSec;
    public final long sizeBytes;
    public final long durationMs;
    public final int width;
    public final int height;

    public final boolean favorite;
    public final boolean screenshot;
    public final boolean motionPhoto;

    public LocalMediaItem(
            @NonNull String localId,
            @NonNull String uri,
            @NonNull String displayName,
            @NonNull String mimeType,
            @NonNull String relativePath,
            boolean isVideo,
            long createdAtSec,
            long dateModifiedSec,
            long sizeBytes,
            long durationMs,
            int width,
            int height,
            boolean favorite,
            boolean screenshot,
            boolean motionPhoto
    ) {
        this.localId = localId;
        this.uri = uri;
        this.displayName = displayName;
        this.mimeType = mimeType;
        this.relativePath = relativePath;
        this.isVideo = isVideo;
        this.createdAtSec = createdAtSec;
        this.dateModifiedSec = dateModifiedSec;
        this.sizeBytes = sizeBytes;
        this.durationMs = durationMs;
        this.width = width;
        this.height = height;
        this.favorite = favorite;
        this.screenshot = screenshot;
        this.motionPhoto = motionPhoto;
    }

    @NonNull
    public String folderPathNormalized() {
        if (relativePath.isEmpty()) return "";
        String p = relativePath;
        if (p.endsWith("/")) p = p.substring(0, p.length() - 1);
        return p;
    }
}
