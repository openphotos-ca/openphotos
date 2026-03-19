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

/** Album detail grid using /api/photos?album_id=. */
public class AlbumDetailFragment extends Fragment {
    private MediaGridAdapter adapter;
    private int albumId;

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
                    androidx.navigation.NavController nav = androidx.navigation.fragment.NavHostFragment.findNavController(AlbumDetailFragment.this);
                    android.os.Bundle args = new android.os.Bundle();
                    java.util.ArrayList<String> uris = new java.util.ArrayList<>();
                    java.util.ArrayList<String> assetIds = new java.util.ArrayList<>();
                    for (MediaGridAdapter.Cell it : adapter.getCurrentList()) { uris.add(it.uri); assetIds.add(it.assetId); }
                    args.putStringArrayList("uris", uris);
                    args.putStringArrayList("assetIds", assetIds);
                    args.putInt("index", position);
                    args.putBoolean("isServer", true);
                    android.view.View image = getImageForPosition(rv, position);
                    if (image != null) {
                        androidx.navigation.fragment.FragmentNavigator.Extras extras = new androidx.navigation.fragment.FragmentNavigator.Extras.Builder().addSharedElement(image, "hero_image").build();
                        nav.navigate(R.id.viewerFragment, args, null, extras);
                    } else {
                        nav.navigate(R.id.viewerFragment, args);
                    }
                }
            }
            @Override public void onLongItemClick(View view, int position) { }
        }));

        albumId = getArguments() != null ? getArguments().getInt("album_id", 0) : 0;
        refresh();
        return root;
    }

    private void refresh() {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONObject resp = svc.listPhotos(albumId, null, null, 1, 120);
                JSONArray photos = resp.has("photos") ? resp.getJSONArray("photos") : new JSONArray();
                ArrayList<MediaGridAdapter.Cell> list = new ArrayList<>();
                for (int i = 0; i < photos.length(); i++) {
                    org.json.JSONObject p = photos.getJSONObject(i);
                    String assetId = p.optString("asset_id");
                    boolean isVideo = p.optBoolean("is_video", false);
                    boolean locked = p.optBoolean("locked", false);
                    int rating = p.optInt("rating", 0);
                    String thumb = svc.thumbnailUrl(assetId);
                    list.add(new MediaGridAdapter.Cell("album-"+assetId, p.optString("filename", assetId), locked, thumb, isVideo, assetId, rating));
                }
                requireActivity().runOnUiThread(() -> adapter.submitList(list));
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> Toast.makeText(requireContext(), "Album load failed", Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private View getImageForPosition(RecyclerView rv, int position) {
        RecyclerView.ViewHolder vh = rv.findViewHolderForAdapterPosition(position);
        if (vh == null) return null; return vh.itemView.findViewById(R.id.image);
    }
}
