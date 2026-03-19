package ca.openphotos.android.ui;

import android.content.Context;
import android.os.Bundle;
import android.util.Log;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageButton;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.navigation.fragment.NavHostFragment;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.e2ee.E2EEManager;
import ca.openphotos.android.prefs.SyncFoldersPreferences;
import ca.openphotos.android.prefs.SyncPreferences;
import ca.openphotos.android.ui.local.LocalMediaItem;
import ca.openphotos.android.ui.local.LocalMediaRepository;
import com.google.android.material.switchmaterial.SwitchMaterial;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** Full-screen Selected Albums manager for Sync tab. */
public class SyncAlbumsFragment extends Fragment {
    private static final String TAG = "OpenPhotos";
    private SyncPreferences prefs;
    private SyncFoldersPreferences folderPrefs;
    private Context appContext;

    private SwitchMaterial swUnassigned;
    private ImageButton btnUnassignedLock;
    private RecyclerView list;

    private final Set<String> syncFolders = new LinkedHashSet<>();
    private final Set<String> lockedFolders = new LinkedHashSet<>();
    private final Set<String> expandedPaths = new HashSet<>();

    private final List<Row> visibleRows = new ArrayList<>();
    private final java.util.Map<String, Node> nodesByPath = new java.util.HashMap<>();
    private final List<Node> roots = new ArrayList<>();

    private final RowsAdapter adapter = new RowsAdapter();

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_sync_albums, container, false);
        appContext = requireContext().getApplicationContext();
        prefs = new SyncPreferences(appContext);
        folderPrefs = new SyncFoldersPreferences(appContext);

        swUnassigned = root.findViewById(R.id.sw_sync_unassigned);
        btnUnassignedLock = root.findViewById(R.id.btn_sync_unassigned_lock);
        list = root.findViewById(R.id.list_sync_albums);

        root.findViewById(R.id.btn_sync_albums_back).setOnClickListener(v ->
                NavHostFragment.findNavController(this).navigateUp());

        list.setLayoutManager(new LinearLayoutManager(requireContext()));
        list.setAdapter(adapter);

        loadPrefs();
        bindUnassigned();
        reloadTreeAsync();

        return root;
    }

    private void loadPrefs() {
        syncFolders.clear();
        lockedFolders.clear();
        syncFolders.addAll(normalizeSet(folderPrefs.getSyncFolders()));
        lockedFolders.addAll(normalizeSet(folderPrefs.getLockedFolders()));

        swUnassigned.setChecked(prefs.syncIncludeUnassigned());
        updateUnassignedLockVisual();
    }

    private void bindUnassigned() {
        swUnassigned.setOnCheckedChangeListener((b, on) -> prefs.setSyncIncludeUnassigned(on));
        btnUnassignedLock.setOnClickListener(v -> {
            boolean currentlyLocked = prefs.syncUnassignedLocked();
            if (currentlyLocked) {
                prefs.setSyncUnassignedLocked(false);
                updateUnassignedLockVisual();
                return;
            }
            ensureUnlockedThen(() -> {
                prefs.setSyncUnassignedLocked(true);
                updateUnassignedLockVisual();
            });
        });
    }

    private void updateUnassignedLockVisual() {
        boolean locked = prefs.syncUnassignedLocked();
        btnUnassignedLock.setImageResource(android.R.drawable.ic_lock_lock);
        btnUnassignedLock.setColorFilter(ContextCompat.getColor(requireContext(),
                locked ? R.color.app_lock_active : R.color.app_lock_inactive));
    }

    private void reloadTreeAsync() {
        new Thread(() -> {
            Set<String> paths = queryLocalPhotosTabFolders();
            String source = "local-photos-tab";
            if (paths.isEmpty()) {
                // Keep prior selections visible when local index is temporarily empty.
                paths = new LinkedHashSet<>(syncFolders);
                paths.addAll(lockedFolders);
                source = "local-empty-fallback-selected";
            }

            try {
                Log.i(TAG, "[SYNC-ALBUMS] source=" + source + " count=" + paths.size());
            } catch (Exception ignored) {}
            buildTree(paths);
            rebuildRows();
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> adapter.notifyDataSetChanged());
        }).start();
    }

    private Set<String> queryLocalPhotosTabFolders() {
        Set<String> out = new HashSet<>();
        try {
            List<LocalMediaItem> items = new LocalMediaRepository(appContext).loadAll();
            for (LocalMediaItem item : items) {
                String p = item.folderPathNormalized();
                String norm = normalizePath(p);
                if (!norm.isEmpty()) out.add(norm);
            }
            try {
                Log.i(TAG, "[SYNC-ALBUMS] local folders=" + out.size());
                ArrayList<String> sample = new ArrayList<>(out);
                Collections.sort(sample);
                if (sample.size() > 12) sample = new ArrayList<>(sample.subList(0, 12));
                Log.i(TAG, "[SYNC-ALBUMS] local sample=" + sample);
            } catch (Exception ignored) {}
        } catch (Exception ignored) {
            try {
                Log.w(TAG, "[SYNC-ALBUMS] local folder load failed", ignored);
            } catch (Exception ignored2) {}
        }
        return out;
    }

    private void buildTree(Set<String> paths) {
        nodesByPath.clear();
        roots.clear();
        List<String> sorted = new ArrayList<>(paths);
        Collections.sort(sorted, String::compareToIgnoreCase);

        for (String path : sorted) {
            String key = normalizePath(path);
            if (key.isEmpty()) continue;
            if (nodesByPath.containsKey(key)) continue;
            Node node = new Node(key, key);
            nodesByPath.put(key, node);
            roots.add(node);
        }

        for (Node r : roots) {
            if (!expandedPaths.contains(r.path)) expandedPaths.add(r.path);
            sortRecursively(r);
        }
    }

    private void sortRecursively(@NonNull Node n) {
        n.children.sort((a, b) -> a.label.compareToIgnoreCase(b.label));
        for (Node c : n.children) sortRecursively(c);
    }

    private void rebuildRows() {
        visibleRows.clear();
        for (Node root : roots) {
            dfs(root, 0);
        }
    }

    private void dfs(@NonNull Node n, int depth) {
        visibleRows.add(new Row(n, depth));
        if (!expandedPaths.contains(n.path)) return;
        for (Node c : n.children) dfs(c, depth + 1);
    }

    private void toggleExpanded(@NonNull Node node) {
        if (expandedPaths.contains(node.path)) expandedPaths.remove(node.path);
        else expandedPaths.add(node.path);
        rebuildRows();
        adapter.notifyDataSetChanged();
    }

    private void setSyncEnabled(@NonNull String path, boolean enabled) {
        if (enabled) syncFolders.add(path); else syncFolders.remove(path);
        folderPrefs.setSyncFolders(syncFolders);
    }

    private void setLockedEnabled(@NonNull String path, boolean locked) {
        if (locked) {
            ensureUnlockedThen(() -> {
                lockedFolders.add(path);
                folderPrefs.setLockedFolders(lockedFolders);
                adapter.notifyDataSetChanged();
            });
            return;
        }
        lockedFolders.remove(path);
        folderPrefs.setLockedFolders(lockedFolders);
    }

    private void applySubtree(@NonNull Node node, boolean syncEnabled, @Nullable Boolean lockEnabled) {
        List<String> all = new ArrayList<>();
        collectPaths(node, all);
        for (String path : all) {
            if (syncEnabled) syncFolders.add(path); else syncFolders.remove(path);
            if (lockEnabled != null) {
                if (lockEnabled) lockedFolders.add(path);
                else lockedFolders.remove(path);
            }
        }
        folderPrefs.setSyncFolders(syncFolders);
        folderPrefs.setLockedFolders(lockedFolders);
        adapter.notifyDataSetChanged();
    }

    private void collectPaths(@NonNull Node node, @NonNull List<String> out) {
        out.add(node.path);
        for (Node c : node.children) collectPaths(c, out);
    }

    private void ensureUnlockedThen(@NonNull Runnable onSuccess) {
        E2EEManager e2 = new E2EEManager(requireContext().getApplicationContext());
        if (e2.getUmk() != null) {
            onSuccess.run();
            return;
        }

        new EnterPinDialog().setListener(pin -> new Thread(() -> {
            boolean ok = e2.unlockWithPin(pin);
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> {
                if (ok) onSuccess.run();
                else Toast.makeText(requireContext(), "Unlock failed", Toast.LENGTH_SHORT).show();
            });
        }).start()).show(getParentFragmentManager(), "sync_albums_pin");
    }

    private static Set<String> normalizeSet(Set<String> src) {
        Set<String> out = new LinkedHashSet<>();
        if (src == null) return out;
        for (String s : src) {
            String n = normalizePath(s);
            if (!n.isEmpty()) out.add(n);
        }
        return out;
    }

    private static String normalizePath(String path) {
        if (path == null) return "";
        String p = path;
        while (p.endsWith("/")) p = p.substring(0, p.length() - 1);
        return p;
    }

    private static final class Node {
        final String path;
        final String label;
        final List<Node> children = new ArrayList<>();

        Node(String path, String label) {
            this.path = path;
            this.label = label;
        }
    }

    private static final class Row {
        final Node node;
        final int depth;

        Row(Node node, int depth) {
            this.node = node;
            this.depth = depth;
        }
    }

    private final class RowsAdapter extends RecyclerView.Adapter<RowsAdapter.VH> {
        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_sync_album_row, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            Row row = visibleRows.get(position);
            Node node = row.node;

            int indentPx = Math.round(row.depth * 18f * h.itemView.getResources().getDisplayMetrics().density);
            h.root.setPadding(indentPx, h.root.getPaddingTop(), h.root.getPaddingRight(), h.root.getPaddingBottom());

            h.title.setText(node.label);

            boolean hasChildren = !node.children.isEmpty();
            h.expand.setVisibility(hasChildren ? View.VISIBLE : View.INVISIBLE);
            h.expand.setImageResource(expandedPaths.contains(node.path)
                    ? android.R.drawable.arrow_down_float
                    : android.R.drawable.arrow_up_float);
            h.expand.setOnClickListener(v -> toggleExpanded(node));

            h.sync.setOnCheckedChangeListener(null);
            h.sync.setChecked(syncFolders.contains(node.path));
            h.sync.setOnCheckedChangeListener((b, on) -> setSyncEnabled(node.path, on));

            boolean locked = lockedFolders.contains(node.path);
            h.lock.setImageResource(android.R.drawable.ic_lock_lock);
            h.lock.setColorFilter(ContextCompat.getColor(requireContext(),
                    locked ? R.color.app_lock_active : R.color.app_lock_inactive));
            h.lock.setOnClickListener(v -> setLockedEnabled(node.path, !locked));

            h.more.setOnClickListener(v -> {
                androidx.appcompat.widget.PopupMenu pm = new androidx.appcompat.widget.PopupMenu(requireContext(), h.more);
                pm.getMenu().add(0, 1, 1, "Enable subtree sync");
                pm.getMenu().add(0, 2, 2, "Disable subtree sync");
                pm.getMenu().add(0, 3, 3, "Lock subtree");
                pm.getMenu().add(0, 4, 4, "Unlock subtree");
                pm.setOnMenuItemClickListener(item -> {
                    int id = item.getItemId();
                    if (id == 1) {
                        applySubtree(node, true, null);
                        return true;
                    }
                    if (id == 2) {
                        applySubtree(node, false, null);
                        return true;
                    }
                    if (id == 3) {
                        ensureUnlockedThen(() -> applySubtree(node, true, true));
                        return true;
                    }
                    if (id == 4) {
                        applySubtree(node, true, false);
                        return true;
                    }
                    return false;
                });
                pm.show();
            });
        }

        @Override
        public int getItemCount() {
            return visibleRows.size();
        }

        final class VH extends RecyclerView.ViewHolder {
            final View root;
            final ImageButton expand;
            final TextView title;
            final ImageButton lock;
            final SwitchMaterial sync;
            final ImageButton more;

            VH(@NonNull View itemView) {
                super(itemView);
                root = itemView.findViewById(R.id.row_root);
                expand = itemView.findViewById(R.id.btn_row_expand);
                title = itemView.findViewById(R.id.tv_row_name);
                lock = itemView.findViewById(R.id.btn_row_lock);
                sync = itemView.findViewById(R.id.sw_row_sync);
                more = itemView.findViewById(R.id.btn_row_more);
            }
        }
    }
}
