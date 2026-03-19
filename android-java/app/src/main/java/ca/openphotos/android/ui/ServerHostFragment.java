package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import androidx.fragment.app.FragmentActivity;
import androidx.viewpager2.adapter.FragmentStateAdapter;
import androidx.viewpager2.widget.ViewPager2;
import android.os.Bundle;

import ca.openphotos.android.R;
import com.google.android.material.tabs.TabLayout;
import com.google.android.material.tabs.TabLayoutMediator;

/**
 * Hosts the Server sub-sections with a top segmented control: Library | Albums | Faces | Search.
 */
public class ServerHostFragment extends Fragment {
    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        return inflater.inflate(R.layout.fragment_server_host, container, false);
    }

    @Override
    public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        // If not authenticated, redirect to login screen
        if (!ca.openphotos.android.core.AuthManager.get(requireContext()).isAuthenticated()) {
            try {
                androidx.navigation.fragment.NavHostFragment.findNavController(this).navigate(ca.openphotos.android.R.id.serverLoginFragment);
            } catch (Exception ignored) {}
            return;
        }
        TabLayout tabs = view.findViewById(R.id.server_tabs);
        ViewPager2 pager = view.findViewById(R.id.server_pager);
        // Use child FragmentManager by passing this Fragment to the adapter
        // to avoid crashes when hosting ViewPager2 inside a Fragment.
        pager.setAdapter(new ServerTabsAdapter(this));
        // Disable horizontal swipe; navigation happens only via tabs/buttons
        pager.setUserInputEnabled(false);
        new TabLayoutMediator(tabs, pager, (tab, position) -> {
            switch (position) {
                case 0: tab.setText("Library"); break;
                case 1: tab.setText("Albums"); break;
                case 2: tab.setText("Faces"); break;
                default: tab.setText("Search"); break;
            }
        }).attach();
        // Hide the top tabs on the Photos page to match iOS layout
        ViewPager2.OnPageChangeCallback cb = new ViewPager2.OnPageChangeCallback() {
            @Override public void onPageSelected(int position) {
                super.onPageSelected(position);
                tabs.setVisibility(position == 0 ? View.GONE : View.VISIBLE);
            }
        };
        pager.registerOnPageChangeCallback(cb);
        tabs.setVisibility(pager.getCurrentItem() == 0 ? View.GONE : View.VISIBLE);
    }

    static class ServerTabsAdapter extends FragmentStateAdapter {
        ServerTabsAdapter(@NonNull Fragment fragment) { super(fragment); }
        @NonNull @Override public Fragment createFragment(int position) {
            switch (position) {
                case 0: return new PhotosHomeFragment();
                case 1: return new AlbumsListFragment();
                case 2: return new FacesGridFragment();
                default: return new SearchFragment();
            }
        }
        @Override public int getItemCount() { return 4; }
    }
    @Override public void onResume() {
        super.onResume();
        // Navigate to specific tab if requested via argument
        ViewPager2 pager = requireView().findViewById(R.id.server_pager);
        Bundle args = getArguments();
        if (args != null && pager != null) {
            int idx = args.getInt("initialTab", -1);
            if (idx >= 0 && idx < 4) { pager.setCurrentItem(idx, false); args.remove("initialTab"); }
        }
    }
}
