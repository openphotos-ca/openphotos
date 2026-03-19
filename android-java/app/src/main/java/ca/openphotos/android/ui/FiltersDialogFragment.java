package ca.openphotos.android.ui;

import android.app.DatePickerDialog;
import android.content.Context;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.EditText;
import android.widget.Spinner;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.DialogFragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.FilterParams;
import ca.openphotos.android.server.ServerPhotosService;
import com.google.android.material.switchmaterial.SwitchMaterial;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Date;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/**
 * Full-screen Filters dialog that mirrors iOS/Web. It gathers filter selections
 * (faces/date/type/rating/location) and returns them to the host only when the
 * user taps Done. Clear All resets local selections but does not apply until Done.
 */
public class FiltersDialogFragment extends DialogFragment {
    public static final String KEY_RESULT = "filters.result";
    public static final String KEY_MANAGE_FACES = "filters.manageFaces";
    private static final String ARG_INITIAL = "initial";

    public static FiltersDialogFragment newInstance(@Nullable FilterParams initial) {
        FiltersDialogFragment f = new FiltersDialogFragment();
        Bundle b = new Bundle();
        if (initial != null) b.putParcelable(ARG_INITIAL, initial);
        f.setArguments(b);
        return f;
    }

    private FilterParams working; // local copy; applied on Done

    // UI refs
    private RecyclerView facesGrid;
    private SwitchMaterial swScreenshots, swLive;
    private TextView tvStart, tvEnd;
    private TextView star1, star2, star3, star4, star5;
    private Spinner spCountry, spCity;
    private EditText etRegion;

    // Metadata
    private final ArrayList<FaceItem> faces = new ArrayList<>();
    private final ArrayList<String> countries = new ArrayList<>();
    private final ArrayList<String> cities = new ArrayList<>();
    private FacesAdapter facesAdapter;
    private final SimpleDateFormat fmt = new SimpleDateFormat("MMM d, yyyy", Locale.US);

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_filters_dialog, container, false);
        FilterParams initial = getArguments() != null ? getArguments().getParcelable(ARG_INITIAL) : null;
        working = new FilterParams(initial);

        // App bar actions
        root.findViewById(R.id.btn_done).setOnClickListener(v -> applyAndClose());
        root.findViewById(R.id.btn_clear_all).setOnClickListener(v -> clearAllLocal());
        root.findViewById(R.id.btn_manage_faces).setOnClickListener(v -> {
            // Signal host to open Manage Faces and close this panel
            Bundle res = new Bundle(); res.putBoolean(KEY_MANAGE_FACES, true);
            getParentFragmentManager().setFragmentResult(KEY_MANAGE_FACES, res);
            dismissAllowingStateLoss();
        });

        facesGrid = root.findViewById(R.id.faces_grid);
        int faceSizeDp = 80; int labelDp = 16; int rowsVisible = 3; int rowSpacingDp = 4;
        int heightPx = dp(requireContext(), rowsVisible * (faceSizeDp + labelDp) + (rowsVisible - 1) * rowSpacingDp + 8);
        facesGrid.getLayoutParams().height = heightPx;
        facesGrid.setLayoutManager(new GridLayoutManager(requireContext(), 3));
        facesAdapter = new FacesAdapter(working.faces);
        facesGrid.setAdapter(facesAdapter);

        // Time range
        root.findViewById(R.id.btn_clear_dates).setOnClickListener(v -> { working.dateFrom = null; working.dateTo = null; bindDates(); });
        tvStart = root.findViewById(R.id.date_start);
        tvEnd = root.findViewById(R.id.date_end);
        tvStart.setOnClickListener(v -> pickDate(true));
        tvEnd.setOnClickListener(v -> pickDate(false));

        // Type toggles
        swScreenshots = root.findViewById(R.id.toggle_screenshots);
        swLive = root.findViewById(R.id.toggle_live);
        swScreenshots.setChecked(working.screenshots);
        swLive.setChecked(working.livePhotos);
        swScreenshots.setOnCheckedChangeListener((b, on) -> working.screenshots = on);
        swLive.setOnCheckedChangeListener((b, on) -> working.livePhotos = on);

        // Rating stars
        star1 = root.findViewById(R.id.star1); star2 = root.findViewById(R.id.star2); star3 = root.findViewById(R.id.star3); star4 = root.findViewById(R.id.star4); star5 = root.findViewById(R.id.star5);
        View.OnClickListener starL = v -> {
            int n = v == star1 ? 1 : v == star2 ? 2 : v == star3 ? 3 : v == star4 ? 4 : 5;
            working.ratingMin = n; bindStars(); };
        star1.setOnClickListener(starL); star2.setOnClickListener(starL); star3.setOnClickListener(starL); star4.setOnClickListener(starL); star5.setOnClickListener(starL);
        root.findViewById(R.id.btn_clear_rating).setOnClickListener(v -> { working.ratingMin = null; bindStars(); });

        // Location (UI-only)
        spCountry = root.findViewById(R.id.sp_country);
        spCity = root.findViewById(R.id.sp_city);
        etRegion = root.findViewById(R.id.et_region);

        bindDates(); bindStars();
        fetchMetadataAsync();
        return root;
    }

    private void applyAndClose() {
        working.country = (String) spCountry.getSelectedItem(); if (TextUtils.isEmpty(working.country)) working.country = null;
        working.city = (String) spCity.getSelectedItem(); if (TextUtils.isEmpty(working.city)) working.city = null;
        working.region = etRegion.getText() != null ? etRegion.getText().toString().trim() : null; if (TextUtils.isEmpty(working.region)) working.region = null;
        Bundle b = new Bundle(); b.putParcelable(KEY_RESULT, working);
        getParentFragmentManager().setFragmentResult(KEY_RESULT, b);
        dismissAllowingStateLoss();
    }

    private void clearAllLocal() {
        working.faces.clear(); if (facesAdapter != null) facesAdapter.setSelected(working.faces);
        working.dateFrom = null; working.dateTo = null; bindDates();
        working.screenshots = false; working.livePhotos = false; if (swScreenshots != null) swScreenshots.setChecked(false); if (swLive != null) swLive.setChecked(false);
        working.ratingMin = null; bindStars();
        // Location UI-only: clear selections
        if (spCountry != null && spCountry.getAdapter() != null) spCountry.setSelection(0);
        if (spCity != null && spCity.getAdapter() != null) spCity.setSelection(0);
        if (etRegion != null) etRegion.setText("");
    }

    private void pickDate(boolean start) {
        final Calendar cal = Calendar.getInstance();
        Long sec = start ? working.dateFrom : working.dateTo;
        if (sec != null) cal.setTimeInMillis(sec * 1000L);
        DatePickerDialog dlg = new DatePickerDialog(requireContext(), (view, y, m, d) -> {
            Calendar c = Calendar.getInstance(); c.set(Calendar.YEAR, y); c.set(Calendar.MONTH, m); c.set(Calendar.DAY_OF_MONTH, d);
            c.set(Calendar.HOUR_OF_DAY, 0); c.set(Calendar.MINUTE, 0); c.set(Calendar.SECOND, 0); c.set(Calendar.MILLISECOND, 0);
            if (start) {
                working.dateFrom = c.getTimeInMillis() / 1000L;
            } else {
                // Inclusive end-of-day
                c.set(Calendar.HOUR_OF_DAY, 23); c.set(Calendar.MINUTE, 59); c.set(Calendar.SECOND, 59);
                working.dateTo = c.getTimeInMillis() / 1000L;
            }
            bindDates();
        }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH));
        dlg.show();
    }

    private void bindDates() {
        tvStart.setText(working.dateFrom != null ? fmt.format(new Date(working.dateFrom * 1000L)) : "");
        tvEnd.setText(working.dateTo != null ? fmt.format(new Date(working.dateTo * 1000L)) : "");
    }

    private void bindStars() {
        int n = working.ratingMin != null ? working.ratingMin : 0;
        star1.setText(n >= 1 ? "★" : "☆");
        star2.setText(n >= 2 ? "★" : "☆");
        star3.setText(n >= 3 ? "★" : "☆");
        star4.setText(n >= 4 ? "★" : "☆");
        star5.setText(n >= 5 ? "★" : "☆");
    }

    private void fetchMetadataAsync() {
        faces.clear(); countries.clear(); cities.clear();
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                JSONObject meta = svc.getFilterMetadata();
                if (meta.has("faces")) {
                    JSONArray arr = meta.getJSONArray("faces");
                    for (int i=0;i<arr.length();i++) {
                        JSONObject f = arr.getJSONObject(i);
                        FaceItem it = new FaceItem(
                                f.optString("person_id", f.optString("id", "")),
                                f.optString("name", null),
                                f.optInt("photo_count", 0)
                        );
                        faces.add(it);
                    }
                }
                JSONArray ctry = meta.optJSONArray("countries"); if (ctry != null) { for (int i=0;i<ctry.length();i++) countries.add(ctry.getString(i)); }
                JSONArray city = meta.optJSONArray("cities"); if (city != null) { for (int i=0;i<city.length();i++) cities.add(city.getString(i)); }
                requireActivity().runOnUiThread(() -> {
                    facesAdapter.submit(faces);
                    ArrayList<String> cx = new ArrayList<>(); cx.add(""); cx.addAll(countries);
                    spCountry.setAdapter(new ArrayAdapter<>(requireContext(), android.R.layout.simple_spinner_dropdown_item, cx));
                    ArrayList<String> cy = new ArrayList<>(); cy.add(""); cy.addAll(cities);
                    spCity.setAdapter(new ArrayAdapter<>(requireContext(), android.R.layout.simple_spinner_dropdown_item, cy));
                });
            } catch (Exception ignored) { }
        }).start();
    }

    private static int dp(Context c, int d) { return Math.round(c.getResources().getDisplayMetrics().density * d); }

    // Face grid
    static class FaceItem { final String id; final String name; final int count; FaceItem(String id, String name, int count){ this.id=id; this.name=name; this.count=count; }}
    static class FaceVH extends RecyclerView.ViewHolder {
        final android.widget.ImageView img; final TextView label; final View overlay;
        FaceVH(@NonNull View v) {
            super(v);
            img = new android.widget.ImageView(v.getContext()); label = new TextView(v.getContext()); overlay = new View(v.getContext());
            android.widget.LinearLayout root = new android.widget.LinearLayout(v.getContext()); root.setOrientation(android.widget.LinearLayout.VERTICAL);
            int pad=4; root.setPadding(pad,pad,pad,pad);
            img.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(v.getContext(),80)));
            img.setScaleType(android.widget.ImageView.ScaleType.CENTER_CROP);
            overlay.setBackground(new android.graphics.drawable.GradientDrawable(){
                { setColor(0x00000000); setStroke(dp(v.getContext(),2), ContextCompat.getColor(v.getContext(), R.color.app_accent)); setCornerRadius(dp(v.getContext(),8)); }
            });
            overlay.setVisibility(View.GONE);
            label.setTextSize(12f); label.setMaxLines(1); label.setEllipsize(android.text.TextUtils.TruncateAt.END);
            root.addView(img); root.addView(label);
            ((ViewGroup)v).addView(root);
            ((ViewGroup)v).addView(overlay, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        }
        void bind(FaceItem f, boolean selected) {
            String text = (f.name != null && !f.name.isEmpty() ? f.name : f.id) + " (" + f.count + ")";
            label.setText(text);
            overlay.setVisibility(selected ? View.VISIBLE : View.GONE);
        }
    }
    static class FacesAdapter extends RecyclerView.Adapter<FaceVH> {
        private final ArrayList<FaceItem> items = new ArrayList<>();
        private final Set<String> selected; // external set owned by FilterParams
        FacesAdapter(Set<String> selected) { this.selected = selected != null ? selected : new HashSet<>(); }
        void submit(ArrayList<FaceItem> list){ items.clear(); items.addAll(list); notifyDataSetChanged(); }
        void setSelected(Set<String> sel) { if (sel != null) { selected.clear(); selected.addAll(sel); notifyDataSetChanged(); } }
        @NonNull @Override public FaceVH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            android.widget.FrameLayout frame = new android.widget.FrameLayout(parent.getContext());
            frame.setLayoutParams(new RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            return new FaceVH(frame);
        }
        @Override public void onBindViewHolder(@NonNull FaceVH holder, int position) {
            FaceItem f = items.get(position);
            boolean sel = selected.contains(f.id);
            holder.bind(f, sel);
            // Load thumbnail with Authorization header when available
            try {
                String base = AuthManager.get(holder.img.getContext()).getServerUrl();
                String enc = java.net.URLEncoder.encode(f.id, java.nio.charset.StandardCharsets.UTF_8.name());
                String u = base + "/api/face-thumbnail?personId=" + enc;
                Object model;
                String t = AuthManager.get(holder.img.getContext()).getToken();
                if (t != null && !t.isEmpty()) {
                    model = new com.bumptech.glide.load.model.GlideUrl(u, new com.bumptech.glide.load.model.LazyHeaders.Builder().addHeader("Authorization", "Bearer " + t).build());
                } else { model = u; }
                com.bumptech.glide.Glide.with(holder.img.getContext()).load(model).centerCrop()
                        .error(new android.graphics.drawable.ColorDrawable(ContextCompat.getColor(holder.img.getContext(), R.color.app_placeholder_alt)))
                        .into(holder.img);
            } catch (Exception ignored) {}
            holder.itemView.setOnClickListener(v -> {
                if (sel) selected.remove(f.id); else selected.add(f.id);
                notifyItemChanged(position);
            });
        }
        @Override public int getItemCount() { return items.size(); }
    }
}
