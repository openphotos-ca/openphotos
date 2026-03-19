package ca.openphotos.android.ui;

import android.app.Dialog;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import ca.openphotos.android.server.ServerPhotosService;

/** Bottom sheet to edit caption/description for a server photo. */
public class EditMetadataBottomSheet extends DialogFragment {
    public static EditMetadataBottomSheet newInstance(String assetId) {
        EditMetadataBottomSheet s = new EditMetadataBottomSheet();
        Bundle b = new Bundle(); b.putString("assetId", assetId); s.setArguments(b); return s;
    }

    @NonNull @Override public Dialog onCreateDialog(@Nullable Bundle savedInstanceState) {
        android.app.AlertDialog.Builder b = new android.app.AlertDialog.Builder(requireContext());
        View v = getLayoutInflater().inflate(android.R.layout.simple_list_item_2, null);
        // Reuse a simple layout; attach two inputs programmatically
        android.widget.LinearLayout root = new android.widget.LinearLayout(requireContext());
        root.setOrientation(android.widget.LinearLayout.VERTICAL);
        int pad = 24; root.setPadding(pad,pad,pad,pad);
        EditText caption = new EditText(requireContext()); caption.setHint("Caption");
        EditText desc = new EditText(requireContext()); desc.setHint("Description"); desc.setMinLines(2);
        root.addView(caption); root.addView(desc);
        b.setView(root);
        b.setTitle("Edit Metadata");
        b.setPositiveButton("Save", (d,w) -> {
            String assetId = getArguments() != null ? getArguments().getString("assetId", "") : "";
            new Thread(() -> {
                try {
                    new ServerPhotosService(requireContext().getApplicationContext()).updateMetadata(assetId, caption.getText().toString(), desc.getText().toString());
                    requireActivity().runOnUiThread(() -> Toast.makeText(requireContext(), "Saved", Toast.LENGTH_SHORT).show());
                } catch (Exception e) {
                    requireActivity().runOnUiThread(() -> Toast.makeText(requireContext(), "Save failed", Toast.LENGTH_LONG).show());
                }
            }).start();
        });
        b.setNegativeButton("Cancel", null);
        return b.create();
    }
}

