package ca.openphotos.android.ui;

import android.app.Dialog;
import android.content.ContentResolver;
import android.database.Cursor;
import android.os.Build;
import android.provider.MediaStore;
import android.view.View;
import android.widget.CheckBox;
import android.widget.LinearLayout;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import ca.openphotos.android.prefs.SyncFoldersPreferences;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Minimal folder selection dialog using MediaStore RELATIVE_PATH values. Not a full tree,
 * but lists unique paths and allows marking Sync and Locked sets.
 */
public class FolderTreeDialog extends DialogFragment {
    @NonNull @Override public Dialog onCreateDialog(@Nullable android.os.Bundle savedInstanceState) {
        android.app.AlertDialog.Builder b = new android.app.AlertDialog.Builder(requireContext());
        LinearLayout root = new LinearLayout(requireContext()); root.setOrientation(LinearLayout.VERTICAL); int pad=24; root.setPadding(pad,pad,pad,pad);
        List<String> paths = queryPaths();
        SyncFoldersPreferences prefs = new SyncFoldersPreferences(requireContext());
        Set<String> sync = prefs.getSyncFolders(); Set<String> locked = prefs.getLockedFolders();
        List<Row> rows = new ArrayList<>();
        for (String p : paths) {
            LinearLayout row = new LinearLayout(requireContext()); row.setOrientation(LinearLayout.HORIZONTAL);
            CheckBox cbSync = new CheckBox(requireContext()); cbSync.setText(p); cbSync.setChecked(sync.contains(p));
            CheckBox cbLocked = new CheckBox(requireContext()); cbLocked.setText("Locked"); cbLocked.setChecked(locked.contains(p));
            row.addView(cbSync); row.addView(cbLocked); root.addView(row);
            rows.add(new Row(p, cbSync, cbLocked));
        }
        b.setTitle("Select folders");
        b.setView(root);
        b.setPositiveButton("Save", (d,w)->{
            Set<String> ns = new HashSet<>(); Set<String> nl = new HashSet<>();
            for (Row r : rows) { if (r.sync.isChecked()) ns.add(r.path); if (r.locked.isChecked()) nl.add(r.path); }
            prefs.setSyncFolders(ns); prefs.setLockedFolders(nl);
        });
        b.setNegativeButton("Cancel", null);
        return b.create();
    }

    private List<String> queryPaths() {
        List<String> out = new ArrayList<>();
        ContentResolver cr = requireContext().getContentResolver();
        String column = Build.VERSION.SDK_INT >= 29 ? MediaStore.MediaColumns.RELATIVE_PATH : MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME;
        String[] proj = new String[]{ column };
        java.util.HashSet<String> uniq = new java.util.HashSet<>();
        for (android.net.Uri uri : new android.net.Uri[]{ MediaStore.Images.Media.EXTERNAL_CONTENT_URI, MediaStore.Video.Media.EXTERNAL_CONTENT_URI }) {
            try (Cursor c = cr.query(uri, proj, null, null, null)) {
                if (c == null) continue;
                while (c.moveToNext()) {
                    String p = c.getString(0); if (p == null) p = ""; if (p.endsWith("/")) p = p.substring(0, p.length()-1);
                    if (uniq.add(p)) out.add(p);
                }
            } catch (Exception ignored) {}
        }
        java.util.Collections.sort(out);
        return out;
    }

    static class Row { String path; CheckBox sync; CheckBox locked; Row(String p, CheckBox s, CheckBox l){path=p;sync=s;locked=l;} }
}

