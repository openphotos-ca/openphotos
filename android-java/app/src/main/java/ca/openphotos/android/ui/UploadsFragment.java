package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;

import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.dao.UploadDao;
import ca.openphotos.android.data.db.entities.UploadEntity;
import ca.openphotos.android.prefs.SyncPreferences;
import ca.openphotos.android.upload.UploadScheduler;
import ca.openphotos.android.upload.UploadStopController;
import ca.openphotos.android.util.ForegroundUploadScreenController;
import com.google.android.material.switchmaterial.SwitchMaterial;

import java.util.List;

/** Upload queue view with iOS-like essentials: progress list + keep-screen + background switch. */
public class UploadsFragment extends Fragment {
    private LinearLayout list;
    private SyncPreferences prefs;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        prefs = new SyncPreferences(requireContext().getApplicationContext());

        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL);

        LinearLayout topBar = new LinearLayout(requireContext());
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setPadding(dp(12), dp(8), dp(12), dp(8));

        Button refresh = new Button(requireContext());
        refresh.setText("Refresh");
        refresh.setOnClickListener(v -> refresh());
        topBar.addView(refresh);

        root.addView(topBar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        ScrollView sv = new ScrollView(requireContext());
        list = new LinearLayout(requireContext());
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(dp(12), dp(8), dp(12), dp(8));
        sv.addView(list);

        LinearLayout.LayoutParams lpList = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        root.addView(sv, lpList);

        LinearLayout controls = new LinearLayout(requireContext());
        controls.setOrientation(LinearLayout.VERTICAL);
        controls.setPadding(dp(12), dp(8), dp(12), dp(12));

        SwitchMaterial keepScreen = new SwitchMaterial(requireContext());
        keepScreen.setText("Keep screen on during upload");
        keepScreen.setChecked(prefs.keepScreenOn());
        keepScreen.setOnCheckedChangeListener((b, on) -> {
            prefs.setKeepScreenOn(on);
            if (isAdded()) ForegroundUploadScreenController.applyTo(requireActivity());
        });
        controls.addView(keepScreen);

        Button bg = new Button(requireContext());
        bg.setText("Switch to Background Uploads");
        bg.setOnClickListener(v -> {
            UploadStopController.clearUserStopRequest();
            UploadScheduler.scheduleOnce(requireContext().getApplicationContext(), prefs.wifiOnly());
            Toast.makeText(requireContext(), "Background upload scheduled", Toast.LENGTH_SHORT).show();
        });
        controls.addView(bg);

        root.addView(controls, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return root;
    }

    @Override
    public void onResume() {
        super.onResume();
        refresh();
    }

    private void refresh() {
        if (list == null) return;
        list.removeAllViews();
        new Thread(() -> {
            UploadDao dao = AppDatabase.get(requireContext().getApplicationContext()).uploadDao();
            List<UploadEntity> rows = dao.listAll();
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> {
                for (UploadEntity e : rows) {
                    TextView row = new TextView(requireContext());
                    String st = statusText(e.status);
                    String prog = formatBytes(e.sentBytes) + " / " + formatBytes(e.totalBytes);
                    row.setText(e.filename + "\n" + st + "  ·  " + prog);
                    row.setTextSize(14f);
                    row.setPadding(0, dp(8), 0, dp(8));
                    list.addView(row);
                }
            });
        }).start();
    }

    private String statusText(int s) {
        switch (s) {
            case 0:
                return "Queued";
            case 1:
                return "Uploading";
            case 2:
                return "Completed";
            case 3:
                return "Failed";
            default:
                return "Unknown";
        }
    }

    private String formatBytes(long b) {
        if (b < 1024) return b + " B";
        int exp = (int) (Math.log(b) / Math.log(1024));
        String pre = ("KMGTPE").charAt(exp - 1) + "";
        return String.format(java.util.Locale.US, "%.1f %sB", b / Math.pow(1024, exp), pre);
    }

    private int dp(int v) {
        float d = getResources().getDisplayMetrics().density;
        return Math.round(v * d);
    }
}
