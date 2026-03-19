package ca.openphotos.android.ui;

import android.app.AlertDialog;
import android.graphics.Color;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.LayoutInflater;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;
import androidx.fragment.app.Fragment;
import androidx.fragment.app.FragmentActivity;
import androidx.navigation.NavController;
import androidx.navigation.fragment.NavHostFragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.SimilarMediaModels;
import ca.openphotos.android.server.ServerPhotosService;
import com.bumptech.glide.Glide;
import com.bumptech.glide.load.model.GlideUrl;
import com.bumptech.glide.load.model.LazyHeaders;
import com.google.android.material.button.MaterialButton;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Full-screen Similar Media hub (photo + video groups). */
public class SimilarMediaDialogFragment extends DialogFragment {
    private enum PhotoSortKind {
        DATE,
        SIZE
    }

    private static final int PHOTO_THRESHOLD = 8;
    private static final int MIN_GROUP_SIZE = 2;
    private static final int PAGE_LIMIT = 50;

    private final ArrayList<PhotoGroupState> photoGroups = new ArrayList<>();
    private final ArrayList<VideoGroupState> videoGroups = new ArrayList<>();
    private final ArrayList<AlbumItem> albums = new ArrayList<>();

    private ServerPhotosService service;

    private boolean loadingPhotos = false;
    private boolean loadingVideos = false;
    private boolean photoDone = false;
    private boolean videoDone = false;
    private int photoCursor = 0;
    private int videoCursor = 0;
    private @Nullable String errorMessage;
    private boolean loadingAlbums = false;

    private TextView tvError;
    private TextView tvPhotoCount;
    private TextView tvVideoCount;
    private TextView tvPhotoEmpty;
    private TextView tvVideoEmpty;
    private MaterialButton btnPhotoLoadMore;
    private MaterialButton btnVideoLoadMore;
    private RecyclerView rvPhotoGroups;
    private RecyclerView rvVideoGroups;

    private final PhotoGroupAdapter photoAdapter = new PhotoGroupAdapter();
    private final VideoGroupAdapter videoAdapter = new VideoGroupAdapter();

    public static SimilarMediaDialogFragment newInstance() {
        return new SimilarMediaDialogFragment();
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_similar_media_dialog, container, false);
        service = new ServerPhotosService(requireContext().getApplicationContext());

        ImageButton btnClose = root.findViewById(R.id.btn_close);
        btnClose.setOnClickListener(v -> dismissAllowingStateLoss());

        tvError = root.findViewById(R.id.tv_error);
        tvPhotoCount = root.findViewById(R.id.tv_photo_groups_count);
        tvVideoCount = root.findViewById(R.id.tv_video_groups_count);
        tvPhotoEmpty = root.findViewById(R.id.tv_photo_empty);
        tvVideoEmpty = root.findViewById(R.id.tv_video_empty);
        btnPhotoLoadMore = root.findViewById(R.id.btn_photo_load_more);
        btnVideoLoadMore = root.findViewById(R.id.btn_video_load_more);
        rvPhotoGroups = root.findViewById(R.id.rv_photo_groups);
        rvVideoGroups = root.findViewById(R.id.rv_video_groups);

        rvPhotoGroups.setLayoutManager(new LinearLayoutManager(requireContext()));
        rvPhotoGroups.setNestedScrollingEnabled(false);
        rvPhotoGroups.setAdapter(photoAdapter);

        rvVideoGroups.setLayoutManager(new LinearLayoutManager(requireContext()));
        rvVideoGroups.setNestedScrollingEnabled(false);
        rvVideoGroups.setAdapter(videoAdapter);

        btnPhotoLoadMore.setOnClickListener(v -> loadMorePhotos());
        btnVideoLoadMore.setOnClickListener(v -> loadMoreVideos());

        updateUi();
        loadInitial();
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

    private void loadInitial() {
        photoGroups.clear();
        videoGroups.clear();
        errorMessage = null;
        photoCursor = 0;
        videoCursor = 0;
        photoDone = false;
        videoDone = false;
        loadingPhotos = false;
        loadingVideos = false;
        updateUi();
        loadMorePhotos();
        loadMoreVideos();
    }

    private void loadMorePhotos() {
        if (loadingPhotos || photoDone) return;
        loadingPhotos = true;
        updateUi();
        new Thread(() -> {
            try {
                SimilarMediaModels.GroupsResponse resp = service.getSimilarPhotoGroups(
                        PHOTO_THRESHOLD,
                        MIN_GROUP_SIZE,
                        PAGE_LIMIT,
                        photoCursor
                );
                ArrayList<PhotoGroupState> toAdd = new ArrayList<>();
                for (SimilarMediaModels.SimilarGroup g : resp.groups) {
                    List<String> base = toBaseItems(g);
                    Map<String, SimilarMediaModels.AssetMeta> meta = new HashMap<>();
                    for (String id : base) {
                        SimilarMediaModels.AssetMeta m = resp.metadata.get(id);
                        if (m != null) meta.put(id, m);
                    }
                    toAdd.add(new PhotoGroupState(g, base, meta));
                }
                runOnUi(() -> {
                    photoGroups.addAll(toAdd);
                    if (resp.nextCursor != null) {
                        photoCursor = resp.nextCursor;
                    } else {
                        photoDone = true;
                    }
                    loadingPhotos = false;
                    updateUi();
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    loadingPhotos = false;
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    if (photoGroups.isEmpty()) {
                        errorMessage = msg.isEmpty() ? "Failed to load similar photo groups" : msg;
                        photoDone = true;
                    } else {
                        Toast.makeText(requireContext(), "Failed to load more photo groups", Toast.LENGTH_LONG).show();
                    }
                    updateUi();
                });
            }
        }).start();
    }

    private void loadMoreVideos() {
        if (loadingVideos || videoDone) return;
        loadingVideos = true;
        updateUi();
        new Thread(() -> {
            try {
                SimilarMediaModels.GroupsResponse resp = service.getSimilarVideoGroups(
                        MIN_GROUP_SIZE,
                        PAGE_LIMIT,
                        videoCursor
                );
                ArrayList<VideoGroupState> toAdd = new ArrayList<>();
                for (SimilarMediaModels.SimilarGroup g : resp.groups) {
                    toAdd.add(new VideoGroupState(g, toBaseItems(g)));
                }
                runOnUi(() -> {
                    videoGroups.addAll(toAdd);
                    if (resp.nextCursor != null) {
                        videoCursor = resp.nextCursor;
                    } else {
                        videoDone = true;
                    }
                    loadingVideos = false;
                    updateUi();
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    loadingVideos = false;
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    if (videoGroups.isEmpty()) {
                        errorMessage = msg.isEmpty() ? "Failed to load similar video groups" : msg;
                        videoDone = true;
                    } else {
                        Toast.makeText(requireContext(), "Failed to load more video groups", Toast.LENGTH_LONG).show();
                    }
                    updateUi();
                });
            }
        }).start();
    }

    private List<String> toBaseItems(SimilarMediaModels.SimilarGroup group) {
        ArrayList<String> out = new ArrayList<>();
        if (group == null) return out;
        if (group.members.contains(group.representative)) {
            out.add(group.representative);
            for (String m : group.members) {
                if (!TextUtils.equals(m, group.representative)) out.add(m);
            }
        } else {
            out.addAll(group.members);
        }
        return out;
    }

    private void updateUi() {
        if (!isAdded()) return;
        tvError.setVisibility(TextUtils.isEmpty(errorMessage) ? View.GONE : View.VISIBLE);
        tvError.setText(errorMessage == null ? "" : errorMessage);

        tvPhotoCount.setText(photoGroups.size() + " groups loaded");
        tvVideoCount.setText(videoGroups.size() + " groups loaded");

        if (photoDone) {
            btnPhotoLoadMore.setEnabled(false);
            btnPhotoLoadMore.setText("All loaded");
        } else if (loadingPhotos) {
            btnPhotoLoadMore.setEnabled(false);
            btnPhotoLoadMore.setText("Loading...");
        } else {
            btnPhotoLoadMore.setEnabled(true);
            btnPhotoLoadMore.setText("Load more");
        }

        if (videoDone) {
            btnVideoLoadMore.setEnabled(false);
            btnVideoLoadMore.setText("All loaded");
        } else if (loadingVideos) {
            btnVideoLoadMore.setEnabled(false);
            btnVideoLoadMore.setText("Loading...");
        } else {
            btnVideoLoadMore.setEnabled(true);
            btnVideoLoadMore.setText("Load more");
        }

        tvPhotoEmpty.setVisibility(photoGroups.isEmpty() && !loadingPhotos ? View.VISIBLE : View.GONE);
        tvVideoEmpty.setVisibility(videoGroups.isEmpty() && !loadingVideos ? View.VISIBLE : View.GONE);

        photoAdapter.submit(photoGroups);
        videoAdapter.submit(videoGroups);
    }

    private void toggleSelectAllPhotos(int groupIndex) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        if (g.selected.isEmpty()) {
            g.selected.addAll(g.visibleItems());
        } else {
            g.selected.clear();
        }
        photoAdapter.notifyItemChanged(groupIndex);
    }

    private void toggleSelectPhoto(int groupIndex, @NonNull String assetId) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        if (g.selected.contains(assetId)) g.selected.remove(assetId);
        else g.selected.add(assetId);
        photoAdapter.notifyItemChanged(groupIndex);
    }

    private void clearSelectionForPhotoGroup(int groupIndex) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        g.selected.clear();
        photoAdapter.notifyItemChanged(groupIndex);
    }

    private void setPhotoSort(int groupIndex, @NonNull PhotoSortKind sortKind) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        g.sortKind = sortKind;
        photoAdapter.notifyItemChanged(groupIndex);
    }

    private void selectInferiorPhotos(int groupIndex) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        List<String> items = g.visibleItems();
        if (items.isEmpty()) return;
        String maxId = items.get(0);
        long maxSize = g.metaFor(maxId).size;
        for (int i = 1; i < items.size(); i++) {
            String id = items.get(i);
            long size = g.metaFor(id).size;
            if (size > maxSize) {
                maxSize = size;
                maxId = id;
            }
        }
        g.selected.clear();
        for (String id : items) {
            if (!TextUtils.equals(id, maxId)) g.selected.add(id);
        }
        photoAdapter.notifyItemChanged(groupIndex);
    }

    private void deleteSelectedPhotos(int groupIndex) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        ArrayList<String> ids = new ArrayList<>(g.selected);
        if (ids.isEmpty()) return;
        new Thread(() -> {
            try {
                service.deletePhotos(ids);
                runOnUi(() -> {
                    g.removedIds.addAll(ids);
                    g.selected.clear();
                    photoAdapter.notifyItemChanged(groupIndex);
                    Toast.makeText(requireContext(), "Deleted " + ids.size() + " photo(s)", Toast.LENGTH_SHORT).show();
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    Toast.makeText(requireContext(), "Delete failed" + (msg.isEmpty() ? "" : (": " + msg)), Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void applyAlbumFilterToPhotoGroup(int groupIndex, int albumId, @Nullable String albumName) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        Set<String> targetIds = new LinkedHashSet<>(g.baseItems);
        new Thread(() -> {
            Set<String> found = new LinkedHashSet<>();
            int page = 1;
            final int perPage = 250;
            boolean hasMore = true;
            while (hasMore && found.size() < targetIds.size()) {
                try {
                    JSONObject res = service.listPhotos(albumId, null, null, page, perPage);
                    JSONArray photos = res.optJSONArray("photos");
                    if (photos != null) {
                        for (int i = 0; i < photos.length(); i++) {
                            JSONObject p = photos.optJSONObject(i);
                            if (p == null) continue;
                            String id = p.optString("asset_id", "");
                            if (targetIds.contains(id)) found.add(id);
                        }
                    }
                    hasMore = res.optBoolean("has_more", false);
                    page += 1;
                } catch (Exception e) {
                    hasMore = false;
                    runOnUi(() -> {
                        String msg = e.getMessage() != null ? e.getMessage() : "";
                        if (handleSessionExpiredIfNeeded(msg)) return;
                        Toast.makeText(requireContext(), "Failed to apply album filter", Toast.LENGTH_LONG).show();
                    });
                }
            }
            runOnUi(() -> {
                if (!photoGroupsIndicesContains(groupIndex)) return;
                PhotoGroupState state = photoGroups.get(groupIndex);
                state.filteredItems = new ArrayList<>();
                for (String id : state.baseItems) {
                    if (found.contains(id)) state.filteredItems.add(id);
                }
                state.albumId = albumId;
                state.albumName = albumName;
                state.selected.clear();
                photoAdapter.notifyItemChanged(groupIndex);
            });
        }).start();
    }

    private void clearAlbumFilterForPhotoGroup(int groupIndex) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        g.filteredItems = null;
        g.albumId = null;
        g.albumName = null;
        g.selected.clear();
        photoAdapter.notifyItemChanged(groupIndex);
    }

    private void toggleSelectAllVideos(int groupIndex) {
        if (!videoGroupsIndicesContains(groupIndex)) return;
        VideoGroupState g = videoGroups.get(groupIndex);
        if (g.selected.isEmpty()) g.selected.addAll(g.visibleItems());
        else g.selected.clear();
        videoAdapter.notifyItemChanged(groupIndex);
    }

    private void toggleSelectVideo(int groupIndex, @NonNull String assetId) {
        if (!videoGroupsIndicesContains(groupIndex)) return;
        VideoGroupState g = videoGroups.get(groupIndex);
        if (g.selected.contains(assetId)) g.selected.remove(assetId);
        else g.selected.add(assetId);
        videoAdapter.notifyItemChanged(groupIndex);
    }

    private void clearSelectionForVideoGroup(int groupIndex) {
        if (!videoGroupsIndicesContains(groupIndex)) return;
        VideoGroupState g = videoGroups.get(groupIndex);
        g.selected.clear();
        videoAdapter.notifyItemChanged(groupIndex);
    }

    private void selectInferiorVideos(int groupIndex) {
        if (!videoGroupsIndicesContains(groupIndex)) return;
        VideoGroupState g = videoGroups.get(groupIndex);
        List<String> items = g.visibleItems();
        if (items.isEmpty()) return;
        ArrayList<String> missing = new ArrayList<>();
        for (String id : items) {
            if (!g.sizes.containsKey(id)) missing.add(id);
        }

        new Thread(() -> {
            if (!missing.isEmpty()) {
                try {
                    JSONArray arr = service.getPhotosByAssetIds(missing, true);
                    for (int i = 0; i < arr.length(); i++) {
                        JSONObject p = arr.optJSONObject(i);
                        if (p == null) continue;
                        String id = p.optString("asset_id", "");
                        long size = p.optLong("size", 0L);
                        if (!id.isEmpty()) g.sizes.put(id, size);
                    }
                } catch (Exception e) {
                    runOnUi(() -> {
                        String msg = e.getMessage() != null ? e.getMessage() : "";
                        if (handleSessionExpiredIfNeeded(msg)) return;
                        Toast.makeText(requireContext(), "Failed to load video sizes", Toast.LENGTH_LONG).show();
                    });
                }
            }
            runOnUi(() -> {
                if (!videoGroupsIndicesContains(groupIndex)) return;
                VideoGroupState state = videoGroups.get(groupIndex);
                List<String> visible = state.visibleItems();
                if (visible.isEmpty()) return;
                String maxId = visible.get(0);
                long maxSize = state.sizeFor(maxId);
                for (int i = 1; i < visible.size(); i++) {
                    String id = visible.get(i);
                    long size = state.sizeFor(id);
                    if (size > maxSize) {
                        maxSize = size;
                        maxId = id;
                    }
                }
                state.selected.clear();
                for (String id : visible) {
                    if (!TextUtils.equals(id, maxId)) state.selected.add(id);
                }
                videoAdapter.notifyItemChanged(groupIndex);
            });
        }).start();
    }

    private void deleteSelectedVideos(int groupIndex) {
        if (!videoGroupsIndicesContains(groupIndex)) return;
        VideoGroupState g = videoGroups.get(groupIndex);
        ArrayList<String> ids = new ArrayList<>(g.selected);
        if (ids.isEmpty()) return;
        new Thread(() -> {
            try {
                service.deletePhotos(ids);
                runOnUi(() -> {
                    g.removedIds.addAll(ids);
                    g.selected.clear();
                    videoAdapter.notifyItemChanged(groupIndex);
                    Toast.makeText(requireContext(), "Deleted " + ids.size() + " video(s)", Toast.LENGTH_SHORT).show();
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    Toast.makeText(requireContext(), "Delete failed" + (msg.isEmpty() ? "" : (": " + msg)), Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void openViewer(@NonNull String assetId) {
        String uri = service.imageUrl(assetId);
        dismissAllowingStateLoss();
        if (!isAdded()) return;
        requireActivity().getWindow().getDecorView().post(() -> {
            try {
                FragmentActivity act = requireActivity();
                Fragment navHost = act.getSupportFragmentManager().findFragmentById(R.id.nav_host_fragment);
                if (navHost instanceof NavHostFragment) {
                    NavController nav = ((NavHostFragment) navHost).getNavController();
                    Bundle b = new Bundle();
                    b.putString("uri", uri);
                    b.putBoolean("isServer", true);
                    b.putString("assetId", assetId);
                    nav.navigate(R.id.viewerFragment, b);
                }
            } catch (Exception e) {
                Toast.makeText(requireContext(), "Failed to open viewer", Toast.LENGTH_SHORT).show();
            }
        });
    }

    private void showPhotoActionsMenu(@NonNull View anchor, int groupIndex) {
        if (!photoGroupsIndicesContains(groupIndex)) return;
        PhotoGroupState g = photoGroups.get(groupIndex);
        PopupMenu pm = new PopupMenu(requireContext(), anchor);
        pm.getMenu().add(0, 1, 0, "Select All");
        pm.getMenu().add(0, 2, 1, "Clear Selection");
        pm.getMenu().add(0, 3, 2, "Select Inferior");
        MenuItem del = pm.getMenu().add(0, 4, 3, "Delete Selected");
        del.setEnabled(!g.selected.isEmpty());
        pm.setOnMenuItemClickListener(item -> {
            int id = item.getItemId();
            if (id == 1) toggleSelectAllPhotos(groupIndex);
            else if (id == 2) clearSelectionForPhotoGroup(groupIndex);
            else if (id == 3) selectInferiorPhotos(groupIndex);
            else if (id == 4) deleteSelectedPhotos(groupIndex);
            return true;
        });
        pm.show();
    }

    private void showVideoActionsMenu(@NonNull View anchor, int groupIndex) {
        if (!videoGroupsIndicesContains(groupIndex)) return;
        VideoGroupState g = videoGroups.get(groupIndex);
        PopupMenu pm = new PopupMenu(requireContext(), anchor);
        pm.getMenu().add(0, 1, 0, "Select All");
        pm.getMenu().add(0, 2, 1, "Clear Selection");
        pm.getMenu().add(0, 3, 2, "Select Inferior");
        MenuItem del = pm.getMenu().add(0, 4, 3, "Delete Selected");
        del.setEnabled(!g.selected.isEmpty());
        pm.setOnMenuItemClickListener(item -> {
            int id = item.getItemId();
            if (id == 1) toggleSelectAllVideos(groupIndex);
            else if (id == 2) clearSelectionForVideoGroup(groupIndex);
            else if (id == 3) selectInferiorVideos(groupIndex);
            else if (id == 4) deleteSelectedVideos(groupIndex);
            return true;
        });
        pm.show();
    }

    private void showPhotoSortMenu(@NonNull View anchor, int groupIndex) {
        PopupMenu pm = new PopupMenu(requireContext(), anchor);
        pm.getMenu().add(0, 1, 0, "Date (Newest First)");
        pm.getMenu().add(0, 2, 1, "File Size (Largest First)");
        pm.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == 1) setPhotoSort(groupIndex, PhotoSortKind.DATE);
            else if (item.getItemId() == 2) setPhotoSort(groupIndex, PhotoSortKind.SIZE);
            return true;
        });
        pm.show();
    }

    private void openAlbumPickerForPhotoGroup(int groupIndex) {
        if (loadingAlbums) return;
        if (!albums.isEmpty()) {
            showAlbumPickerDialog(groupIndex);
            return;
        }
        loadingAlbums = true;
        new Thread(() -> {
            try {
                JSONArray arr = service.listAlbums();
                ArrayList<AlbumItem> loaded = new ArrayList<>();
                for (int i = 0; i < arr.length(); i++) {
                    JSONObject j = arr.optJSONObject(i);
                    if (j == null) continue;
                    int id = j.optInt("id", 0);
                    String name = j.optString("name", "");
                    if (id > 0 && !name.trim().isEmpty()) loaded.add(new AlbumItem(id, name));
                }
                runOnUi(() -> {
                    loadingAlbums = false;
                    albums.clear();
                    albums.addAll(loaded);
                    showAlbumPickerDialog(groupIndex);
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    loadingAlbums = false;
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    Toast.makeText(requireContext(), "Failed to load albums", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void showAlbumPickerDialog(int groupIndex) {
        if (albums.isEmpty()) {
            Toast.makeText(requireContext(), "No albums available", Toast.LENGTH_SHORT).show();
            return;
        }
        CharSequence[] labels = new CharSequence[albums.size()];
        for (int i = 0; i < albums.size(); i++) labels[i] = albums.get(i).name;
        new AlertDialog.Builder(requireContext())
                .setTitle("Filter by Album")
                .setItems(labels, (dialog, which) -> {
                    if (which < 0 || which >= albums.size()) return;
                    AlbumItem item = albums.get(which);
                    applyAlbumFilterToPhotoGroup(groupIndex, item.id, item.name);
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private boolean photoGroupsIndicesContains(int idx) {
        return idx >= 0 && idx < photoGroups.size();
    }

    private boolean videoGroupsIndicesContains(int idx) {
        return idx >= 0 && idx < videoGroups.size();
    }

    private boolean handleSessionExpiredIfNeeded(@Nullable String msg) {
        if (msg == null) return false;
        if (msg.contains("HTTP 401") && !AuthManager.get(requireContext().getApplicationContext()).isAuthenticated()) {
            handleAuthExpired();
            return true;
        }
        return false;
    }

    private void handleAuthExpired() {
        try {
            AuthManager.get(requireContext()).logout();
        } catch (Exception ignored) {
        }
        Toast.makeText(requireContext(), "Session expired. Please sign in again.", Toast.LENGTH_LONG).show();
        try {
            FragmentActivity act = requireActivity();
            Fragment navHost = act.getSupportFragmentManager().findFragmentById(R.id.nav_host_fragment);
            if (navHost instanceof NavHostFragment) {
                NavController nav = ((NavHostFragment) navHost).getNavController();
                nav.navigate(R.id.serverLoginFragment);
            }
            dismissAllowingStateLoss();
        } catch (Exception ignored) {
        }
    }

    private Object authAwareModel(@NonNull String absoluteUrl) {
        String token = AuthManager.get(requireContext()).getToken();
        if (token == null || token.isEmpty()) return absoluteUrl;
        return new GlideUrl(
                absoluteUrl,
                new LazyHeaders.Builder().addHeader("Authorization", "Bearer " + token).build()
        );
    }

    private void runOnUi(@NonNull Runnable runnable) {
        if (!isAdded()) return;
        requireActivity().runOnUiThread(() -> {
            if (!isAdded()) return;
            runnable.run();
        });
    }

    private static final class PhotoGroupState {
        final SimilarMediaModels.SimilarGroup group;
        final ArrayList<String> baseItems;
        final HashMap<String, SimilarMediaModels.AssetMeta> metadata = new HashMap<>();
        @Nullable ArrayList<String> filteredItems;
        final LinkedHashSet<String> removedIds = new LinkedHashSet<>();
        final LinkedHashSet<String> selected = new LinkedHashSet<>();
        @Nullable Integer albumId;
        @Nullable String albumName;
        PhotoSortKind sortKind = PhotoSortKind.DATE;

        PhotoGroupState(
                @NonNull SimilarMediaModels.SimilarGroup group,
                @NonNull List<String> baseItems,
                @NonNull Map<String, SimilarMediaModels.AssetMeta> metadata
        ) {
            this.group = group;
            this.baseItems = new ArrayList<>(baseItems);
            this.metadata.putAll(metadata);
        }

        SimilarMediaModels.AssetMeta metaFor(@NonNull String assetId) {
            SimilarMediaModels.AssetMeta m = metadata.get(assetId);
            if (m != null) return m;
            return new SimilarMediaModels.AssetMeta(null, 0L, 0L);
        }

        List<String> visibleItems() {
            List<String> source = filteredItems != null ? filteredItems : baseItems;
            ArrayList<String> out = new ArrayList<>();
            for (String id : source) {
                if (!removedIds.contains(id)) out.add(id);
            }
            if (sortKind == PhotoSortKind.DATE) {
                out.sort((a, b) -> Long.compare(metaFor(b).createdAt, metaFor(a).createdAt));
            } else {
                out.sort((a, b) -> Long.compare(metaFor(b).size, metaFor(a).size));
            }
            return out;
        }
    }

    private static final class VideoGroupState {
        final SimilarMediaModels.SimilarGroup group;
        final ArrayList<String> baseItems;
        final LinkedHashSet<String> removedIds = new LinkedHashSet<>();
        final LinkedHashSet<String> selected = new LinkedHashSet<>();
        final HashMap<String, Long> sizes = new HashMap<>();

        VideoGroupState(@NonNull SimilarMediaModels.SimilarGroup group, @NonNull List<String> baseItems) {
            this.group = group;
            this.baseItems = new ArrayList<>(baseItems);
        }

        List<String> visibleItems() {
            ArrayList<String> out = new ArrayList<>();
            for (String id : baseItems) {
                if (!removedIds.contains(id)) out.add(id);
            }
            return out;
        }

        long sizeFor(@NonNull String assetId) {
            Long s = sizes.get(assetId);
            return s != null ? s : 0L;
        }
    }

    private static final class AlbumItem {
        final int id;
        final String name;

        AlbumItem(int id, @NonNull String name) {
            this.id = id;
            this.name = name;
        }
    }

    private final class PhotoGroupAdapter extends RecyclerView.Adapter<PhotoGroupAdapter.PhotoGroupVH> {
        private final ArrayList<PhotoGroupState> items = new ArrayList<>();

        void submit(List<PhotoGroupState> list) {
            items.clear();
            if (list != null) items.addAll(list);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public PhotoGroupVH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_similar_photo_group, parent, false);
            return new PhotoGroupVH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull PhotoGroupVH holder, int position) {
            PhotoGroupState g = items.get(position);
            List<String> visible = g.visibleItems();
            holder.groupCount.setText(visible.size() + " / " + g.group.count);
            holder.selectedCount.setVisibility(g.selected.isEmpty() ? View.GONE : View.VISIBLE);
            holder.selectedCount.setText("Selected (" + g.selected.size() + ")");
            holder.btnActions.setOnClickListener(v -> showPhotoActionsMenu(v, holder.getBindingAdapterPosition()));
            holder.btnSort.setOnClickListener(v -> showPhotoSortMenu(v, holder.getBindingAdapterPosition()));
            holder.btnAlbum.setOnClickListener(v -> openAlbumPickerForPhotoGroup(holder.getBindingAdapterPosition()));
            holder.albumFilterWrap.setVisibility(g.albumId != null && !TextUtils.isEmpty(g.albumName) ? View.VISIBLE : View.GONE);
            holder.albumFilterText.setText(g.albumName == null ? "" : g.albumName);
            holder.btnClearAlbum.setOnClickListener(v -> clearAlbumFilterForPhotoGroup(holder.getBindingAdapterPosition()));

            holder.assets.setLayoutManager(new GridLayoutManager(requireContext(), 3));
            holder.assets.setNestedScrollingEnabled(false);
            holder.assets.setAdapter(new AssetTileAdapter(
                    visible,
                    g.selected,
                    (assetId) -> {
                        int idx = holder.getBindingAdapterPosition();
                        if (!photoGroupsIndicesContains(idx)) return;
                        PhotoGroupState state = photoGroups.get(idx);
                        if (state.selected.isEmpty()) openViewer(assetId);
                        else toggleSelectPhoto(idx, assetId);
                    }
            ));
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        final class PhotoGroupVH extends RecyclerView.ViewHolder {
            final TextView groupCount;
            final TextView selectedCount;
            final MaterialButton btnActions;
            final MaterialButton btnSort;
            final MaterialButton btnAlbum;
            final LinearLayout albumFilterWrap;
            final TextView albumFilterText;
            final ImageButton btnClearAlbum;
            final RecyclerView assets;

            PhotoGroupVH(@NonNull View itemView) {
                super(itemView);
                groupCount = itemView.findViewById(R.id.tv_group_count);
                selectedCount = itemView.findViewById(R.id.tv_selected_count);
                btnActions = itemView.findViewById(R.id.btn_actions);
                btnSort = itemView.findViewById(R.id.btn_sort);
                btnAlbum = itemView.findViewById(R.id.btn_album);
                albumFilterWrap = itemView.findViewById(R.id.layout_album_filter);
                albumFilterText = itemView.findViewById(R.id.tv_album_filter);
                btnClearAlbum = itemView.findViewById(R.id.btn_clear_album);
                assets = itemView.findViewById(R.id.rv_assets);
            }
        }
    }

    private final class VideoGroupAdapter extends RecyclerView.Adapter<VideoGroupAdapter.VideoGroupVH> {
        private final ArrayList<VideoGroupState> items = new ArrayList<>();

        void submit(List<VideoGroupState> list) {
            items.clear();
            if (list != null) items.addAll(list);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public VideoGroupVH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_similar_video_group, parent, false);
            return new VideoGroupVH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VideoGroupVH holder, int position) {
            VideoGroupState g = items.get(position);
            List<String> visible = g.visibleItems();
            holder.groupCount.setText(visible.size() + " / " + g.group.count);
            holder.selectedCount.setVisibility(g.selected.isEmpty() ? View.GONE : View.VISIBLE);
            holder.selectedCount.setText("Selected (" + g.selected.size() + ")");
            holder.btnActions.setOnClickListener(v -> showVideoActionsMenu(v, holder.getBindingAdapterPosition()));

            holder.assets.setLayoutManager(new GridLayoutManager(requireContext(), 3));
            holder.assets.setNestedScrollingEnabled(false);
            holder.assets.setAdapter(new AssetTileAdapter(
                    visible,
                    g.selected,
                    (assetId) -> {
                        int idx = holder.getBindingAdapterPosition();
                        if (!videoGroupsIndicesContains(idx)) return;
                        VideoGroupState state = videoGroups.get(idx);
                        if (state.selected.isEmpty()) openViewer(assetId);
                        else toggleSelectVideo(idx, assetId);
                    }
            ));
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        final class VideoGroupVH extends RecyclerView.ViewHolder {
            final TextView groupCount;
            final TextView selectedCount;
            final MaterialButton btnActions;
            final RecyclerView assets;

            VideoGroupVH(@NonNull View itemView) {
                super(itemView);
                groupCount = itemView.findViewById(R.id.tv_group_count);
                selectedCount = itemView.findViewById(R.id.tv_selected_count);
                btnActions = itemView.findViewById(R.id.btn_actions);
                assets = itemView.findViewById(R.id.rv_assets);
            }
        }
    }

    private interface AssetClickListener {
        void onTap(@NonNull String assetId);
    }

    private final class AssetTileAdapter extends RecyclerView.Adapter<AssetTileAdapter.AssetVH> {
        private final List<String> items;
        private final Set<String> selected;
        private final AssetClickListener listener;

        AssetTileAdapter(@NonNull List<String> items, @NonNull Set<String> selected, @NonNull AssetClickListener listener) {
            this.items = items;
            this.selected = selected;
            this.listener = listener;
        }

        @NonNull
        @Override
        public AssetVH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_similar_asset_tile, parent, false);
            return new AssetVH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull AssetVH holder, int position) {
            String assetId = items.get(position);
            holder.check.setVisibility(selected.contains(assetId) ? View.VISIBLE : View.GONE);
            String thumb = service.thumbnailUrl(assetId);
            Glide.with(SimilarMediaDialogFragment.this)
                    .load(authAwareModel(thumb))
                    .centerCrop()
                    .placeholder(new android.graphics.drawable.ColorDrawable(androidx.core.content.ContextCompat.getColor(requireContext(), R.color.app_placeholder)))
                    .error(new android.graphics.drawable.ColorDrawable(androidx.core.content.ContextCompat.getColor(requireContext(), R.color.app_placeholder_alt)))
                    .into(holder.image);
            holder.itemView.setOnClickListener(v -> listener.onTap(assetId));
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        final class AssetVH extends RecyclerView.ViewHolder {
            final ImageView image;
            final TextView check;

            AssetVH(@NonNull View itemView) {
                super(itemView);
                image = itemView.findViewById(R.id.img_asset);
                check = itemView.findViewById(R.id.tv_check);
            }
        }
    }
}
