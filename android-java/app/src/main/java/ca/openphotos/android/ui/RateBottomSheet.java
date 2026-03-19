package ca.openphotos.android.ui;

import android.app.Dialog;
import android.os.Bundle;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import ca.openphotos.android.server.ServerPhotosService;

/** Bottom sheet to set rating 0..5 (0 clears) for server items. */
public class RateBottomSheet extends DialogFragment {
    public interface OnRated { void onRated(int value); }
    private OnRated onRated;
    public void setOnRated(OnRated cb) { this.onRated = cb; }
    public static RateBottomSheet newInstance(String assetId, int current) {
        RateBottomSheet s = new RateBottomSheet();
        Bundle b = new Bundle(); b.putString("assetId", assetId); b.putInt("current", current); s.setArguments(b); return s;
    }
    @NonNull @Override public Dialog onCreateDialog(@Nullable Bundle savedInstanceState) {
        android.app.AlertDialog.Builder b = new android.app.AlertDialog.Builder(requireContext());
        LinearLayout root = new LinearLayout(requireContext()); root.setOrientation(LinearLayout.VERTICAL); int pad=24; root.setPadding(pad,pad,pad,pad);
        TextView title = new TextView(requireContext()); title.setText("Select rating (0 clears)"); root.addView(title);
        LinearLayout row = new LinearLayout(requireContext()); row.setOrientation(LinearLayout.HORIZONTAL);
        final int[] sel = new int[]{ getArguments()!=null ? getArguments().getInt("current", 0) : 0 };
        for (int i=0;i<=5;i++) {
            final int v=i; TextView tv = new TextView(requireContext()); tv.setText(i==0?"0":"★"+i); tv.setPadding(16,16,16,16); tv.setOnClickListener(view->{ sel[0]=v; }); row.addView(tv);
        }
        root.addView(row);
        b.setView(root);
        b.setTitle("Rate");
        b.setPositiveButton("Save", (d,w)->{
            String assetId = getArguments()!=null? getArguments().getString("assetId", ""):"";
            new Thread(() -> {
                try {
                    Integer val = (sel[0] == 0) ? null : Integer.valueOf(sel[0]);
                    new ServerPhotosService(requireContext().getApplicationContext()).updateRating(assetId, val);
                    if (onRated!=null) requireActivity().runOnUiThread(()-> onRated.onRated(sel[0]));
                } catch (Exception e) { requireActivity().runOnUiThread(()-> Toast.makeText(requireContext(), "Rating failed", Toast.LENGTH_LONG).show()); }
            }).start();
        });
        b.setNegativeButton("Cancel", null);
        return b.create();
    }
}

