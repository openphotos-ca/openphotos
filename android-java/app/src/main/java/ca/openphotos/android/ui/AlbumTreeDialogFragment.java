package ca.openphotos.android.ui;

import android.app.Dialog;
import android.os.Bundle;
import android.text.InputType;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.DialogFragment;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.server.ServerPhotosService;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import com.google.android.material.switchmaterial.SwitchMaterial;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Full-screen Album tree dialog used by the Photos screen.
 *
 * Features:
 * - Single selection (returns album_id via Fragment Result API)
 * - "Include sub-albums" toggle (default OFF; not persisted)
 * - Create top-level and sub-albums; delete album with confirmation
 * - Root is not selectable
 *
 * Events (Fragment Result API):
 * - {@link #KEY_SELECT_RESULT} with extras: {@code album_id (int)}, {@code include_subtree (boolean)}
 * - {@link #KEY_ALBUMS_UPDATED} (no extras) emitted after create/delete so host can refresh chips
 */
public class AlbumTreeDialogFragment extends DialogFragment {
    public static final String KEY_SELECT_RESULT = "album.tree.select";
    public static final String KEY_ALBUMS_UPDATED = "album.tree.updated";

    private static final String ARG_INCLUDE_INITIAL = "include.initial";

    public static AlbumTreeDialogFragment newInstance(boolean initialIncludeSubtree) {
        AlbumTreeDialogFragment f = new AlbumTreeDialogFragment();
        Bundle b = new Bundle(); b.putBoolean(ARG_INCLUDE_INITIAL, initialIncludeSubtree); f.setArguments(b);
        return f;
    }

    private RecyclerView recycler;
    private SwitchMaterial swInclude;
    private View btnOk;
    private AlbumsAdapter adapter;

    private boolean includeSubtree = false; // default OFF per spec
    private Integer selectedAlbumId = null; // null until user selects a row

    // In-memory tree
    private final Map<Integer, Node> nodesById = new HashMap<>();
    private final List<Node> rootNodes = new ArrayList<>();
    private final Set<Integer> expanded = new HashSet<>();

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_album_tree_dialog, container, false);
        includeSubtree = getArguments() != null && getArguments().getBoolean(ARG_INCLUDE_INITIAL, false);

        // App bar
        root.findViewById(R.id.btn_close).setOnClickListener(v -> dismissAllowingStateLoss());

        // Include sub-albums switch (default OFF; not persisted)
        swInclude = root.findViewById(R.id.switch_include);
        swInclude.setChecked(includeSubtree);
        swInclude.setOnCheckedChangeListener((b, on) -> includeSubtree = on);

        // Root row add button
        root.findViewById(R.id.btn_add_root).setOnClickListener(v -> promptCreate(null));

        // Recycler
        recycler = root.findViewById(R.id.tree_list);
        recycler.setLayoutManager(new LinearLayoutManager(requireContext()));
        adapter = new AlbumsAdapter();
        recycler.setAdapter(adapter);

        // Bottom actions
        root.findViewById(R.id.btn_cancel).setOnClickListener(v -> dismissAllowingStateLoss());
        btnOk = root.findViewById(R.id.btn_ok);
        btnOk.setEnabled(false);
        btnOk.setOnClickListener(v -> applyAndClose());

        // Load data
        reloadTreeAsync();
        return root;
    }

    private void applyAndClose() {
        if (selectedAlbumId == null) return;
        Bundle b = new Bundle();
        b.putInt("album_id", selectedAlbumId);
        b.putBoolean("include_subtree", includeSubtree);
        getParentFragmentManager().setFragmentResult(KEY_SELECT_RESULT, b);
        dismissAllowingStateLoss();
    }

    private void reloadTreeAsync() {
        new Thread(() -> {
            try {
                List<Node> roots = fetchTree();
                requireActivity().runOnUiThread(() -> applyTree(roots));
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> applyTree(new ArrayList<>()));
            }
        }).start();
    }

    private List<Node> fetchTree() throws IOException {
        nodesById.clear(); rootNodes.clear();
        JSONArray arr = new ServerPhotosService(requireContext().getApplicationContext()).listAlbums();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject a = arr.optJSONObject(i); if (a == null) continue;
            Node n = new Node();
            n.id = a.optInt("id");
            n.name = a.optString("name", "Album " + n.id);
            n.parentId = a.has("parent_id") && !a.isNull("parent_id") ? a.optInt("parent_id") : null;
            n.isLive = a.optBoolean("is_live", false);
            nodesById.put(n.id, n);
        }
        // Build children
        for (Node n : new ArrayList<>(nodesById.values())) {
            if (n.parentId == null) { rootNodes.add(n); }
            else {
                Node p = nodesById.get(n.parentId);
                if (p != null) p.children.add(n); else rootNodes.add(n);
            }
        }
        // Sort by name for stability (server may also provide position)
        java.util.Comparator<Node> cmp = (a,b)->a.name.compareToIgnoreCase(b.name);
        for (Node n : nodesById.values()) n.children.sort(cmp);
        rootNodes.sort(cmp);
        return rootNodes;
    }

    private void applyTree(List<Node> roots) {
        // Expand root and first level by default (small trees may fully expand)
        expanded.clear();
        for (Node r : roots) {
            expanded.add(r.id);
            for (Node c : r.children) expanded.add(c.id);
        }
        adapter.submit(buildVisible());
    }

    private List<Row> buildVisible() {
        List<Row> out = new ArrayList<>();
        for (Node r : rootNodes) dfs(r, 0, out);
        return out;
    }

    private void dfs(Node n, int depth, List<Row> out) {
        out.add(new Row(n, depth));
        if (!expanded.contains(n.id)) return;
        for (Node c : n.children) dfs(c, depth + 1, out);
    }

    private void promptCreate(@Nullable Integer parentId) {
        final EditText input = new EditText(requireContext());
        input.setHint("Album name"); input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_WORDS);
        new MaterialAlertDialogBuilder(requireContext())
                .setTitle(parentId == null ? "New Album" : "New Sub‑album")
                .setView(input)
                .setPositiveButton("Create", (d,w)->{
                    String name = input.getText().toString().trim(); if (name.isEmpty()) return;
                    new Thread(() -> {
                        try { new ServerPhotosService(requireContext().getApplicationContext()).createAlbum(name, null, parentId == null ? null : Long.valueOf(parentId));
                            requireActivity().runOnUiThread(() -> {
                                // Notify host and reload
                                getParentFragmentManager().setFragmentResult(KEY_ALBUMS_UPDATED, new Bundle());
                                reloadTreeAsync();
                                android.widget.Toast.makeText(requireContext(), "Album created", android.widget.Toast.LENGTH_SHORT).show();
                            });
                        } catch (Exception e) {
                            requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Create failed", android.widget.Toast.LENGTH_LONG).show());
                        }
                    }).start();
                })
                .setNegativeButton("Cancel", null).show();
    }

    private void confirmDelete(int albumId, String name, boolean isLive) {
        new MaterialAlertDialogBuilder(requireContext())
                .setTitle("Delete " + name + "?")
                .setMessage("Delete this album? Sub‑albums are also removed. Photos are not deleted.")
                .setPositiveButton("Delete", (d,w)->{
                    new Thread(() -> {
                        try { new ServerPhotosService(requireContext().getApplicationContext()).deleteAlbum(albumId);
                            requireActivity().runOnUiThread(() -> {
                                getParentFragmentManager().setFragmentResult(KEY_ALBUMS_UPDATED, new Bundle());
                                reloadTreeAsync();
                                if (selectedAlbumId != null && selectedAlbumId == albumId) { selectedAlbumId = null; btnOk.setEnabled(false); }
                                android.widget.Toast.makeText(requireContext(), "Album deleted", android.widget.Toast.LENGTH_SHORT).show();
                            });
                        } catch (Exception e) {
                            requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Delete failed", android.widget.Toast.LENGTH_LONG).show());
                        }
                    }).start();
                })
                .setNegativeButton("Cancel", null).show();
    }

    // --- Data structures ---
    private static class Node {
        int id; String name; @Nullable Integer parentId; boolean isLive;
        final List<Node> children = new ArrayList<>();
    }
    private static class Row { final Node node; final int depth; Row(Node n, int d){ node=n; depth=d; }}

    // --- Recycler adapter ---
    private class AlbumsAdapter extends RecyclerView.Adapter<AlbumsAdapter.VH> {
        private final List<Row> rows = new ArrayList<>();
        void submit(List<Row> list) { rows.clear(); rows.addAll(list); notifyDataSetChanged(); }

        @NonNull @Override public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_album_tree_row, parent, false);
            return new VH(v);
        }
        @Override public void onBindViewHolder(@NonNull VH h, int position) {
            Row r = rows.get(position);
            Node n = r.node;
            h.title.setText(n.name);
            h.icon.setImageResource(n.isLive ? android.R.drawable.btn_star_big_on : android.R.drawable.ic_menu_agenda);
            // indent via paddingLeft based on depth
            int base = h.itemView.getResources().getDimensionPixelSize(R.dimen.album_tree_indent_base);
            int pad = base * Math.max(0, r.depth);
            h.itemRoot.setPadding(pad, h.itemRoot.getPaddingTop(), h.itemRoot.getPaddingRight(), h.itemRoot.getPaddingBottom());

            // expand/collapse chevron visibility based on children
            h.btnToggle.setVisibility(n.children.isEmpty() ? View.INVISIBLE : View.VISIBLE);
            boolean isExpanded = expanded.contains(n.id);
            h.btnToggle.setImageResource(isExpanded ? android.R.drawable.arrow_down_float : android.R.drawable.ic_media_play);
            h.btnToggle.setOnClickListener(v -> {
                if (isExpanded) expanded.remove(n.id); else expanded.add(n.id);
                submit(buildVisible());
            });

            // selection
            boolean selected = (selectedAlbumId != null && selectedAlbumId == n.id);
            h.itemRoot.setBackgroundColor(selected
                    ? ContextCompat.getColor(requireContext(), R.color.app_selection_bg)
                    : android.graphics.Color.TRANSPARENT);
            h.itemRoot.setOnClickListener(v -> {
                selectedAlbumId = n.id;
                btnOk.setEnabled(true);
                notifyDataSetChanged();
            });

            // trailing actions visible when selected
            h.btnAdd.setVisibility(selected && !n.isLive ? View.VISIBLE : (selected && n.isLive ? View.INVISIBLE : View.GONE));
            h.btnDelete.setVisibility(selected ? View.VISIBLE : View.GONE);
            h.btnAdd.setOnClickListener(v -> promptCreate(n.id));
            h.btnDelete.setOnClickListener(v -> confirmDelete(n.id, n.name, n.isLive));
        }
        @Override public int getItemCount() { return rows.size(); }

        class VH extends RecyclerView.ViewHolder {
            final LinearLayout itemRoot; final ImageView icon; final TextView title; final ImageButton btnToggle; final ImageButton btnAdd; final ImageButton btnDelete;
            VH(@NonNull View itemView) {
                super(itemView);
                itemRoot = itemView.findViewById(R.id.row_root);
                icon = itemView.findViewById(R.id.icon);
                title = itemView.findViewById(R.id.title);
                btnToggle = itemView.findViewById(R.id.btn_toggle);
                btnAdd = itemView.findViewById(R.id.btn_add);
                btnDelete = itemView.findViewById(R.id.btn_delete);
            }
        }
    }
}
