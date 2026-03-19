package ca.openphotos.android.ui;

import android.app.AlertDialog;
import android.os.Bundle;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.DialogFragment;
import androidx.fragment.app.Fragment;
import androidx.fragment.app.FragmentActivity;
import androidx.navigation.NavController;
import androidx.navigation.fragment.NavHostFragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.FaceModels;
import ca.openphotos.android.server.FilterParams;
import ca.openphotos.android.server.ServerPhotosService;
import com.bumptech.glide.Glide;
import com.bumptech.glide.load.model.GlideUrl;
import com.bumptech.glide.load.model.LazyHeaders;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.card.MaterialCardView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/** Full-screen Manage Faces flow matching iOS behavior and actions. */
public class ManageFacesDialogFragment extends DialogFragment {
    private enum Mode {
        IDLE,
        MERGE_SELECT,
        CHOOSE_PRIMARY,
        EDIT,
        MERGING
    }

    private static final int PREVIEW_LIMIT = 30;
    private static final int PREVIEW_RENDER_LIMIT = 10;
    private static final Pattern DEFAULT_NAME_PATTERN = Pattern.compile("^p\\d+$", Pattern.CASE_INSENSITIVE);
    private final ArrayList<FaceModels.Person> persons = new ArrayList<>();
    private final LinkedHashSet<String> selection = new LinkedHashSet<>();
    private final ArrayList<PreviewItem> previewItems = new ArrayList<>();

    private @Nullable String primaryId;
    private @Nullable String lastSelectedPersonId;
    private @Nullable String activePersonId;
    private Mode mode = Mode.IDLE;
    private boolean loadingPersons = false;
    private boolean loadingPreview = false;
    private @Nullable String loadError;

    private ServerPhotosService service;

    private TextView tvTotalCount;
    private TextView tvSelectedCount;
    private TextView tvLoadError;
    private TextView tvModeMessage;
    private TextView tvPersonsEmpty;
    private TextView tvPreviewTitle;
    private TextView tvPreviewEmpty;
    private EditText etEditName;
    private EditText etEditBirth;
    private View layoutPersonsLoading;
    private View layoutPreviewLoading;
    private LinearLayout rowModeIdle;
    private LinearLayout rowModeMessage;
    private View rowModeEdit;
    private LinearLayout rowModeMerging;
    private MaterialButton btnMergeFaces;
    private MaterialButton btnDeleteFaces;
    private MaterialButton btnModeCancel;
    private MaterialButton btnModeNext;
    private MaterialButton btnEditCancel;
    private MaterialButton btnEditSubmit;
    private RecyclerView rvPersons;
    private RecyclerView rvPreview;

    private final PersonsAdapter personsAdapter = new PersonsAdapter();
    private final PreviewAdapter previewAdapter = new PreviewAdapter();

    public static ManageFacesDialogFragment newInstance() {
        return new ManageFacesDialogFragment();
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_manage_faces_dialog, container, false);
        service = new ServerPhotosService(requireContext().getApplicationContext());

        ImageButton btnClose = root.findViewById(R.id.btn_close);
        btnClose.setOnClickListener(v -> dismissAllowingStateLoss());

        tvTotalCount = root.findViewById(R.id.tv_total_count);
        tvSelectedCount = root.findViewById(R.id.tv_selected_count);
        tvLoadError = root.findViewById(R.id.tv_load_error);
        tvModeMessage = root.findViewById(R.id.tv_mode_message);
        tvPersonsEmpty = root.findViewById(R.id.tv_persons_empty);
        tvPreviewTitle = root.findViewById(R.id.tv_preview_title);
        tvPreviewEmpty = root.findViewById(R.id.tv_preview_empty);
        etEditName = root.findViewById(R.id.et_edit_name);
        etEditBirth = root.findViewById(R.id.et_edit_birth);
        layoutPersonsLoading = root.findViewById(R.id.layout_persons_loading);
        layoutPreviewLoading = root.findViewById(R.id.layout_preview_loading);
        rowModeIdle = root.findViewById(R.id.row_mode_idle);
        rowModeMessage = root.findViewById(R.id.row_mode_message);
        rowModeEdit = root.findViewById(R.id.row_mode_edit);
        rowModeMerging = root.findViewById(R.id.row_mode_merging);
        btnMergeFaces = root.findViewById(R.id.btn_merge_faces);
        btnDeleteFaces = root.findViewById(R.id.btn_delete_faces);
        btnModeCancel = root.findViewById(R.id.btn_mode_cancel);
        btnModeNext = root.findViewById(R.id.btn_mode_next);
        btnEditCancel = root.findViewById(R.id.btn_edit_cancel);
        btnEditSubmit = root.findViewById(R.id.btn_edit_submit);

        rvPersons = root.findViewById(R.id.rv_persons);
        rvPersons.setLayoutManager(new GridLayoutManager(requireContext(), 3));
        rvPersons.setAdapter(personsAdapter);

        rvPreview = root.findViewById(R.id.rv_preview);
        rvPreview.setLayoutManager(new GridLayoutManager(requireContext(), 5));
        rvPreview.setNestedScrollingEnabled(false);
        rvPreview.setAdapter(previewAdapter);

        btnMergeFaces.setOnClickListener(v -> startMergeFlow());
        btnDeleteFaces.setOnClickListener(v -> confirmDeleteSelected());
        btnModeCancel.setOnClickListener(v -> resetMergeFlow());
        btnModeNext.setOnClickListener(v -> {
            if (mode == Mode.MERGE_SELECT) nextFromSelect();
            else if (mode == Mode.CHOOSE_PRIMARY) nextFromChoosePrimary();
        });
        btnEditCancel.setOnClickListener(v -> resetMergeFlow());
        btnEditSubmit.setOnClickListener(v -> submitMergeOrSave());

        updateUi();
        loadPersonsAsync(true);
        return root;
    }

    @Override
    public void onStart() {
        super.onStart();
        if (getDialog() != null && getDialog().getWindow() != null) {
            getDialog().getWindow().setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            getDialog().getWindow().setBackgroundDrawableResource(R.color.app_background);
        }
    }

    private int color(int resId) {
        return ContextCompat.getColor(requireContext(), resId);
    }

    private void loadPersonsAsync(boolean showLoading) {
        if (loadingPersons) return;
        loadingPersons = true;
        if (showLoading) updateUi();
        new Thread(() -> {
            try {
                List<FaceModels.Person> loaded = service.listPersons();
                Collections.sort(loaded, Comparator.comparing(
                        p -> p.label().toLowerCase(Locale.US),
                        Comparator.naturalOrder()
                ));
                runOnUi(() -> {
                    persons.clear();
                    persons.addAll(loaded);
                    loadingPersons = false;
                    loadError = null;
                    selection.clear();
                    primaryId = null;
                    lastSelectedPersonId = null;
                    activePersonId = null;
                    previewItems.clear();
                    loadingPreview = false;
                    mode = Mode.IDLE;
                    updateUi();
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    loadingPersons = false;
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    if (msg.contains("HTTP 403")) {
                        loadError = "Not authorized to manage faces";
                        Toast.makeText(requireContext(), "Not authorized to manage faces", Toast.LENGTH_LONG).show();
                    } else {
                        loadError = msg.isEmpty() ? "Failed to load faces" : msg;
                    }
                    updateUi();
                });
            }
        }).start();
    }

    private void toggleSelection(@NonNull String personId) {
        if (mode == Mode.MERGING) return;
        if (selection.contains(personId)) {
            selection.remove(personId);
            if (TextUtils.equals(primaryId, personId)) primaryId = null;
            if (personId.equals(lastSelectedPersonId)) {
                lastSelectedPersonId = selection.isEmpty() ? null : selection.iterator().next();
            }
        } else {
            selection.add(personId);
            lastSelectedPersonId = personId;
        }
        if (selection.isEmpty()) primaryId = null;
        recomputeActivePersonAndPreview();
        updateUi();
    }

    private void setPrimary(@NonNull String personId) {
        if (mode == Mode.MERGING) return;
        primaryId = personId;
        selection.add(personId);
        recomputeActivePersonAndPreview();
        updateUi();
    }

    private void startMergeFlow() {
        primaryId = null;
        mode = selection.size() >= 2 ? Mode.CHOOSE_PRIMARY : Mode.MERGE_SELECT;
        updateUi();
    }

    private void nextFromSelect() {
        if (selection.size() < 2) return;
        primaryId = null;
        mode = Mode.CHOOSE_PRIMARY;
        updateUi();
    }

    private void nextFromChoosePrimary() {
        if (primaryId == null) return;
        FaceModels.Person primary = personForId(primaryId);
        List<FaceModels.Person> selected = selectedPersons();
        String primaryName = displayName(primary);
        String candidateName = isDefaultName(primaryName) ? null : primaryName;
        if (candidateName == null) {
            for (FaceModels.Person p : selected) {
                String candidate = displayName(p);
                if (!isDefaultName(candidate)) {
                    candidateName = candidate;
                    break;
                }
            }
        }

        String birthCandidate = primary != null ? trimBirthDate(primary.birthDate) : null;
        if (TextUtils.isEmpty(birthCandidate)) {
            for (FaceModels.Person p : selected) {
                String candidate = trimBirthDate(p.birthDate);
                if (!TextUtils.isEmpty(candidate)) {
                    birthCandidate = candidate;
                    break;
                }
            }
        }

        etEditName.setText(candidateName == null ? "" : candidateName);
        etEditBirth.setText(birthCandidate == null ? "" : birthCandidate);
        mode = Mode.EDIT;
        updateUi();
    }

    private void beginSingleEdit(@NonNull String personId) {
        FaceModels.Person p = personForId(personId);
        selection.clear();
        selection.add(personId);
        primaryId = personId;
        lastSelectedPersonId = personId;
        etEditName.setText(displayName(p) == null ? "" : displayName(p));
        etEditBirth.setText(trimBirthDate(p != null ? p.birthDate : null));
        mode = Mode.EDIT;
        recomputeActivePersonAndPreview();
        updateUi();
    }

    private void submitMergeOrSave() {
        if (primaryId == null) return;
        final String primary = primaryId;
        final ArrayList<String> sources = new ArrayList<>(selection);
        sources.remove(primary);

        final String trimmedName = etEditName.getText() != null ? etEditName.getText().toString().trim() : "";
        final String trimmedBirth = etEditBirth.getText() != null ? etEditBirth.getText().toString().trim() : "";

        if (sources.isEmpty() && trimmedName.isEmpty() && trimmedBirth.isEmpty()) {
            mode = Mode.EDIT;
            updateUi();
            return;
        }

        mode = Mode.MERGING;
        updateUi();
        new Thread(() -> {
            try {
                if (!sources.isEmpty()) {
                    service.mergeFaces(primary, sources);
                }
                if (!trimmedName.isEmpty() || !trimmedBirth.isEmpty()) {
                    service.updatePerson(primary, trimmedName.isEmpty() ? null : trimmedName, trimmedBirth.isEmpty() ? null : trimmedBirth);
                }
                runOnUi(() -> {
                    int totalMerged = sources.size() + 1;
                    String msg = sources.isEmpty() ? "Updated face" : ("Merged " + totalMerged + " faces");
                    Toast.makeText(requireContext(), msg, Toast.LENGTH_SHORT).show();
                    loadPersonsAsync(false);
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    if (msg.contains("HTTP 403")) {
                        Toast.makeText(requireContext(), "Not authorized to update faces", Toast.LENGTH_LONG).show();
                    } else {
                        Toast.makeText(requireContext(), "Merge failed" + (msg.isEmpty() ? "" : (": " + msg)), Toast.LENGTH_LONG).show();
                    }
                    mode = Mode.EDIT;
                    updateUi();
                });
            }
        }).start();
    }

    private void confirmDeleteSelected() {
        final int count = selection.size();
        if (count <= 0) return;
        String plural = count == 1 ? "" : "s";
        new AlertDialog.Builder(requireContext())
                .setTitle("Delete faces?")
                .setMessage("This will delete " + count + " face" + plural + ". This cannot be undone.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Delete", (d, which) -> deleteSelectedPersonsAsync())
                .show();
    }

    private void deleteSelectedPersonsAsync() {
        final ArrayList<String> ids = new ArrayList<>(selection);
        if (ids.isEmpty()) return;
        mode = Mode.MERGING;
        updateUi();
        new Thread(() -> {
            try {
                int deleted = service.deletePersons(ids);
                runOnUi(() -> {
                    int shown = deleted > 0 ? deleted : ids.size();
                    String suffix = shown == 1 ? "" : "s";
                    Toast.makeText(requireContext(), "Deleted " + shown + " face" + suffix, Toast.LENGTH_SHORT).show();
                    loadPersonsAsync(false);
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    if (msg.contains("HTTP 403")) {
                        Toast.makeText(requireContext(), "Not authorized to delete faces", Toast.LENGTH_LONG).show();
                    } else {
                        Toast.makeText(requireContext(), "Delete failed" + (msg.isEmpty() ? "" : (": " + msg)), Toast.LENGTH_LONG).show();
                    }
                    mode = Mode.IDLE;
                    updateUi();
                });
            }
        }).start();
    }

    private void resetMergeFlow() {
        mode = Mode.IDLE;
        selection.clear();
        primaryId = null;
        lastSelectedPersonId = null;
        etEditName.setText("");
        etEditBirth.setText("");
        recomputeActivePersonAndPreview();
        updateUi();
    }

    private void recomputeActivePersonAndPreview() {
        String candidate = primaryId != null ? primaryId : lastSelectedPersonId;
        if (!TextUtils.equals(candidate, activePersonId)) {
            activePersonId = candidate;
            loadPreviewAsync(activePersonId);
        } else if (activePersonId == null) {
            previewItems.clear();
            loadingPreview = false;
        }
    }

    private void loadPreviewAsync(@Nullable String personId) {
        if (personId == null || personId.trim().isEmpty()) {
            loadingPreview = false;
            previewItems.clear();
            updateUi();
            return;
        }
        final String requestPersonId = personId.trim();
        loadingPreview = true;
        previewItems.clear();
        updateUi();
        new Thread(() -> {
            try {
                FilterParams filters = new FilterParams();
                filters.faces.add(requestPersonId);
                filters.facesMode = "any";
                JSONObject resp = service.listPhotos(null, null, null, null, false, 1, PREVIEW_LIMIT, filters);
                JSONArray arr = resp.optJSONArray("photos");
                ArrayList<PreviewItem> list = new ArrayList<>();
                if (arr != null) {
                    for (int i = 0; i < arr.length(); i++) {
                        JSONObject p = arr.optJSONObject(i);
                        if (p == null) continue;
                        String assetId = p.optString("asset_id", "");
                        if (assetId.isEmpty()) continue;
                        list.add(new PreviewItem(assetId));
                    }
                }
                runOnUi(() -> {
                    if (!TextUtils.equals(requestPersonId, activePersonId)) return;
                    loadingPreview = false;
                    previewItems.clear();
                    int lim = Math.min(PREVIEW_RENDER_LIMIT, list.size());
                    previewItems.addAll(list.subList(0, lim));
                    updateUi();
                });
            } catch (Exception e) {
                runOnUi(() -> {
                    if (!TextUtils.equals(requestPersonId, activePersonId)) return;
                    loadingPreview = false;
                    previewItems.clear();
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (handleSessionExpiredIfNeeded(msg)) return;
                    if (msg.contains("HTTP 403")) {
                        Toast.makeText(requireContext(), "Not authorized to load face items", Toast.LENGTH_LONG).show();
                    } else {
                        Toast.makeText(requireContext(), "Failed to load items" + (msg.isEmpty() ? "" : (": " + msg)), Toast.LENGTH_SHORT).show();
                    }
                    updateUi();
                });
            }
        }).start();
    }

    private void updateUi() {
        if (!isAdded()) return;
        tvTotalCount.setText(persons.size() + " total");
        int selectedCount = selection.size();
        if (selectedCount > 0) {
            tvSelectedCount.setVisibility(View.VISIBLE);
            tvSelectedCount.setText(selectedCount + " selected");
        } else {
            tvSelectedCount.setVisibility(View.GONE);
        }

        tvLoadError.setVisibility(mode == Mode.IDLE && !TextUtils.isEmpty(loadError) ? View.VISIBLE : View.GONE);
        if (!TextUtils.isEmpty(loadError)) tvLoadError.setText(loadError);

        rowModeIdle.setVisibility(mode == Mode.IDLE ? View.VISIBLE : View.GONE);
        rowModeMessage.setVisibility(mode == Mode.MERGE_SELECT || mode == Mode.CHOOSE_PRIMARY ? View.VISIBLE : View.GONE);
        rowModeEdit.setVisibility(mode == Mode.EDIT ? View.VISIBLE : View.GONE);
        rowModeMerging.setVisibility(mode == Mode.MERGING ? View.VISIBLE : View.GONE);

        btnMergeFaces.setEnabled(selectedCount >= 2);
        btnDeleteFaces.setEnabled(selectedCount >= 1);

        if (mode == Mode.MERGE_SELECT) {
            tvModeMessage.setText("Select at least two faces to merge");
            btnModeNext.setEnabled(selectedCount >= 2);
        } else if (mode == Mode.CHOOSE_PRIMARY) {
            tvModeMessage.setText("Pick the face to keep as primary");
            btnModeNext.setEnabled(primaryId != null);
        } else {
            tvModeMessage.setText("");
            btnModeNext.setEnabled(false);
        }

        List<FaceModels.Person> rendered = personsToRender();
        personsAdapter.submit(rendered);
        boolean showPersonsLoading = loadingPersons && persons.isEmpty();
        layoutPersonsLoading.setVisibility(showPersonsLoading ? View.VISIBLE : View.GONE);
        tvPersonsEmpty.setVisibility(!loadingPersons && rendered.isEmpty() ? View.VISIBLE : View.GONE);
        rvPersons.setVisibility(showPersonsLoading ? View.GONE : View.VISIBLE);

        if (activePersonId == null) {
            tvPreviewTitle.setText("Select a face to preview items");
            layoutPreviewLoading.setVisibility(View.GONE);
            tvPreviewEmpty.setVisibility(View.GONE);
            rvPreview.setVisibility(View.GONE);
            previewAdapter.submit(Collections.emptyList());
        } else {
            FaceModels.Person active = personForId(activePersonId);
            String label = active != null ? active.label() : activePersonId;
            tvPreviewTitle.setText("Items for " + label);
            layoutPreviewLoading.setVisibility(loadingPreview ? View.VISIBLE : View.GONE);
            if (!loadingPreview && previewItems.isEmpty()) {
                tvPreviewEmpty.setVisibility(View.VISIBLE);
                rvPreview.setVisibility(View.GONE);
            } else if (!loadingPreview) {
                tvPreviewEmpty.setVisibility(View.GONE);
                rvPreview.setVisibility(View.VISIBLE);
            } else {
                tvPreviewEmpty.setVisibility(View.GONE);
                rvPreview.setVisibility(View.GONE);
            }
            previewAdapter.submit(new ArrayList<>(previewItems));
        }
    }

    private List<FaceModels.Person> personsToRender() {
        if (mode == Mode.CHOOSE_PRIMARY || mode == Mode.EDIT) {
            ArrayList<FaceModels.Person> filtered = new ArrayList<>();
            for (FaceModels.Person p : persons) {
                if (selection.contains(p.personId)) filtered.add(p);
            }
            if (!filtered.isEmpty()) return filtered;
        }
        return new ArrayList<>(persons);
    }

    @Nullable
    private FaceModels.Person personForId(@Nullable String personId) {
        if (personId == null) return null;
        for (FaceModels.Person p : persons) {
            if (personId.equals(p.personId)) return p;
        }
        return null;
    }

    private List<FaceModels.Person> selectedPersons() {
        ArrayList<FaceModels.Person> out = new ArrayList<>();
        for (FaceModels.Person p : persons) {
            if (selection.contains(p.personId)) out.add(p);
        }
        return out;
    }

    @Nullable
    private String displayName(@Nullable FaceModels.Person person) {
        if (person == null || person.displayName == null) return null;
        String t = person.displayName.trim();
        return t.isEmpty() ? null : t;
    }

    private boolean isDefaultName(@Nullable String name) {
        if (name == null || name.trim().isEmpty()) return true;
        return DEFAULT_NAME_PATTERN.matcher(name.trim()).matches();
    }

    @Nullable
    private String trimBirthDate(@Nullable String birthDate) {
        if (birthDate == null || birthDate.trim().isEmpty()) return null;
        String t = birthDate.trim();
        return t.length() > 10 ? t.substring(0, 10) : t;
    }

    private int dp(int value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, requireContext().getResources().getDisplayMetrics()));
    }

    private boolean handleSessionExpiredIfNeeded(@Nullable String msg) {
        if (msg == null) return false;
        if (msg.contains("HTTP 401") && !AuthManager.get(requireContext().getApplicationContext()).isAuthenticated()) {
            handleAuthExpired();
            return true;
        }
        return false;
    }

    private void handleAuthExpired() {
        try {
            AuthManager.get(requireContext()).logout();
        } catch (Exception ignored) {
        }
        Toast.makeText(requireContext(), "Session expired. Please sign in again.", Toast.LENGTH_LONG).show();
        try {
            FragmentActivity act = requireActivity();
            Fragment navHost = act.getSupportFragmentManager().findFragmentById(R.id.nav_host_fragment);
            if (navHost instanceof NavHostFragment) {
                NavController nav = ((NavHostFragment) navHost).getNavController();
                nav.navigate(R.id.serverLoginFragment);
            }
            dismissAllowingStateLoss();
        } catch (Exception ignored) {
        }
    }

    private void runOnUi(@NonNull Runnable runnable) {
        if (!isAdded()) return;
        requireActivity().runOnUiThread(() -> {
            if (!isAdded()) return;
            runnable.run();
        });
    }

    private Object authAwareModel(@NonNull String absoluteUrl) {
        String token = AuthManager.get(requireContext()).getToken();
        if (token == null || token.isEmpty()) return absoluteUrl;
        return new GlideUrl(
                absoluteUrl,
                new LazyHeaders.Builder().addHeader("Authorization", "Bearer " + token).build()
        );
    }

    private String personLabelWithCount(@NonNull FaceModels.Person person) {
        int count = person.faceCount > 0 ? person.faceCount : person.photoCount;
        if (count > 0) return person.label() + " (" + count + ")";
        return person.label();
    }

    private static final class PreviewItem {
        final String assetId;

        PreviewItem(String assetId) {
            this.assetId = assetId;
        }
    }

    private final class PersonsAdapter extends RecyclerView.Adapter<PersonsAdapter.PersonVH> {
        private final ArrayList<FaceModels.Person> items = new ArrayList<>();

        void submit(List<FaceModels.Person> newItems) {
            items.clear();
            if (newItems != null) items.addAll(newItems);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public PersonVH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_manage_face_person, parent, false);
            return new PersonVH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull PersonVH holder, int position) {
            FaceModels.Person person = items.get(position);
            boolean isSelected = selection.contains(person.personId);
            boolean isPrimary = TextUtils.equals(primaryId, person.personId);
            boolean showPrimaryOnly = mode == Mode.CHOOSE_PRIMARY || mode == Mode.EDIT;
            boolean activeHighlighted = showPrimaryOnly ? isPrimary : (isSelected || isPrimary);
            int accent = color(R.color.app_accent);
            int border = color(R.color.app_card_stroke);
            int strokeColor = showPrimaryOnly ? (isPrimary ? accent : border) : ((isSelected || isPrimary) ? accent : border);

            holder.label.setText(personLabelWithCount(person));
            holder.card.setStrokeColor(strokeColor);
            holder.card.setStrokeWidth(dp((isSelected || isPrimary) ? 2 : 1));
            holder.card.setCardBackgroundColor(activeHighlighted ? color(R.color.app_selection_bg) : color(R.color.app_surface));

            boolean showCheck = showPrimaryOnly ? isPrimary : (isSelected || isPrimary);
            holder.checkBadge.setVisibility(showCheck ? View.VISIBLE : View.GONE);
            holder.checkBadge.setBackgroundTintList(android.content.res.ColorStateList.valueOf(accent));
            holder.label.setTextColor(color(R.color.app_text_primary));

            holder.card.setOnClickListener(v -> {
                if (mode == Mode.CHOOSE_PRIMARY) {
                    setPrimary(person.personId);
                } else {
                    toggleSelection(person.personId);
                }
            });
            holder.label.setOnClickListener(v -> beginSingleEdit(person.personId));

            String faceUrl = service.faceThumbnailUrl(person.personId);
            Glide.with(ManageFacesDialogFragment.this)
                    .load(authAwareModel(faceUrl))
                    .centerCrop()
                    .placeholder(new android.graphics.drawable.ColorDrawable(color(R.color.app_placeholder)))
                    .error(new android.graphics.drawable.ColorDrawable(color(R.color.app_placeholder_alt)))
                    .into(holder.image);
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        final class PersonVH extends RecyclerView.ViewHolder {
            final MaterialCardView card;
            final ImageView image;
            final TextView checkBadge;
            final TextView label;

            PersonVH(@NonNull View itemView) {
                super(itemView);
                card = itemView.findViewById(R.id.card_thumb);
                image = itemView.findViewById(R.id.img_thumb);
                checkBadge = itemView.findViewById(R.id.tv_check_badge);
                label = itemView.findViewById(R.id.tv_label);
            }
        }
    }

    private final class PreviewAdapter extends RecyclerView.Adapter<PreviewAdapter.PreviewVH> {
        private final ArrayList<PreviewItem> items = new ArrayList<>();

        void submit(List<PreviewItem> newItems) {
            items.clear();
            if (newItems != null) items.addAll(newItems);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public PreviewVH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_manage_face_preview, parent, false);
            return new PreviewVH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull PreviewVH holder, int position) {
            PreviewItem item = items.get(position);
            String thumbUrl = service.thumbnailUrl(item.assetId);
            Glide.with(ManageFacesDialogFragment.this)
                    .load(authAwareModel(thumbUrl))
                    .centerCrop()
                    .placeholder(new android.graphics.drawable.ColorDrawable(color(R.color.app_placeholder)))
                    .error(new android.graphics.drawable.ColorDrawable(color(R.color.app_placeholder_alt)))
                    .into(holder.image);
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        final class PreviewVH extends RecyclerView.ViewHolder {
            final ImageView image;

            PreviewVH(@NonNull View itemView) {
                super(itemView);
                image = itemView.findViewById(R.id.img_preview);
            }
        }
    }
}
