package ca.openphotos.android.ui;

import android.app.AlertDialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.text.InputType;
import android.text.format.Formatter;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.server.TeamModels;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** One Users & Groups page (Users or Groups). */
public class UsersGroupsListFragment extends Fragment {
    public static final int MODE_USERS = 0;
    public static final int MODE_GROUPS = 1;

    private static final String ARG_MODE = "mode";

    private int mode = MODE_USERS;
    private SwipeRefreshLayout swipe;
    private RecyclerView recycler;
    private View emptyState;
    private TextView emptyTitle;
    private TextView emptyMessage;
    private View loading;
    private View usersControls;
    private View groupsControls;
    private Spinner spRoleFilter;
    private Spinner spStatusFilter;
    private ImageButton btnAddUser;
    private ImageButton btnAddGroup;

    private final List<TeamModels.TeamUser> users = new ArrayList<>();
    private final List<TeamModels.TeamUser> filteredUsers = new ArrayList<>();
    private final List<TeamModels.TeamGroup> groups = new ArrayList<>();
    private final Map<Integer, Integer> groupMemberCounts = new HashMap<>();

    private UserAdapter userAdapter;
    private GroupAdapter groupAdapter;

    private String roleFilter = "all";
    private String statusFilter = "all";
    private volatile boolean loadInFlight = false;

    public static UsersGroupsListFragment newInstance(int mode) {
        UsersGroupsListFragment f = new UsersGroupsListFragment();
        Bundle b = new Bundle();
        b.putInt(ARG_MODE, mode);
        f.setArguments(b);
        return f;
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        if (getArguments() != null) mode = getArguments().getInt(ARG_MODE, MODE_USERS);
        View root = inflater.inflate(R.layout.fragment_users_groups_list, container, false);
        swipe = root.findViewById(R.id.swipe);
        recycler = root.findViewById(R.id.recycler);
        emptyState = root.findViewById(R.id.empty_state);
        emptyTitle = root.findViewById(R.id.empty_title);
        emptyMessage = root.findViewById(R.id.empty_message);
        loading = root.findViewById(R.id.loading);
        usersControls = root.findViewById(R.id.users_controls);
        groupsControls = root.findViewById(R.id.groups_controls);
        spRoleFilter = root.findViewById(R.id.sp_role_filter);
        spStatusFilter = root.findViewById(R.id.sp_status_filter);
        btnAddUser = root.findViewById(R.id.btn_add_user);
        btnAddGroup = root.findViewById(R.id.btn_add_group);

        recycler.setLayoutManager(new LinearLayoutManager(requireContext()));

        if (mode == MODE_USERS) {
            usersControls.setVisibility(View.VISIBLE);
            groupsControls.setVisibility(View.GONE);
            userAdapter = new UserAdapter();
            recycler.setAdapter(userAdapter);
            setupUserFilters();
            btnAddUser.setOnClickListener(v -> openAddUserDialog());
            emptyTitle.setText("No users");
            emptyMessage.setText("Create your first team user.");
        } else {
            usersControls.setVisibility(View.GONE);
            groupsControls.setVisibility(View.VISIBLE);
            groupAdapter = new GroupAdapter();
            recycler.setAdapter(groupAdapter);
            btnAddGroup.setOnClickListener(v -> openAddGroupDialog());
            emptyTitle.setText("No groups");
            emptyMessage.setText("Create your first team group.");
        }

        swipe.setOnRefreshListener(() -> loadData(true));
        loadData(false);
        return root;
    }

    public void refreshNow() {
        loadData(true);
    }

    private void setupUserFilters() {
        ArrayAdapter<String> roleAdapter = new ArrayAdapter<>(
                requireContext(),
                android.R.layout.simple_spinner_item,
                new String[]{"All roles", "Admin", "Regular"}
        );
        roleAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spRoleFilter.setAdapter(roleAdapter);
        spRoleFilter.setSelection(0, false);
        spRoleFilter.setOnItemSelectedListener(new SimpleItemSelectedListener(position -> {
            if (position == 1) roleFilter = "admin";
            else if (position == 2) roleFilter = "regular";
            else roleFilter = "all";
            applyUserFilters();
        }));

        ArrayAdapter<String> statusAdapter = new ArrayAdapter<>(
                requireContext(),
                android.R.layout.simple_spinner_item,
                new String[]{"All status", "Active", "Disabled"}
        );
        statusAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spStatusFilter.setAdapter(statusAdapter);
        spStatusFilter.setSelection(0, false);
        spStatusFilter.setOnItemSelectedListener(new SimpleItemSelectedListener(position -> {
            if (position == 1) statusFilter = "active";
            else if (position == 2) statusFilter = "disabled";
            else statusFilter = "all";
            applyUserFilters();
        }));
    }

    private void loadData(boolean manualRefresh) {
        if (loadInFlight) return;
        loadInFlight = true;
        if (!manualRefresh) loading.setVisibility(View.VISIBLE);

        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                if (mode == MODE_USERS) {
                    List<TeamModels.TeamUser> list = svc.listTeamUsers();
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        users.clear();
                        users.addAll(list);
                        applyUserFilters();
                    });
                } else {
                    List<TeamModels.TeamGroup> list = svc.listTeamGroups();
                    Map<Integer, Integer> counts = new HashMap<>();
                    for (TeamModels.TeamGroup g : list) {
                        try {
                            List<TeamModels.GroupMember> members = svc.listTeamGroupUsers(g.id);
                            counts.put(g.id, members.size());
                        } catch (Exception ignored) {
                        }
                    }
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> {
                        groups.clear();
                        groups.addAll(list);
                        groupMemberCounts.clear();
                        groupMemberCounts.putAll(counts);
                        if (groupAdapter != null) {
                            groupAdapter.submit(groups, groupMemberCounts);
                        }
                        renderStates();
                    });
                }
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    handleTeamError(e, mode == MODE_USERS ? "Failed to load users" : "Failed to load groups");
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

    private void applyUserFilters() {
        filteredUsers.clear();
        for (TeamModels.TeamUser user : users) {
            boolean roleMatch;
            if ("admin".equals(roleFilter)) {
                roleMatch = "admin".equalsIgnoreCase(user.role) || "owner".equalsIgnoreCase(user.role);
            } else if ("regular".equals(roleFilter)) {
                roleMatch = !"admin".equalsIgnoreCase(user.role) && !"owner".equalsIgnoreCase(user.role);
            } else {
                roleMatch = true;
            }

            boolean statusMatch = "all".equals(statusFilter) || statusFilter.equalsIgnoreCase(user.status);
            if (roleMatch && statusMatch) filteredUsers.add(user);
        }

        if (userAdapter != null) userAdapter.submit(filteredUsers);
        renderStates();
    }

    private void renderStates() {
        boolean empty = (mode == MODE_USERS) ? filteredUsers.isEmpty() : groups.isEmpty();
        emptyState.setVisibility(empty ? View.VISIBLE : View.GONE);
        swipe.setVisibility(empty ? View.GONE : View.VISIBLE);
    }

    private void handleTeamError(@NonNull Exception e, @NonNull String fallback) {
        String msg = e.getMessage() != null ? e.getMessage() : "";
        if (msg.contains("HTTP 401")) {
            AuthManager auth = AuthManager.get(requireContext().getApplicationContext());
            if (!auth.isAuthenticated()) {
                notifyUnauthorized();
                return;
            }
            Toast.makeText(requireContext(), "Unauthorized", Toast.LENGTH_LONG).show();
            return;
        }
        if (msg.contains("HTTP 403")) {
            Toast.makeText(requireContext(), "Not authorized to access Users & Groups", Toast.LENGTH_LONG).show();
            return;
        }
        Toast.makeText(requireContext(), fallback, Toast.LENGTH_LONG).show();
    }

    private void notifyUnauthorized() {
        Fragment parent = getParentFragment();
        if (parent instanceof UsersGroupsDialogFragment) {
            ((UsersGroupsDialogFragment) parent).onUnauthorizedFromChild();
        }
    }

    private void openAddUserDialog() {
        new Thread(() -> {
            List<TeamModels.TeamGroup> availableGroups = new ArrayList<>();
            try {
                availableGroups = new ServerPhotosService(requireContext().getApplicationContext()).listTeamGroups();
            } catch (Exception ignored) {
            }
            if (!isAdded()) return;
            List<TeamModels.TeamGroup> finalAvailableGroups = availableGroups;
            requireActivity().runOnUiThread(() -> showAddUserDialog(finalAvailableGroups));
        }).start();
    }

    private void showAddUserDialog(@NonNull List<TeamModels.TeamGroup> availableGroups) {
        ScrollView scroll = new ScrollView(requireContext());
        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        EditText etEmail = makeEditText("Email");
        etEmail.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        root.addView(etEmail);

        EditText etName = makeEditText("Name");
        root.addView(etName);

        Spinner spRole = new Spinner(requireContext());
        ArrayAdapter<String> roleAdapter = new ArrayAdapter<>(
                requireContext(),
                android.R.layout.simple_spinner_item,
                new String[]{"Regular", "Admin"}
        );
        roleAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spRole.setAdapter(roleAdapter);
        root.addView(spRole);

        EditText etPassword = makeEditText("Password (min 6)");
        etPassword.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        root.addView(etPassword);

        EditText etConfirm = makeEditText("Confirm Password");
        etConfirm.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        root.addView(etConfirm);

        CheckBox cbMustChange = new CheckBox(requireContext());
        cbMustChange.setText("Must change password on first login");
        cbMustChange.setChecked(true);
        root.addView(cbMustChange);

        Set<Integer> selectedGroupIds = new HashSet<>();
        if (!availableGroups.isEmpty()) {
            TextView tvGroups = makeSectionTitle("Groups (Optional)");
            root.addView(tvGroups);
            for (TeamModels.TeamGroup g : availableGroups) {
                CheckBox cb = new CheckBox(requireContext());
                cb.setText(g.name);
                cb.setOnCheckedChangeListener((buttonView, isChecked) -> {
                    if (isChecked) selectedGroupIds.add(g.id);
                    else selectedGroupIds.remove(g.id);
                });
                root.addView(cb);
            }
        }

        AlertDialog dialog = new AlertDialog.Builder(requireContext())
                .setTitle("Add User")
                .setView(scroll)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Create", null)
                .create();

        dialog.setOnShowListener(d -> {
            Button btnCreate = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            btnCreate.setOnClickListener(v -> {
                String email = textOf(etEmail).toLowerCase(Locale.US);
                String name = textOf(etName);
                String password = textOf(etPassword);
                String confirm = textOf(etConfirm);
                String role = spRole.getSelectedItemPosition() == 1 ? "admin" : "regular";

                if (email.isEmpty() || !email.contains("@") || !email.contains(".")) {
                    etEmail.setError("Enter a valid email");
                    return;
                }
                if (name.isEmpty()) {
                    etName.setError("Name is required");
                    return;
                }
                if (password.length() < 6) {
                    etPassword.setError("Minimum 6 characters");
                    return;
                }
                if (!password.equals(confirm)) {
                    etConfirm.setError("Passwords do not match");
                    return;
                }

                btnCreate.setEnabled(false);
                new Thread(() -> {
                    try {
                        TeamModels.CreateTeamUserRequest req = new TeamModels.CreateTeamUserRequest();
                        req.email = email;
                        req.name = name;
                        req.role = role;
                        req.initialPassword = password;
                        req.mustChangePassword = cbMustChange.isChecked();
                        if (!selectedGroupIds.isEmpty()) req.groups = new ArrayList<>(selectedGroupIds);
                        TeamModels.TeamUser created = new ServerPhotosService(requireContext().getApplicationContext()).createTeamUser(req);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnCreate.setEnabled(true);
                            dialog.dismiss();
                            Toast.makeText(requireContext(), "User created: " + safeUserLabel(created), Toast.LENGTH_SHORT).show();
                            loadData(true);
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnCreate.setEnabled(true);
                            handleTeamError(e, "Failed to create user");
                        });
                    }
                }).start();
            });
        });
        dialog.show();
    }

    private void openUserDetailDialog(@NonNull TeamModels.TeamUser user) {
        String currentUserId = AuthManager.get(requireContext().getApplicationContext()).getUserId();
        boolean isSelf = currentUserId != null && currentUserId.equals(user.userId);
        boolean canEdit = !user.isCreator || isSelf;
        boolean canEditRole = !user.isCreator && !"owner".equalsIgnoreCase(user.role);
        boolean canEditStatus = !user.isCreator && !"owner".equalsIgnoreCase(user.role);
        boolean canDelete = !isSelf && !user.isCreator;
        boolean canResetPassword = isSelf || !user.isCreator;

        ScrollView scroll = new ScrollView(requireContext());
        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView tvId = makeKeyValue("User ID", user.userId);
        root.addView(tvId);

        EditText etName = makeEditText("Name");
        etName.setText(user.name);
        etName.setEnabled(canEdit);
        root.addView(etName);

        TextView tvEmail = makeKeyValue("Email", TeamModels.firstNonEmpty(user.email, "—"));
        root.addView(tvEmail);

        Spinner spRole = new Spinner(requireContext());
        final String[] roleValues;
        if ("owner".equalsIgnoreCase(user.role)) {
            roleValues = new String[]{"Owner"};
        } else {
            roleValues = new String[]{"Regular", "Admin"};
        }
        ArrayAdapter<String> roleAdapter = new ArrayAdapter<>(requireContext(), android.R.layout.simple_spinner_item, roleValues);
        roleAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spRole.setAdapter(roleAdapter);
        if ("admin".equalsIgnoreCase(user.role)) spRole.setSelection(1, false);
        else spRole.setSelection(0, false);
        spRole.setEnabled(canEdit && canEditRole);
        root.addView(makeSectionTitle("Role"));
        root.addView(spRole);

        Spinner spStatus = new Spinner(requireContext());
        String[] statusValues = new String[]{"Active", "Disabled"};
        ArrayAdapter<String> statusAdapter = new ArrayAdapter<>(requireContext(), android.R.layout.simple_spinner_item, statusValues);
        statusAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spStatus.setAdapter(statusAdapter);
        spStatus.setSelection("disabled".equalsIgnoreCase(user.status) ? 1 : 0, false);
        spStatus.setEnabled(canEdit && canEditStatus);
        root.addView(makeSectionTitle("Status"));
        root.addView(spStatus);

        root.addView(makeKeyValue("Media Count", String.valueOf(Math.max(0, user.mediaCount))));
        root.addView(makeKeyValue("Storage", Formatter.formatFileSize(requireContext(), Math.max(0L, user.storageBytes))));

        LinearLayout actionsRow = new LinearLayout(requireContext());
        actionsRow.setOrientation(LinearLayout.HORIZONTAL);
        actionsRow.setPadding(0, dp(8), 0, 0);

        Button btnReset = new Button(requireContext());
        btnReset.setText("Reset Password");
        btnReset.setEnabled(canResetPassword);
        actionsRow.addView(btnReset, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Button btnDelete = new Button(requireContext());
        btnDelete.setText("Delete");
        btnDelete.setTextColor(color(R.color.app_error));
        btnDelete.setEnabled(canDelete);
        actionsRow.addView(btnDelete, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        root.addView(actionsRow);

        AlertDialog dialog = new AlertDialog.Builder(requireContext())
                .setTitle("User Details")
                .setView(scroll)
                .setNegativeButton("Close", null)
                .setPositiveButton("Save", null)
                .create();

        btnReset.setOnClickListener(v -> openResetPasswordDialog(user));
        btnDelete.setOnClickListener(v -> confirmDeleteUser(user, dialog));

        dialog.setOnShowListener(d -> {
            Button btnSave = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            btnSave.setOnClickListener(v -> {
                String newName = textOf(etName);
                if (newName.isEmpty()) {
                    etName.setError("Name cannot be empty");
                    return;
                }

                TeamModels.UpdateTeamUserRequest req = new TeamModels.UpdateTeamUserRequest();
                if (canEdit && !newName.equals(user.name)) req.name = newName;
                if (canEditRole) {
                    if ("owner".equalsIgnoreCase(user.role)) {
                        req.role = null;
                    } else {
                        String selectedRole = spRole.getSelectedItemPosition() == 1 ? "admin" : "regular";
                        if (!selectedRole.equalsIgnoreCase(user.role)) req.role = selectedRole;
                    }
                }
                if (canEditStatus) {
                    String selectedStatus = spStatus.getSelectedItemPosition() == 1 ? "disabled" : "active";
                    if (!selectedStatus.equalsIgnoreCase(user.status)) req.status = selectedStatus;
                }

                if (req.name == null && req.role == null && req.status == null) {
                    dialog.dismiss();
                    return;
                }

                btnSave.setEnabled(false);
                new Thread(() -> {
                    try {
                        new ServerPhotosService(requireContext().getApplicationContext()).updateTeamUser(user.userId, req);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnSave.setEnabled(true);
                            dialog.dismiss();
                            Toast.makeText(requireContext(), "User updated", Toast.LENGTH_SHORT).show();
                            loadData(true);
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnSave.setEnabled(true);
                            handleTeamError(e, "Failed to update user");
                        });
                    }
                }).start();
            });
        });
        dialog.show();
    }

    private void openResetPasswordDialog(@NonNull TeamModels.TeamUser user) {
        String currentUserId = AuthManager.get(requireContext().getApplicationContext()).getUserId();
        boolean isSelf = currentUserId != null && currentUserId.equals(user.userId);

        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);

        EditText etCurrent = null;
        if (isSelf) {
            etCurrent = makeEditText("Current Password");
            etCurrent.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
            root.addView(etCurrent);
        }

        EditText etNew = makeEditText("New Password (min 6)");
        etNew.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        root.addView(etNew);

        EditText etConfirm = makeEditText("Confirm New Password");
        etConfirm.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        root.addView(etConfirm);

        EditText finalEtCurrent = etCurrent;
        AlertDialog dialog = new AlertDialog.Builder(requireContext())
                .setTitle("Reset Password")
                .setView(root)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Reset", null)
                .create();

        dialog.setOnShowListener(d -> {
            Button btnReset = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            btnReset.setOnClickListener(v -> {
                String current = finalEtCurrent != null ? textOf(finalEtCurrent) : "";
                String newPw = textOf(etNew);
                String confirm = textOf(etConfirm);
                if (isSelf && current.isEmpty()) {
                    finalEtCurrent.setError("Current password required");
                    return;
                }
                if (newPw.length() < 6) {
                    etNew.setError("Minimum 6 characters");
                    return;
                }
                if (!newPw.equals(confirm)) {
                    etConfirm.setError("Passwords do not match");
                    return;
                }

                btnReset.setEnabled(false);
                new Thread(() -> {
                    try {
                        TeamModels.ResetPasswordRequest req = new TeamModels.ResetPasswordRequest();
                        req.newPassword = newPw;
                        req.currentPassword = isSelf ? current : null;
                        new ServerPhotosService(requireContext().getApplicationContext()).resetTeamUserPassword(user.userId, req);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnReset.setEnabled(true);
                            dialog.dismiss();
                            Toast.makeText(requireContext(), "Password reset for " + safeUserLabel(user), Toast.LENGTH_SHORT).show();
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnReset.setEnabled(true);
                            handleTeamError(e, "Failed to reset password");
                        });
                    }
                }).start();
            });
        });
        dialog.show();
    }

    private void confirmDeleteUser(@NonNull TeamModels.TeamUser user, @Nullable AlertDialog parentDialog) {
        new AlertDialog.Builder(requireContext())
                .setTitle("Delete User")
                .setMessage("Delete user '" + safeUserLabel(user) + "' and all their data? This cannot be undone.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Delete", (d, which) -> new Thread(() -> {
                    try {
                        new ServerPhotosService(requireContext().getApplicationContext()).deleteTeamUser(user.userId, true);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            if (parentDialog != null) parentDialog.dismiss();
                            Toast.makeText(requireContext(), "User deleted", Toast.LENGTH_SHORT).show();
                            loadData(true);
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> handleTeamError(e, "Failed to delete user"));
                    }
                }).start())
                .show();
    }

    private void openAddGroupDialog() {
        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);

        EditText etName = makeEditText("Group name");
        root.addView(etName);
        EditText etDescription = makeEditText("Description (optional)");
        root.addView(etDescription);

        AlertDialog dialog = new AlertDialog.Builder(requireContext())
                .setTitle("Add Group")
                .setView(root)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Create", null)
                .create();

        dialog.setOnShowListener(d -> {
            Button btnCreate = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            btnCreate.setOnClickListener(v -> {
                String name = textOf(etName);
                String description = textOf(etDescription);
                if (name.isEmpty()) {
                    etName.setError("Group name is required");
                    return;
                }
                btnCreate.setEnabled(false);
                new Thread(() -> {
                    try {
                        TeamModels.CreateGroupRequest req = new TeamModels.CreateGroupRequest();
                        req.name = name;
                        req.description = description.isEmpty() ? null : description;
                        TeamModels.TeamGroup created = new ServerPhotosService(requireContext().getApplicationContext()).createTeamGroup(req);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnCreate.setEnabled(true);
                            dialog.dismiss();
                            Toast.makeText(requireContext(), "Group created: " + created.name, Toast.LENGTH_SHORT).show();
                            loadData(true);
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnCreate.setEnabled(true);
                            handleTeamError(e, "Failed to create group");
                        });
                    }
                }).start();
            });
        });
        dialog.show();
    }

    private void openGroupDetailDialog(@NonNull TeamModels.TeamGroup group) {
        ScrollView scroll = new ScrollView(requireContext());
        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        EditText etName = makeEditText("Group name");
        etName.setText(group.name);
        root.addView(etName);

        EditText etDescription = makeEditText("Description (optional)");
        if (group.description != null) etDescription.setText(group.description);
        root.addView(etDescription);

        root.addView(makeSectionTitle("Members"));
        LinearLayout membersContainer = new LinearLayout(requireContext());
        membersContainer.setOrientation(LinearLayout.VERTICAL);
        membersContainer.setPadding(0, dp(6), 0, dp(6));
        root.addView(membersContainer);

        LinearLayout actionRow = new LinearLayout(requireContext());
        actionRow.setOrientation(LinearLayout.HORIZONTAL);
        actionRow.setPadding(0, dp(8), 0, 0);
        root.addView(actionRow);

        Button btnAddMembers = new Button(requireContext());
        btnAddMembers.setText("Add Members");
        actionRow.addView(btnAddMembers, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Button btnDeleteGroup = new Button(requireContext());
        btnDeleteGroup.setText("Delete Group");
        btnDeleteGroup.setTextColor(color(R.color.app_error));
        actionRow.addView(btnDeleteGroup, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        List<TeamModels.GroupMember> currentMembers = new ArrayList<>();
        AlertDialog dialog = new AlertDialog.Builder(requireContext())
                .setTitle("Group Details")
                .setView(scroll)
                .setNegativeButton("Close", null)
                .setPositiveButton("Save", null)
                .create();

        btnAddMembers.setOnClickListener(v ->
                openMemberPickerDialog(group, new ArrayList<>(currentMembers), () -> {
                    reloadGroupMembersInto(group, membersContainer, currentMembers);
                    loadData(true);
                })
        );
        btnDeleteGroup.setOnClickListener(v -> confirmDeleteGroup(group, dialog));

        dialog.setOnShowListener(d -> {
            Button btnSave = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            btnSave.setOnClickListener(v -> {
                String name = textOf(etName);
                String description = textOf(etDescription);
                if (name.isEmpty()) {
                    etName.setError("Group name is required");
                    return;
                }

                TeamModels.UpdateGroupRequest req = new TeamModels.UpdateGroupRequest();
                if (!name.equals(group.name)) req.name = name;
                String existingDescription = group.description != null ? group.description : "";
                if (!description.equals(existingDescription)) req.description = description;

                if (req.name == null && req.description == null) {
                    dialog.dismiss();
                    return;
                }

                btnSave.setEnabled(false);
                new Thread(() -> {
                    try {
                        new ServerPhotosService(requireContext().getApplicationContext()).updateTeamGroup(group.id, req);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnSave.setEnabled(true);
                            dialog.dismiss();
                            Toast.makeText(requireContext(), "Group updated", Toast.LENGTH_SHORT).show();
                            loadData(true);
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            btnSave.setEnabled(true);
                            handleTeamError(e, "Failed to update group");
                        });
                    }
                }).start();
            });
        });
        dialog.show();
        reloadGroupMembersInto(group, membersContainer, currentMembers);
    }

    private void reloadGroupMembersInto(
            @NonNull TeamModels.TeamGroup group,
            @NonNull LinearLayout container,
            @NonNull List<TeamModels.GroupMember> currentMembers
    ) {
        container.removeAllViews();
        ProgressBar pb = new ProgressBar(requireContext());
        container.addView(pb);
        new Thread(() -> {
            try {
                List<TeamModels.GroupMember> members = new ServerPhotosService(requireContext().getApplicationContext()).listTeamGroupUsers(group.id);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    currentMembers.clear();
                    currentMembers.addAll(members);
                    renderGroupMembers(group, container, currentMembers);
                    groupMemberCounts.put(group.id, currentMembers.size());
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    container.removeAllViews();
                    TextView tv = new TextView(requireContext());
                    tv.setText("Failed to load members");
                    tv.setTextColor(color(R.color.app_text_secondary));
                    container.addView(tv);
                    handleTeamError(e, "Failed to load members");
                });
            }
        }).start();
    }

    private void renderGroupMembers(
            @NonNull TeamModels.TeamGroup group,
            @NonNull LinearLayout container,
            @NonNull List<TeamModels.GroupMember> members
    ) {
        container.removeAllViews();
        if (members.isEmpty()) {
            TextView tv = new TextView(requireContext());
            tv.setText("No members yet");
            tv.setTextColor(color(R.color.app_text_secondary));
            container.addView(tv);
            return;
        }

        for (TeamModels.GroupMember member : members) {
            LinearLayout row = new LinearLayout(requireContext());
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setPadding(0, dp(6), 0, dp(6));
            row.setGravity(android.view.Gravity.CENTER_VERTICAL);

            LinearLayout info = new LinearLayout(requireContext());
            info.setOrientation(LinearLayout.VERTICAL);
            TextView tvName = new TextView(requireContext());
            tvName.setText(safeMemberLabel(member));
            tvName.setTextColor(color(R.color.app_text_primary));
            tvName.setTypeface(tvName.getTypeface(), Typeface.BOLD);
            info.addView(tvName);
            if (member.email != null && !member.email.trim().isEmpty()) {
                TextView tvEmail = new TextView(requireContext());
                tvEmail.setText(member.email);
                tvEmail.setTextColor(color(R.color.app_text_secondary));
                tvEmail.setTextSize(12f);
                info.addView(tvEmail);
            }
            TextView tvRole = new TextView(requireContext());
            tvRole.setText(roleLabel(member.role));
            tvRole.setTextSize(11f);
            styleBadge(tvRole, color(R.color.app_badge_success_bg), color(R.color.app_badge_success_text));
            info.addView(tvRole);

            row.addView(info, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

            ImageButton btnRemove = new ImageButton(requireContext());
            btnRemove.setBackgroundColor(Color.TRANSPARENT);
            btnRemove.setImageResource(android.R.drawable.ic_menu_close_clear_cancel);
            btnRemove.setContentDescription("Remove member");
            btnRemove.setOnClickListener(v -> confirmRemoveMember(group, member, () -> reloadGroupMembersInto(group, container, members)));
            row.addView(btnRemove, new LinearLayout.LayoutParams(dp(36), dp(36)));

            container.addView(row);
        }
    }

    private void confirmRemoveMember(
            @NonNull TeamModels.TeamGroup group,
            @NonNull TeamModels.GroupMember member,
            @NonNull Runnable onDone
    ) {
        new AlertDialog.Builder(requireContext())
                .setTitle("Remove Member")
                .setMessage("Remove '" + safeMemberLabel(member) + "' from this group?")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Remove", (d, which) -> new Thread(() -> {
                    try {
                        TeamModels.ModifyGroupUsersRequest req = new TeamModels.ModifyGroupUsersRequest();
                        req.remove = Collections.singletonList(member.userId);
                        new ServerPhotosService(requireContext().getApplicationContext()).modifyTeamGroupUsers(group.id, req);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            Toast.makeText(requireContext(), "Member removed", Toast.LENGTH_SHORT).show();
                            onDone.run();
                            loadData(true);
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> handleTeamError(e, "Failed to remove member"));
                    }
                }).start())
                .show();
    }

    private void openMemberPickerDialog(
            @NonNull TeamModels.TeamGroup group,
            @NonNull List<TeamModels.GroupMember> currentMembers,
            @NonNull Runnable onDone
    ) {
        new Thread(() -> {
            try {
                List<TeamModels.TeamUser> users = new ServerPhotosService(requireContext().getApplicationContext()).listTeamUsers();
                Set<String> existingIds = new HashSet<>();
                for (TeamModels.GroupMember m : currentMembers) existingIds.add(m.userId);
                List<TeamModels.TeamUser> candidates = new ArrayList<>();
                for (TeamModels.TeamUser u : users) {
                    if (!"active".equalsIgnoreCase(u.status)) continue;
                    if (existingIds.contains(u.userId)) continue;
                    candidates.add(u);
                }

                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (candidates.isEmpty()) {
                        Toast.makeText(requireContext(), "No users available to add", Toast.LENGTH_SHORT).show();
                        return;
                    }
                    String[] labels = new String[candidates.size()];
                    boolean[] checked = new boolean[candidates.size()];
                    for (int i = 0; i < candidates.size(); i++) {
                        TeamModels.TeamUser u = candidates.get(i);
                        String label = safeUserLabel(u);
                        if (u.email != null && !u.email.trim().isEmpty() && !label.equalsIgnoreCase(u.email)) {
                            label += " (" + u.email + ")";
                        }
                        labels[i] = label;
                    }

                    new AlertDialog.Builder(requireContext())
                            .setTitle("Add Members")
                            .setMultiChoiceItems(labels, checked, (dialog, which, isChecked) -> checked[which] = isChecked)
                            .setNegativeButton("Cancel", null)
                            .setPositiveButton("Add", (dialog, which) -> new Thread(() -> {
                                try {
                                    ArrayList<String> add = new ArrayList<>();
                                    for (int i = 0; i < checked.length; i++) {
                                        if (checked[i]) add.add(candidates.get(i).userId);
                                    }
                                    if (add.isEmpty()) return;
                                    TeamModels.ModifyGroupUsersRequest req = new TeamModels.ModifyGroupUsersRequest();
                                    req.add = add;
                                    new ServerPhotosService(requireContext().getApplicationContext()).modifyTeamGroupUsers(group.id, req);
                                    if (!isAdded()) return;
                                    requireActivity().runOnUiThread(() -> {
                                        Toast.makeText(requireContext(), "Members added", Toast.LENGTH_SHORT).show();
                                        onDone.run();
                                        loadData(true);
                                    });
                                } catch (Exception e) {
                                    if (!isAdded()) return;
                                    requireActivity().runOnUiThread(() -> handleTeamError(e, "Failed to add members"));
                                }
                            }).start())
                            .show();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> handleTeamError(e, "Failed to load users"));
            }
        }).start();
    }

    private void confirmDeleteGroup(@NonNull TeamModels.TeamGroup group, @Nullable AlertDialog parentDialog) {
        new AlertDialog.Builder(requireContext())
                .setTitle("Delete Group")
                .setMessage("Delete group '" + group.name + "'?")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Delete", (d, which) -> new Thread(() -> {
                    try {
                        new ServerPhotosService(requireContext().getApplicationContext()).deleteTeamGroup(group.id);
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> {
                            if (parentDialog != null) parentDialog.dismiss();
                            Toast.makeText(requireContext(), "Group deleted", Toast.LENGTH_SHORT).show();
                            loadData(true);
                        });
                    } catch (Exception e) {
                        if (!isAdded()) return;
                        requireActivity().runOnUiThread(() -> handleTeamError(e, "Failed to delete group"));
                    }
                }).start())
                .show();
    }

    private EditText makeEditText(@NonNull String hint) {
        EditText et = new EditText(requireContext());
        et.setHint(hint);
        et.setSingleLine(true);
        et.setLayoutParams(new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return et;
    }

    private TextView makeSectionTitle(@NonNull String text) {
        TextView tv = new TextView(requireContext());
        tv.setText(text);
        tv.setTextColor(color(R.color.app_text_secondary));
        tv.setTypeface(tv.getTypeface(), Typeface.BOLD);
        tv.setTextSize(12f);
        tv.setPadding(0, dp(10), 0, dp(6));
        return tv;
    }

    private TextView makeKeyValue(@NonNull String key, @NonNull String value) {
        TextView tv = new TextView(requireContext());
        tv.setText(key + ": " + value);
        tv.setTextColor(color(R.color.app_text_secondary));
        tv.setTextSize(13f);
        tv.setPadding(0, dp(4), 0, dp(4));
        return tv;
    }

    private static String textOf(@Nullable EditText et) {
        return et != null && et.getText() != null ? et.getText().toString().trim() : "";
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private int color(int resId) {
        return ContextCompat.getColor(requireContext(), resId);
    }

    private void styleBadge(@NonNull TextView tv, int bgColor, int textColor) {
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(bgColor);
        bg.setCornerRadius(dp(999));
        tv.setBackground(bg);
        tv.setTextColor(textColor);
        tv.setPadding(dp(8), dp(3), dp(8), dp(3));
    }

    private static String roleLabel(@Nullable String roleRaw) {
        if (roleRaw == null) return "Regular";
        if ("owner".equalsIgnoreCase(roleRaw)) return "Owner";
        if ("admin".equalsIgnoreCase(roleRaw)) return "Admin";
        return "Regular";
    }

    private static String statusLabel(@Nullable String statusRaw) {
        if ("disabled".equalsIgnoreCase(statusRaw)) return "Disabled";
        return "Active";
    }

    @NonNull
    private static String safeUserLabel(@NonNull TeamModels.TeamUser user) {
        String s = TeamModels.firstNonEmpty(user.name, user.email, user.userId);
        return s != null ? s : "User";
    }

    @NonNull
    private static String safeMemberLabel(@NonNull TeamModels.GroupMember member) {
        String s = TeamModels.firstNonEmpty(member.name, member.email, member.userId);
        return s != null ? s : "Member";
    }

    private static final class SimpleItemSelectedListener implements android.widget.AdapterView.OnItemSelectedListener {
        interface Callback { void onSelected(int position); }
        private final Callback callback;

        SimpleItemSelectedListener(@NonNull Callback callback) {
            this.callback = callback;
        }

        @Override
        public void onItemSelected(android.widget.AdapterView<?> parent, View view, int position, long id) {
            callback.onSelected(position);
        }

        @Override
        public void onNothingSelected(android.widget.AdapterView<?> parent) {
        }
    }

    private final class UserAdapter extends RecyclerView.Adapter<UserAdapter.VH> {
        private final List<TeamModels.TeamUser> data = new ArrayList<>();

        void submit(@NonNull List<TeamModels.TeamUser> items) {
            data.clear();
            data.addAll(items);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_team_user, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            TeamModels.TeamUser u = data.get(position);
            h.name.setText(safeUserLabel(u));
            h.email.setText(TeamModels.firstNonEmpty(u.email, u.userId, "—"));
            h.role.setText(roleLabel(u.role));
            h.status.setText(statusLabel(u.status));
            h.media.setText(Math.max(0, u.mediaCount) + " media");
            h.storage.setText(Formatter.formatFileSize(requireContext(), Math.max(0L, u.storageBytes)));
            h.creator.setVisibility(u.isCreator ? View.VISIBLE : View.GONE);

            if ("admin".equalsIgnoreCase(u.role) || "owner".equalsIgnoreCase(u.role)) {
                styleBadge(h.role, color(R.color.app_badge_info_bg), color(R.color.app_badge_info_text));
            } else {
                styleBadge(h.role, color(R.color.app_badge_success_bg), color(R.color.app_badge_success_text));
            }
            if ("disabled".equalsIgnoreCase(u.status)) {
                styleBadge(h.status, color(R.color.app_badge_danger_bg), color(R.color.app_badge_danger_text));
            } else {
                styleBadge(h.status, color(R.color.app_badge_info_bg), color(R.color.app_badge_info_text));
            }
            styleBadge(h.creator, color(R.color.app_badge_special_bg), color(R.color.app_badge_special_text));

            h.itemView.setOnClickListener(v -> openUserDetailDialog(u));
        }

        @Override
        public int getItemCount() {
            return data.size();
        }

        final class VH extends RecyclerView.ViewHolder {
            final TextView name;
            final TextView creator;
            final TextView email;
            final TextView role;
            final TextView status;
            final TextView media;
            final TextView storage;

            VH(@NonNull View itemView) {
                super(itemView);
                name = itemView.findViewById(R.id.tv_name);
                creator = itemView.findViewById(R.id.tv_creator_badge);
                email = itemView.findViewById(R.id.tv_email);
                role = itemView.findViewById(R.id.tv_role);
                status = itemView.findViewById(R.id.tv_status);
                media = itemView.findViewById(R.id.tv_media);
                storage = itemView.findViewById(R.id.tv_storage);
            }
        }
    }

    private final class GroupAdapter extends RecyclerView.Adapter<GroupAdapter.VH> {
        private final List<TeamModels.TeamGroup> data = new ArrayList<>();
        private final Map<Integer, Integer> counts = new HashMap<>();

        void submit(@NonNull List<TeamModels.TeamGroup> items, @NonNull Map<Integer, Integer> memberCounts) {
            data.clear();
            data.addAll(items);
            counts.clear();
            counts.putAll(memberCounts);
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_team_group, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            TeamModels.TeamGroup g = data.get(position);
            h.name.setText(g.name);
            h.description.setText((g.description != null && !g.description.trim().isEmpty()) ? g.description : "No description");
            int memberCount = counts.containsKey(g.id) ? Math.max(0, counts.get(g.id)) : 0;
            h.members.setText(memberCount + " member" + (memberCount == 1 ? "" : "s"));
            h.itemView.setOnClickListener(v -> openGroupDetailDialog(g));
            h.itemView.setOnLongClickListener(v -> {
                PopupMenu pm = new PopupMenu(requireContext(), v);
                pm.getMenu().add("Delete Group");
                pm.setOnMenuItemClickListener(item -> {
                    confirmDeleteGroup(g, null);
                    return true;
                });
                pm.show();
                return true;
            });
        }

        @Override
        public int getItemCount() {
            return data.size();
        }

        final class VH extends RecyclerView.ViewHolder {
            final TextView name;
            final TextView description;
            final TextView members;

            VH(@NonNull View itemView) {
                super(itemView);
                name = itemView.findViewById(R.id.tv_group_name);
                description = itemView.findViewById(R.id.tv_group_description);
                members = itemView.findViewById(R.id.tv_group_members);
            }
        }
    }
}
