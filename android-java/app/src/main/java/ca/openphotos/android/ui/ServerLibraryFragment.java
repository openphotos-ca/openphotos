package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.server.ServerPhotosService;

import org.json.JSONArray;

import java.util.ArrayList;

/** Server Library grid using the shared MediaGridAdapter. */
public class ServerLibraryFragment extends Fragment {
    private MediaGridAdapter adapter;
    private androidx.swiperefreshlayout.widget.SwipeRefreshLayout swipe;
    private String mediaFilter = "all"; // all|photos|videos
    private Boolean lockedFilter = null; // null=all, true=locked only
    private final java.util.ArrayList<MediaGridAdapter.Cell> all = new java.util.ArrayList<>();
    private int page = 1; private final int limit = 60; private boolean hasMore = true; private boolean loading = false;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_server_grid, container, false);
        RecyclerView rv = root.findViewById(R.id.server_grid);
        rv.setLayoutManager(new GridLayoutManager(requireContext(), 3));
        adapter = new MediaGridAdapter();
        rv.setAdapter(adapter);
        rv.addOnItemTouchListener(new ca.openphotos.android.ui.util.RecyclerItemClickListener(requireContext(), rv, new ca.openphotos.android.ui.util.RecyclerItemClickListener.OnItemClickListener() {
            @Override public void onItemClick(View view, int position) {
                java.util.List<MediaGridAdapter.Cell> list = adapter.getCurrentList();
                if (position >= 0 && position < list.size()) {
                    androidx.navigation.NavController nav = androidx.navigation.fragment.NavHostFragment.findNavController(ServerLibraryFragment.this);
                    android.os.Bundle args = new android.os.Bundle();
                    java.util.ArrayList<String> uris = new java.util.ArrayList<>();
                    java.util.ArrayList<String> assetIds = new java.util.ArrayList<>();
                    for (MediaGridAdapter.Cell it : all) { uris.add(it.uri); assetIds.add(it.assetId); }
                    args.putStringArrayList("uris", uris);
                    args.putStringArrayList("assetIds", assetIds);
                    args.putInt("index", position);
                    args.putBoolean("isServer", true);
                    android.view.View image = getImageForPosition(rv, position);
                    if (image != null) {
                        androidx.navigation.fragment.FragmentNavigator.Extras extras = new androidx.navigation.fragment.FragmentNavigator.Extras.Builder().addSharedElement(image, "hero_image").build();
                        nav.navigate(ca.openphotos.android.R.id.viewerFragment, args, null, extras);
                    } else {
                        nav.navigate(ca.openphotos.android.R.id.viewerFragment, args);
                    }
                }
            }
            @Override public void onLongItemClick(View view, int position) { /* selection in future */ }
        }));
        swipe = root.findViewById(R.id.swipe);
        swipe.setOnRefreshListener(this::refresh);

        // Filters
        com.google.android.material.chip.Chip chipAll = root.findViewById(R.id.chip_all);
        com.google.android.material.chip.Chip chipPhotos = root.findViewById(R.id.chip_photos);
        com.google.android.material.chip.Chip chipVideos = root.findViewById(R.id.chip_videos);
        com.google.android.material.chip.Chip chipLocked = root.findViewById(R.id.chip_locked);
        View.OnClickListener l = v -> {
            if (v == chipAll) { mediaFilter = "all"; lockedFilter = null; }
            else if (v == chipPhotos) { mediaFilter = "photos"; lockedFilter = null; }
            else if (v == chipVideos) { mediaFilter = "videos"; lockedFilter = null; }
            else if (v == chipLocked) { lockedFilter = true; mediaFilter = "all"; }
            refresh();
        };
        chipAll.setOnClickListener(l); chipPhotos.setOnClickListener(l); chipVideos.setOnClickListener(l); chipLocked.setOnClickListener(l);

        rv.addOnScrollListener(new RecyclerView.OnScrollListener() {
            @Override public void onScrolled(@NonNull RecyclerView recyclerView, int dx, int dy) {
                super.onScrolled(recyclerView, dx, dy);
                GridLayoutManager lm = (GridLayoutManager) recyclerView.getLayoutManager();
                int last = lm.findLastVisibleItemPosition();
                if (hasMore && !loading && last >= Math.max(0, all.size() - 6)) { loadNext(); }
            }
        });

        refresh(true);
        return root;
    }

    private void refresh() { refresh(false); }
    private void refresh(boolean reset) {
        if (reset) { page = 1; hasMore = true; all.clear(); adapter.submitList(new java.util.ArrayList<>(all)); }
        new Thread(() -> {
            try {
                loading = true;
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                String media = mediaFilter.equals("photos") ? "photos" : (mediaFilter.equals("videos") ? "videos" : null);
                org.json.JSONObject resp = svc.listPhotos(null, media, lockedFilter, page, limit);
                JSONArray photos = resp.has("photos") ? resp.getJSONArray("photos") : new JSONArray();
                hasMore = resp.optBoolean("has_more", false);
                ArrayList<MediaGridAdapter.Cell> list = new ArrayList<>();
                for (int i = 0; i < photos.length(); i++) {
                    org.json.JSONObject p = photos.getJSONObject(i);
                    String assetId = p.optString("asset_id");
                    boolean isVideo = p.optBoolean("is_video", false);
                    boolean locked = p.optBoolean("locked", false);
                    int rating = p.optInt("rating", 0);
                    String imgUrl = svc.thumbnailUrl(assetId);
                    list.add(new MediaGridAdapter.Cell("server-"+assetId, p.optString("filename", assetId), locked, imgUrl, isVideo, assetId, rating));
                }
                all.addAll(list);
                requireActivity().runOnUiThread(() -> { adapter.submitList(new java.util.ArrayList<>(all)); swipe.setRefreshing(false); });
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> { swipe.setRefreshing(false); Toast.makeText(requireContext(), "Server load failed", Toast.LENGTH_LONG).show(); });
            } finally { loading = false; }
        }).start();
    }

    private void loadNext() { if (!hasMore || loading) return; page += 1; refresh(false); }

    private View getImageForPosition(RecyclerView rv, int position) {
        RecyclerView.ViewHolder vh = rv.findViewHolderForAdapterPosition(position);
        if (vh == null) return null; return vh.itemView.findViewById(R.id.image);
    }
}
