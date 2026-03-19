package ca.openphotos.android.ui;

import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.recyclerview.widget.DiffUtil;
import androidx.recyclerview.widget.ListAdapter;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.media.DiskImageCache;

/**
 * Minimal, reusable grid adapter for media items. For now binds a label and optional badges.
 * Can be extended to load thumbnails via Glide and attach click listeners for the viewer.
 */
public class MediaGridAdapter extends ListAdapter<MediaGridAdapter.Cell, MediaGridAdapter.VH> {
    public static class Cell {
        public final String id;            // stable id
        public final String label;         // caption/filename or placeholder
        public final boolean locked;       // shows LOCKED badge
        public final String uri;           // content:// URI for thumbnail
        public final boolean isVideo;      // simple badge logic
        public final String assetId;       // server asset id (optional; empty for local)
        public final int rating;           // 0..5
        public final long durationMs;      // local video duration
        public final boolean cloudBackedUp;// local cloud-check badge

        public Cell(String id, String label, boolean locked, String uri, boolean isVideo) { this(id,label,locked,uri,isVideo,"",0,0L,false); }
        public Cell(String id, String label, boolean locked, String uri, boolean isVideo, String assetId) { this(id,label,locked,uri,isVideo,assetId,0,0L,false); }
        public Cell(String id, String label, boolean locked, String uri, boolean isVideo, String assetId, int rating) { this(id,label,locked,uri,isVideo,assetId,rating,0L,false); }
        public Cell(String id, String label, boolean locked, String uri, boolean isVideo, String assetId, int rating, long durationMs, boolean cloudBackedUp) {
            this.id = id;
            this.label = label;
            this.locked = locked;
            this.uri = uri;
            this.isVideo = isVideo;
            this.assetId = assetId;
            this.rating = rating;
            this.durationMs = durationMs;
            this.cloudBackedUp = cloudBackedUp;
        }
    }

    public MediaGridAdapter() { super(DIFF); }

    private static android.graphics.drawable.ColorDrawable placeholder(@NonNull android.content.Context context) {
        return new android.graphics.drawable.ColorDrawable(
                androidx.core.content.ContextCompat.getColor(context, R.color.app_placeholder_alt));
    }

    // Optional selection state managed by parent fragment
    private boolean selectionMode = false;
    private java.util.Set<String> selectedIds = new java.util.HashSet<>();
    private boolean showLabels = true;
    public void setSelectionMode(boolean enabled, java.util.Set<String> selected) {
        this.selectionMode = enabled;
        this.selectedIds = selected != null ? selected : new java.util.HashSet<>();
        notifyDataSetChanged();
    }
    public void setShowLabels(boolean show) {
        this.showLabels = show;
        notifyDataSetChanged();
    }

    private static final DiffUtil.ItemCallback<Cell> DIFF = new DiffUtil.ItemCallback<Cell>() {
        @Override public boolean areItemsTheSame(@NonNull Cell a, @NonNull Cell b) { return a.id.equals(b.id); }
        @Override public boolean areContentsTheSame(@NonNull Cell a, @NonNull Cell b) {
            return a.label.equals(b.label)
                    && a.locked == b.locked
                    && a.uri.equals(b.uri)
                    && a.rating == b.rating
                    && a.isVideo == b.isVideo
                    && a.durationMs == b.durationMs
                    && a.cloudBackedUp == b.cloudBackedUp;
        }
    };

    static class VH extends RecyclerView.ViewHolder {
        ImageView image;
        TextView label;
        View badgeLocked;
        TextView badgeRating;
        View badgeSelected;
        TextView badgeDuration;
        View badgeCloud;

        VH(@NonNull View v) {
            super(v);
            image = v.findViewById(R.id.image);
            label = v.findViewById(R.id.label);
            badgeLocked = v.findViewById(R.id.badge_locked);
            badgeRating = v.findViewById(R.id.badge_rating);
            badgeSelected = v.findViewById(R.id.badge_selected);
            badgeDuration = v.findViewById(R.id.badge_duration);
            badgeCloud = v.findViewById(R.id.badge_cloud);
        }

        void bind(Cell c, boolean selectionMode, boolean isSelected, boolean showLabels) {
            if (showLabels) {
                label.setText(c.label);
                label.setVisibility(View.VISIBLE);
            } else {
                label.setText("");
                label.setVisibility(View.GONE);
            }
            badgeLocked.setVisibility(c.locked ? View.VISIBLE : View.GONE);
            if (badgeRating != null) {
                if (c.rating > 0) { badgeRating.setVisibility(View.VISIBLE); badgeRating.setText("★" + c.rating); }
                else { badgeRating.setVisibility(View.GONE); }
            }
            if (badgeSelected != null) { badgeSelected.setVisibility(selectionMode && isSelected ? View.VISIBLE : View.GONE); }
            if (badgeDuration != null) {
                if (c.isVideo) {
                    badgeDuration.setVisibility(View.VISIBLE);
                    badgeDuration.setText(formatDuration(c.durationMs));
                } else {
                    badgeDuration.setVisibility(View.GONE);
                }
            }
            if (badgeCloud != null) {
                badgeCloud.setVisibility(c.cloudBackedUp ? View.VISIBLE : View.GONE);
            }
            try {
                if (c.locked) {
                    // Attempt to decrypt locked thumbnail if UMK is available; otherwise show placeholder.
                    ca.openphotos.android.e2ee.E2EEManager e2 = new ca.openphotos.android.e2ee.E2EEManager(image.getContext());
                    byte[] umk = e2.getUmk();
                    if (umk == null) {
                        try { android.util.Log.i("OpenPhotos","[LOCKED] UMK missing; showing placeholder asset="+c.assetId); } catch (Exception ignored) {}
                        image.setImageDrawable(placeholder(image.getContext()));
                    } else {
                        final String tagId = c.id;
                        image.setTag(tagId);
                        image.setImageDrawable(placeholder(image.getContext()));
                        // Cache-first: check decrypted thumb already stored
                        try {
                            if (c.assetId != null && !c.assetId.isEmpty()) {
                                java.io.File cf = DiskImageCache.get(image.getContext()).readFile(DiskImageCache.Bucket.THUMBS, c.assetId);
                                if (cf != null && cf.exists()) {
                                    android.graphics.Bitmap bmp = decodeBitmapRobust(cf);
                                    if (bmp != null) { image.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP); image.setImageBitmap(bmp); return; }
                                }
                            }
                        } catch (Exception ignored) {}
                        try { android.util.Log.i("OpenPhotos","[LOCKED] Start fetch+decrypt asset="+c.assetId+" url="+c.uri); } catch (Exception ignored) {}
                        new Thread(() -> {
                            try {
                                okhttp3.OkHttpClient client = ca.openphotos.android.core.AuthorizedHttpClient.get(image.getContext()).raw();
                                java.io.File dec = new java.io.File(image.getContext().getCacheDir(), c.assetId + "_t.dec");
                                String uid = ca.openphotos.android.core.AuthManager.get(image.getContext()).getUserId();
                                byte[] userIdKey = uid != null ? uid.getBytes(java.nio.charset.StandardCharsets.UTF_8) : new byte[0];

                                boolean prepared = prepareLockedMediaFile(client, c.uri, umk, userIdKey, dec, c.assetId);
                                if (!prepared && c.assetId != null && !c.assetId.isEmpty()) {
                                    // Decrypt failed on locked thumbnail path; retry via /api/images to tolerate legacy rows.
                                    String imageUrl = new ca.openphotos.android.server.ServerPhotosService(image.getContext().getApplicationContext()).imageUrl(c.assetId);
                                    prepared = prepareLockedMediaFile(client, imageUrl, umk, userIdKey, dec, c.assetId);
                                }
                                if (!prepared) throw new java.io.IOException("Failed to prepare locked media payload");
                                try {
                                    android.util.Log.i("OpenPhotos", "[LOCKED] Prepared media asset=" + c.assetId + " dec=" + dec.length());
                                    // Log magic bytes of decrypted output
                                    java.io.FileInputStream fis = new java.io.FileInputStream(dec);
                                    byte[] head = new byte[8]; int rr = fis.read(head); fis.close();
                                    StringBuilder sb = new StringBuilder(); for(int i=0;i<rr;i++){ sb.append(String.format("%02X", head[i])); }
                                    android.util.Log.i("OpenPhotos", "[LOCKED] dec head="+sb.toString());
                                } catch (Exception ignored) {}
                                // Bind back to the same view only if not recycled
                                android.os.Handler h = new android.os.Handler(image.getContext().getMainLooper());
                                h.post(() -> {
                                    if (!tagId.equals(image.getTag())) return;
                                    // Persist decrypted bytes in disk cache for quick relaunches.
                                    try {
                                        if (c.assetId != null && !c.assetId.isEmpty()) {
                                            java.io.FileInputStream fis = new java.io.FileInputStream(dec);
                                            DiskImageCache.get(image.getContext()).write(DiskImageCache.Bucket.THUMBS, c.assetId, fis, dec.length(), "webp");
                                            try { fis.close(); } catch (Exception ignored) {}
                                        }
                                    } catch (Exception ignored) {}

                                    // Decode as image first (BitmapFactory + ImageDecoder fallback for HEIC/AVIF).
                                    android.graphics.Bitmap bmp = decodeBitmapRobust(dec);
                                    if (bmp != null) {
                                        image.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
                                        image.setImageBitmap(bmp);
                                        return;
                                    }

                                    // If image decode fails, try to extract a video frame.
                                    android.graphics.Bitmap frame = decodeVideoFrame(dec);
                                    if (frame != null) {
                                        image.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
                                        image.setImageBitmap(frame);
                                    } else {
                                        image.setImageDrawable(placeholder(image.getContext()));
                                    }
                                });
                            } catch (Exception ex) {
                                // Fallback placeholder on any failure and log for diagnostics
                                try { android.util.Log.w("OpenPhotos", "[LOCKED] Decrypt/display failed asset=" + c.assetId + " err=" + ex.getMessage()); } catch (Exception ignored) {}
                                android.os.Handler h = new android.os.Handler(image.getContext().getMainLooper());
                                h.post(() -> image.setImageDrawable(placeholder(image.getContext())));
                            }
                        }).start();
                    }
                } else {
                    String u = c.uri != null ? c.uri : "";
                    if (u.startsWith("http://") || u.startsWith("https://")) {
                        // Cache-first: thumbs bucket by assetId
                        if (c.assetId != null && !c.assetId.isEmpty()) {
                            try {
                                java.io.File cf = DiskImageCache.get(image.getContext()).readFile(DiskImageCache.Bucket.THUMBS, c.assetId);
                                if (cf != null && cf.exists()) {
                                    android.graphics.Bitmap bmp = android.graphics.BitmapFactory.decodeFile(cf.getAbsolutePath());
                                    if (bmp != null) { image.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP); image.setImageBitmap(bmp); return; }
                                }
                            } catch (Exception ignored) {}
                        }
                        // Fetch → write cache → display
                        final String tagId2 = c.id; image.setTag(tagId2);
                        image.setImageDrawable(placeholder(image.getContext()));
                        new Thread(() -> {
                            try {
                                okhttp3.OkHttpClient client = ca.openphotos.android.core.AuthorizedHttpClient.get(image.getContext()).raw();
                                okhttp3.Request req = new okhttp3.Request.Builder().url(u).get().build();
                                try (okhttp3.Response r = client.newCall(req).execute()) {
                                    if (!r.isSuccessful() || r.body()==null) throw new java.io.IOException("HTTP " + r.code());
                                    String ct = r.header("Content-Type", "").toLowerCase();
                                    String ext = ct.contains("image/webp") ? "webp" : (ct.contains("jpeg")?"jpg": (ct.contains("png")?"png": "webp"));
                                    java.io.File out = null;
                                    if (c.assetId != null && !c.assetId.isEmpty()) {
                                        java.io.InputStream is = r.body().byteStream();
                                        out = DiskImageCache.get(image.getContext()).write(DiskImageCache.Bucket.THUMBS, c.assetId, is, r.body().contentLength(), ext);
                                    }
                                    if (out != null && out.exists()) {
                                        android.graphics.Bitmap bmp = android.graphics.BitmapFactory.decodeFile(out.getAbsolutePath());
                                        if (bmp != null) {
                                            android.os.Handler h = new android.os.Handler(image.getContext().getMainLooper());
                                            h.post(() -> { if (tagId2.equals(image.getTag())) { image.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP); image.setImageBitmap(bmp); } });
                                        }
                                    }
                                }
                            } catch (Exception ignored) {}
                        }).start();
                    } else {
                        // Local URI fallback
                        Object model = android.net.Uri.parse(u);
                        com.bumptech.glide.Glide.with(image.getContext()).load(model).thumbnail(0.25f).centerCrop().into(image);
                    }
                }
            } catch (Exception ignored) {}
        }
    }

    @NonNull @Override public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
        View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.grid_item_media, parent, false);
        return new VH(v);
    }

    @Override public void onBindViewHolder(@NonNull VH holder, int position) {
        Cell c = getItem(position);
        boolean isSelected = selectedIds.contains(selectionKey(c));
        holder.bind(c, selectionMode, isSelected, showLabels);
    }

    private String selectionKey(@NonNull Cell c) {
        return (c.assetId != null && !c.assetId.isEmpty()) ? c.assetId : c.id;
    }

    @NonNull
    private static String formatDuration(long durationMs) {
        long totalSec = Math.max(0L, durationMs / 1000L);
        long h = totalSec / 3600L;
        long m = (totalSec % 3600L) / 60L;
        long s = totalSec % 60L;
        if (h > 0L) return String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, s);
        return String.format(java.util.Locale.US, "%d:%02d", m, s);
    }

    private static android.graphics.Bitmap decodeBitmapRobust(@NonNull java.io.File file) {
        try {
            android.graphics.BitmapFactory.Options opts = new android.graphics.BitmapFactory.Options();
            opts.inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888;
            android.graphics.Bitmap bmp = android.graphics.BitmapFactory.decodeFile(file.getAbsolutePath(), opts);
            if (bmp != null) return bmp;
        } catch (Exception ignored) {}
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            try {
                android.graphics.ImageDecoder.Source src = android.graphics.ImageDecoder.createSource(file);
                return android.graphics.ImageDecoder.decodeBitmap(src);
            } catch (Exception ignored) {}
        }
        return null;
    }

    private static android.graphics.Bitmap decodeVideoFrame(@NonNull java.io.File file) {
        try {
            android.media.MediaMetadataRetriever mmr = new android.media.MediaMetadataRetriever();
            mmr.setDataSource(file.getAbsolutePath());
            android.graphics.Bitmap frame = mmr.getFrameAtTime(0);
            mmr.release();
            return frame;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static boolean prepareLockedMediaFile(@NonNull okhttp3.OkHttpClient client, @NonNull String url, @NonNull byte[] umk, @NonNull byte[] userIdKey, @NonNull java.io.File decOut, @Nullable String assetId) {
        String id = (assetId == null || assetId.isEmpty()) ? "locked" : assetId;
        java.io.File enc = new java.io.File(decOut.getParentFile(), id + "_lock_fetch.tmp");
        try {
            if (!downloadToFile(client, url, enc)) return false;
            if (isPae3File(enc)) {
                try {
                    ca.openphotos.android.e2ee.PAE3.decryptToFile(umk, userIdKey, enc, decOut);
                    return true;
                } catch (Exception e) {
                    try { android.util.Log.w("OpenPhotos", "[LOCKED] PAE3 decrypt failed for url=" + url + " err=" + e.getMessage()); } catch (Exception ignored) {}
                    return false;
                }
            }
            copyFile(enc, decOut);
            return true;
        } catch (Exception ignored) {
            return false;
        } finally {
            try { if (enc.exists()) enc.delete(); } catch (Exception ignored) {}
        }
    }

    private static boolean downloadToFile(@NonNull okhttp3.OkHttpClient client, @NonNull String url, @NonNull java.io.File out) {
        try {
            okhttp3.Request req = new okhttp3.Request.Builder().url(url).get().build();
            try (okhttp3.Response r = client.newCall(req).execute()) {
                if (!r.isSuccessful() || r.body() == null) return false;
                try (java.io.InputStream is = r.body().byteStream(); java.io.FileOutputStream fos = new java.io.FileOutputStream(out)) {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = is.read(buf)) > 0) fos.write(buf, 0, n);
                }
            }
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }

    private static boolean isPae3File(@NonNull java.io.File file) {
        try (java.io.FileInputStream fis = new java.io.FileInputStream(file)) {
            byte[] head = new byte[4];
            int n = fis.read(head);
            return n == 4 && head[0] == 'P' && head[1] == 'A' && head[2] == 'E' && head[3] == '3';
        } catch (Exception ignored) {
            return false;
        }
    }

    private static void copyFile(@NonNull java.io.File src, @NonNull java.io.File dst) throws java.io.IOException {
        try (java.io.FileInputStream fis = new java.io.FileInputStream(src); java.io.FileOutputStream fos = new java.io.FileOutputStream(dst)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = fis.read(buf)) > 0) fos.write(buf, 0, n);
        }
    }
}
