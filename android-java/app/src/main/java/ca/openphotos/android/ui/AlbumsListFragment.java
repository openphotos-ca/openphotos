package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import androidx.recyclerview.widget.DividerItemDecoration;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.server.ServerPhotosService;

import org.json.JSONArray;

/** Albums list using a simple RecyclerView. */
public class AlbumsListFragment extends Fragment {
    private RecyclerView rv;
    private AlbumsAdapter adapter;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_albums_list, container, false);
        rv = root.findViewById(R.id.albums_list);
        rv.setLayoutManager(new LinearLayoutManager(requireContext()));
        rv.addItemDecoration(new DividerItemDecoration(requireContext(), DividerItemDecoration.VERTICAL));
        adapter = new AlbumsAdapter();
        rv.setAdapter(adapter);
        rv.addOnItemTouchListener(new ca.openphotos.android.ui.util.RecyclerItemClickListener(requireContext(), rv, new ca.openphotos.android.ui.util.RecyclerItemClickListener.OnItemClickListener() {
            @Override public void onItemClick(View view, int position) {
                AlbumCell c = adapter.getItem(position);
                if (c == null) return;
                android.os.Bundle args = new android.os.Bundle(); args.putInt("album_id", c.id);
                androidx.navigation.fragment.NavHostFragment.findNavController(AlbumsListFragment.this).navigate(R.id.albumDetailFragment, args);
            }
            @Override public void onLongItemClick(View view, int position) {
                AlbumCell c = adapter.getItem(position); if (c==null) return;
                String[] items = new String[]{"Rename","Delete","Freeze"};
                new android.app.AlertDialog.Builder(requireContext())
                        .setTitle(c.name)
                        .setItems(items, (d,w)->{
                            switch (w) {
                                case 0: promptRename(c); break;
                                case 1: confirmDelete(c); break;
                                case 2: promptFreeze(c); break;
                            }
                        }).show();
            }
        }));
        // FAB: New album / Live album
        View fab = root.findViewById(R.id.fab_new_album);
        fab.setOnClickListener(v -> {
            String[] options = new String[]{"New Album","New Live Album"};
            new android.app.AlertDialog.Builder(requireContext())
                    .setTitle("Create")
                    .setItems(options, (d,which)->{
                        if (which==0) promptCreateAlbum(); else promptCreateLiveAlbum();
                    }).show();
        });
        refresh();
        return root;
    }

    private void refresh() {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                JSONArray arr = svc.listAlbums();
                java.util.ArrayList<AlbumCell> list = new java.util.ArrayList<>();
                for (int i = 0; i < arr.length(); i++) {
                    org.json.JSONObject a = arr.getJSONObject(i);
                    list.add(new AlbumCell(a.optInt("id"), a.optString("name"), a.optInt("photo_count", 0)));
                }
                requireActivity().runOnUiThread(() -> adapter.submit(list));
            } catch (Exception ignored) {}
        }).start();
    }

    private void promptCreateAlbum() {
        final android.widget.EditText input = new android.widget.EditText(requireContext()); input.setHint("Album name");
        new android.app.AlertDialog.Builder(requireContext())
                .setTitle("New Album")
                .setView(input)
                .setPositiveButton("Create", (d,w)->{
                    String name = input.getText().toString().trim(); if (name.isEmpty()) return;
                    new Thread(() -> { try { new ServerPhotosService(requireContext().getApplicationContext()).createAlbum(name, null, null); requireActivity().runOnUiThread(this::refresh);} catch(Exception ignored){} }).start();
                }).setNegativeButton("Cancel", null).show();
    }

    private void promptCreateLiveAlbum() {
        android.widget.LinearLayout root = new android.widget.LinearLayout(requireContext()); root.setOrientation(android.widget.LinearLayout.VERTICAL); int pad=24; root.setPadding(pad,pad,pad,pad);
        android.widget.EditText name = new android.widget.EditText(requireContext()); name.setHint("Name");
        android.widget.EditText q = new android.widget.EditText(requireContext()); q.setHint("Query (q)");
        android.widget.CheckBox photos = new android.widget.CheckBox(requireContext()); photos.setText("Photos only");
        android.widget.CheckBox videos = new android.widget.CheckBox(requireContext()); videos.setText("Videos only");
        android.widget.CheckBox locked = new android.widget.CheckBox(requireContext()); locked.setText("Locked only");
        root.addView(name); root.addView(q); root.addView(photos); root.addView(videos); root.addView(locked);
        new android.app.AlertDialog.Builder(requireContext())
                .setTitle("New Live Album")
                .setView(root)
                .setPositiveButton("Create", (d,w)->{
                    new Thread(() -> {
                        try {
                            org.json.JSONObject criteria = new org.json.JSONObject();
                            try {
                                if (!q.getText().toString().isEmpty()) criteria.put("q", q.getText().toString());
                                if (photos.isChecked()) criteria.put("filter_is_video", false);
                                if (videos.isChecked()) criteria.put("filter_is_video", true);
                                if (locked.isChecked()) criteria.put("filter_locked_only", true);
                            } catch (Exception ignored) {}
                            new ServerPhotosService(requireContext().getApplicationContext()).createLiveAlbum(name.getText().toString().trim(), null, null, criteria);
                            requireActivity().runOnUiThread(this::refresh);
                        } catch (Exception ignored) {}
                    }).start();
                }).setNegativeButton("Cancel", null).show();
    }

    private void promptRename(AlbumCell c) {
        final android.widget.EditText input = new android.widget.EditText(requireContext()); input.setText(c.name);
        new android.app.AlertDialog.Builder(requireContext())
                .setTitle("Rename Album")
                .setView(input)
                .setPositiveButton("Save", (d,w)-> new Thread(() -> { try { new ServerPhotosService(requireContext().getApplicationContext()).updateAlbum(c.id, input.getText().toString().trim(), null, null, null); requireActivity().runOnUiThread(this::refresh);} catch(Exception ignored){} }).start())
                .setNegativeButton("Cancel", null).show();
    }

    private void confirmDelete(AlbumCell c) {
        new android.app.AlertDialog.Builder(requireContext())
                .setTitle("Delete Album")
                .setMessage("Are you sure?")
                .setPositiveButton("Delete", (d,w)-> new Thread(() -> { try { new ServerPhotosService(requireContext().getApplicationContext()).deleteAlbum(c.id); requireActivity().runOnUiThread(this::refresh);} catch(Exception ignored){} }).start())
                .setNegativeButton("Cancel", null).show();
    }

    private void promptFreeze(AlbumCell c) {
        final android.widget.EditText input = new android.widget.EditText(requireContext()); input.setHint("Frozen name (optional)");
        new android.app.AlertDialog.Builder(requireContext())
                .setTitle("Freeze Live Album")
                .setView(input)
                .setPositiveButton("Freeze", (d,w)-> new Thread(() -> { try { new ServerPhotosService(requireContext().getApplicationContext()).freezeAlbum(c.id, input.getText().toString().trim()); requireActivity().runOnUiThread(this::refresh);} catch(Exception ignored){} }).start())
                .setNegativeButton("Cancel", null).show();
    }

    static class AlbumCell { int id; String name; int count; AlbumCell(int id, String name, int count) { this.id = id; this.name = name; this.count = count; } }

    static class VH extends RecyclerView.ViewHolder {
        TextView title; TextView subtitle;
        VH(@NonNull View v) { super(v); title = v.findViewById(android.R.id.text1); subtitle = v.findViewById(android.R.id.text2); }
        void bind(AlbumCell c) { title.setText(c.name); subtitle.setText(c.count + " items"); }
    }

    static class AlbumsAdapter extends RecyclerView.Adapter<VH> {
        private java.util.List<AlbumCell> items = new java.util.ArrayList<>();
        void submit(java.util.List<AlbumCell> list) { items = list; notifyDataSetChanged(); }
        AlbumCell getItem(int pos) { return (pos>=0 && pos<items.size()) ? items.get(pos) : null; }
        @NonNull @Override public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            android.view.View v = android.view.LayoutInflater.from(parent.getContext()).inflate(android.R.layout.simple_list_item_2, parent, false);
            return new VH(v);
        }
        @Override public void onBindViewHolder(@NonNull VH holder, int position) { holder.bind(items.get(position)); }
        @Override public int getItemCount() { return items.size(); }
    }
}
