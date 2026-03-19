package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;

import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.dao.UploadDao;
import ca.openphotos.android.data.db.entities.UploadEntity;

import java.util.List;

/** Lists WorkManager tasks and queued uploads with basic fields. */
public class BackgroundTasksFragment extends Fragment {
    private LinearLayout list;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        ScrollView sv = new ScrollView(requireContext());
        list = new LinearLayout(requireContext()); list.setOrientation(LinearLayout.VERTICAL); int pad=24; list.setPadding(pad,pad,pad,pad);
        Button refresh = new Button(requireContext()); refresh.setText("Refresh"); refresh.setOnClickListener(v -> refresh());
        list.addView(refresh);
        sv.addView(list);
        return sv;
    }

    @Override public void onResume() { super.onResume(); refresh(); }

    private void refresh() {
        // Clear all but the first view (Refresh button)
        while (list.getChildCount() > 1) list.removeViewAt(1);
        new Thread(() -> {
            List<String> lines = new java.util.ArrayList<>();
            try {
                List<WorkInfo> infos = WorkManager.getInstance(requireContext()).getWorkInfosByTag("uploads").get();
                if (infos != null) for (WorkInfo wi : infos) { lines.add("Work: " + wi.getId() + " — " + wi.getState()); }
            } catch (Exception ignored) {}
            UploadDao dao = AppDatabase.get(requireContext()).uploadDao();
            List<UploadEntity> rows = dao.listQueued(50);
            for (UploadEntity e : rows) lines.add("Queued: " + e.filename + " — " + (e.totalBytes/1024) + " KB");
            requireActivity().runOnUiThread(() -> {
                for (String s : lines) { TextView tv = new TextView(requireContext()); tv.setText(s); list.addView(tv); }
            });
        }).start();
    }
}
