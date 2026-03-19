package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.media.DiskImageCache;

/** Faces grid (avatar + name). */
public class FacesGridFragment extends Fragment {
    private FacesAdapter adapter;

    private static android.graphics.drawable.ColorDrawable placeholder(@NonNull android.content.Context context) {
        return new android.graphics.drawable.ColorDrawable(
                androidx.core.content.ContextCompat.getColor(context, R.color.app_placeholder_alt));
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_faces_grid, container, false);
        RecyclerView rv = root.findViewById(R.id.faces_grid);
        rv.setLayoutManager(new GridLayoutManager(requireContext(), 4));
        adapter = new FacesAdapter();
        rv.setAdapter(adapter);
        refresh();
        return root;
    }

    private void refresh() {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONArray arr = svc.getFaces();
                java.util.ArrayList<FaceCell> list = new java.util.ArrayList<>();
                for (int i=0;i<arr.length();i++) {
                    org.json.JSONObject f = arr.getJSONObject(i);
                    String personId = f.optString("person_id", f.optString("id", ""));
                    String name = f.optString("name", "Unknown");
                    String url = svc.faceThumbnailUrl(personId);
                    list.add(new FaceCell(personId, name, url));
                }
                requireActivity().runOnUiThread(() -> adapter.submit(list));
            } catch (Exception ignored) {}
        }).start();
    }

    static class FaceCell { String id; String name; String url; FaceCell(String id, String name, String url) { this.id=id; this.name=name; this.url=url; } }
    static class VH extends RecyclerView.ViewHolder {
        ImageView img; TextView name;
        VH(@NonNull View v) { super(v); img = new ImageView(v.getContext()); name = new TextView(v.getContext());
            android.widget.LinearLayout root = new android.widget.LinearLayout(v.getContext()); root.setOrientation(android.widget.LinearLayout.VERTICAL); int pad=8; root.setPadding(pad,pad,pad,pad);
            img.setLayoutParams(new android.widget.LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 160));
            name.setTextSize(12f); name.setMaxLines(1); name.setEllipsize(android.text.TextUtils.TruncateAt.END);
            root.addView(img); root.addView(name); ((ViewGroup)v).addView(root); }
        void bind(FaceCell f) { name.setText(f.name); try {
            // Cache-first: faces bucket by personId
            java.io.File local = DiskImageCache.get(img.getContext()).readFile(DiskImageCache.Bucket.FACES, f.id);
            if (local != null && local.exists()) {
                com.bumptech.glide.Glide.with(img.getContext())
                        .load(android.net.Uri.fromFile(local))
                        .circleCrop()
                        .error(placeholder(img.getContext()))
                        .into(img);
                return;
            }
            // Fetch, write to cache, then load from file via Glide (for circle crop)
            String u = f.url != null ? f.url : "";
            if (u.startsWith("http://") || u.startsWith("https://")) {
                new Thread(() -> {
                    try {
                        okhttp3.OkHttpClient client = ca.openphotos.android.core.AuthorizedHttpClient.get(img.getContext()).raw();
                        okhttp3.Request req = new okhttp3.Request.Builder().url(u).get().build();
                        try (okhttp3.Response r = client.newCall(req).execute()) {
                            if (!r.isSuccessful() || r.body()==null) throw new java.io.IOException("HTTP " + r.code());
                            java.io.InputStream is = r.body().byteStream();
                            java.io.File out = DiskImageCache.get(img.getContext()).write(DiskImageCache.Bucket.FACES, f.id, is, r.body().contentLength(), "jpg");
                            if (out != null) {
                                android.os.Handler h = new android.os.Handler(img.getContext().getMainLooper());
                                h.post(() -> com.bumptech.glide.Glide.with(img.getContext())
                                        .load(android.net.Uri.fromFile(out))
                                        .circleCrop()
                                        .error(placeholder(img.getContext()))
                                        .into(img));
                            }
                        }
                    } catch (Exception ignored) {}
                }).start();
            } else {
                com.bumptech.glide.Glide.with(img.getContext())
                        .load(android.net.Uri.parse(u))
                        .circleCrop()
                        .error(placeholder(img.getContext()))
                        .into(img);
            }
        } catch (Exception ignored) {} }
    }
    static class FacesAdapter extends RecyclerView.Adapter<VH> {
        java.util.List<FaceCell> items = new java.util.ArrayList<>();
        void submit(java.util.List<FaceCell> l){ items = l; notifyDataSetChanged(); }
        @NonNull @Override public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            android.widget.FrameLayout frame = new android.widget.FrameLayout(parent.getContext());
            frame.setLayoutParams(new RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            return new VH(frame);
        }
        @Override public void onBindViewHolder(@NonNull VH holder, int position) { holder.bind(items.get(position)); }
        @Override public int getItemCount() { return items.size(); }
    }
}
