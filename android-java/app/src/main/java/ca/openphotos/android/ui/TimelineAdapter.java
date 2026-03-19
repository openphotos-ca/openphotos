package ca.openphotos.android.ui;

import android.graphics.drawable.ColorDrawable;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.recyclerview.widget.DiffUtil;
import androidx.recyclerview.widget.ListAdapter;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;

import java.text.DateFormat;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * TimelineAdapter renders a Timeline layout: Month headers, Day headers, and photo tiles.
 * - Uses a GridLayoutManager with SpanSizeLookup: headers span all columns; photos span 1.
 * - Exposes callbacks for photo taps and near-end detection for paging.
 * - When selection mode is enabled, shows a selection overlay and disables rating overlay.
 */
public class TimelineAdapter extends ListAdapter<TimelineAdapter.Cell, RecyclerView.ViewHolder> {
    public static final int TYPE_YEAR_ANCHOR = 0; // 0-height item used for jump-to-year
    public static final int TYPE_MONTH_HEADER = 1;
    public static final int TYPE_DAY_HEADER = 2;
    public static final int TYPE_PHOTO = 3;

    public interface OnPhotoClickListener { void onPhotoClick(Cell c); }
    public interface OnNearEndListener { void onNearEnd(); }

    public TimelineAdapter() { super(DIFF); }

    private static ColorDrawable placeholder(@NonNull android.content.Context context) {
        return new ColorDrawable(androidx.core.content.ContextCompat.getColor(context, R.color.app_placeholder_alt));
    }

    private boolean selectionMode = false;
    private java.util.Set<String> selectedIds = new java.util.HashSet<>();
    private boolean ratingOverlayEnabled = false; // enabled for Timeline only
    private OnPhotoClickListener photoClickListener = null;
    private OnNearEndListener nearEndListener = null;

    public void setSelectionMode(boolean enabled, java.util.Set<String> selected) {
        this.selectionMode = enabled;
        this.selectedIds = selected != null ? selected : new java.util.HashSet<>();
        notifyDataSetChanged();
    }
    public void setRatingOverlayEnabled(boolean enabled) { this.ratingOverlayEnabled = enabled; }
    public void setOnPhotoClickListener(OnPhotoClickListener l) { this.photoClickListener = l; }
    public void setOnNearEndListener(OnNearEndListener l) { this.nearEndListener = l; }

    // Cell model for all rows
    public static class Cell {
        public final int type;
        public final String id; // stable id
        public final String text; // header text or label
        public final long ts; // epoch seconds for date headers

        // Photo-specific
        public final String assetId;
        public final boolean isVideo;
        public final boolean locked;
        public int rating;
        public final String thumbUrl;
        public final long durationMs;
        public final boolean cloudBackedUp;

        // Anchor
        public final Integer year; // only for TYPE_YEAR_ANCHOR

        private Cell(
                int type,
                String id,
                String text,
                long ts,
                String assetId,
                boolean isVideo,
                boolean locked,
                int rating,
                String thumbUrl,
                long durationMs,
                boolean cloudBackedUp,
                Integer year
        ) {
            this.type = type; this.id = id; this.text = text; this.ts = ts;
            this.assetId = assetId;
            this.isVideo = isVideo;
            this.locked = locked;
            this.rating = rating;
            this.thumbUrl = thumbUrl;
            this.durationMs = durationMs;
            this.cloudBackedUp = cloudBackedUp;
            this.year = year;
        }
        public static Cell yearAnchor(int year) { return new Cell(TYPE_YEAR_ANCHOR, "year-"+year, "", 0L, null, false, false, 0, null, 0L, false, year); }
        public static Cell monthHeader(String text, long ts) { return new Cell(TYPE_MONTH_HEADER, "m-"+ts, text, ts, null, false, false, 0, null, 0L, false, null); }
        public static Cell dayHeader(String text, long ts) { return new Cell(TYPE_DAY_HEADER, "d-"+ts, text, ts, null, false, false, 0, null, 0L, false, null); }
        public static Cell photo(String assetId, boolean isVideo, boolean locked, int rating, String thumbUrl, long ts) {
            return new Cell(TYPE_PHOTO, "p-"+assetId, "", ts, assetId, isVideo, locked, rating, thumbUrl, 0L, false, null);
        }
        public static Cell photo(String assetId, boolean isVideo, boolean locked, int rating, String thumbUrl, long ts, long durationMs, boolean cloudBackedUp) {
            return new Cell(TYPE_PHOTO, "p-"+assetId, "", ts, assetId, isVideo, locked, rating, thumbUrl, durationMs, cloudBackedUp, null);
        }
    }

    private static final DiffUtil.ItemCallback<Cell> DIFF = new DiffUtil.ItemCallback<Cell>() {
        @Override public boolean areItemsTheSame(@NonNull Cell a, @NonNull Cell b) { return a.id.equals(b.id); }
        @Override public boolean areContentsTheSame(@NonNull Cell a, @NonNull Cell b) {
            if (a.type != b.type) return false;
            if (a.type == TYPE_PHOTO) {
                return a.locked == b.locked
                        && a.rating == b.rating
                        && a.durationMs == b.durationMs
                        && a.cloudBackedUp == b.cloudBackedUp
                        && eq(a.thumbUrl, b.thumbUrl);
            }
            return eq(a.text, b.text);
        }
        private boolean eq(Object a, Object b) { return (a==b) || (a!=null && a.equals(b)); }
    };

    @Override public int getItemViewType(int position) { return getItem(position).type; }

    static class MonthVH extends RecyclerView.ViewHolder { TextView t; MonthVH(View v) { super(v); t = v.findViewById(R.id.text); } }
    static class DayVH extends RecyclerView.ViewHolder { TextView t; DayVH(View v) { super(v); t = v.findViewById(R.id.text); } }
    static class YearVH extends RecyclerView.ViewHolder { YearVH(View v) { super(v); } }

    static class PhotoVH extends RecyclerView.ViewHolder {
        android.widget.ImageView image; View badgeLocked; View badgeSelected; TextView badgeRating; TextView badgeDuration; View badgeCloud;
        View ratingOverlay; TextView[] stars = new TextView[5];
        PhotoVH(@NonNull View v) {
            super(v);
            image = v.findViewById(R.id.image);
            badgeLocked = v.findViewById(R.id.badge_locked);
            badgeSelected = v.findViewById(R.id.badge_selected);
            badgeRating = v.findViewById(R.id.badge_rating);
            badgeDuration = v.findViewById(R.id.badge_duration);
            badgeCloud = v.findViewById(R.id.badge_cloud);
            ratingOverlay = v.findViewById(R.id.rating_overlay);
            stars[0] = v.findViewById(R.id.star_1); stars[1] = v.findViewById(R.id.star_2); stars[2] = v.findViewById(R.id.star_3); stars[3] = v.findViewById(R.id.star_4); stars[4] = v.findViewById(R.id.star_5);
        }
    }

    @NonNull @Override public RecyclerView.ViewHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
        LayoutInflater inf = LayoutInflater.from(parent.getContext());
        if (viewType == TYPE_MONTH_HEADER) return new MonthVH(inf.inflate(R.layout.item_timeline_month_header, parent, false));
        if (viewType == TYPE_DAY_HEADER) return new DayVH(inf.inflate(R.layout.item_timeline_day_header, parent, false));
        if (viewType == TYPE_YEAR_ANCHOR) { View v = new View(parent.getContext()); v.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0)); return new YearVH(v); }
        return new PhotoVH(inf.inflate(R.layout.grid_item_media, parent, false));
    }

    @Override public void onBindViewHolder(@NonNull RecyclerView.ViewHolder holder, int position) {
        Cell c = getItem(position);
        switch (c.type) {
            case TYPE_MONTH_HEADER: {
                MonthVH h = (MonthVH) holder; h.t.setText(c.text); break; }
            case TYPE_DAY_HEADER: {
                DayVH h = (DayVH) holder; h.t.setText(c.text); break; }
            case TYPE_YEAR_ANCHOR: { /* no-op */ break; }
            default: {
                bindPhoto((PhotoVH) holder, c, position);
            }
        }
        // Near-end trigger
        if (nearEndListener != null) {
            int n = getItemCount();
            if (n > 0 && position >= n - 6) nearEndListener.onNearEnd();
        }
    }

    private void bindPhoto(@NonNull PhotoVH h, @NonNull Cell c, int position) {
        // Selection overlay and locked badge
        String selectionKey = (c.assetId != null && !c.assetId.isEmpty()) ? c.assetId : c.id;
        boolean isSelected = selectedIds.contains(selectionKey);
        if (h.badgeSelected != null) h.badgeSelected.setVisibility(selectionMode && isSelected ? View.VISIBLE : View.GONE);
        if (h.badgeLocked != null) h.badgeLocked.setVisibility(c.locked ? View.VISIBLE : View.GONE);

        // Legacy text rating badge hidden for Timeline when interactive overlay is enabled
        if (h.badgeRating != null) {
            if (!ratingOverlayEnabled) {
                if (c.rating > 0) { h.badgeRating.setVisibility(View.VISIBLE); h.badgeRating.setText("★" + c.rating); }
                else { h.badgeRating.setVisibility(View.GONE); }
            } else { h.badgeRating.setVisibility(View.GONE); }
        }
        if (h.badgeDuration != null) {
            if (c.isVideo) {
                h.badgeDuration.setVisibility(View.VISIBLE);
                h.badgeDuration.setText(formatDuration(c.durationMs));
            } else {
                h.badgeDuration.setVisibility(View.GONE);
            }
        }
        if (h.badgeCloud != null) {
            h.badgeCloud.setVisibility(c.cloudBackedUp ? View.VISIBLE : View.GONE);
        }

        // Image load (reusing logic from MediaGridAdapter)
        try {
            if (c.locked) {
                ca.openphotos.android.e2ee.E2EEManager e2 = new ca.openphotos.android.e2ee.E2EEManager(h.image.getContext());
                byte[] umk = e2.getUmk();
                if (umk == null) {
                    h.image.setImageDrawable(placeholder(h.image.getContext()));
                } else {
                    final String tagId = c.id; h.image.setTag(tagId);
                    h.image.setImageDrawable(placeholder(h.image.getContext()));
                    new Thread(() -> {
                        try {
                            okhttp3.OkHttpClient client = ca.openphotos.android.core.AuthorizedHttpClient.get(h.image.getContext()).raw();
                            java.io.File dec = new java.io.File(h.image.getContext().getCacheDir(), c.assetId + "_t.jpg");
                            byte[] umkNow = new ca.openphotos.android.e2ee.E2EEManager(h.image.getContext()).getUmk();
                            if (umkNow == null) throw new java.io.IOException("UMK missing");
                            String uid = ca.openphotos.android.core.AuthManager.get(h.image.getContext()).getUserId();
                            byte[] userIdKey = uid != null ? uid.getBytes(java.nio.charset.StandardCharsets.UTF_8) : new byte[0];
                            boolean prepared = prepareLockedMediaFile(client, c.thumbUrl, umkNow, userIdKey, dec, c.assetId);
                            if (!prepared && c.assetId != null && !c.assetId.isEmpty()) {
                                String imageUrl = new ca.openphotos.android.server.ServerPhotosService(h.image.getContext().getApplicationContext()).imageUrl(c.assetId);
                                prepared = prepareLockedMediaFile(client, imageUrl, umkNow, userIdKey, dec, c.assetId);
                            }
                            if (!prepared) throw new java.io.IOException("Failed to prepare locked media payload");
                            android.os.Handler main = new android.os.Handler(h.image.getContext().getMainLooper());
                            main.post(() -> {
                                if (!tagId.equals(h.image.getTag())) return; // recycled
                                try {
                                    // Try image decode first (BitmapFactory + ImageDecoder fallback), then video frame fallback.
                                    android.graphics.Bitmap bmp = decodeBitmapRobust(dec);
                                    if (bmp != null) {
                                        h.image.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
                                        h.image.setImageBitmap(bmp);
                                    } else {
                                        android.graphics.Bitmap frame = decodeVideoFrame(dec);
                                        if (frame != null) { h.image.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP); h.image.setImageBitmap(frame); }
                                        else { h.image.setImageDrawable(placeholder(h.image.getContext())); }
                                    }
                                } catch (Exception e) { h.image.setImageDrawable(placeholder(h.image.getContext())); }
                            });
                        } catch (Exception ex) {
                            android.os.Handler main = new android.os.Handler(h.image.getContext().getMainLooper());
                            main.post(() -> h.image.setImageDrawable(placeholder(h.image.getContext())));
                        }
                    }).start();
                }
            } else {
                Object model; String u = c.thumbUrl != null ? c.thumbUrl : "";
                if (u.startsWith("http://") || u.startsWith("https://")) {
                    String t = ca.openphotos.android.core.AuthManager.get(h.image.getContext()).getToken();
                    if (t != null && !t.isEmpty()) {
                        model = new com.bumptech.glide.load.model.GlideUrl(u,
                                new com.bumptech.glide.load.model.LazyHeaders.Builder().addHeader("Authorization", "Bearer " + t).build());
                    } else { model = u; }
                } else { model = android.net.Uri.parse(u); }
                com.bumptech.glide.Glide.with(h.image.getContext()).load(model).thumbnail(0.25f).centerCrop().into(h.image);
            }
        } catch (Exception ignored) { h.image.setImageDrawable(placeholder(h.image.getContext())); }

        // Rating overlay (interactive) when enabled and not in selection mode
        if (h.ratingOverlay != null) {
            if (ratingOverlayEnabled && !selectionMode) {
                h.ratingOverlay.setVisibility(View.VISIBLE);
                updateStars(h.stars, c.rating);
                for (int i = 0; i < h.stars.length; i++) {
                    final int n = i + 1;
                    h.stars[i].setOnClickListener(v -> {
                        // Optimistic UI update; network call happens outside via PhotosHomeFragment
                        c.rating = n; updateStars(h.stars, n);
                        if (photoClickListener != null) {
                            // Piggyback: signal click with updated rating; fragment will decide whether to persist or open viewer
                            // Here we only handle ratings; a tap outside stars should open viewer (handled by itemView click below)
                        }
                        // Persist rating on background thread
                        new Thread(() -> {
                            try { new ca.openphotos.android.server.ServerPhotosService(h.image.getContext()).updateRating(c.assetId, n); } catch (Exception ignored1) {}
                        }).start();
                    });
                }
            } else {
                h.ratingOverlay.setVisibility(View.GONE);
            }
        }

        // Item click / long-press
        h.itemView.setOnClickListener(v -> {
            if (photoClickListener != null) photoClickListener.onPhotoClick(c);
        });
        h.itemView.setOnLongClickListener(v -> { return false; }); // long-press handled by fragment via ItemTouch if needed
    }

    private void updateStars(TextView[] stars, int rating) {
        for (int i = 0; i < stars.length; i++) { stars[i].setText(i < rating ? "★" : "☆"); }
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

    // Helpers for building header labels using device locale
    public static String monthHeaderFor(long epochSeconds) {
        Date d = new Date(epochSeconds * 1000L);
        DateFormat f = new SimpleDateFormat("LLLL yyyy", Locale.getDefault());
        return f.format(d);
    }
    public static String dayHeaderFor(long epochSeconds) {
        Date d = new Date(epochSeconds * 1000L);
        DateFormat f = new SimpleDateFormat("MMM d, EEE", Locale.getDefault());
        return f.format(d);
    }
}
