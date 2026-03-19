package ca.openphotos.android.ui;

import android.app.AlertDialog;
import android.app.Dialog;
import android.os.Bundle;
import android.widget.Button;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import java.util.ArrayList;

/** Single-select picker for existing local album/folder paths. */
public class LocalAlbumPickerDialogFragment extends DialogFragment {
    public static final String KEY_SELECT_RESULT = "local_album_picker.select_result";
    public static final String RESULT_PATH = "path";
    private static final String ARG_PATHS = "paths";

    private int selectedIndex = -1;

    @NonNull
    public static LocalAlbumPickerDialogFragment newInstance(@NonNull ArrayList<String> paths) {
        LocalAlbumPickerDialogFragment fragment = new LocalAlbumPickerDialogFragment();
        Bundle args = new Bundle();
        args.putStringArrayList(ARG_PATHS, paths);
        fragment.setArguments(args);
        return fragment;
    }

    @NonNull
    @Override
    public Dialog onCreateDialog(@Nullable Bundle savedInstanceState) {
        ArrayList<String> paths = getArguments() != null
                ? getArguments().getStringArrayList(ARG_PATHS)
                : new ArrayList<>();
        if (paths == null) paths = new ArrayList<>();
        final ArrayList<String> finalPaths = paths;

        CharSequence[] items = finalPaths.toArray(new CharSequence[0]);
        AlertDialog dialog = new AlertDialog.Builder(requireContext())
                .setTitle("Choose Album")
                .setSingleChoiceItems(items, -1, (d, which) -> selectedIndex = which)
                .setPositiveButton("Add", (d, which) -> {
                    if (selectedIndex < 0 || selectedIndex >= finalPaths.size()) return;
                    Bundle result = new Bundle();
                    result.putString(RESULT_PATH, finalPaths.get(selectedIndex));
                    getParentFragmentManager().setFragmentResult(KEY_SELECT_RESULT, result);
                })
                .setNegativeButton("Cancel", null)
                .create();

        dialog.setOnShowListener(d -> {
            Button positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            if (positive != null) {
                positive.setEnabled(selectedIndex >= 0);
            }
            if (dialog.getListView() != null) {
                dialog.getListView().setOnItemClickListener((parent, view, position, id) -> {
                    selectedIndex = position;
                    if (positive != null) positive.setEnabled(true);
                });
            }
        });
        return dialog;
    }
}
