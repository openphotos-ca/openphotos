package ca.openphotos.android.ui;

import android.graphics.Typeface;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.ImageButton;
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
import androidx.viewpager2.adapter.FragmentStateAdapter;
import androidx.viewpager2.widget.ViewPager2;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.server.TeamModels;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.tabs.TabLayout;
import com.google.android.material.tabs.TabLayoutMediator;

import java.util.ArrayList;
import java.util.List;

/** Full-screen Users & Groups hub (Users / Groups). */
public class UsersGroupsDialogFragment extends DialogFragment {
    private TabLayout tabs;
    private ViewPager2 pager;
    private ImageButton btnReload;
    private View orgSection;
    private EditText etOrgName;
    private MaterialButton btnSaveOrg;
    private TeamModels.OrgInfo orgInfo;
    private UsersGroupsPagerAdapter pagerAdapter;

    public static UsersGroupsDialogFragment newInstance() {
        return new UsersGroupsDialogFragment();
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_users_groups_dialog, container, false);
        root.findViewById(R.id.btn_close).setOnClickListener(v -> dismissAllowingStateLoss());

        btnReload = root.findViewById(R.id.btn_reload);
        tabs = root.findViewById(R.id.users_groups_tabs);
        pager = root.findViewById(R.id.users_groups_pager);
        orgSection = root.findViewById(R.id.org_section);
        etOrgName = root.findViewById(R.id.et_org_name);
        btnSaveOrg = root.findViewById(R.id.btn_save_org);

        pagerAdapter = new UsersGroupsPagerAdapter(this);
        pager.setAdapter(pagerAdapter);
        new TabLayoutMediator(tabs, pager, (tab, position) -> {
            if (position == 0) tab.setText("Users");
            else tab.setText("Groups");
        }).attach();
        setupTabTypography();

        btnReload.setOnClickListener(v -> {
            refreshCurrentPage();
            loadOrgInfoAsync(false);
        });
        btnSaveOrg.setOnClickListener(v -> saveOrgName());

        loadOrgInfoAsync(true);
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

    void onUnauthorizedFromChild() {
        handleAuthExpired();
    }

    private void refreshCurrentPage() {
        if (pagerAdapter == null || pager == null) return;
        UsersGroupsListFragment f = pagerAdapter.getAt(pager.getCurrentItem());
        if (f != null) f.refreshNow();
    }

    private void loadOrgInfoAsync(boolean silent) {
        new Thread(() -> {
            try {
                TeamModels.OrgInfo loaded = new ServerPhotosService(requireContext().getApplicationContext()).getTeamOrgInfo();
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> applyOrgInfo(loaded));
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (msg.contains("HTTP 401") && !AuthManager.get(requireContext().getApplicationContext()).isAuthenticated()) {
                        handleAuthExpired();
                        return;
                    }
                    if (msg.contains("HTTP 403")) {
                        orgSection.setVisibility(View.GONE);
                        if (!silent) {
                            Toast.makeText(requireContext(), "Not authorized to edit organization", Toast.LENGTH_SHORT).show();
                        }
                        return;
                    }
                    if (!silent) Toast.makeText(requireContext(), "Failed to load organization info", Toast.LENGTH_SHORT).show();
                });
            }
        }).start();
    }

    private void applyOrgInfo(@NonNull TeamModels.OrgInfo info) {
        this.orgInfo = info;
        String currentUserId = AuthManager.get(requireContext().getApplicationContext()).getUserId();
        boolean isCreator = currentUserId != null && currentUserId.equals(info.creatorUserId);
        orgSection.setVisibility(isCreator ? View.VISIBLE : View.GONE);
        if (isCreator) etOrgName.setText(info.name != null ? info.name : "");
    }

    private void saveOrgName() {
        if (orgInfo == null) return;
        String newName = etOrgName.getText() != null ? etOrgName.getText().toString().trim() : "";
        if (newName.isEmpty()) {
            Toast.makeText(requireContext(), "Organization name cannot be empty", Toast.LENGTH_SHORT).show();
            return;
        }
        btnSaveOrg.setEnabled(false);
        new Thread(() -> {
            try {
                TeamModels.UpdateOrgRequest req = new TeamModels.UpdateOrgRequest();
                req.name = newName;
                TeamModels.OrgInfo updated = new ServerPhotosService(requireContext().getApplicationContext()).updateTeamOrg(req);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    btnSaveOrg.setEnabled(true);
                    applyOrgInfo(updated);
                    Toast.makeText(requireContext(), "Organization updated", Toast.LENGTH_SHORT).show();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    btnSaveOrg.setEnabled(true);
                    String msg = e.getMessage() != null ? e.getMessage() : "";
                    if (msg.contains("HTTP 401") && !AuthManager.get(requireContext().getApplicationContext()).isAuthenticated()) {
                        handleAuthExpired();
                        return;
                    }
                    if (msg.contains("HTTP 403")) {
                        Toast.makeText(requireContext(), "Not authorized to update organization", Toast.LENGTH_LONG).show();
                        return;
                    }
                    Toast.makeText(requireContext(), "Failed to update organization", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void setupTabTypography() {
        for (int i = 0; i < tabs.getTabCount(); i++) {
            TabLayout.Tab tab = tabs.getTabAt(i);
            if (tab == null) continue;
            TextView label = new TextView(requireContext());
            label.setSingleLine(true);
            label.setGravity(Gravity.CENTER);
            label.setText(tab.getText());
            tab.setCustomView(label);
        }
        updateTabTypography(tabs.getSelectedTabPosition());
        tabs.addOnTabSelectedListener(new TabLayout.OnTabSelectedListener() {
            @Override
            public void onTabSelected(TabLayout.Tab tab) {
                styleTab(tab, true);
            }

            @Override
            public void onTabUnselected(TabLayout.Tab tab) {
                styleTab(tab, false);
            }

            @Override
            public void onTabReselected(TabLayout.Tab tab) {
                styleTab(tab, true);
            }
        });
    }

    private void updateTabTypography(int selectedIndex) {
        for (int i = 0; i < tabs.getTabCount(); i++) {
            TabLayout.Tab tab = tabs.getTabAt(i);
            if (tab == null) continue;
            styleTab(tab, i == selectedIndex);
        }
    }

    private void styleTab(@NonNull TabLayout.Tab tab, boolean selected) {
        View cv = tab.getCustomView();
        if (!(cv instanceof TextView)) return;
        TextView label = (TextView) cv;
        label.setText(tab.getText());
        label.setTextSize(TypedValue.COMPLEX_UNIT_SP, selected ? 17f : 14f);
        label.setTypeface(null, selected ? Typeface.BOLD : Typeface.NORMAL);
        label.setTextColor(ContextCompat.getColor(requireContext(),
                selected ? R.color.app_tab_text_selected : R.color.app_tab_text_unselected));
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

    private static final class UsersGroupsPagerAdapter extends FragmentStateAdapter {
        private final List<UsersGroupsListFragment> pages = new ArrayList<>();

        UsersGroupsPagerAdapter(@NonNull Fragment parent) {
            super(parent);
            pages.add(UsersGroupsListFragment.newInstance(UsersGroupsListFragment.MODE_USERS));
            pages.add(UsersGroupsListFragment.newInstance(UsersGroupsListFragment.MODE_GROUPS));
        }

        @NonNull
        @Override
        public Fragment createFragment(int position) {
            return pages.get(position);
        }

        @Override
        public int getItemCount() {
            return pages.size();
        }

        @Nullable
        UsersGroupsListFragment getAt(int index) {
            if (index < 0 || index >= pages.size()) return null;
            return pages.get(index);
        }
    }
}
