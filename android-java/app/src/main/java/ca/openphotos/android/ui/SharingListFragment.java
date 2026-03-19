package ca.openphotos.android.ui;

import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.text.InputType;
import android.view.LayoutInflater;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.DialogFragment;
import androidx.fragment.app.Fragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;

import ca.openphotos.android.R;
import ca.openphotos.android.e2ee.ShareE2EEManager;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.server.ShareModels;
import com.google.android.material.button.MaterialButton;

import java.io.File;
import java.io.FileOutputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** One sharing tab page (My Shares / Shared with me / Public Links). */
public class SharingListFragment extends Fragment {
    public static final int MODE_MY_SHARES = 0;
    public static final int MODE_SHARED_WITH_ME = 1;
    public static final int MODE_PUBLIC_LINKS = 2;

    private static final String ARG_MODE = "mode";
    private static final int MENU_LINK_EDIT = 2001;
    private static final int MENU_LINK_COPY = 2002;
    private static final int MENU_LINK_OPEN = 2003;
    private static final int MENU_LINK_SHARE = 2004;
    private static final int MENU_LINK_ROTATE = 2005;
    private static final int MENU_LINK_DELETE = 2006;

    private int mode = MODE_MY_SHARES;
    private SwipeRefreshLayout swipe;
    private RecyclerView recycler;
    private View emptyState;
    private TextView emptyTitle;
    private TextView emptyMessage;
    private MaterialButton btnEmptyAction;
    private View loading;

    private final List<ShareModels.ShareItem> shares = new ArrayList<>();
    private final List<ShareModels.PublicLinkItem> links = new ArrayList<>();
    private final ExecutorService coverExecutor = Executors.newFixedThreadPool(4);

    private ShareCardAdapter shareAdapter;
    private PublicLinkAdapter linkAdapter;
    private volatile boolean loadInFlight = false;

    public static SharingListFragment newInstance(int mode) {
        SharingListFragment f = new SharingListFragment();
        Bundle b = new Bundle();
        b.putInt(ARG_MODE, mode);
        f.setArguments(b);
        return f;
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        if (getArguments() != null) mode = getArguments().getInt(ARG_MODE, MODE_MY_SHARES);
        View root = inflater.inflate(R.layout.fragment_sharing_list, container, false);
        swipe = root.findViewById(R.id.swipe);
        recycler = root.findViewById(R.id.recycler);
        emptyState = root.findViewById(R.id.empty_state);
        emptyTitle = root.findViewById(R.id.empty_title);
        emptyMessage = root.findViewById(R.id.empty_message);
        btnEmptyAction = root.findViewById(R.id.btn_empty_action);
        loading = root.findViewById(R.id.loading);

        if (mode == MODE_PUBLIC_LINKS) {
            recycler.setLayoutManager(new LinearLayoutManager(requireContext()));
            linkAdapter = new PublicLinkAdapter();
            linkAdapter.setListener(new PublicLinkAdapter.Listener() {
                @Override
                public void onOpenMenu(View anchor, ShareModels.PublicLinkItem link) {
                    showPublicLinkMenu(anchor, link);
                }
            });
            recycler.setAdapter(linkAdapter);
        } else {
            recycler.setLayoutManager(new GridLayoutManager(requireContext(), 2));
            shareAdapter = new ShareCardAdapter();
            shareAdapter.setOwnerMode(mode == MODE_MY_SHARES);
            shareAdapter.setListener(new ShareCardAdapter.Listener() {
                @Override
                public void onOpen(ShareModels.ShareItem share) {
                    openShareViewer(share);
                }

                @Override
                public void onOpenMenu(View anchor, ShareModels.ShareItem share) {
                    showShareMenu(anchor, share);
                }
            });
            recycler.setAdapter(shareAdapter);
        }

        swipe.setOnRefreshListener(() -> loadData(true));

        if (mode == MODE_SHARED_WITH_ME) {
            emptyTitle.setText("No shared items");
            emptyMessage.setText("When someone shares with you, it appears here.");
            btnEmptyAction.setVisibility(View.GONE);
        } else if (mode == MODE_PUBLIC_LINKS) {
            emptyTitle.setText("No public links");
            emptyMessage.setText("Create a public link from an album.");
            btnEmptyAction.setText("Create Public Link");
            btnEmptyAction.setVisibility(View.VISIBLE);
            btnEmptyAction.setOnClickListener(v -> launchCreateFromParent(true));
        } else {
            emptyTitle.setText("No shares");
            emptyMessage.setText("Create an internal share for an album.");
            btnEmptyAction.setText("Create Share");
            btnEmptyAction.setVisibility(View.VISIBLE);
            btnEmptyAction.setOnClickListener(v -> launchCreateFromParent(false));
        }

        loadData(false);
        return root;
    }

    @Override
    public void onDestroyView() {
        super.onDestroyView();
        coverExecutor.shutdownNow();
    }

    public void refreshNow() {
        loadData(true);
    }

    private void loadData(boolean manualRefresh) {
        if (loadInFlight) return;
        loadInFlight = true;
        if (!manualRefresh) loading.setVisibility(View.VISIBLE);

        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                if (mode == MODE_PUBLIC_LINKS) {
                    List<ShareModels.PublicLinkItem> list = svc.listPublicLinks();
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        links.clear();
                        links.addAll(list);
                        linkAdapter.submit(links);
                        renderStates();
                    });
                } else {
                    List<ShareModels.ShareItem> list = mode == MODE_MY_SHARES
                            ? svc.listOutgoingShares()
                            : svc.listReceivedShares();
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        shares.clear();
                        shares.addAll(list);
                        shareAdapter.submit(shares);
                        renderStates();
                        preloadCoversForShares(list);
                    });
                }
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) {
                        notifyUnauthorized();
                        return;
                    }
                    Toast.makeText(requireContext(), "Failed to load sharing data", Toast.LENGTH_LONG).show();
                    renderStates();
                });
            } finally {
                loadInFlight = false;
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    swipe.setRefreshing(false);
                    loading.setVisibility(View.GONE);
                });
            }
        }).start();
    }

    private void renderStates() {
        boolean empty;
        if (mode == MODE_PUBLIC_LINKS) {
            empty = links.isEmpty();
            linkAdapter.notifyDataSetChanged();
        } else {
            empty = shares.isEmpty();
            shareAdapter.notifyDataSetChanged();
        }
        emptyState.setVisibility(empty ? View.VISIBLE : View.GONE);
        swipe.setVisibility(empty ? View.GONE : View.VISIBLE);
    }

    private void preloadCoversForShares(List<ShareModels.ShareItem> list) {
        for (ShareModels.ShareItem share : list) {
            coverExecutor.execute(() -> {
                try {
                    CoverData cd = loadCover(share);
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> shareAdapter.updateCover(share.id, cd.bitmap, cd.assetId));
                } catch (Exception ignored) {
                }
            });
        }
    }

    private CoverData loadCover(ShareModels.ShareItem share) {
        ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
        try {
            ShareModels.ShareAssetsPage p = svc.listShareAssets(share.id, 1, 1, "newest");
            if (p.assetIds.isEmpty()) return new CoverData(null, null);
            String aid = p.assetIds.get(0);
            byte[] bytes = svc.getShareAssetThumbnailData(share.id, aid);
            byte[] plain = bytes;
            try {
                plain = ShareE2EEManager.get(requireContext().getApplicationContext())
                        .decryptShareContainer(share.id, aid, "thumb", bytes);
            } catch (Exception ignored) {
            }
            Bitmap bmp = decodeBitmap(plain);
            if (bmp == null) bmp = decodeVideoFrame(plain);
            return new CoverData(bmp, aid);
        } catch (Exception e) {
            return new CoverData(null, null);
        }
    }

    private void openShareViewer(@NonNull ShareModels.ShareItem share) {
        Fragment p = getParentFragment();
        if (p instanceof SharingDialogFragment) {
            ((SharingDialogFragment) p).openShareViewer(share.id, share.name, share.defaultPermissions, share.includeFaces);
        }
    }

    private void showShareMenu(View anchor, ShareModels.ShareItem share) {
        PopupMenu pm = new PopupMenu(requireContext(), anchor);
        pm.getMenu().add(0, 1001, 0, "Open");
        pm.getMenu().add(0, 1002, 1, "Edit");
        pm.getMenu().add(0, 1003, 2, "Recipients");
        pm.getMenu().add(0, 1004, 3, "Revoke");
        pm.setOnMenuItemClickListener(item -> {
            int id = item.getItemId();
            if (id == 1001) {
                openShareViewer(share);
                return true;
            }
            if (id == 1002) {
                showEditShareDialog(share);
                return true;
            }
            if (id == 1003) {
                showRecipientsDialog(share);
                return true;
            }
            if (id == 1004) {
                confirmRevokeShare(share);
                return true;
            }
            return false;
        });
        pm.show();
    }

    private void showEditShareDialog(ShareModels.ShareItem share) {
        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(14);
        root.setPadding(pad, pad, pad, pad);

        EditText etName = new EditText(requireContext());
        etName.setHint("Name");
        etName.setText(share.name);
        root.addView(etName, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        Spinner spRole = new Spinner(requireContext());
        ArrayAdapter<String> roleAdapter = new ArrayAdapter<>(
                requireContext(),
                android.R.layout.simple_spinner_item,
                new String[]{"Viewer", "Commenter", "Contributor"}
        );
        roleAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spRole.setAdapter(roleAdapter);
        int selection = 0;
        if (share.defaultPermissions == (ShareModels.PERM_VIEW | ShareModels.PERM_COMMENT | ShareModels.PERM_LIKE)) selection = 1;
        if (share.defaultPermissions == (ShareModels.PERM_VIEW | ShareModels.PERM_COMMENT | ShareModels.PERM_LIKE | ShareModels.PERM_UPLOAD)) selection = 2;
        spRole.setSelection(selection);
        root.addView(spRole, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        CheckBox cbFaces = new CheckBox(requireContext());
        cbFaces.setText("Include faces");
        cbFaces.setChecked(share.includeFaces);
        root.addView(cbFaces, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        EditText etExpiry = new EditText(requireContext());
        etExpiry.setHint("Expiry date (YYYY-MM-DD, optional)");
        etExpiry.setInputType(InputType.TYPE_CLASS_DATETIME);
        if (share.expiresAt != null && share.expiresAt.length() >= 10) etExpiry.setText(share.expiresAt.substring(0, 10));
        root.addView(etExpiry, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        new AlertDialog.Builder(requireContext())
                .setTitle("Edit Share")
                .setView(root)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Save", (d, w) -> {
                    new Thread(() -> {
                        try {
                            ShareModels.UpdateShareRequest req = new ShareModels.UpdateShareRequest();
                            req.name = textOf(etName);
                            req.includeFaces = cbFaces.isChecked();
                            req.defaultPermissions = permissionsFromSpinner(spRole);
                            String expiry = textOf(etExpiry);
                            req.expiresAt = expiry.isEmpty() ? null : expiry;
                            ShareModels.ShareItem updated = new ServerPhotosService(requireContext().getApplicationContext())
                                    .updateShare(share.id, req);
                            if (!isAdded()) return;
                            requireActivity().runOnUiThread(() -> {
                                replaceShare(updated);
                                Toast.makeText(requireContext(), "Share updated", Toast.LENGTH_SHORT).show();
                            });
                        } catch (Exception e) {
                            if (!isAdded()) return;
                            requireActivity().runOnUiThread(() -> {
                                if (ShareE2EEManager.isUnauthorizedError(e)) {
                                    notifyUnauthorized();
                                } else {
                                    Toast.makeText(requireContext(), "Update failed", Toast.LENGTH_LONG).show();
                                }
                            });
                        }
                    }).start();
                })
                .show();
    }

    private void showRecipientsDialog(ShareModels.ShareItem share) {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                ShareModels.ShareItem fresh = svc.getShare(share.id);
                Map<String, String> userLabelsById = new HashMap<>();
                Map<Integer, String> groupLabelsById = new HashMap<>();
                try {
                    List<ShareModels.ShareTarget> targets = svc.listShareTargets(null);
                    for (ShareModels.ShareTarget t : targets) {
                        if (t == null) continue;
                        String label = formatShareTargetLabel(t);
                        if ("user".equalsIgnoreCase(t.kind) && t.id != null && !t.id.trim().isEmpty()) {
                            userLabelsById.put(t.id.trim(), label);
                        } else if ("group".equalsIgnoreCase(t.kind) && t.id != null) {
                            try {
                                groupLabelsById.put(Integer.parseInt(t.id.trim()), label);
                            } catch (Exception ignored) {
                            }
                        }
                    }
                } catch (Exception ignored) {
                    // Best-effort enhancement; fallback label remains recipient id.
                }
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    List<ShareModels.ShareRecipient> recs = fresh.recipients != null ? fresh.recipients : Collections.emptyList();
                    String[] labels = new String[recs.size()];
                    boolean[] checked = new boolean[recs.size()];
                    for (int i = 0; i < recs.size(); i++) {
                        ShareModels.ShareRecipient r = recs.get(i);
                        String who = resolveRecipientLabel(r, userLabelsById, groupLabelsById);
                        labels[i] = who + " (" + ShareModels.roleName(r.permissions != null ? r.permissions : fresh.defaultPermissions) + ")";
                    }

                    AlertDialog.Builder b = new AlertDialog.Builder(requireContext())
                            .setTitle("Recipients")
                            .setMultiChoiceItems(labels, checked, (d, which, isChecked) -> checked[which] = isChecked)
                            .setNegativeButton("Close", null)
                            .setNeutralButton("Add", (d, which) -> showAddRecipientsDialog(fresh.id))
                            .setPositiveButton("Remove", (d, which) -> removeCheckedRecipients(fresh.id, recs, checked));
                    b.show();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) notifyUnauthorized();
                    else Toast.makeText(requireContext(), "Failed to load recipients", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    @NonNull
    private static String resolveRecipientLabel(
            @NonNull ShareModels.ShareRecipient recipient,
            @NonNull Map<String, String> userLabelsById,
            @NonNull Map<Integer, String> groupLabelsById
    ) {
        if ("user".equalsIgnoreCase(recipient.recipientType)) {
            String uid = trimToNull(recipient.recipientUserId);
            if (uid != null) {
                String mapped = userLabelsById.get(uid);
                if (mapped != null && !mapped.trim().isEmpty()) return mapped;
            }
            String fallback = trimToNull(recipient.displayLabel());
            return fallback != null ? fallback : "User";
        }
        if ("group".equalsIgnoreCase(recipient.recipientType)) {
            Integer gid = recipient.recipientGroupId;
            if (gid != null) {
                String mapped = groupLabelsById.get(gid);
                if (mapped != null && !mapped.trim().isEmpty()) return mapped;
            }
            String fallback = trimToNull(recipient.displayLabel());
            return fallback != null ? fallback : "Group";
        }
        String fallback = trimToNull(recipient.displayLabel());
        return fallback != null ? fallback : "Recipient";
    }

    @NonNull
    private static String formatShareTargetLabel(@NonNull ShareModels.ShareTarget target) {
        String label = trimToNull(target.label);
        String email = trimToNull(target.email);
        if (label != null && email != null && !label.equalsIgnoreCase(email)) {
            return label + " (" + email + ")";
        }
        if (label != null) return label;
        if (email != null) return email;
        String id = trimToNull(target.id);
        if (id != null) return id;
        return "Recipient";
    }

    @Nullable
    private static String trimToNull(@Nullable String s) {
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }

    private void removeCheckedRecipients(String shareId, List<ShareModels.ShareRecipient> recs, boolean[] checked) {
        new Thread(() -> {
            int removed = 0;
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                for (int i = 0; i < recs.size(); i++) {
                    if (!checked[i]) continue;
                    try {
                        svc.removeRecipient(shareId, recs.get(i).id);
                        removed++;
                    } catch (Exception ignored) {
                    }
                }
                int done = removed;
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    Toast.makeText(requireContext(), "Removed " + done + " recipient(s)", Toast.LENGTH_SHORT).show();
                    refreshNow();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) notifyUnauthorized();
                    else Toast.makeText(requireContext(), "Remove recipients failed", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void showAddRecipientsDialog(String shareId) {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                List<ShareModels.ShareTarget> targets = svc.listShareTargets(null);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (targets.isEmpty()) {
                        Toast.makeText(requireContext(), "No recipients available", Toast.LENGTH_SHORT).show();
                        return;
                    }
                    String[] labels = new String[targets.size()];
                    boolean[] checked = new boolean[targets.size()];
                    for (int i = 0; i < targets.size(); i++) {
                        ShareModels.ShareTarget t = targets.get(i);
                        labels[i] = t.label + (t.email != null ? (" (" + t.email + ")") : "");
                    }
                    new AlertDialog.Builder(requireContext())
                            .setTitle("Add Recipients")
                            .setMultiChoiceItems(labels, checked, (d, which, isChecked) -> checked[which] = isChecked)
                            .setNegativeButton("Cancel", null)
                            .setPositiveButton("Add", (d, which) -> addCheckedRecipients(shareId, targets, checked))
                            .show();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) notifyUnauthorized();
                    else Toast.makeText(requireContext(), "Failed to load share targets", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void addCheckedRecipients(String shareId, List<ShareModels.ShareTarget> targets, boolean[] checked) {
        new Thread(() -> {
            try {
                ArrayList<ShareModels.RecipientInput> add = new ArrayList<>();
                for (int i = 0; i < targets.size(); i++) {
                    if (!checked[i]) continue;
                    ShareModels.ShareTarget t = targets.get(i);
                    add.add(new ShareModels.RecipientInput(t.kind, t.id, t.email, null));
                }
                if (add.isEmpty()) return;
                new ServerPhotosService(requireContext().getApplicationContext()).addRecipients(shareId, add);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    Toast.makeText(requireContext(), "Recipients added", Toast.LENGTH_SHORT).show();
                    refreshNow();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) notifyUnauthorized();
                    else Toast.makeText(requireContext(), "Add recipients failed", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void confirmRevokeShare(ShareModels.ShareItem share) {
        new AlertDialog.Builder(requireContext())
                .setTitle("Revoke Share")
                .setMessage("Revoke this share? Recipients will lose access.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Revoke", (d, w) -> {
                    new Thread(() -> {
                        try {
                            new ServerPhotosService(requireContext().getApplicationContext()).deleteShare(share.id);
                            if (!isAdded()) return;
                            requireActivity().runOnUiThread(() -> {
                                shares.remove(share);
                                shareAdapter.submit(shares);
                                renderStates();
                                Toast.makeText(requireContext(), "Share revoked", Toast.LENGTH_SHORT).show();
                            });
                        } catch (Exception e) {
                            if (!isAdded()) return;
                            requireActivity().runOnUiThread(() -> {
                                if (ShareE2EEManager.isUnauthorizedError(e)) notifyUnauthorized();
                                else Toast.makeText(requireContext(), "Revoke failed", Toast.LENGTH_LONG).show();
                            });
                        }
                    }).start();
                })
                .show();
    }

    private void showPublicLinkMenu(View anchor, ShareModels.PublicLinkItem link) {
        PopupMenu pm = new PopupMenu(requireContext(), anchor);
        Menu m = pm.getMenu();
        m.add(0, MENU_LINK_EDIT, 0, "Edit");
        m.add(0, MENU_LINK_COPY, 1, "Copy URL");
        m.add(0, MENU_LINK_OPEN, 2, "Open URL");
        m.add(0, MENU_LINK_SHARE, 3, "Share URL / QR");
        m.add(0, MENU_LINK_ROTATE, 4, "Rotate Key");
        m.add(0, MENU_LINK_DELETE, 5, "Delete");
        pm.setOnMenuItemClickListener(item -> handlePublicLinkMenuClick(item, link));
        pm.show();
    }

    private boolean handlePublicLinkMenuClick(MenuItem item, ShareModels.PublicLinkItem link) {
        int id = item.getItemId();
        if (id == MENU_LINK_EDIT) {
            showEditPublicLinkDialog(link);
            return true;
        }
        if (id == MENU_LINK_COPY) {
            copyPublicUrl(link);
            return true;
        }
        if (id == MENU_LINK_OPEN) {
            openPublicUrl(link);
            return true;
        }
        if (id == MENU_LINK_SHARE) {
            sharePublicUrl(link);
            return true;
        }
        if (id == MENU_LINK_ROTATE) {
            rotatePublicLink(link);
            return true;
        }
        if (id == MENU_LINK_DELETE) {
            confirmDeletePublicLink(link);
            return true;
        }
        return false;
    }

    private void showEditPublicLinkDialog(ShareModels.PublicLinkItem link) {
        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(14);
        root.setPadding(pad, pad, pad, pad);

        EditText etName = new EditText(requireContext());
        etName.setHint("Name");
        etName.setText(link.name);
        root.addView(etName);

        Spinner spRole = new Spinner(requireContext());
        ArrayAdapter<String> roleAdapter = new ArrayAdapter<>(
                requireContext(),
                android.R.layout.simple_spinner_item,
                new String[]{"Viewer", "Commenter", "Contributor"}
        );
        roleAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spRole.setAdapter(roleAdapter);
        int selection = 0;
        if (link.permissions == (ShareModels.PERM_VIEW | ShareModels.PERM_COMMENT | ShareModels.PERM_LIKE)) selection = 1;
        if (link.permissions == (ShareModels.PERM_VIEW | ShareModels.PERM_COMMENT | ShareModels.PERM_LIKE | ShareModels.PERM_UPLOAD)) selection = 2;
        spRole.setSelection(selection);
        root.addView(spRole);

        CheckBox cbModeration = new CheckBox(requireContext());
        cbModeration.setText("Moderation enabled");
        cbModeration.setChecked(link.moderationEnabled);
        root.addView(cbModeration);

        EditText etExpiry = new EditText(requireContext());
        etExpiry.setHint("Expiry date (YYYY-MM-DD)");
        etExpiry.setInputType(InputType.TYPE_CLASS_DATETIME);
        if (link.expiresAt != null && link.expiresAt.length() >= 10) etExpiry.setText(link.expiresAt.substring(0, 10));
        root.addView(etExpiry);

        CheckBox cbHasPin = new CheckBox(requireContext());
        cbHasPin.setText("Set/replace PIN");
        cbHasPin.setChecked(false);
        root.addView(cbHasPin);

        EditText etPin = new EditText(requireContext());
        etPin.setHint("PIN (8 chars)");
        etPin.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        etPin.setVisibility(View.GONE);
        root.addView(etPin);

        CheckBox cbClearPin = new CheckBox(requireContext());
        cbClearPin.setText("Clear existing PIN");
        cbClearPin.setChecked(false);
        root.addView(cbClearPin);

        EditText etCover = new EditText(requireContext());
        etCover.setHint("Cover asset id");
        etCover.setText(link.coverAssetId != null ? link.coverAssetId : "");
        root.addView(etCover);

        cbHasPin.setOnCheckedChangeListener((b, checked) -> etPin.setVisibility(checked ? View.VISIBLE : View.GONE));

        new AlertDialog.Builder(requireContext())
                .setTitle("Edit Public Link")
                .setView(root)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Save", (d, w) -> {
                    new Thread(() -> {
                        try {
                            ShareModels.UpdatePublicLinkRequest req = new ShareModels.UpdatePublicLinkRequest();
                            req.name = textOf(etName);
                            req.permissions = permissionsFromSpinner(spRole);
                            String exp = textOf(etExpiry);
                            req.expiresAt = exp.isEmpty() ? null : exp;
                            req.moderationEnabled = cbModeration.isChecked();
                            req.coverAssetId = textOf(etCover).isEmpty() ? null : textOf(etCover);
                            req.clearPin = cbClearPin.isChecked();
                            if (cbHasPin.isChecked()) {
                                String p = textOf(etPin);
                                if (p.length() != 8) throw new IllegalStateException("PIN must be 8 chars");
                                req.pin = p;
                            }
                            ShareModels.PublicLinkItem updated = new ServerPhotosService(requireContext().getApplicationContext())
                                    .updatePublicLink(link.id, req);
                            if (!isAdded()) return;
                            requireActivity().runOnUiThread(() -> {
                                replacePublicLink(updated);
                                Toast.makeText(requireContext(), "Public link updated", Toast.LENGTH_SHORT).show();
                            });
                        } catch (Exception e) {
                            if (!isAdded()) return;
                            requireActivity().runOnUiThread(() -> {
                                if (ShareE2EEManager.isUnauthorizedError(e)) notifyUnauthorized();
                                else Toast.makeText(requireContext(), e.getMessage() != null ? e.getMessage() : "Update failed", Toast.LENGTH_LONG).show();
                            });
                        }
                    }).start();
                })
                .show();
    }

    private void rotatePublicLink(ShareModels.PublicLinkItem link) {
        new Thread(() -> {
            try {
                ShareModels.PublicLinkItem rotated = new ServerPhotosService(requireContext().getApplicationContext())
                        .rotatePublicLinkKey(link.id);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    replacePublicLink(rotated);
                    Toast.makeText(requireContext(), "Public link rotated", Toast.LENGTH_SHORT).show();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) notifyUnauthorized();
                    else Toast.makeText(requireContext(), "Rotate failed", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void confirmDeletePublicLink(ShareModels.PublicLinkItem link) {
        new AlertDialog.Builder(requireContext())
                .setTitle("Delete Public Link")
                .setMessage("Delete this public link? Existing URL will stop working.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Delete", (d, w) -> new Thread(() -> {
                    try {
                        new ServerPhotosService(requireContext().getApplicationContext()).deletePublicLink(link.id);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            links.remove(link);
                            linkAdapter.submit(links);
                            renderStates();
                            Toast.makeText(requireContext(), "Public link deleted", Toast.LENGTH_SHORT).show();
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            if (ShareE2EEManager.isUnauthorizedError(e)) notifyUnauthorized();
                            else Toast.makeText(requireContext(), "Delete failed", Toast.LENGTH_LONG).show();
                        });
                    }
                }).start())
                .show();
    }

    private void copyPublicUrl(ShareModels.PublicLinkItem link) {
        String url = withVk(link);
        if (url == null || url.isEmpty()) {
            Toast.makeText(requireContext(), "No URL available", Toast.LENGTH_SHORT).show();
            return;
        }
        ClipboardManager cm = (ClipboardManager) requireContext().getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("public_link", url));
        Toast.makeText(requireContext(), "Copied", Toast.LENGTH_SHORT).show();
    }

    private void openPublicUrl(ShareModels.PublicLinkItem link) {
        String url = withVk(link);
        if (url == null || url.isEmpty()) {
            Toast.makeText(requireContext(), "No URL available", Toast.LENGTH_SHORT).show();
            return;
        }
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (Exception e) {
            Toast.makeText(requireContext(), "Cannot open URL", Toast.LENGTH_SHORT).show();
        }
    }

    private void sharePublicUrl(ShareModels.PublicLinkItem link) {
        String url = withVk(link);
        if (url == null || url.isEmpty()) {
            Toast.makeText(requireContext(), "No URL available", Toast.LENGTH_SHORT).show();
            return;
        }
        PublicLinkQrDialogFragment dlg = PublicLinkQrDialogFragment.newInstance(link.name, url);
        dlg.show(getParentFragmentManager(), "public_link_qr");
    }

    @Nullable
    private String withVk(ShareModels.PublicLinkItem link) {
        String raw = link.url;
        if (raw == null || raw.isEmpty()) return raw;
        String stored = requireContext().getSharedPreferences("ee.share.public", Context.MODE_PRIVATE)
                .getString("vk." + link.id, null);
        if (stored != null && !stored.isEmpty()) {
            return ShareE2EEManager.appendVkToUrl(raw, stored);
        }
        return raw;
    }

    private void replaceShare(ShareModels.ShareItem updated) {
        for (int i = 0; i < shares.size(); i++) {
            if (shares.get(i).id.equals(updated.id)) {
                shares.set(i, updated);
                shareAdapter.submit(shares);
                return;
            }
        }
        shares.add(0, updated);
        shareAdapter.submit(shares);
    }

    private void replacePublicLink(ShareModels.PublicLinkItem updated) {
        for (int i = 0; i < links.size(); i++) {
            if (links.get(i).id.equals(updated.id)) {
                links.set(i, updated);
                linkAdapter.submit(links);
                return;
            }
        }
        links.add(0, updated);
        linkAdapter.submit(links);
    }

    private void launchCreateFromParent(boolean publicTab) {
        try {
            AlbumTreeDialogFragment tree = AlbumTreeDialogFragment.newInstance(false);
            getParentFragmentManager().setFragmentResultListener(AlbumTreeDialogFragment.KEY_SELECT_RESULT, this,
                    (key, bundle) -> {
                        getParentFragmentManager().clearFragmentResultListener(AlbumTreeDialogFragment.KEY_SELECT_RESULT);
                        int albumId = bundle.getInt("album_id", 0);
                        if (albumId <= 0) return;
                        CreateShareDialogFragment dlg = CreateShareDialogFragment.newInstance(
                                "album",
                                String.valueOf(albumId),
                                "Album " + albumId,
                                0,
                                null,
                                null
                        );
                        dlg.setInitialTab(publicTab ? CreateShareDialogFragment.INITIAL_TAB_PUBLIC : CreateShareDialogFragment.INITIAL_TAB_INTERNAL);
                        dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
                        dlg.show(getParentFragmentManager(), "create_share_from_empty");
                    });
            tree.show(getParentFragmentManager(), "sharing_empty_create_album");
        } catch (Exception ignored) {
        }
    }

    private int permissionsFromSpinner(Spinner spinner) {
        int p = spinner.getSelectedItemPosition();
        if (p == 2) return ShareModels.PERM_VIEW | ShareModels.PERM_COMMENT | ShareModels.PERM_LIKE | ShareModels.PERM_UPLOAD;
        if (p == 1) return ShareModels.PERM_VIEW | ShareModels.PERM_COMMENT | ShareModels.PERM_LIKE;
        return ShareModels.PERM_VIEW;
    }

    private String textOf(EditText et) {
        return et.getText() == null ? "" : et.getText().toString().trim();
    }

    private int dp(int v) {
        float d = requireContext().getResources().getDisplayMetrics().density;
        return Math.round(v * d);
    }

    private static Bitmap decodeBitmap(byte[] bytes) {
        if (bytes == null || bytes.length == 0) return null;
        try {
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        } catch (Exception ignored) {
            return null;
        }
    }

    private Bitmap decodeVideoFrame(byte[] bytes) {
        if (bytes == null || bytes.length == 0) return null;
        File tmp = null;
        try {
            tmp = File.createTempFile("share_thumb", ".bin", requireContext().getCacheDir());
            try (FileOutputStream fos = new FileOutputStream(tmp)) {
                fos.write(bytes);
            }
            android.media.MediaMetadataRetriever mmr = new android.media.MediaMetadataRetriever();
            mmr.setDataSource(tmp.getAbsolutePath());
            Bitmap frame = mmr.getFrameAtTime(0);
            mmr.release();
            return frame;
        } catch (Exception ignored) {
            return null;
        } finally {
            if (tmp != null) {
                try {
                    //noinspection ResultOfMethodCallIgnored
                    tmp.delete();
                } catch (Exception ignored) {
                }
            }
        }
    }

    private void notifyUnauthorized() {
        Fragment p = getParentFragment();
        if (p instanceof SharingDialogFragment) {
            ((SharingDialogFragment) p).onUnauthorizedFromChild();
        }
    }

    private static String formatDate(@Nullable String dateTime) {
        if (dateTime == null || dateTime.isEmpty()) return "";
        try {
            String s = dateTime.length() >= 10 ? dateTime.substring(0, 10) : dateTime;
            Date d = new SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(s);
            if (d == null) return s;
            return new SimpleDateFormat("MMM d, yyyy", Locale.US).format(d);
        } catch (Exception ignored) {
            return dateTime;
        }
    }

    private static final class CoverData {
        @Nullable final Bitmap bitmap;
        @Nullable final String assetId;

        CoverData(@Nullable Bitmap bitmap, @Nullable String assetId) {
            this.bitmap = bitmap;
            this.assetId = assetId;
        }
    }

    private static final class ShareCardAdapter extends RecyclerView.Adapter<ShareCardAdapter.VH> {
        interface Listener {
            void onOpen(ShareModels.ShareItem share);
            void onOpenMenu(View anchor, ShareModels.ShareItem share);
        }

        private final List<ShareModels.ShareItem> items = new ArrayList<>();
        private final Map<String, Bitmap> covers = new HashMap<>();
        private final Map<String, String> firstAssetByShare = new HashMap<>();
        @Nullable private Listener listener;
        private boolean ownerMode;

        void setOwnerMode(boolean ownerMode) {
            this.ownerMode = ownerMode;
        }

        void setListener(@Nullable Listener listener) {
            this.listener = listener;
        }

        void submit(List<ShareModels.ShareItem> shares) {
            items.clear();
            if (shares != null) items.addAll(shares);
            notifyDataSetChanged();
        }

        void updateCover(String shareId, @Nullable Bitmap bitmap, @Nullable String firstAssetId) {
            if (bitmap != null) covers.put(shareId, bitmap);
            if (firstAssetId != null && !firstAssetId.isEmpty()) firstAssetByShare.put(shareId, firstAssetId);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_share_card, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            ShareModels.ShareItem s = items.get(position);
            Bitmap c = covers.get(s.id);
            if (c != null) h.cover.setImageBitmap(c);
            else h.cover.setImageDrawable(new android.graphics.drawable.ColorDrawable(ContextCompat.getColor(h.itemView.getContext(), R.color.app_placeholder)));

            h.title.setText(s.name == null || s.name.isEmpty() ? "Shared items" : s.name);
            h.iconKind.setImageResource("album".equals(s.objectKind) ? android.R.drawable.ic_menu_agenda : android.R.drawable.ic_menu_gallery);
            if (ownerMode) {
                int count = s.recipients != null ? s.recipients.size() : 0;
                h.subtitle.setText(count + " recipient" + (count == 1 ? "" : "s"));
                h.btnMore.setVisibility(View.VISIBLE);
                h.btnMore.setOnClickListener(v -> {
                    if (listener != null) listener.onOpenMenu(v, s);
                });
            } else {
                String ownerLabel = null;
                if (s.ownerDisplayName != null && !s.ownerDisplayName.trim().isEmpty()) {
                    ownerLabel = s.ownerDisplayName.trim();
                } else if (s.ownerEmail != null && !s.ownerEmail.trim().isEmpty()) {
                    ownerLabel = s.ownerEmail.trim();
                } else if (s.ownerUserId != null && !s.ownerUserId.trim().isEmpty()) {
                    ownerLabel = s.ownerUserId.trim();
                }
                h.subtitle.setText(ownerLabel == null ? "Shared with you" : ("From " + ownerLabel));
                h.btnMore.setVisibility(View.GONE);
            }

            h.badges.removeAllViews();
            addBadge(h.badges, ShareModels.roleName(s.defaultPermissions),
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_success_bg),
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_success_text));
            if (s.includeFaces) addBadge(h.badges, "Faces",
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_info_bg),
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_info_text));
            if (s.expiresAt != null && !s.expiresAt.isEmpty()) {
                addBadge(h.badges, "Expires " + formatDate(s.expiresAt),
                        ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_neutral_bg),
                        ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_neutral_text));
            }

            h.itemView.setOnClickListener(v -> {
                if (listener != null) listener.onOpen(s);
            });
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        static final class VH extends RecyclerView.ViewHolder {
            final ImageView cover;
            final ImageView iconKind;
            final TextView title;
            final TextView subtitle;
            final LinearLayout badges;
            final ImageButton btnMore;

            VH(@NonNull View v) {
                super(v);
                cover = v.findViewById(R.id.cover);
                iconKind = v.findViewById(R.id.icon_kind);
                title = v.findViewById(R.id.title);
                subtitle = v.findViewById(R.id.subtitle);
                badges = v.findViewById(R.id.badges);
                btnMore = v.findViewById(R.id.btn_more);
            }
        }
    }

    private static final class PublicLinkAdapter extends RecyclerView.Adapter<PublicLinkAdapter.VH> {
        interface Listener {
            void onOpenMenu(View anchor, ShareModels.PublicLinkItem link);
        }

        private final List<ShareModels.PublicLinkItem> items = new ArrayList<>();
        @Nullable private Listener listener;

        void setListener(@Nullable Listener listener) {
            this.listener = listener;
        }

        void submit(List<ShareModels.PublicLinkItem> links) {
            items.clear();
            if (links != null) items.addAll(links);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_public_link_row, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            ShareModels.PublicLinkItem link = items.get(position);
            h.title.setText(link.name == null || link.name.isEmpty() ? "Public link" : link.name);
            h.metaRow.removeAllViews();

            addBadge(h.metaRow, ShareModels.roleName(link.permissions),
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_success_bg),
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_success_text));
            if (Boolean.TRUE.equals(link.hasPin)) addBadge(h.metaRow, "PIN",
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_warning_bg),
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_warning_text));
            if (link.expiresAt != null && !link.expiresAt.isEmpty()) addBadge(h.metaRow, "Expires " + formatDate(link.expiresAt),
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_neutral_bg),
                    ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_neutral_text));
            if (link.moderationEnabled) {
                int pending = link.pendingCount != null ? link.pendingCount : 0;
                if (pending > 0) addBadge(h.metaRow, "Pending " + pending,
                        ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_warning_bg),
                        ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_warning_text));
                else addBadge(h.metaRow, "Moderation",
                        ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_neutral_bg),
                        ContextCompat.getColor(h.itemView.getContext(), R.color.app_badge_neutral_text));
            }

            View.OnClickListener menuClick = v -> {
                if (listener != null) listener.onOpenMenu(v, link);
            };
            h.itemView.setOnClickListener(menuClick);
            h.chevron.setOnClickListener(menuClick);
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        static final class VH extends RecyclerView.ViewHolder {
            final TextView title;
            final LinearLayout metaRow;
            final ImageView chevron;

            VH(@NonNull View v) {
                super(v);
                title = v.findViewById(R.id.title);
                metaRow = v.findViewById(R.id.meta_row);
                chevron = v.findViewById(R.id.chevron);
            }
        }
    }

    private static void addBadge(LinearLayout parent, String text, int bgColor, int fgColor) {
        TextView tv = new TextView(parent.getContext());
        tv.setText(text);
        tv.setTextSize(11f);
        tv.setTextColor(fgColor);
        int hp = dpStatic(parent.getContext(), 9);
        int vp = dpStatic(parent.getContext(), 3);
        tv.setPadding(hp, vp, hp, vp);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(bgColor);
        bg.setCornerRadius(dpStatic(parent.getContext(), 999));
        tv.setBackground(bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMarginEnd(dpStatic(parent.getContext(), 6));
        parent.addView(tv, lp);
    }

    private static int dpStatic(Context c, int v) {
        return Math.round(v * c.getResources().getDisplayMetrics().density);
    }
}
