package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.Manifest;
import android.database.Cursor;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import android.util.Log;
import android.view.Menu;
import android.view.MenuInflater;
import android.view.MenuItem;
import android.widget.Toast;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.appcompat.view.ActionMode;
import androidx.lifecycle.ViewModelProvider;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;

import ca.openphotos.android.R;
import ca.openphotos.android.media.MotionPhotoSupport;
import ca.openphotos.android.ui.util.RecyclerItemClickListener;

/** Local Library grid using a minimal adapter placeholder. */
public class LocalFragment extends Fragment {
    private static final String MOTION_TAG = MotionPhotoSupport.TAG;
    private MediaGridAdapter adapter;
    private LocalGridViewModel vm;
    private final java.util.LinkedHashSet<Integer> selection = new java.util.LinkedHashSet<>();
    private ActionMode actionMode;

    private ActivityResultLauncher<String[]> permLauncher;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_local_grid, container, false);
        RecyclerView rv = root.findViewById(R.id.local_grid);
        rv.setLayoutManager(new GridLayoutManager(requireContext(), 3));
        adapter = new MediaGridAdapter();
        rv.setAdapter(adapter);
        rv.addOnItemTouchListener(new androidx.recyclerview.widget.RecyclerView.SimpleOnItemTouchListener(){});
        rv.setAdapter(adapter);

        // Click/long-click for selection
        adapter.registerAdapterDataObserver(new RecyclerView.AdapterDataObserver(){});
        rv.addOnItemTouchListener(new RecyclerItemClickListener(requireContext(), rv, new RecyclerItemClickListener.OnItemClickListener() {
            @Override public void onItemClick(View view, int position) { LocalFragment.this.onItemClick(position); }
            @Override public void onLongItemClick(View view, int position) { LocalFragment.this.onItemLongClick(position); }
        }));

        // ViewModel and data
        vm = new ViewModelProvider(this).get(LocalGridViewModel.class);
        vm.cells().observe(getViewLifecycleOwner(), list -> adapter.submitList(list));

        // Permission launcher
        permLauncher = registerForActivityResult(new ActivityResultContracts.RequestMultiplePermissions(), res -> vm.start());
        requestMediaReadIfNeeded();
        return root;
    }

    @Override public void onStart() { super.onStart(); if (hasMediaRead()) vm.start(); }
    @Override public void onStop() { super.onStop(); vm.stop(); }

    private void onItemClick(int position) {
        if (actionMode != null) { toggleSelect(position); return; }
        // Navigate to viewer
        java.util.List<MediaGridAdapter.Cell> list = adapter.getCurrentList();
        if (position >= 0 && position < list.size()) {
            androidx.navigation.NavController nav = androidx.navigation.fragment.NavHostFragment.findNavController(this);
            android.os.Bundle args = new android.os.Bundle();
            java.util.ArrayList<String> uris = new java.util.ArrayList<>();
            for (MediaGridAdapter.Cell it : list) uris.add(it.uri);
            args.putStringArrayList("uris", uris);
            args.putInt("index", position);
            args.putBoolean("isServer", false);
            android.view.View image = getRecyclerViewChildImage(position);
            if (image != null) {
                androidx.navigation.fragment.FragmentNavigator.Extras extras = new androidx.navigation.fragment.FragmentNavigator.Extras.Builder().addSharedElement(image, "hero_image").build();
                nav.navigate(ca.openphotos.android.R.id.viewerFragment, args, null, extras);
            } else {
                nav.navigate(ca.openphotos.android.R.id.viewerFragment, args);
            }
        }
    }

    private View getRecyclerViewChildImage(int position) {
        View rootView = getView(); if (rootView == null) return null;
        RecyclerView rv = rootView.findViewById(R.id.local_grid); if (rv == null) return null;
        RecyclerView.ViewHolder vh = rv.findViewHolderForAdapterPosition(position);
        if (vh == null) return null; View item = vh.itemView; return item.findViewById(R.id.image);
    }

    private void onItemLongClick(int position) {
        if (actionMode == null) actionMode = ((androidx.appcompat.app.AppCompatActivity) requireActivity()).startSupportActionMode(actionCb);
        toggleSelect(position);
    }

    private void toggleSelect(int position) {
        if (selection.contains(position)) selection.remove(position); else selection.add(position);
        if (actionMode != null) {
            int count = selection.size();
            actionMode.setTitle(count + " selected");
            if (count == 0) { actionMode.finish(); }
        }
    }

    private final ActionMode.Callback actionCb = new ActionMode.Callback() {
        @Override public boolean onCreateActionMode(ActionMode mode, Menu menu) {
            MenuInflater mi = mode.getMenuInflater(); mi.inflate(R.menu.local_selection, menu); return true; }
        @Override public boolean onPrepareActionMode(ActionMode mode, Menu menu) { return false; }
        @Override public boolean onActionItemClicked(ActionMode mode, MenuItem item) {
            int id = item.getItemId();
            if (id == R.id.action_upload) { enqueueSelected(false); mode.finish(); return true; }
            if (id == R.id.action_upload_locked) { enqueueSelected(true); mode.finish(); return true; }
            return false;
        }
        @Override public void onDestroyActionMode(ActionMode mode) { selection.clear(); actionMode = null; }
    };

    private void enqueueSelected(boolean locked) {
        java.util.List<MediaGridAdapter.Cell> list = adapter.getCurrentList();
        java.util.ArrayList<MediaGridAdapter.Cell> picked = new java.util.ArrayList<>();
        for (Integer pos : selection) if (pos >= 0 && pos < list.size()) picked.add(list.get(pos));
        new Thread(() -> {
            try {
                ca.openphotos.android.upload.UploadStopController.clearUserStopRequest();
                if (locked) {
                    ca.openphotos.android.upload.UploadOrchestrator orch = new ca.openphotos.android.upload.UploadOrchestrator(requireContext().getApplicationContext());
                    for (MediaGridAdapter.Cell c : picked) {
                        android.net.Uri uri = android.net.Uri.parse(c.uri);
                        LocalUploadMeta meta = readLocalMeta(uri, c.isVideo);
                        String cid = stableContentId(c.uri);
                        java.io.File motion = null;
                        if (!meta.isVideo) {
                            motion = MotionPhotoSupport.extractMotionIfLikely(
                                    requireContext().getApplicationContext(),
                                    uri,
                                    meta.displayName,
                                    meta.mimeType,
                                    cid,
                                    "manual"
                            );
                        }
                        orch.enqueueLocked(cid, uri, meta.isVideo, meta.creationTs, "[]", meta.mimeType);
                        if (motion != null && motion.exists() && motion.length() > 0) {
                            orch.enqueueLockedFile(cid, motion, true, meta.creationTs, "[]", "video/mp4");
                            Log.i(MOTION_TAG, "paired-enqueue mode=manual-locked contentId=" + cid
                                    + " still=" + meta.displayName + " motion=" + motion.getName());
                            try { motion.delete(); } catch (Exception ignored) {}
                        }
                    }
                } else {
                    ca.openphotos.android.upload.TusUploadManager mgr = new ca.openphotos.android.upload.TusUploadManager(requireContext().getApplicationContext());
                    for (MediaGridAdapter.Cell c : picked) {
                        android.net.Uri uri = android.net.Uri.parse(c.uri);
                        LocalUploadMeta meta = readLocalMeta(uri, c.isVideo);
                        String cid = stableContentId(c.uri);
                        java.io.File motion = null;
                        if (!meta.isVideo) {
                            motion = MotionPhotoSupport.extractMotionIfLikely(
                                    requireContext().getApplicationContext(),
                                    uri,
                                    meta.displayName,
                                    meta.mimeType,
                                    cid,
                                    "manual"
                            );
                        }
                        java.io.File tmp = copyToCache(uri);
                        ca.openphotos.android.data.db.entities.PhotoEntity p = new ca.openphotos.android.data.db.entities.PhotoEntity();
                        p.contentId = cid;
                        p.mediaType = meta.isVideo ? 1 : 0;
                        p.creationTs = meta.creationTs;
                        p.contentUri = c.uri;
                        p.pixelWidth = 0;
                        p.pixelHeight = 0;
                        p.syncState = 0;
                        mgr.uploadUnlocked(tmp, p, "[]");
                        tmp.delete();
                        if (motion != null && motion.exists() && motion.length() > 0) {
                            ca.openphotos.android.data.db.entities.PhotoEntity mv = new ca.openphotos.android.data.db.entities.PhotoEntity();
                            mv.contentId = cid;
                            mv.mediaType = 1;
                            mv.creationTs = meta.creationTs;
                            mv.contentUri = c.uri;
                            mv.pixelWidth = 0;
                            mv.pixelHeight = 0;
                            mv.syncState = 0;
                            mgr.uploadUnlocked(motion, mv, "[]");
                            Log.i(MOTION_TAG, "paired-enqueue mode=manual-unlocked contentId=" + cid
                                    + " still=" + meta.displayName + " motion=" + motion.getName());
                            try { motion.delete(); } catch (Exception ignored) {}
                        }
                    }
                }
                requireActivity().runOnUiThread(() -> Toast.makeText(requireContext(), "Queued " + picked.size(), Toast.LENGTH_SHORT).show());
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> Toast.makeText(requireContext(), "Upload error", Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private java.io.File copyToCache(android.net.Uri uri) throws Exception {
        java.io.File out = java.io.File.createTempFile("ux_", ".bin", requireContext().getCacheDir());
        try (java.io.InputStream is = requireContext().getContentResolver().openInputStream(uri); java.io.FileOutputStream fos = new java.io.FileOutputStream(out)) {
            byte[] buf = new byte[8192]; int r; while ((r = is.read(buf)) > 0) fos.write(buf, 0, r);
        }
        return out;
    }

    private LocalUploadMeta readLocalMeta(Uri uri, boolean isVideoHint) {
        LocalUploadMeta out = new LocalUploadMeta();
        out.isVideo = isVideoHint;
        out.creationTs = System.currentTimeMillis() / 1000L;
        out.mimeType = isVideoHint ? "video/*" : "image/*";
        out.displayName = uri.getLastPathSegment() != null ? uri.getLastPathSegment() : "unknown";
        String[] proj = isVideoHint
                ? new String[]{
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.MIME_TYPE,
                MediaStore.Video.Media.DATE_TAKEN,
                MediaStore.Video.Media.DATE_ADDED
        }
                : new String[]{
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.MIME_TYPE,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_ADDED
        };
        try (Cursor c = requireContext().getContentResolver().query(uri, proj, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                String n = c.getString(0);
                String m = c.getString(1);
                long taken = c.getLong(2);
                long added = c.getLong(3);
                if (n != null && !n.isEmpty()) out.displayName = n;
                if (m != null && !m.isEmpty()) out.mimeType = m;
                out.creationTs = taken > 0 ? (taken / 1000L) : Math.max(1L, added);
            }
        } catch (Exception ignored) {}
        return out;
    }

    private static String stableContentId(String localId) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("MD5");
            byte[] digest = md.digest(localId.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return ca.openphotos.android.util.Base58.encode(digest);
        } catch (Exception ignored) {
            return localId;
        }
    }

    private static final class LocalUploadMeta {
        boolean isVideo;
        long creationTs;
        String mimeType;
        String displayName;
    }

    private boolean hasMediaRead() {
        if (Build.VERSION.SDK_INT >= 33) {
            return requireContext().checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED &&
                    requireContext().checkSelfPermission(Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED;
        } else {
            return requireContext().checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED;
        }
    }

    private void requestMediaReadIfNeeded() {
        if (hasMediaRead()) { vm.start(); return; }
        if (Build.VERSION.SDK_INT >= 33) {
            permLauncher.launch(new String[]{Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO});
        } else {
            permLauncher.launch(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE});
        }
    }
}
