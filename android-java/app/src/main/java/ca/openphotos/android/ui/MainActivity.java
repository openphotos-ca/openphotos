package ca.openphotos.android.ui;

import android.os.Bundle;
import android.content.SharedPreferences;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.appcompat.app.AppCompatActivity;
import androidx.appcompat.app.AppCompatDelegate;
import ca.openphotos.android.R;
import com.google.android.material.bottomnavigation.BottomNavigationView;
import androidx.navigation.NavController;
import androidx.navigation.fragment.NavHostFragment;
import androidx.navigation.ui.NavigationUI;
import ca.openphotos.android.prefs.AppearancePreferences;
import ca.openphotos.android.core.AppUpdateService;
import ca.openphotos.android.util.ForegroundUploadScreenController;
import ca.openphotos.android.util.PermissionsHelper;

/**
 * Minimal host activity with tabs planned for Local and Server.
 * For now, this is an empty scaffold per plan (UI added in later steps).
 */
public class MainActivity extends AppCompatActivity {
    private static final String PREFS_STARTUP = "startup.permissions";
    private static final String KEY_MEDIA_READ_PROMPTED = "media_read_prompted";

    private ActivityResultLauncher<String[]> mediaReadPermissionLauncher;
    private final Runnable keepScreenOnUpdater = () -> ForegroundUploadScreenController.applyTo(this);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        AppCompatDelegate.setDefaultNightMode(new AppearancePreferences(this).nightMode());
        super.onCreate(savedInstanceState);

        mediaReadPermissionLauncher = registerForActivityResult(
                new ActivityResultContracts.RequestMultiplePermissions(),
                result -> { /* Local photos tab remains the fallback UI if access is denied. */ });

        setContentView(R.layout.activity_main);
        ForegroundUploadScreenController.applyTo(this);

        NavHostFragment navHost = (NavHostFragment) getSupportFragmentManager().findFragmentById(R.id.nav_host_fragment);
        NavController navController = navHost.getNavController();
        BottomNavigationView bottom = findViewById(R.id.bottom_nav);
        // Map bottom nav selections to top-level destinations in nav_graph
        bottom.setOnItemSelectedListener(item -> {
            int id = item.getItemId();
            if (id == R.id.nav_local) { navController.navigate(R.id.localFragment); return true; }
            if (id == R.id.nav_server) {
                boolean authed = ca.openphotos.android.core.AuthManager.get(this).isAuthenticated();
                if (!authed) { navController.navigate(R.id.serverLoginFragment); }
                else { navController.navigate(R.id.serverHostFragment); }
                return true;
            }
            if (id == R.id.nav_sync) { navController.navigate(R.id.syncFragment); return true; }
            if (id == R.id.nav_settings) { navController.navigate(R.id.settingsFragment); return true; }
            return false;
        });
        // Default to Photos (Server) first
        bottom.setSelectedItemId(R.id.nav_server);

        requestStartupMediaReadIfNeeded(savedInstanceState == null);
    }

    @Override
    protected void onStart() {
        super.onStart();
        ForegroundUploadScreenController.addListener(keepScreenOnUpdater);
        ForegroundUploadScreenController.applyTo(this);
        // Trigger auto-start whenever app becomes foregrounded.
        try {
            ca.openphotos.android.sync.SyncService.get(this).onAppOpen();
        } catch (Exception ignored) {
        }
        try {
            AppUpdateService.maybeCheckIfStale(this);
        } catch (Exception ignored) {
        }
    }

    @Override
    protected void onStop() {
        ForegroundUploadScreenController.removeListener(keepScreenOnUpdater);
        super.onStop();
    }

    private void requestStartupMediaReadIfNeeded(boolean firstCreation) {
        if (!firstCreation) return;
        if (PermissionsHelper.hasMediaRead(this)) return;

        SharedPreferences prefs = getSharedPreferences(PREFS_STARTUP, MODE_PRIVATE);
        if (prefs.getBoolean(KEY_MEDIA_READ_PROMPTED, false)) return;

        prefs.edit().putBoolean(KEY_MEDIA_READ_PROMPTED, true).apply();
        mediaReadPermissionLauncher.launch(PermissionsHelper.mediaReadPermissions());
    }
}
