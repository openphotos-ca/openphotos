package ca.openphotos.android.ui;

import android.app.AlertDialog;
import android.app.DatePickerDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.EditText;
import android.widget.RadioGroup;
import android.widget.Spinner;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.e2ee.ShareE2EEManager;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.server.ShareModels;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.button.MaterialButtonToggleGroup;
import com.google.android.material.chip.Chip;
import com.google.android.material.chip.ChipGroup;
import com.google.android.material.switchmaterial.SwitchMaterial;

import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.Locale;

/** Full-screen share creation dialog with Internal/Public tabs (iOS-style flow). */
public class CreateShareDialogFragment extends DialogFragment {
    public static final String KEY_SHARE_CREATED = "share.created";
    public static final String INITIAL_TAB_INTERNAL = "internal";
    public static final String INITIAL_TAB_PUBLIC = "public";

    private static final String ARG_OBJECT_KIND = "object_kind";
    private static final String ARG_OBJECT_ID = "object_id";
    private static final String ARG_OBJECT_NAME = "object_name";
    private static final String ARG_SELECTION_COUNT = "selection_count";
    private static final String ARG_TEMP_ALBUM_ID = "temp_album_id";
    private static final String ARG_FIRST_SELECTED_ASSET_ID = "first_selected_asset_id";
    private static final String ARG_INITIAL_TAB = "initial_tab";

    public static CreateShareDialogFragment newInstance(
            String objectKind,
            String objectId,
            @Nullable String objectName,
            int selectionCount,
            @Nullable Integer tempAlbumId,
            @Nullable String firstSelectedAssetId
    ) {
        CreateShareDialogFragment f = new CreateShareDialogFragment();
        Bundle b = new Bundle();
        b.putString(ARG_OBJECT_KIND, objectKind);
        b.putString(ARG_OBJECT_ID, objectId);
        b.putString(ARG_OBJECT_NAME, objectName);
        b.putInt(ARG_SELECTION_COUNT, selectionCount);
        if (tempAlbumId != null) b.putInt(ARG_TEMP_ALBUM_ID, tempAlbumId);
        b.putString(ARG_FIRST_SELECTED_ASSET_ID, firstSelectedAssetId);
        f.setArguments(b);
        return f;
    }

    public void setInitialTab(@NonNull String tab) {
        String t = INITIAL_TAB_INTERNAL;
        if (INITIAL_TAB_PUBLIC.equalsIgnoreCase(tab)) t = INITIAL_TAB_PUBLIC;
        Bundle b = getArguments() != null ? getArguments() : new Bundle();
        b.putString(ARG_INITIAL_TAB, t);
        setArguments(b);
    }

    private String objectKind = "asset";
    private String objectId = "";
    @Nullable private String objectName = null;
    private int selectionCount = 1;
    @Nullable private Integer tempAlbumId = null;
    @Nullable private String firstSelectedAssetId = null;
    private String initialTab = INITIAL_TAB_INTERNAL;
    private boolean shareCreated = false;
    private boolean creating = false;
    private Context appContext;

    // Common
    private MaterialButtonToggleGroup toggleShareType;
    private EditText etShareName;
    private TextView tvShareContext;
    private MaterialButton btnCreateShare;

    // Internal
    private View sectionInternal;
    private ChipGroup chipsRecipients;
    private MaterialButton btnAddRecipients;
    private Spinner spInternalPermissions;
    private SwitchMaterial swInternalExpiry;
    private MaterialButton btnInternalExpiry;
    private SwitchMaterial swInternalIncludeFaces;
    @Nullable private Calendar internalExpiryDate;

    // Public
    private View sectionPublic;
    private RadioGroup rgPublicMode;
    private Spinner spPublicRole;
    private SwitchMaterial swPublicModeration;
    private SwitchMaterial swPublicExpiry;
    private MaterialButton btnPublicExpiry;
    private SwitchMaterial swPublicPin;
    private EditText etPublicPin;
    private EditText etPublicCoverAsset;
    @Nullable private Calendar publicExpiryDate;

    private final List<ShareModels.ShareTarget> availableTargets = new ArrayList<>();
    private final List<ShareModels.ShareTarget> selectedTargets = new ArrayList<>();

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_create_share_dialog, container, false);
        appContext = requireContext().getApplicationContext();
        parseArgs();
        bindViews(root);
        setupUi();
        return root;
    }

    @Override
    public void onDismiss(@NonNull DialogInterface dialog) {
        super.onDismiss(dialog);
        cleanupTempAlbumIfNeeded();
    }

    private void parseArgs() {
        Bundle a = getArguments();
        if (a == null) return;
        objectKind = a.getString(ARG_OBJECT_KIND, "asset");
        objectId = a.getString(ARG_OBJECT_ID, "");
        objectName = a.getString(ARG_OBJECT_NAME);
        selectionCount = a.getInt(ARG_SELECTION_COUNT, 1);
        if (a.containsKey(ARG_TEMP_ALBUM_ID)) tempAlbumId = a.getInt(ARG_TEMP_ALBUM_ID);
        firstSelectedAssetId = a.getString(ARG_FIRST_SELECTED_ASSET_ID);
        initialTab = a.getString(ARG_INITIAL_TAB, INITIAL_TAB_INTERNAL);
        if (!INITIAL_TAB_PUBLIC.equals(initialTab)) initialTab = INITIAL_TAB_INTERNAL;
    }

    private void bindViews(View root) {
        root.findViewById(R.id.btn_close).setOnClickListener(v -> dismissAllowingStateLoss());
        toggleShareType = root.findViewById(R.id.toggle_share_type);
        etShareName = root.findViewById(R.id.et_share_name);
        tvShareContext = root.findViewById(R.id.tv_share_context);
        btnCreateShare = root.findViewById(R.id.btn_create_share);

        sectionInternal = root.findViewById(R.id.section_internal);
        chipsRecipients = root.findViewById(R.id.chips_recipients);
        btnAddRecipients = root.findViewById(R.id.btn_add_recipients);
        spInternalPermissions = root.findViewById(R.id.sp_internal_permissions);
        swInternalExpiry = root.findViewById(R.id.sw_internal_expiry);
        btnInternalExpiry = root.findViewById(R.id.btn_internal_expiry);
        swInternalIncludeFaces = root.findViewById(R.id.sw_internal_include_faces);

        sectionPublic = root.findViewById(R.id.section_public);
        rgPublicMode = root.findViewById(R.id.rg_public_mode);
        spPublicRole = root.findViewById(R.id.sp_public_role);
        swPublicModeration = root.findViewById(R.id.sw_public_moderation);
        swPublicExpiry = root.findViewById(R.id.sw_public_expiry);
        btnPublicExpiry = root.findViewById(R.id.btn_public_expiry);
        swPublicPin = root.findViewById(R.id.sw_public_pin);
        etPublicPin = root.findViewById(R.id.et_public_pin);
        etPublicCoverAsset = root.findViewById(R.id.et_public_cover_asset);
    }

    private void setupUi() {
        toggleShareType.check(INITIAL_TAB_PUBLIC.equals(initialTab) ? R.id.btn_tab_public : R.id.btn_tab_internal);
        toggleShareType.addOnButtonCheckedListener((group, checkedId, isChecked) -> {
            if (!isChecked) return;
            applyShareTabVisibility(checkedId == R.id.btn_tab_internal);
        });
        applyShareTabVisibility(toggleShareType.getCheckedButtonId() == R.id.btn_tab_internal);

        String defaultName = !TextUtils.isEmpty(objectName) ? objectName : "Shared";
        etShareName.setText(defaultName);
        tvShareContext.setText("Sharing: " + objectKind + " \"" + defaultName + "\"");
        if ("asset".equalsIgnoreCase(objectKind)) swInternalIncludeFaces.setVisibility(View.GONE);

        ArrayAdapter<String> permAdapter = new ArrayAdapter<>(
                requireContext(),
                android.R.layout.simple_spinner_item,
                new String[]{"Viewer", "Commenter", "Contributor"}
        );
        permAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spInternalPermissions.setAdapter(permAdapter);
        spPublicRole.setAdapter(permAdapter);

        swInternalExpiry.setOnCheckedChangeListener((b, on) -> btnInternalExpiry.setVisibility(on ? View.VISIBLE : View.GONE));
        swPublicExpiry.setOnCheckedChangeListener((b, on) -> btnPublicExpiry.setVisibility(on ? View.VISIBLE : View.GONE));
        swPublicPin.setOnCheckedChangeListener((b, on) -> etPublicPin.setVisibility(on ? View.VISIBLE : View.GONE));

        btnInternalExpiry.setOnClickListener(v -> pickDate(true));
        btnPublicExpiry.setOnClickListener(v -> pickDate(false));
        btnAddRecipients.setOnClickListener(v -> showRecipientsPicker());

        if (selectionCount > 1) {
            rgPublicMode.setVisibility(View.VISIBLE);
            rgPublicMode.check(R.id.rb_public_selection);
        } else {
            rgPublicMode.setVisibility(View.GONE);
        }

        String defaultCover = !TextUtils.isEmpty(firstSelectedAssetId) ? firstSelectedAssetId
                : ("asset".equalsIgnoreCase(objectKind) ? objectId : "default");
        etPublicCoverAsset.setText(defaultCover);

        btnCreateShare.setOnClickListener(v -> createShare());
    }

    private void applyShareTabVisibility(boolean internal) {
        sectionInternal.setVisibility(internal ? View.VISIBLE : View.GONE);
        sectionPublic.setVisibility(internal ? View.GONE : View.VISIBLE);
        btnCreateShare.setText(internal ? "Create" : "Create Link");
    }

    private void pickDate(boolean internal) {
        Calendar now = Calendar.getInstance();
        DatePickerDialog dlg = new DatePickerDialog(
                requireContext(),
                (view, year, month, dayOfMonth) -> {
                    Calendar c = Calendar.getInstance();
                    c.set(Calendar.YEAR, year);
                    c.set(Calendar.MONTH, month);
                    c.set(Calendar.DAY_OF_MONTH, dayOfMonth);
                    c.set(Calendar.HOUR_OF_DAY, 23);
                    c.set(Calendar.MINUTE, 59);
                    c.set(Calendar.SECOND, 59);
                    String text = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(c.getTime());
                    if (internal) {
                        internalExpiryDate = c;
                        btnInternalExpiry.setText(text);
                    } else {
                        publicExpiryDate = c;
                        btnPublicExpiry.setText(text);
                    }
                },
                now.get(Calendar.YEAR),
                now.get(Calendar.MONTH),
                now.get(Calendar.DAY_OF_MONTH)
        );
        dlg.show();
    }

    private void showRecipientsPicker() {
        if (availableTargets.isEmpty()) {
            loadShareTargetsAndThen(this::showRecipientsPicker);
            return;
        }
        int n = availableTargets.size();
        String[] labels = new String[n];
        boolean[] checked = new boolean[n];
        for (int i = 0; i < n; i++) {
            ShareModels.ShareTarget t = availableTargets.get(i);
            labels[i] = t.label + (t.email != null ? (" (" + t.email + ")") : "");
            checked[i] = containsSelectedTarget(t);
        }
        new AlertDialog.Builder(requireContext())
                .setTitle("Select Recipients")
                .setMultiChoiceItems(labels, checked, (dialog, which, isChecked) -> checked[which] = isChecked)
                .setPositiveButton("Done", (dialog, which) -> {
                    selectedTargets.clear();
                    for (int i = 0; i < n; i++) {
                        if (checked[i]) selectedTargets.add(availableTargets.get(i));
                    }
                    renderRecipientChips();
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private boolean containsSelectedTarget(ShareModels.ShareTarget t) {
        String key = recipientKey(t);
        for (ShareModels.ShareTarget s : selectedTargets) {
            if (recipientKey(s).equals(key)) return true;
        }
        return false;
    }

    private String recipientKey(ShareModels.ShareTarget t) {
        return t.kind + ":" + (t.id != null ? t.id : (t.email != null ? t.email : t.label));
    }

    private void renderRecipientChips() {
        chipsRecipients.removeAllViews();
        for (ShareModels.ShareTarget t : selectedTargets) {
            Chip c = new Chip(requireContext());
            c.setText(t.label);
            c.setCloseIconVisible(true);
            c.setOnCloseIconClickListener(v -> {
                selectedTargets.remove(t);
                renderRecipientChips();
            });
            chipsRecipients.addView(c);
        }
    }

    private void loadShareTargetsAndThen(Runnable done) {
        new Thread(() -> {
            try {
                List<ShareModels.ShareTarget> targets = new ServerPhotosService(appContext).listShareTargets(null);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    availableTargets.clear();
                    availableTargets.addAll(targets);
                    done.run();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() ->
                        android.widget.Toast.makeText(requireContext(), "Failed to load recipients", android.widget.Toast.LENGTH_LONG).show()
                );
            }
        }).start();
    }

    private void createShare() {
        if (creating) return;
        String name = etShareName.getText() != null ? etShareName.getText().toString().trim() : "";
        if (name.isEmpty()) {
            android.widget.Toast.makeText(requireContext(), "Share name is required", android.widget.Toast.LENGTH_SHORT).show();
            return;
        }
        boolean internal = toggleShareType.getCheckedButtonId() == R.id.btn_tab_internal;
        if (internal && selectedTargets.isEmpty()) {
            android.widget.Toast.makeText(requireContext(), "Select at least one recipient", android.widget.Toast.LENGTH_SHORT).show();
            return;
        }
        if (!internal && swPublicPin.isChecked()) {
            String pin = etPublicPin.getText() != null ? etPublicPin.getText().toString() : "";
            if (pin.length() != 8) {
                android.widget.Toast.makeText(requireContext(), "PIN must be exactly 8 characters", android.widget.Toast.LENGTH_SHORT).show();
                return;
            }
        }

        creating = true;
        btnCreateShare.setEnabled(false);
        new Thread(() -> {
            if (internal) runInternalCreate(name); else runPublicCreate(name);
        }).start();
    }

    private void runInternalCreate(String name) {
        try {
            ServerPhotosService svc = new ServerPhotosService(appContext);
            ShareModels.CreateShareRequest req = new ShareModels.CreateShareRequest();
            req.objectKind = objectKind;
            req.objectId = objectId;
            req.name = name;
            req.defaultPermissions = ShareModels.permissionForRole(selectedRole(spInternalPermissions));
            req.includeFaces = swInternalIncludeFaces.isChecked();
            req.includeSubtree = false;
            req.expiresAt = swInternalExpiry.isChecked() ? formatCalendarDate(internalExpiryDate) : null;
            for (ShareModels.ShareTarget t : selectedTargets) {
                req.recipients.add(new ShareModels.RecipientInput(
                        t.kind,
                        t.id,
                        t.email,
                        null
                ));
            }
            JSONObject createdRaw = svc.createShare(req);
            ShareModels.ShareItem created = ShareModels.ShareItem.fromJson(createdRaw);
            if (!created.id.isEmpty()) {
                try { prepareInternalShareE2ee(svc, created.id); } catch (Exception ignored) {}
            }
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> {
                shareCreated = true;
                emitShareCreatedResult("internal", created.id, null);
                android.widget.Toast.makeText(requireContext(), "Share created", android.widget.Toast.LENGTH_SHORT).show();
                dismissAllowingStateLoss();
            });
        } catch (Exception e) {
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> onCreateFailed("Share creation failed"));
        }
    }

    private void runPublicCreate(String name) {
        Integer createdAlbumForPublic = null;
        Integer cleanupAlbumAfterSuccess = null;
        try {
            ServerPhotosService svc = new ServerPhotosService(appContext);
            String scopeKind = "album";
            Integer scopeAlbumId;
            boolean firstItemMode = selectionCount > 1 && rgPublicMode.getVisibility() == View.VISIBLE
                    && rgPublicMode.getCheckedRadioButtonId() == R.id.rb_public_first_item;

            if (firstItemMode) {
                String firstAsset = !TextUtils.isEmpty(firstSelectedAssetId) ? firstSelectedAssetId : objectId;
                String firstAlbumName = name + " (first item)";
                JSONObject album = svc.createAlbum(firstAlbumName, "Auto-created for public link", null);
                createdAlbumForPublic = album.optInt("id", 0);
                if (createdAlbumForPublic == null || createdAlbumForPublic <= 0) throw new IllegalStateException("Album create failed");
                List<Integer> ids = resolvePhotoIds(svc, java.util.Collections.singletonList(firstAsset));
                if (ids.isEmpty()) throw new IllegalStateException("Missing photo id");
                svc.addPhotosToAlbum(createdAlbumForPublic, ids);
                scopeAlbumId = createdAlbumForPublic;
                if (tempAlbumId != null && tempAlbumId > 0) {
                    cleanupAlbumAfterSuccess = tempAlbumId;
                }
            } else if ("album".equalsIgnoreCase(objectKind)) {
                scopeAlbumId = Integer.parseInt(objectId);
            } else {
                JSONObject album = svc.createAlbum(name, "Auto-created for public link", null);
                createdAlbumForPublic = album.optInt("id", 0);
                if (createdAlbumForPublic == null || createdAlbumForPublic <= 0) throw new IllegalStateException("Album create failed");
                List<Integer> ids = resolvePhotoIds(svc, java.util.Collections.singletonList(objectId));
                if (ids.isEmpty()) throw new IllegalStateException("Missing photo id");
                svc.addPhotosToAlbum(createdAlbumForPublic, ids);
                scopeAlbumId = createdAlbumForPublic;
            }

            ShareModels.CreatePublicLinkRequest req = new ShareModels.CreatePublicLinkRequest();
            req.name = name;
            req.scopeKind = scopeKind;
            req.scopeAlbumId = scopeAlbumId;
            req.permissions = ShareModels.permissionForRole(selectedRole(spPublicRole));
            req.expiresAt = swPublicExpiry.isChecked() ? formatCalendarDate(publicExpiryDate) : null;
            req.pin = swPublicPin.isChecked() ? etPublicPin.getText().toString() : null;
            req.coverAssetId = nonEmptyOrDefault(etPublicCoverAsset.getText() != null ? etPublicCoverAsset.getText().toString().trim() : "", "default");
            req.moderationEnabled = swPublicModeration.isChecked();

            JSONObject resp = svc.createPublicLink(req);
            ShareModels.CreatePublicLinkResponse link = ShareModels.CreatePublicLinkResponse.fromJson(resp);
            String finalUrl = link.url;
            try {
                ShareE2eePublicResult ee = preparePublicLinkE2ee(svc, link.id, scopeAlbumId, req.coverAssetId, link.url);
                if (ee != null) {
                    finalUrl = ee.urlWithVk;
                }
            } catch (Exception ignored) {
            }
            if (cleanupAlbumAfterSuccess != null
                    && cleanupAlbumAfterSuccess > 0
                    && (createdAlbumForPublic == null || !cleanupAlbumAfterSuccess.equals(createdAlbumForPublic))) {
                try { svc.deleteAlbum(cleanupAlbumAfterSuccess); } catch (Exception ignored) {}
                tempAlbumId = null;
            }
            if (!isAdded()) return;
            final String showUrl = finalUrl;
            requireActivity().runOnUiThread(() -> {
                shareCreated = true;
                emitShareCreatedResult("public", link.id, showUrl);
                showPublicLinkResult(link.id, showUrl);
            });
        } catch (Exception e) {
            if (createdAlbumForPublic != null && createdAlbumForPublic > 0) {
                try { new ServerPhotosService(appContext).deleteAlbum(createdAlbumForPublic); } catch (Exception ignored) {}
            }
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> onCreateFailed("Public link creation failed"));
        }
    }

    private void emitShareCreatedResult(@NonNull String type, @Nullable String id, @Nullable String url) {
        Bundle b = new Bundle();
        b.putString("type", type);
        if (id != null) b.putString("id", id);
        if (url != null) b.putString("url", url);
        getParentFragmentManager().setFragmentResult(KEY_SHARE_CREATED, b);
    }

    private void prepareInternalShareE2ee(@NonNull ServerPhotosService svc, @NonNull String shareId) throws Exception {
        List<String> lockedAssetIds = collectLockedAssetIdsForScope(svc);
        if (lockedAssetIds.isEmpty()) return;

        byte[] umk = ShareE2EEManager.currentUmk(appContext);
        if (umk == null) return;

        String ownerUserId = AuthManager.get(appContext).getUserId();
        if (ownerUserId == null) ownerUserId = "";

        ShareE2EEManager e2ee = ShareE2EEManager.get(appContext);
        e2ee.ensureIdentityKeyPair();

        byte[] smk = new byte[32];
        new java.security.SecureRandom().nextBytes(smk);

        ArrayList<String> recipientUserIds = new ArrayList<>();
        for (ShareModels.ShareTarget t : selectedTargets) {
            if ("user".equalsIgnoreCase(t.kind) && t.id != null && !t.id.isEmpty()) recipientUserIds.add(t.id);
        }
        if (!recipientUserIds.isEmpty()) {
            e2ee.uploadShareRecipientEnvelopes(shareId, recipientUserIds, smk);
        }

        List<ShareModels.DekWrap> wraps = new ArrayList<>();
        wraps.addAll(e2ee.buildWrapsForShare(lockedAssetIds, umk, smk, "thumb", ownerUserId));
        wraps.addAll(e2ee.buildWrapsForShare(lockedAssetIds, umk, smk, "orig", ownerUserId));
        if (!wraps.isEmpty()) e2ee.uploadShareWraps(shareId, wraps);
    }

    @Nullable
    private ShareE2eePublicResult preparePublicLinkE2ee(
            @NonNull ServerPhotosService svc,
            @NonNull String linkId,
            @Nullable Integer scopeAlbumId,
            @Nullable String coverAssetId,
            @Nullable String baseUrl
    ) throws Exception {
        List<String> lockedAssetIds = new ArrayList<>();
        if (scopeAlbumId != null && scopeAlbumId > 0) {
            lockedAssetIds.addAll(listAlbumAssetIds(svc, scopeAlbumId, true));
        } else if (coverAssetId != null && !coverAssetId.isEmpty()) {
            org.json.JSONArray arr = svc.getPhotosByAssetIds(java.util.Collections.singletonList(coverAssetId), true);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject p = arr.optJSONObject(i);
                if (p != null && p.optBoolean("locked", false)) lockedAssetIds.add(p.optString("asset_id", ""));
            }
        }
        for (int i = lockedAssetIds.size() - 1; i >= 0; i--) {
            String s = lockedAssetIds.get(i);
            if (s == null || s.isEmpty()) lockedAssetIds.remove(i);
        }
        if (lockedAssetIds.isEmpty()) return null;

        byte[] umk = ShareE2EEManager.currentUmk(appContext);
        if (umk == null) return null;

        String ownerUserId = AuthManager.get(appContext).getUserId();
        if (ownerUserId == null) ownerUserId = "";

        ShareE2EEManager e2ee = ShareE2EEManager.get(appContext);
        ShareE2EEManager.PublicLinkKeys keys = e2ee.generatePublicLinkKeys();
        JSONObject env = e2ee.createPublicLinkEnvelope(keys.smk, keys.vk);
        e2ee.uploadPublicLinkEnvelope(linkId, env);
        List<ShareModels.DekWrap> wraps = e2ee.buildWrapsForPublicLink(lockedAssetIds, umk, keys.smk, ownerUserId);
        if (!wraps.isEmpty()) e2ee.uploadPublicLinkWraps(linkId, wraps);

        String vk = keys.vkB64Url();
        appContext.getSharedPreferences("ee.share.public", Context.MODE_PRIVATE)
                .edit()
                .putString("vk." + linkId, vk)
                .apply();
        return new ShareE2eePublicResult(vk, ShareE2EEManager.appendVkToUrl(baseUrl, vk));
    }

    private List<String> collectLockedAssetIdsForScope(@NonNull ServerPhotosService svc) throws Exception {
        if ("asset".equalsIgnoreCase(objectKind)) {
            org.json.JSONArray arr = svc.getPhotosByAssetIds(java.util.Collections.singletonList(objectId), true);
            ArrayList<String> ids = new ArrayList<>();
            for (int i = 0; i < arr.length(); i++) {
                JSONObject p = arr.optJSONObject(i);
                if (p != null && p.optBoolean("locked", false)) ids.add(p.optString("asset_id", ""));
            }
            for (int i = ids.size() - 1; i >= 0; i--) {
                String s = ids.get(i);
                if (s == null || s.isEmpty()) ids.remove(i);
            }
            return ids;
        }
        if ("album".equalsIgnoreCase(objectKind)) {
            int albumId = Integer.parseInt(objectId);
            return listAlbumAssetIds(svc, albumId, true);
        }
        return new ArrayList<>();
    }

    private List<String> listAlbumAssetIds(@NonNull ServerPhotosService svc, int albumId, boolean lockedOnly) throws Exception {
        ArrayList<String> out = new ArrayList<>();
        int p = 1;
        while (true) {
            JSONObject resp = svc.listPhotos(albumId, null, lockedOnly ? Boolean.TRUE : null, p, 200);
            org.json.JSONArray photos = resp.optJSONArray("photos");
            if (photos == null || photos.length() == 0) break;
            for (int i = 0; i < photos.length(); i++) {
                JSONObject row = photos.optJSONObject(i);
                if (row == null) continue;
                String aid = row.optString("asset_id", "");
                if (!aid.isEmpty()) out.add(aid);
            }
            boolean more = resp.optBoolean("has_more", false);
            if (!more) break;
            p++;
        }
        return out;
    }

    private static final class ShareE2eePublicResult {
        final String vk;
        @Nullable final String urlWithVk;

        ShareE2eePublicResult(String vk, @Nullable String urlWithVk) {
            this.vk = vk;
            this.urlWithVk = urlWithVk;
        }
    }

    private List<Integer> resolvePhotoIds(ServerPhotosService svc, List<String> assetIds) throws Exception {
        org.json.JSONArray arr = svc.getPhotosByAssetIds(assetIds, true);
        List<Integer> ids = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject p = arr.getJSONObject(i);
            int id = p.optInt("id", 0);
            if (id > 0) ids.add(id);
        }
        return ids;
    }

    private String selectedRole(Spinner spinner) {
        Object item = spinner.getSelectedItem();
        if (item == null) return "viewer";
        String t = String.valueOf(item).toLowerCase(Locale.US);
        if (t.contains("contributor")) return "contributor";
        if (t.contains("comment")) return "commenter";
        return "viewer";
    }

    @Nullable
    private String formatCalendarDate(@Nullable Calendar c) {
        if (c == null) return null;
        return new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(c.getTime());
    }

    private String nonEmptyOrDefault(String value, String fallback) {
        return value == null || value.isEmpty() ? fallback : value;
    }

    private void showPublicLinkResult(@Nullable String linkId, @Nullable String url) {
        String rawUrl = url;
        if ((rawUrl == null || rawUrl.isEmpty()) && linkId != null && !linkId.isEmpty()) {
            rawUrl = "Link created with id: " + linkId;
        }
        final String showUrl = rawUrl == null ? "" : rawUrl;
        new AlertDialog.Builder(requireContext())
                .setTitle("Public Link Created")
                .setMessage(showUrl)
                .setPositiveButton("Done", (d, w) -> dismissAllowingStateLoss())
                .setNeutralButton("Copy", (d, w) -> {
                    ClipboardManager cm = (ClipboardManager) requireContext().getSystemService(Context.CLIPBOARD_SERVICE);
                    if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("public_link", showUrl));
                    android.widget.Toast.makeText(requireContext(), "Copied", android.widget.Toast.LENGTH_SHORT).show();
                })
                .setNegativeButton("Open", (d, w) -> {
                    try {
                        startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(showUrl)));
                    } catch (Exception ignored) {}
                    dismissAllowingStateLoss();
                })
                .show();
    }

    private void onCreateFailed(String msg) {
        creating = false;
        btnCreateShare.setEnabled(true);
        android.widget.Toast.makeText(requireContext(), msg, android.widget.Toast.LENGTH_LONG).show();
    }

    private void cleanupTempAlbumIfNeeded() {
        if (shareCreated || appContext == null) return;
        if (tempAlbumId == null || tempAlbumId <= 0) return;
        final int id = tempAlbumId;
        new Thread(() -> {
            try {
                new ServerPhotosService(appContext).deleteAlbum(id);
            } catch (Exception ignored) {}
        }).start();
    }
}
