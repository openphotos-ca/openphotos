package ca.openphotos.android.ui;

import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
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
import com.google.android.material.tabs.TabLayout;
import com.google.android.material.tabs.TabLayoutMediator;

import java.util.ArrayList;
import java.util.List;

/** Full-screen sharing hub (My Shares / Shared with me / Public Links). */
public class SharingDialogFragment extends DialogFragment {
    private TabLayout tabs;
    private ViewPager2 pager;
    private ImageButton btnAdd;
    private SharingPagerAdapter pagerAdapter;

    public static SharingDialogFragment newInstance() {
        return new SharingDialogFragment();
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_sharing_dialog, container, false);
        root.findViewById(R.id.btn_close).setOnClickListener(v -> dismissAllowingStateLoss());
        btnAdd = root.findViewById(R.id.btn_add);
        tabs = root.findViewById(R.id.sharing_tabs);
        pager = root.findViewById(R.id.sharing_pager);

        pagerAdapter = new SharingPagerAdapter(this);
        pager.setAdapter(pagerAdapter);
        new TabLayoutMediator(tabs, pager, (tab, position) -> {
            if (position == 0) tab.setText("My Shares");
            else if (position == 1) tab.setText("Shared with me");
            else tab.setText("Public Links");
        }).attach();
        setupTabTypography();

        pager.registerOnPageChangeCallback(new ViewPager2.OnPageChangeCallback() {
            @Override
            public void onPageSelected(int position) {
                updateAddVisibility(position);
            }
        });
        updateAddVisibility(0);

        btnAdd.setOnClickListener(v -> onAddPressed());

        getParentFragmentManager().setFragmentResultListener(CreateShareDialogFragment.KEY_SHARE_CREATED, this,
                (key, result) -> refreshCurrent());
        getParentFragmentManager().setFragmentResultListener(ShareViewerFragment.KEY_VIEWER_AUTH_EXPIRED, this,
                (key, result) -> handleAuthExpired());
        return root;
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
        label.setTypeface(null, selected ? android.graphics.Typeface.BOLD : android.graphics.Typeface.NORMAL);
        label.setTextColor(ContextCompat.getColor(requireContext(),
                selected ? R.color.app_tab_text_selected : R.color.app_tab_text_unselected));
    }

    @Override
    public void onStart() {
        super.onStart();
        if (getDialog() != null && getDialog().getWindow() != null) {
            getDialog().getWindow().setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            getDialog().getWindow().setBackgroundDrawableResource(R.color.app_background);
        }
    }

    private void updateAddVisibility(int tabIndex) {
        if (btnAdd == null) return;
        btnAdd.setVisibility(tabIndex == 1 ? View.INVISIBLE : View.VISIBLE);
    }

    private void onAddPressed() {
        int tab = pager.getCurrentItem();
        if (tab == 1) return;

        AlbumTreeDialogFragment tree = AlbumTreeDialogFragment.newInstance(false);
        getParentFragmentManager().setFragmentResultListener(AlbumTreeDialogFragment.KEY_SELECT_RESULT, this,
                (key, bundle) -> {
                    getParentFragmentManager().clearFragmentResultListener(AlbumTreeDialogFragment.KEY_SELECT_RESULT);
                    int albumId = bundle.getInt("album_id", 0);
                    if (albumId <= 0) return;
                    openCreateDialogForAlbum(albumId, tab == 2);
                });
        tree.show(getParentFragmentManager(), "sharing_album_picker");
    }

    private void openCreateDialogForAlbum(int albumId, boolean publicTab) {
        new Thread(() -> {
            String albumName = "Album " + albumId;
            try {
                List<AlbumName> names = queryAlbumNames();
                for (AlbumName a : names) {
                    if (a.id == albumId && a.name != null && !a.name.isEmpty()) {
                        albumName = a.name;
                        break;
                    }
                }
            } catch (Exception ignored) {
            }
            final String finalName = albumName;
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> {
                CreateShareDialogFragment dlg = CreateShareDialogFragment.newInstance(
                        "album",
                        String.valueOf(albumId),
                        finalName,
                        0,
                        null,
                        null
                );
                dlg.setInitialTab(publicTab ? CreateShareDialogFragment.INITIAL_TAB_PUBLIC : CreateShareDialogFragment.INITIAL_TAB_INTERNAL);
                dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
                dlg.show(getParentFragmentManager(), "create_share_from_hub");
            });
        }).start();
    }

    private void refreshCurrent() {
        if (pagerAdapter == null || pager == null) return;
        SharingListFragment f = pagerAdapter.getAt(pager.getCurrentItem());
        if (f != null) f.refreshNow();
    }

    void openShareViewer(@NonNull String shareId, @NonNull String title, int perms, boolean includeFaces) {
        ShareViewerFragment f = ShareViewerFragment.newInstance(shareId, title, perms, includeFaces);
        f.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
        f.show(getParentFragmentManager(), "share_viewer");
    }

    void onUnauthorizedFromChild() {
        handleAuthExpired();
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

    private List<AlbumName> queryAlbumNames() throws Exception {
        ArrayList<AlbumName> out = new ArrayList<>();
        org.json.JSONArray arr = new ServerPhotosService(requireContext().getApplicationContext()).listAlbums();
        for (int i = 0; i < arr.length(); i++) {
            org.json.JSONObject j = arr.optJSONObject(i);
            if (j == null) continue;
            out.add(new AlbumName(j.optInt("id", 0), j.optString("name", "")));
        }
        return out;
    }

    private static final class AlbumName {
        final int id;
        final String name;

        AlbumName(int id, String name) {
            this.id = id;
            this.name = name;
        }
    }

    private static final class SharingPagerAdapter extends FragmentStateAdapter {
        private final List<SharingListFragment> pages = new ArrayList<>();

        SharingPagerAdapter(@NonNull Fragment parent) {
            super(parent);
            pages.add(SharingListFragment.newInstance(SharingListFragment.MODE_MY_SHARES));
            pages.add(SharingListFragment.newInstance(SharingListFragment.MODE_SHARED_WITH_ME));
            pages.add(SharingListFragment.newInstance(SharingListFragment.MODE_PUBLIC_LINKS));
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
        SharingListFragment getAt(int index) {
            if (index < 0 || index >= pages.size()) return null;
            return pages.get(index);
        }
    }
}
