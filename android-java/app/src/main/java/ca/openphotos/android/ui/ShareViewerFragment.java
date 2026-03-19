package ca.openphotos.android.ui;

import android.app.AlertDialog;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.DialogFragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;

import ca.openphotos.android.R;
import ca.openphotos.android.e2ee.ShareE2EEManager;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.server.ShareModels;
import com.google.android.material.button.MaterialButton;

import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Full share viewer with assets, faces filter, comments/likes, and selection import. */
public class ShareViewerFragment extends DialogFragment {
    public static final String KEY_VIEWER_AUTH_EXPIRED = "share.viewer.auth.expired";

    private static final String ARG_SHARE_ID = "share_id";
    private static final String ARG_TITLE = "title";
    private static final String ARG_PERMISSIONS = "permissions";
    private static final String ARG_INCLUDE_FACES = "include_faces";

    private String shareId = "";
    private String title = "Share";
    private int permissions = ShareModels.PERM_VIEW;
    private boolean includeFaces = true;

    private RecyclerView grid;
    private RecyclerView facesRail;
    private SwipeRefreshLayout swipe;
    private View empty;
    private MaterialButton btnImport;
    private View selectionBar;
    private TextView tvSelectedCount;

    private final List<String> allAssetIds = new ArrayList<>();
    private final Map<String, AssetTile> assetById = new HashMap<>();
    private final List<AssetTile> visibleTiles = new ArrayList<>();

    private final Set<String> selectedIds = new HashSet<>();
    @Nullable private Set<String> activeFaceAssetIds = null;

    private int page = 1;
    private boolean hasMore = false;
    private boolean loading = false;
    private boolean selectionMode = false;

    private AssetAdapter assetAdapter;
    private FacesAdapter facesAdapter;

    private final ExecutorService loadExecutor = Executors.newFixedThreadPool(4);

    public static ShareViewerFragment newInstance(String shareId, String title, int permissions, boolean includeFaces) {
        ShareViewerFragment f = new ShareViewerFragment();
        Bundle b = new Bundle();
        b.putString(ARG_SHARE_ID, shareId);
        b.putString(ARG_TITLE, title);
        b.putInt(ARG_PERMISSIONS, permissions);
        b.putBoolean(ARG_INCLUDE_FACES, includeFaces);
        f.setArguments(b);
        return f;
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        if (getArguments() != null) {
            shareId = getArguments().getString(ARG_SHARE_ID, "");
            title = getArguments().getString(ARG_TITLE, "Share");
            permissions = getArguments().getInt(ARG_PERMISSIONS, ShareModels.PERM_VIEW);
            includeFaces = getArguments().getBoolean(ARG_INCLUDE_FACES, true);
        }

        View root = inflater.inflate(R.layout.fragment_share_viewer, container, false);
        root.findViewById(R.id.btn_close).setOnClickListener(v -> dismissAllowingStateLoss());
        ((TextView) root.findViewById(R.id.tv_title)).setText(title == null || title.isEmpty() ? "Share" : title);

        View btnMore = root.findViewById(R.id.btn_more);
        btnMore.setOnClickListener(this::showMoreMenu);

        facesRail = root.findViewById(R.id.faces_rail);
        grid = root.findViewById(R.id.grid);
        swipe = root.findViewById(R.id.swipe);
        empty = root.findViewById(R.id.empty);
        selectionBar = root.findViewById(R.id.selection_bar);
        tvSelectedCount = root.findViewById(R.id.tv_selected_count);
        btnImport = root.findViewById(R.id.btn_import);

        GridLayoutManager glm = new GridLayoutManager(requireContext(), 3);
        grid.setLayoutManager(glm);
        assetAdapter = new AssetAdapter();
        grid.setAdapter(assetAdapter);
        grid.addOnScrollListener(new RecyclerView.OnScrollListener() {
            @Override
            public void onScrolled(@NonNull RecyclerView recyclerView, int dx, int dy) {
                if (dy <= 0) return;
                int total = glm.getItemCount();
                int last = glm.findLastVisibleItemPosition();
                if (hasMore && !loading && total > 0 && last >= total - 8) {
                    loadPage(page + 1, false);
                }
            }
        });

        facesRail.setLayoutManager(new LinearLayoutManager(requireContext(), RecyclerView.HORIZONTAL, false));
        facesAdapter = new FacesAdapter();
        facesRail.setAdapter(facesAdapter);
        facesRail.setVisibility(includeFaces ? View.VISIBLE : View.GONE);

        swipe.setOnRefreshListener(() -> loadPage(1, true));
        btnImport.setOnClickListener(v -> importSelected());

        getParentFragmentManager().setFragmentResultListener(ShareCommentsDialogFragment.KEY_COMMENTS_CHANGED, this,
                (key, bundle) -> {
                    String aid = bundle.getString("asset_id", "");
                    if (!aid.isEmpty()) refreshLatestCommentFor(aid);
                });

        updateSelectionUi();
        loadPage(1, true);
        if (includeFaces) loadFaces();
        return root;
    }

    @Override
    public void onStart() {
        super.onStart();
        if (getDialog() != null && getDialog().getWindow() != null) {
            getDialog().getWindow().setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            getDialog().getWindow().setBackgroundDrawableResource(R.color.app_background);
        }
    }

    @Override
    public void onDestroyView() {
        loadExecutor.shutdownNow();
        super.onDestroyView();
    }

    private boolean canComment() {
        return (permissions & ShareModels.PERM_COMMENT) != 0;
    }

    private boolean canLike() {
        return (permissions & ShareModels.PERM_LIKE) != 0;
    }

    private boolean canImport() {
        return (permissions & ShareModels.PERM_VIEW) != 0;
    }

    private int color(int resId) {
        return ContextCompat.getColor(requireContext(), resId);
    }

    private void showMoreMenu(View anchor) {
        android.widget.PopupMenu pm = new android.widget.PopupMenu(requireContext(), anchor);
        Menu m = pm.getMenu();
        if (!selectionMode) {
            m.add(0, 1001, 0, "Select");
        } else {
            m.add(0, 1002, 0, "Select All");
            m.add(0, 1003, 1, "Deselect All");
            m.add(0, 1004, 2, "Cancel Selection");
        }
        m.add(0, 1005, 3, "Refresh");
        pm.setOnMenuItemClickListener(item -> {
            int id = item.getItemId();
            if (id == 1001) {
                setSelectionMode(true);
                return true;
            }
            if (id == 1002) {
                for (AssetTile t : visibleTiles) selectedIds.add(t.assetId);
                updateSelectionUi();
                assetAdapter.notifyDataSetChanged();
                return true;
            }
            if (id == 1003) {
                selectedIds.clear();
                updateSelectionUi();
                assetAdapter.notifyDataSetChanged();
                return true;
            }
            if (id == 1004) {
                setSelectionMode(false);
                return true;
            }
            if (id == 1005) {
                loadPage(1, true);
                return true;
            }
            return false;
        });
        pm.show();
    }

    private void setSelectionMode(boolean enabled) {
        selectionMode = enabled;
        if (!enabled) selectedIds.clear();
        updateSelectionUi();
        assetAdapter.notifyDataSetChanged();
    }

    private void updateSelectionUi() {
        selectionBar.setVisibility(selectionMode ? View.VISIBLE : View.GONE);
        tvSelectedCount.setText(selectedIds.size() + " selected");
        btnImport.setVisibility(canImport() && selectionMode ? View.VISIBLE : View.GONE);
        btnImport.setEnabled(!selectedIds.isEmpty());
    }

    private void loadPage(int pageToLoad, boolean reset) {
        if (loading) return;
        loading = true;
        if (reset) {
            swipe.setRefreshing(true);
            empty.setVisibility(View.GONE);
        }

        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                ShareModels.ShareAssetsPage pageResp = svc.listShareAssets(shareId, pageToLoad, 60, "newest");
                List<String> ids = pageResp.assetIds;

                Map<String, ShareModels.ShareAssetMetadata> metas = new HashMap<>();
                for (String aid : ids) {
                    try {
                        metas.put(aid, svc.getShareAssetMetadata(shareId, aid));
                    } catch (Exception ignored) {
                    }
                }

                Map<String, ShareModels.ShareComment> latestByAsset = svc.latestShareCommentsByAssets(shareId, ids);
                List<ShareModels.ShareLikeCount> likeCounts = svc.shareLikeCountsByAssets(shareId, ids);
                Map<String, ShareModels.ShareLikeCount> likeMap = new HashMap<>();
                for (ShareModels.ShareLikeCount lc : likeCounts) likeMap.put(lc.assetId, lc);

                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (reset) {
                        allAssetIds.clear();
                        assetById.clear();
                        page = 1;
                        hasMore = false;
                    }

                    for (String aid : ids) {
                        if (!assetById.containsKey(aid)) allAssetIds.add(aid);
                        ShareModels.ShareAssetMetadata m = metas.get(aid);
                        ShareModels.ShareLikeCount lc = likeMap.get(aid);
                        ShareModels.ShareComment cc = latestByAsset.get(aid);
                        AssetTile tile = assetById.get(aid);
                        if (tile == null) tile = new AssetTile(aid);
                        tile.meta = m;
                        tile.likeCount = lc != null ? lc.count : 0;
                        tile.likedByMe = lc != null && lc.likedByMe;
                        tile.latestComment = cc;
                        assetById.put(aid, tile);
                    }

                    hasMore = pageResp.hasMore;
                    page = pageToLoad;
                    rebuildVisibleList();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) {
                        unauthorizedAndClose();
                    } else {
                        Toast.makeText(requireContext(), "Failed to load share assets", Toast.LENGTH_LONG).show();
                        rebuildVisibleList();
                    }
                });
            } finally {
                loading = false;
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> swipe.setRefreshing(false));
            }
        }).start();
    }

    private void loadFaces() {
        new Thread(() -> {
            try {
                List<ShareModels.ShareFace> faces = new ServerPhotosService(requireContext().getApplicationContext())
                        .listShareFaces(shareId, 20);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    facesAdapter.submit(faces);
                    facesRail.setVisibility(faces.isEmpty() ? View.GONE : View.VISIBLE);
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) unauthorizedAndClose();
                    else facesRail.setVisibility(View.GONE);
                });
            }
        }).start();
    }

    private void onFaceSelected(@Nullable ShareModels.ShareFace face) {
        if (face == null) {
            activeFaceAssetIds = null;
            rebuildVisibleList();
            return;
        }
        swipe.setRefreshing(true);
        new Thread(() -> {
            try {
                List<String> ids = new ServerPhotosService(requireContext().getApplicationContext())
                        .listShareFaceAssets(shareId, face.personId);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    activeFaceAssetIds = new HashSet<>(ids);
                    rebuildVisibleList();
                    swipe.setRefreshing(false);
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    swipe.setRefreshing(false);
                    if (ShareE2EEManager.isUnauthorizedError(e)) unauthorizedAndClose();
                    else Toast.makeText(requireContext(), "Face filter failed", Toast.LENGTH_SHORT).show();
                });
            }
        }).start();
    }

    private void rebuildVisibleList() {
        visibleTiles.clear();
        for (String aid : allAssetIds) {
            if (activeFaceAssetIds != null && !activeFaceAssetIds.contains(aid)) continue;
            AssetTile t = assetById.get(aid);
            if (t != null) visibleTiles.add(t);
        }
        assetAdapter.submit(visibleTiles);
        empty.setVisibility(visibleTiles.isEmpty() ? View.VISIBLE : View.GONE);
        updateSelectionUi();
    }

    private void onAssetClick(int position) {
        if (position < 0 || position >= visibleTiles.size()) return;
        AssetTile tile = visibleTiles.get(position);
        if (selectionMode) {
            toggleSelection(tile.assetId);
            return;
        }
        ArrayList<String> ids = new ArrayList<>();
        for (AssetTile t : visibleTiles) ids.add(t.assetId);
        ShareFullScreenDialogFragment f = ShareFullScreenDialogFragment.newInstance(shareId, ids, position);
        f.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_MediaFullscreenDialog);
        f.show(getParentFragmentManager(), "share_fullscreen");
    }

    private void onAssetLongClick(int position) {
        if (position < 0 || position >= visibleTiles.size()) return;
        if (!selectionMode) setSelectionMode(true);
        toggleSelection(visibleTiles.get(position).assetId);
    }

    private void toggleSelection(String assetId) {
        if (selectedIds.contains(assetId)) selectedIds.remove(assetId);
        else selectedIds.add(assetId);
        updateSelectionUi();
        assetAdapter.notifyDataSetChanged();
    }

    private void onCommentClick(AssetTile tile) {
        ShareCommentsDialogFragment d = ShareCommentsDialogFragment.newInstance(shareId, tile.assetId, canComment());
        d.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
        d.show(getParentFragmentManager(), "share_comments");
    }

    private void refreshLatestCommentFor(String assetId) {
        loadExecutor.execute(() -> {
            try {
                List<ShareModels.ShareComment> list = new ServerPhotosService(requireContext().getApplicationContext())
                        .listShareComments(shareId, assetId, 1, null);
                ShareModels.ShareComment latest = list.isEmpty() ? null : list.get(0);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    AssetTile tile = assetById.get(assetId);
                    if (tile != null) {
                        tile.latestComment = latest;
                        assetAdapter.notifyDataSetChanged();
                    }
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) unauthorizedAndClose();
                });
            }
        });
    }

    private void onLikeClick(AssetTile tile) {
        if (!canLike()) return;
        boolean nextLike = !tile.likedByMe;
        new Thread(() -> {
            try {
                ShareModels.ShareLikeCount r = new ServerPhotosService(requireContext().getApplicationContext())
                        .toggleShareLike(shareId, tile.assetId, nextLike);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    AssetTile t = assetById.get(tile.assetId);
                    if (t != null) {
                        t.likedByMe = r.likedByMe;
                        t.likeCount = r.count;
                        assetAdapter.notifyDataSetChanged();
                    }
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) unauthorizedAndClose();
                    else Toast.makeText(requireContext(), "Like failed", Toast.LENGTH_SHORT).show();
                });
            }
        }).start();
    }

    private void importSelected() {
        if (!canImport()) return;
        if (selectedIds.isEmpty()) return;
        ArrayList<String> ids = new ArrayList<>(selectedIds);
        new Thread(() -> {
            try {
                ShareModels.ImportResult r = new ServerPhotosService(requireContext().getApplicationContext())
                        .importShareAssets(shareId, ids);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    Toast.makeText(requireContext(), "Imported " + r.imported + ", skipped " + r.skipped + ", failed " + r.failed, Toast.LENGTH_LONG).show();
                    setSelectionMode(false);
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) unauthorizedAndClose();
                    else Toast.makeText(requireContext(), "Import failed", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void unauthorizedAndClose() {
        getParentFragmentManager().setFragmentResult(KEY_VIEWER_AUTH_EXPIRED, new Bundle());
        dismissAllowingStateLoss();
    }

    private final class AssetAdapter extends RecyclerView.Adapter<AssetAdapter.VH> {
        private final List<AssetTile> data = new ArrayList<>();
        private final Map<String, Bitmap> thumbs = new HashMap<>();
        private final Set<String> loadingThumbs = new HashSet<>();

        void submit(List<AssetTile> tiles) {
            data.clear();
            data.addAll(tiles);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_share_asset, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            AssetTile t = data.get(position);
            Bitmap bmp = thumbs.get(t.assetId);
            if (bmp != null) {
                h.image.setImageBitmap(bmp);
            } else {
                h.image.setImageDrawable(new ColorDrawable(color(R.color.app_placeholder_alt)));
                maybeLoadThumb(t, h);
            }

            h.iconVideo.setVisibility(t.meta != null && t.meta.isVideo ? View.VISIBLE : View.GONE);
            h.btnComment.setVisibility((canComment() || t.latestComment != null) ? View.VISIBLE : View.GONE);
            h.btnLike.setVisibility((canLike() || t.likeCount > 0) ? View.VISIBLE : View.GONE);
            h.tvLikeCount.setVisibility(t.likeCount > 0 ? View.VISIBLE : View.GONE);
            h.tvLikeCount.setText(String.valueOf(t.likeCount));
            h.btnLike.setText(t.likedByMe ? "\u2665" : "\u2661");
            h.btnLike.setTextColor(t.likedByMe ? color(R.color.app_error) : Color.WHITE);

            boolean selected = selectedIds.contains(t.assetId);
            h.check.setVisibility(selectionMode ? View.VISIBLE : View.GONE);
            h.selectionBorder.setVisibility(selectionMode && selected ? View.VISIBLE : View.GONE);
            h.check.setImageResource(selected ? android.R.drawable.checkbox_on_background : android.R.drawable.checkbox_off_background);

            h.itemView.setOnClickListener(v -> onAssetClick(position));
            h.itemView.setOnLongClickListener(v -> {
                onAssetLongClick(position);
                return true;
            });
            h.btnComment.setOnClickListener(v -> onCommentClick(t));
            h.btnLike.setOnClickListener(v -> onLikeClick(t));
        }

        private void maybeLoadThumb(AssetTile tile, VH holder) {
            if (loadingThumbs.contains(tile.assetId)) return;
            loadingThumbs.add(tile.assetId);
            loadExecutor.execute(() -> {
                try {
                    ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                    ShareModels.ShareAssetMetadata meta = tile.meta;
                    if (meta == null) {
                        try {
                            meta = svc.getShareAssetMetadata(shareId, tile.assetId);
                            tile.meta = meta;
                        } catch (Exception ignored) {
                        }
                    }

                    byte[] bytes = svc.getShareAssetThumbnailData(shareId, tile.assetId);
                    byte[] plain = bytes;
                    if (meta != null && meta.locked) {
                        try {
                            plain = ShareE2EEManager.get(requireContext().getApplicationContext())
                                    .decryptShareContainer(shareId, tile.assetId, "thumb", bytes);
                        } catch (Exception ignored) {
                        }
                    }
                    Bitmap bmp = decodeBitmap(plain);
                    if (bmp == null) bmp = decodeVideoFrame(plain);
                    if (bmp != null) thumbs.put(tile.assetId, bmp);
                    final Bitmap finalBmp = bmp;

                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        loadingThumbs.remove(tile.assetId);
                        if (!tile.assetId.equals(holder.image.getTag())) {
                            notifyDataSetChanged();
                            return;
                        }
                        if (finalBmp != null) holder.image.setImageBitmap(finalBmp);
                    });
                } catch (Exception e) {
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        loadingThumbs.remove(tile.assetId);
                        if (ShareE2EEManager.isUnauthorizedError(e)) unauthorizedAndClose();
                    });
                }
            });
        }

        @Override
        public int getItemCount() {
            return data.size();
        }

        final class VH extends RecyclerView.ViewHolder {
            final android.widget.ImageView image;
            final android.widget.ImageView iconVideo;
            final TextView btnComment;
            final TextView btnLike;
            final TextView tvLikeCount;
            final android.widget.ImageView check;
            final View selectionBorder;

            VH(@NonNull View itemView) {
                super(itemView);
                image = itemView.findViewById(R.id.image);
                iconVideo = itemView.findViewById(R.id.icon_video);
                btnComment = itemView.findViewById(R.id.btn_comment);
                btnLike = itemView.findViewById(R.id.btn_like);
                tvLikeCount = itemView.findViewById(R.id.tv_like_count);
                check = itemView.findViewById(R.id.check);
                selectionBorder = itemView.findViewById(R.id.selection_border);
            }
        }
    }

    private final class FacesAdapter extends RecyclerView.Adapter<FacesAdapter.VH> {
        private final List<ShareModels.ShareFace> data = new ArrayList<>();
        @Nullable private String selectedPersonId = null;
        private final Map<String, Bitmap> thumbs = new HashMap<>();
        private final Set<String> loadingFace = new HashSet<>();

        void submit(List<ShareModels.ShareFace> faces) {
            data.clear();
            data.addAll(faces);
            if (selectedPersonId != null) {
                boolean found = false;
                for (ShareModels.ShareFace f : data) if (selectedPersonId.equals(f.personId)) found = true;
                if (!found) selectedPersonId = null;
            }
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_share_face, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            ShareModels.ShareFace f = data.get(position);
            h.name.setText(f.label());
            h.count.setText(String.valueOf(f.count));

            Bitmap bmp = thumbs.get(f.personId);
            if (bmp != null) h.face.setImageBitmap(bmp);
            else {
                h.face.setImageDrawable(new ColorDrawable(color(R.color.app_placeholder)));
                maybeLoadFaceThumb(f, h);
            }

            boolean selected = f.personId.equals(selectedPersonId);
            GradientDrawable bg = new GradientDrawable();
            bg.setCornerRadius(dp(10));
            bg.setStroke(dp(1), selected ? color(R.color.app_accent) : Color.TRANSPARENT);
            bg.setColor(selected ? color(R.color.app_selection_bg) : Color.TRANSPARENT);
            h.itemView.setBackground(bg);

            h.itemView.setOnClickListener(v -> {
                if (selected) {
                    selectedPersonId = null;
                    onFaceSelected(null);
                } else {
                    selectedPersonId = f.personId;
                    onFaceSelected(f);
                }
                notifyDataSetChanged();
            });
        }

        private void maybeLoadFaceThumb(ShareModels.ShareFace f, VH holder) {
            if (loadingFace.contains(f.personId)) return;
            loadingFace.add(f.personId);
            loadExecutor.execute(() -> {
                try {
                    byte[] bytes = new ServerPhotosService(requireContext().getApplicationContext())
                            .getShareFaceThumbnailData(shareId, f.personId);
                    Bitmap bmp = decodeBitmap(bytes);
                    if (bmp != null) thumbs.put(f.personId, bmp);
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        loadingFace.remove(f.personId);
                        if (bmp != null) holder.face.setImageBitmap(bmp);
                    });
                } catch (Exception e) {
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        loadingFace.remove(f.personId);
                        if (ShareE2EEManager.isUnauthorizedError(e)) unauthorizedAndClose();
                    });
                }
            });
        }

        @Override
        public int getItemCount() {
            return data.size();
        }

        final class VH extends RecyclerView.ViewHolder {
            final android.widget.ImageView face;
            final TextView name;
            final TextView count;

            VH(@NonNull View itemView) {
                super(itemView);
                face = itemView.findViewById(R.id.face);
                name = itemView.findViewById(R.id.name);
                count = itemView.findViewById(R.id.count);
            }
        }
    }

    private static final class AssetTile {
        final String assetId;
        @Nullable ShareModels.ShareAssetMetadata meta;
        int likeCount = 0;
        boolean likedByMe = false;
        @Nullable ShareModels.ShareComment latestComment;

        AssetTile(String assetId) {
            this.assetId = assetId;
        }
    }

    @Nullable
    private static Bitmap decodeBitmap(byte[] bytes) {
        if (bytes == null || bytes.length == 0) return null;
        try {
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        } catch (Exception ignored) {
            return null;
        }
    }

    @Nullable
    private Bitmap decodeVideoFrame(byte[] bytes) {
        if (bytes == null || bytes.length == 0) return null;
        File tmp = null;
        try {
            tmp = File.createTempFile("share_asset", ".bin", requireContext().getCacheDir());
            try (FileOutputStream fos = new FileOutputStream(tmp)) {
                fos.write(bytes);
            }
            android.media.MediaMetadataRetriever mmr = new android.media.MediaMetadataRetriever();
            mmr.setDataSource(tmp.getAbsolutePath());
            Bitmap b = mmr.getFrameAtTime(0);
            mmr.release();
            return b;
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

    private int dp(int v) {
        float d = requireContext().getResources().getDisplayMetrics().density;
        return Math.round(v * d);
    }
}
