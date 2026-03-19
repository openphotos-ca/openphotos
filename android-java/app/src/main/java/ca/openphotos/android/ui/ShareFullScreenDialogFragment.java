package ca.openphotos.android.ui;

import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.net.Uri;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.FileProvider;
import androidx.exifinterface.media.ExifInterface;
import androidx.fragment.app.DialogFragment;
import androidx.recyclerview.widget.RecyclerView;
import androidx.viewpager2.widget.ViewPager2;

import ca.openphotos.android.R;
import ca.openphotos.android.e2ee.ShareE2EEManager;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.server.ShareModels;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Full-screen swipe viewer for shared assets. */
public class ShareFullScreenDialogFragment extends DialogFragment {
    private static final String ARG_SHARE_ID = "share_id";
    private static final String ARG_ASSET_IDS = "asset_ids";
    private static final String ARG_INDEX = "index";

    private String shareId = "";
    private ArrayList<String> assetIds = new ArrayList<>();
    private int startIndex = 0;

    private ViewPager2 pager;
    private TextView tvCounter;
    private FullAdapter adapter;

    public static ShareFullScreenDialogFragment newInstance(String shareId, ArrayList<String> assetIds, int startIndex) {
        ShareFullScreenDialogFragment f = new ShareFullScreenDialogFragment();
        Bundle b = new Bundle();
        b.putString(ARG_SHARE_ID, shareId);
        b.putStringArrayList(ARG_ASSET_IDS, assetIds);
        b.putInt(ARG_INDEX, startIndex);
        f.setArguments(b);
        return f;
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        if (getArguments() != null) {
            shareId = getArguments().getString(ARG_SHARE_ID, "");
            ArrayList<String> ids = getArguments().getStringArrayList(ARG_ASSET_IDS);
            if (ids != null) assetIds = ids;
            startIndex = getArguments().getInt(ARG_INDEX, 0);
        }

        View root = inflater.inflate(R.layout.fragment_share_fullscreen, container, false);
        root.findViewById(R.id.btn_close).setOnClickListener(v -> dismissAllowingStateLoss());
        tvCounter = root.findViewById(R.id.tv_counter);
        pager = root.findViewById(R.id.pager);
        adapter = new FullAdapter();
        pager.setAdapter(adapter);

        int idx = Math.max(0, Math.min(startIndex, Math.max(0, assetIds.size() - 1)));
        pager.setCurrentItem(idx, false);
        updateCounter(idx);
        pager.registerOnPageChangeCallback(new ViewPager2.OnPageChangeCallback() {
            @Override
            public void onPageSelected(int position) {
                updateCounter(position);
            }
        });
        return root;
    }

    @Override
    public void onStart() {
        super.onStart();
        if (getDialog() != null && getDialog().getWindow() != null) {
            getDialog().getWindow().setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            getDialog().getWindow().setBackgroundDrawableResource(android.R.color.black);
        }
    }

    @Override
    public void onDestroyView() {
        if (adapter != null) adapter.shutdown();
        super.onDestroyView();
    }

    private void updateCounter(int position) {
        tvCounter.setText((position + 1) + " / " + Math.max(1, assetIds.size()));
    }

    private final class FullAdapter extends RecyclerView.Adapter<FullAdapter.VH> {
        private final ExecutorService exec = Executors.newFixedThreadPool(3);
        private final Map<String, Bitmap> bitmapByAsset = new HashMap<>();
        private final Map<String, ShareModels.ShareAssetMetadata> metaByAsset = new HashMap<>();
        private final Map<String, Boolean> loadingByAsset = new HashMap<>();

        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_share_fullscreen_page, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            String aid = assetIds.get(position);
            h.image.setTag(aid);
            Bitmap bmp = bitmapByAsset.get(aid);
            if (bmp != null) {
                h.image.setImageBitmap(bmp);
                h.loading.setVisibility(View.GONE);
            } else {
                h.image.setImageDrawable(new android.graphics.drawable.ColorDrawable(0xFF202020));
                h.loading.setVisibility(View.VISIBLE);
                if (!Boolean.TRUE.equals(loadingByAsset.get(aid))) {
                    loadingByAsset.put(aid, true);
                    loadAssetAsync(aid, h);
                }
            }

            ShareModels.ShareAssetMetadata meta = metaByAsset.get(aid);
            boolean isVideo = meta != null && meta.isVideo;
            h.playIcon.setVisibility(isVideo ? View.VISIBLE : View.GONE);
            h.itemView.setOnClickListener(v -> {
                if (isVideo) {
                    openVideo(aid);
                }
            });
        }

        private void loadAssetAsync(String aid, VH holder) {
            exec.execute(() -> {
                try {
                    ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                    ShareModels.ShareAssetMetadata meta = svc.getShareAssetMetadata(shareId, aid);
                    metaByAsset.put(aid, meta);

                    byte[] bytes;
                    String variant;
                    if (meta.isVideo) {
                        bytes = svc.getShareAssetThumbnailData(shareId, aid);
                        variant = "thumb";
                    } else {
                        bytes = svc.getShareAssetImageData(shareId, aid);
                        variant = "orig";
                    }

                    byte[] plain = bytes;
                    if (meta.locked) {
                        try {
                            plain = ShareE2EEManager.get(requireContext().getApplicationContext())
                                    .decryptShareContainer(shareId, aid, variant, bytes);
                        } catch (Exception ignored) {
                        }
                    }

                    Bitmap bmp = decodeBitmap(plain);
                    if (bmp == null) bmp = decodeVideoFrame(plain);
                    if (bmp != null) bitmapByAsset.put(aid, bmp);
                    final Bitmap finalBmp = bmp;

                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        if (!aid.equals(holder.image.getTag())) return;
                        holder.loading.setVisibility(View.GONE);
                        ShareModels.ShareAssetMetadata m = metaByAsset.get(aid);
                        holder.playIcon.setVisibility(m != null && m.isVideo ? View.VISIBLE : View.GONE);
                        if (finalBmp != null) holder.image.setImageBitmap(finalBmp);
                    });
                } catch (Exception e) {
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        if (!aid.equals(holder.image.getTag())) return;
                        holder.loading.setVisibility(View.GONE);
                    });
                }
            });
        }

        private void openVideo(String aid) {
            new Thread(() -> {
                try {
                    ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                    ShareModels.ShareAssetMetadata meta = metaByAsset.get(aid);
                    if (meta == null) meta = svc.getShareAssetMetadata(shareId, aid);
                    byte[] bytes = svc.getShareAssetImageData(shareId, aid);
                    byte[] plain = bytes;
                    if (meta.locked) {
                        plain = ShareE2EEManager.get(requireContext().getApplicationContext())
                                .decryptShareContainer(shareId, aid, "orig", bytes);
                    }

                    File out = File.createTempFile("share_video_", ".mp4", requireContext().getCacheDir());
                    try (FileOutputStream fos = new FileOutputStream(out)) {
                        fos.write(plain);
                    }

                    Uri uri = FileProvider.getUriForFile(requireContext(), requireContext().getPackageName() + ".provider", out);
                    Intent i = new Intent(Intent.ACTION_VIEW);
                    i.setDataAndType(uri, "video/*");
                    i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    requireActivity().runOnUiThread(() -> {
                        try {
                            startActivity(i);
                        } catch (Exception e) {
                            Toast.makeText(requireContext(), "No video player found", Toast.LENGTH_SHORT).show();
                        }
                    });
                } catch (Exception e) {
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> Toast.makeText(requireContext(), "Failed to open video", Toast.LENGTH_LONG).show());
                }
            }).start();
        }

        @Override
        public int getItemCount() {
            return assetIds.size();
        }

        void shutdown() {
            exec.shutdownNow();
        }

        final class VH extends RecyclerView.ViewHolder {
            final com.github.chrisbanes.photoview.PhotoView image;
            final ImageView playIcon;
            final ProgressBar loading;

            VH(@NonNull View itemView) {
                super(itemView);
                image = itemView.findViewById(R.id.image);
                playIcon = itemView.findViewById(R.id.play_icon);
                loading = itemView.findViewById(R.id.loading);
            }
        }
    }

    private static Bitmap decodeBitmap(byte[] bytes) {
        if (bytes == null || bytes.length == 0) return null;
        try {
            Bitmap decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            if (decoded == null) return null;
            return applyExifOrientation(decoded, bytes);
        } catch (Exception ignored) {
            return null;
        }
    }

    private static Bitmap applyExifOrientation(@NonNull Bitmap source, @NonNull byte[] bytes) {
        int orientation = ExifInterface.ORIENTATION_UNDEFINED;
        try (ByteArrayInputStream bis = new ByteArrayInputStream(bytes)) {
            ExifInterface exif = new ExifInterface(bis);
            orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED);
        } catch (Exception ignored) {
        }

        Matrix matrix = new Matrix();
        switch (orientation) {
            case ExifInterface.ORIENTATION_FLIP_HORIZONTAL:
                matrix.setScale(-1f, 1f);
                break;
            case ExifInterface.ORIENTATION_ROTATE_180:
                matrix.setRotate(180f);
                break;
            case ExifInterface.ORIENTATION_FLIP_VERTICAL:
                matrix.setRotate(180f);
                matrix.postScale(-1f, 1f);
                break;
            case ExifInterface.ORIENTATION_TRANSPOSE:
                matrix.setRotate(90f);
                matrix.postScale(-1f, 1f);
                break;
            case ExifInterface.ORIENTATION_ROTATE_90:
                matrix.setRotate(90f);
                break;
            case ExifInterface.ORIENTATION_TRANSVERSE:
                matrix.setRotate(-90f);
                matrix.postScale(-1f, 1f);
                break;
            case ExifInterface.ORIENTATION_ROTATE_270:
                matrix.setRotate(-90f);
                break;
            case ExifInterface.ORIENTATION_NORMAL:
            case ExifInterface.ORIENTATION_UNDEFINED:
            default:
                return source;
        }

        try {
            Bitmap adjusted = Bitmap.createBitmap(source, 0, 0, source.getWidth(), source.getHeight(), matrix, true);
            if (adjusted != source) source.recycle();
            return adjusted;
        } catch (Exception ignored) {
            return source;
        }
    }

    @Nullable
    private Bitmap decodeVideoFrame(byte[] bytes) {
        if (bytes == null || bytes.length == 0) return null;
        File tmp = null;
        try {
            tmp = File.createTempFile("share_preview_", ".bin", requireContext().getCacheDir());
            try (FileOutputStream fos = new FileOutputStream(tmp)) {
                fos.write(bytes);
            }
            android.media.MediaMetadataRetriever mmr = new android.media.MediaMetadataRetriever();
            mmr.setDataSource(tmp.getAbsolutePath());
            Bitmap frame = mmr.getFrameAtTime(0);
            mmr.release();
            return frame;
        } catch (Exception ignored) {
            return null;
        } finally {
            if (tmp != null) {
                try {
                    //noinspection ResultOfMethodCallIgnored
                    tmp.delete();
                } catch (Exception ignored) {
                }
            }
        }
    }
}
