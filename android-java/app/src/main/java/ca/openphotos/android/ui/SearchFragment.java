package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;
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

/** Simple search UI: query field, search button, and results grid. */
public class SearchFragment extends Fragment {
    private MediaGridAdapter adapter;
    private EditText input;
    private TextView banner;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        android.widget.LinearLayout root = new android.widget.LinearLayout(requireContext());
        root.setOrientation(android.widget.LinearLayout.VERTICAL);
        int pad = 16; root.setPadding(pad,pad,pad,pad);

        input = new EditText(requireContext()); input.setHint("Search query");
        banner = new TextView(requireContext()); banner.setText("Server text results"); banner.setPadding(12,12,12,12); banner.setBackgroundColor(0xFFEEE8AA); banner.setVisibility(View.GONE);
        Button go = new Button(requireContext()); go.setText("Search");
        RecyclerView rv = new RecyclerView(requireContext()); rv.setLayoutManager(new GridLayoutManager(requireContext(), 3));
        adapter = new MediaGridAdapter(); rv.setAdapter(adapter);
        rv.addOnItemTouchListener(new ca.openphotos.android.ui.util.RecyclerItemClickListener(requireContext(), rv, new ca.openphotos.android.ui.util.RecyclerItemClickListener.OnItemClickListener() {
            @Override public void onItemClick(View view, int position) {
                java.util.List<MediaGridAdapter.Cell> list = adapter.getCurrentList();
                if (position >= 0 && position < list.size()) {
                    androidx.navigation.NavController nav = androidx.navigation.fragment.NavHostFragment.findNavController(SearchFragment.this);
                    android.os.Bundle args = new android.os.Bundle();
                    java.util.ArrayList<String> uris = new java.util.ArrayList<>();
                    java.util.ArrayList<String> assetIds = new java.util.ArrayList<>();
                    for (MediaGridAdapter.Cell it : list) { uris.add(it.uri); assetIds.add(it.assetId); }
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
            @Override public void onLongItemClick(View view, int position) { }
        }));

        go.setOnClickListener(v -> doSearch());

        root.addView(input, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(banner, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(go, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(rv, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0));
        ((android.widget.LinearLayout.LayoutParams)rv.getLayoutParams()).weight = 1f;
        return root;
    }

    private void doSearch() {
        final String q = input.getText().toString();
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONObject res = svc.search(q, null, null, null, null, 1, 60);
                final boolean isText = "text".equalsIgnoreCase(res.optString("mode", ""));
                JSONArray ids = res.optJSONArray("ids");
                java.util.ArrayList<String> idList = new java.util.ArrayList<>();
                if (ids != null) for (int i = 0; i < ids.length(); i++) idList.add(ids.getString(i));
                JSONArray photos = idList.isEmpty() ? new JSONArray() : svc.getPhotosByAssetIds(idList, true);
                ArrayList<MediaGridAdapter.Cell> list = new ArrayList<>();
                for (int i = 0; i < photos.length(); i++) {
                    org.json.JSONObject p = photos.getJSONObject(i);
                    String assetId = p.optString("asset_id");
                    boolean isVideo = p.optBoolean("is_video", false);
                    boolean locked = p.optBoolean("locked", false);
                    int rating = p.optInt("rating", 0);
                    String thumb = svc.thumbnailUrl(assetId);
                    list.add(new MediaGridAdapter.Cell("search-"+assetId, p.optString("filename", assetId), locked, thumb, isVideo, assetId, rating));
                }
                requireActivity().runOnUiThread(() -> { banner.setVisibility(isText ? View.VISIBLE : View.GONE); adapter.submitList(list); });
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> Toast.makeText(requireContext(), "Search failed", Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private View getImageForPosition(RecyclerView rv, int position) {
        RecyclerView.ViewHolder vh = rv.findViewHolderForAdapterPosition(position);
        if (vh == null) return null; return vh.itemView.findViewById(R.id.image);
    }
}
