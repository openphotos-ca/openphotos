package ca.openphotos.android.ui;

import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.ProgressBar;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;

import java.util.List;
import ca.openphotos.android.media.DiskImageCache;

/** Simple pager adapter that displays image URIs using Glide. */
public class ViewerPagerAdapter extends RecyclerView.Adapter<ViewerPagerAdapter.VH> {
    public interface OnTapListener { void onTap(); }
    public interface OnLongPressListener { boolean onLongPress(); }
    public interface OnScaleChangeListener { void onScaleChanged(float scale); }
    private final List<String> uris;
    private final List<String> assetIds; // optional; used for server caching
    private final boolean isServer;
    private final boolean[] videoFlags;
    private OnTapListener tapListener;
    private OnLongPressListener longPressListener;
    private OnScaleChangeListener scaleListener;
    public ViewerPagerAdapter(List<String> uris) { this(uris, null, false); }
    public ViewerPagerAdapter(List<String> uris, List<String> assetIds, boolean isServer) { this(uris, assetIds, isServer, null); }
    public ViewerPagerAdapter(List<String> uris, List<String> assetIds, boolean isServer, @Nullable boolean[] videoFlags) {
        this.uris = uris;
        this.assetIds = assetIds;
        this.isServer = isServer;
        this.videoFlags = videoFlags;
    }
    public void setOnTapListener(OnTapListener l) { this.tapListener = l; }
    public void setOnLongPressListener(OnLongPressListener l) { this.longPressListener = l; }
    public void setOnScaleChangeListener(OnScaleChangeListener l) { this.scaleListener = l; }

    private static android.graphics.drawable.ColorDrawable placeholder(@NonNull android.content.Context context) {
        return new android.graphics.drawable.ColorDrawable(
                androidx.core.content.ContextCompat.getColor(context, R.color.app_placeholder_alt));
    }

    static class VH extends RecyclerView.ViewHolder {
        com.github.chrisbanes.photoview.PhotoView image;
        ProgressBar loading;
        VH(@NonNull View v) {
            super(v);
            image = v.findViewById(R.id.image);
            loading = v.findViewById(R.id.loading);
        }

        void setLoading(boolean show) {
            if (loading != null) loading.setVisibility(show ? View.VISIBLE : View.GONE);
        }
    }

    @NonNull @Override public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
        View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.viewer_page_item, parent, false);
        return new VH(v);
    }
    @Override public void onBindViewHolder(@NonNull VH holder, int position) {
        String uri = uris.get(position);
        bindInteractions(holder);
        // Server originals: prefer DiskImageCache(images) and manage network ourselves for parity with iOS
        if (isServer && assetIds != null && position < assetIds.size()) {
            if (isVideoPosition(position)) {
                holder.image.setTag(assetIds.get(position) + "#" + position);
                holder.setLoading(false);
                loadUriWithGlide(holder, uri);
                return;
            }
            String assetId = assetIds.get(position);
            final String bindKey = assetId + "#" + position;
            final String cacheKey = serverImageCacheKey(assetId);
            holder.image.setTag(bindKey);
            holder.setLoading(false);
            // 1) Cache-first
            try {
                java.io.File f = DiskImageCache.get(holder.image.getContext()).readFile(DiskImageCache.Bucket.IMAGES, cacheKey);
                if (f != null && f.exists()) {
                    android.graphics.Bitmap bmp = decodeBitmapRobust(f);
                    if (bmp != null) { holder.image.setImageBitmap(bmp); return; }
                }
            } catch (Exception ignored) {}

            // 2) Fetch → decrypt if needed → write cache → display
            holder.image.setImageDrawable(placeholder(holder.image.getContext()));
            holder.setLoading(true);
            new Thread(() -> {
                try {
                    okhttp3.OkHttpClient client = ca.openphotos.android.core.AuthorizedHttpClient.get(holder.image.getContext()).raw();
                    String imageUrl = new ca.openphotos.android.server.ServerPhotosService(holder.image.getContext().getApplicationContext()).imageUrl(assetId);
                    boolean ok = loadServerImage(client, holder, bindKey, imageUrl, assetId, cacheKey);
                    if (!ok) {
                        hideLoadingIfStillBound(holder, bindKey);
                        try {
                            android.util.Log.w("OpenPhotos", "[VIEWER] failed to load full-res asset=" + assetId + " url=" + imageUrl);
                        } catch (Exception ignored) {}
                    }
                } catch (Exception e) {
                    hideLoadingIfStillBound(holder, bindKey);
                    try {
                        android.util.Log.w("OpenPhotos", "[VIEWER] exception loading asset=" + assetId + " err=" + e.getMessage(), e);
                    } catch (Exception ignored) {}
                }
            }).start();
            return;
        }

        // Non-server or missing assetIds: fall back to Glide loading
        holder.setLoading(false);
        try {
            loadUriWithGlide(holder, uri);
        } catch (Exception ignored) {}
    }

    @Override public void onViewRecycled(@NonNull VH holder) {
        super.onViewRecycled(holder);
        holder.image.setTag(null);
        holder.setLoading(false);
        holder.image.setImageDrawable(placeholder(holder.image.getContext()));
    }

    public static String serverImageCacheKey(@NonNull String assetId) {
        return "full:" + assetId;
    }

    private boolean isVideoPosition(int position) {
        return videoFlags != null && position >= 0 && position < videoFlags.length && videoFlags[position];
    }

    private void loadUriWithGlide(@NonNull VH holder, @Nullable String uri) {
        Object model;
        String u = uri != null ? uri : "";
        if (u.startsWith("http://") || u.startsWith("https://")) {
            String t = ca.openphotos.android.core.AuthManager.get(holder.image.getContext()).getToken();
            if (t != null && !t.isEmpty()) {
                model = new com.bumptech.glide.load.model.GlideUrl(u,
                        new com.bumptech.glide.load.model.LazyHeaders.Builder()
                                .addHeader("Authorization", "Bearer " + t)
                                .build());
            } else { model = u; }
        } else { model = android.net.Uri.parse(u); }
        com.bumptech.glide.Glide.with(holder.image.getContext())
                .load(model)
                .placeholder(placeholder(holder.image.getContext()))
                .error(placeholder(holder.image.getContext()))
                .fitCenter()
                .dontAnimate()
                .into(holder.image);
    }

    private void bindInteractions(@NonNull VH holder) {
        android.view.View.OnClickListener click = v -> { if (tapListener != null) tapListener.onTap(); };
        holder.itemView.setOnClickListener(click);
        holder.image.setOnClickListener(click);
        android.view.View.OnLongClickListener longClick = v -> longPressListener != null && longPressListener.onLongPress();
        holder.itemView.setOnLongClickListener(longClick);
        holder.image.setOnLongClickListener(longClick);
        // Notify parent when zoom scale changes to disable/enable pager swipes at >1x
        holder.image.setOnScaleChangeListener((scaleFactor, focusX, focusY) -> {
            if (scaleListener != null) {
                float s = holder.image.getScale();
                scaleListener.onScaleChanged(s);
            }
        });
    }

    private boolean loadServerImage(
            @NonNull okhttp3.OkHttpClient client,
            @NonNull VH holder,
            @NonNull String bindKey,
            @NonNull String url,
            @NonNull String assetId,
            @NonNull String cacheKey
    ) {
        try {
            okhttp3.Request req = new okhttp3.Request.Builder().url(url).get().build();
            try (okhttp3.Response r = client.newCall(req).execute()) {
                if (!r.isSuccessful() || r.body() == null) return false;
                String ct = r.header("Content-Type", "").toLowerCase();
                java.io.File out;
                if (ct.startsWith("application/octet-stream")) {
                    // Locked PAE3; requires UMK
                    ca.openphotos.android.e2ee.E2EEManager e2 = new ca.openphotos.android.e2ee.E2EEManager(holder.image.getContext());
                    byte[] umk = e2.getUmk();
                    String uid = ca.openphotos.android.core.AuthManager.get(holder.image.getContext()).getUserId();
                    if (umk == null || uid == null || uid.isEmpty()) {
                        try { android.util.Log.w("OpenPhotos", "[VIEWER] UMK missing for locked asset=" + assetId); } catch (Exception ignored) {}
                        return false;
                    }
                    java.io.File enc = java.io.File.createTempFile("img_", ".pae3", holder.image.getContext().getCacheDir());
                    java.io.File dec = java.io.File.createTempFile("img_", ".bin", holder.image.getContext().getCacheDir());
                    try {
                        try (java.io.InputStream is = r.body().byteStream(); java.io.FileOutputStream fos = new java.io.FileOutputStream(enc)) {
                            byte[] buf = new byte[8192];
                            int n;
                            while ((n = is.read(buf)) > 0) fos.write(buf, 0, n);
                        }
                        ca.openphotos.android.e2ee.PAE3.decryptToFile(umk, uid.getBytes(java.nio.charset.StandardCharsets.UTF_8), enc, dec);
                        try (java.io.FileInputStream fis = new java.io.FileInputStream(dec)) {
                            out = DiskImageCache.get(holder.image.getContext()).write(DiskImageCache.Bucket.IMAGES, cacheKey, fis, dec.length(), null);
                        }
                    } finally {
                        try { if (enc.exists()) enc.delete(); } catch (Exception ignored) {}
                        try { if (dec.exists()) dec.delete(); } catch (Exception ignored) {}
                    }
                } else {
                    // Unlocked image; store raw bytes (infer ext from content-type)
                    String ext = ct.contains("image/heic") ? "heic" : (ct.contains("jpeg") ? "jpg" : (ct.contains("png") ? "png" : null));
                    out = DiskImageCache.get(holder.image.getContext()).write(DiskImageCache.Bucket.IMAGES, cacheKey, r.body().byteStream(), r.body().contentLength(), ext);
                }

                if (out == null || !out.exists()) return false;
                android.graphics.Bitmap bmp = decodeBitmapRobust(out);
                if (bmp == null) return false;

                android.os.Handler h = new android.os.Handler(holder.image.getContext().getMainLooper());
                h.post(() -> {
                    if (!bindKey.equals(holder.image.getTag())) return;
                    holder.image.setImageBitmap(bmp);
                    holder.setLoading(false);
                });
                return true;
            }
        } catch (Exception e) {
            try { android.util.Log.w("OpenPhotos", "[VIEWER] loadServerImage failed asset=" + assetId + " url=" + url + " err=" + e.getMessage()); } catch (Exception ignored) {}
            return false;
        }
    }

    private static void hideLoadingIfStillBound(@NonNull VH holder, @NonNull String bindKey) {
        android.os.Handler h = new android.os.Handler(holder.image.getContext().getMainLooper());
        h.post(() -> {
            if (bindKey.equals(holder.image.getTag())) holder.setLoading(false);
        });
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

    @Override public int getItemCount() { return uris.size(); }
}
