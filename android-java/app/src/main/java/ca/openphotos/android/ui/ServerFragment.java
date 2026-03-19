package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;

import ca.openphotos.android.server.ServerPhotosService;

/** Minimal Server UI placeholder: refresh to fetch album count. */
public class ServerFragment extends Fragment {
    private TextView status;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);
        status = new TextView(requireContext());
        status.setText("Server: tap a button");
        Button albums = new Button(requireContext());
        albums.setText("Refresh Albums");
        albums.setOnClickListener(v -> fetchAlbums());
        Button faces = new Button(requireContext());
        faces.setText("Fetch Faces Count");
        faces.setOnClickListener(v -> fetchFaces());
        Button media = new Button(requireContext());
        media.setText("Fetch Media Count");
        media.setOnClickListener(v -> fetchMedia());
        android.widget.EditText q = new android.widget.EditText(requireContext()); q.setHint("Search query");
        Button search = new Button(requireContext()); search.setText("Search"); search.setOnClickListener(v -> doSearch(q.getText().toString()));
        root.addView(status);
        root.addView(albums);
        root.addView(faces);
        root.addView(media);
        root.addView(q);
        root.addView(search);
        int pad = 24; root.setPadding(pad,pad,pad,pad);
        return root;
    }

    private void fetchAlbums() {
        status.setText("Loading…");
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONArray arr = svc.listAlbums();
                int n = arr.length();
                requireActivity().runOnUiThread(() -> status.setText("Albums: " + n));
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> status.setText("Error"));
            }
        }).start();
    }

    private void fetchFaces() {
        status.setText("Loading faces…");
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONArray arr = svc.getFaces();
                int n = arr.length();
                requireActivity().runOnUiThread(() -> status.setText("Faces: " + n));
            } catch (Exception e) { requireActivity().runOnUiThread(() -> status.setText("Error")); }
        }).start();
    }

    private void doSearch(String query) {
        status.setText("Searching…");
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONObject res = svc.search(query, null, null, null, null, 1, 50);
                int hits = res.has("ids") ? res.getJSONArray("ids").length() : 0;
                int total = res.optInt("total", hits);
                requireActivity().runOnUiThread(() -> status.setText("Search hits: " + hits + "/" + total));
            } catch (Exception e) { requireActivity().runOnUiThread(() -> status.setText("Error")); }
        }).start();
    }

    private void fetchMedia() {
        status.setText("Loading media…");
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONArray arr = svc.listMedia();
                int n = arr.length();
                requireActivity().runOnUiThread(() -> status.setText("Media: " + n));
            } catch (Exception e) { requireActivity().runOnUiThread(() -> status.setText("Error")); }
        }).start();
    }
}
