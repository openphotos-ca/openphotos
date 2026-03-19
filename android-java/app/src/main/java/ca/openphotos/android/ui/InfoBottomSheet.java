package ca.openphotos.android.ui;

import android.app.Dialog;
import android.os.Bundle;
import android.text.SpannableStringBuilder;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import ca.openphotos.android.server.ServerPhotosService;

/**
 * InfoBottomSheet shows read-only metadata sections (File/Camera/Dates/Location/People) and
 * provides quick actions to edit metadata and set rating (opens existing sheets).
 */
public class InfoBottomSheet extends DialogFragment {
    public static InfoBottomSheet newInstance(String assetId) { InfoBottomSheet s = new InfoBottomSheet(); Bundle b = new Bundle(); b.putString("assetId", assetId); s.setArguments(b); return s; }

    @NonNull @Override public Dialog onCreateDialog(@Nullable Bundle savedInstanceState) {
        String aid = getArguments()!=null? getArguments().getString("assetId","") : "";
        ScrollView sv = new ScrollView(requireContext());
        LinearLayout root = new LinearLayout(requireContext()); root.setOrientation(LinearLayout.VERTICAL); int pad=24; root.setPadding(pad,pad,pad,pad);
        sv.addView(root);

        TextView header = new TextView(requireContext()); header.setText("Loading…"); header.setTextAppearance(android.R.style.TextAppearance_Medium); root.addView(header);
        TextView body = new TextView(requireContext()); root.addView(body);

        LinearLayout actions = new LinearLayout(requireContext()); actions.setOrientation(LinearLayout.HORIZONTAL);
        android.widget.Button edit = new android.widget.Button(requireContext()); edit.setText("Edit Metadata"); edit.setOnClickListener(v -> EditMetadataBottomSheet.newInstance(aid).show(getParentFragmentManager(), "editMeta"));
        android.widget.Button rate = new android.widget.Button(requireContext()); rate.setText("Set Rating"); rate.setOnClickListener(v -> { RateBottomSheet r = RateBottomSheet.newInstance(aid, 0); r.show(getParentFragmentManager(), "rate"); });
        actions.addView(edit); actions.addView(rate); root.addView(actions);

        Dialog d = new android.app.AlertDialog.Builder(requireContext()).setTitle("Info").setView(sv).setPositiveButton("Close", null).create();

        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONArray arr = svc.getPhotosByAssetIds(java.util.Collections.singletonList(aid), true);
                org.json.JSONObject p = arr.length()>0? arr.getJSONObject(0): null;
                org.json.JSONArray persons = svc.getPersonsForAsset(aid);
                SpannableStringBuilder sb = new SpannableStringBuilder();
                if (p != null) {
                    // File
                    sb.append("File\n");
                    sb.append("Name: ").append(p.optString("filename", aid)).append("\n");
                    sb.append("Asset ID: ").append(aid).append("\n");
                    sb.append("Size: ").append(String.valueOf(p.optLong("size",0))).append(" bytes\n\n");
                    // Camera
                    sb.append("Camera\n");
                    sb.append(p.optString("camera_make","")); if (p.has("camera_model")) sb.append(" ").append(p.optString("camera_model","")); sb.append("\n");
                    // Dates
                    sb.append("Dates\n"); sb.append("Taken: ").append(String.valueOf(p.optLong("created_at",0))).append("\n\n");
                    // Location
                    sb.append("Location\n"); sb.append(p.optString("location_name"," ")).append("\n\n");
                }
                sb.append("People\n");
                for (int i=0;i<persons.length();i++) { org.json.JSONObject per = persons.getJSONObject(i); String name = per.optString("display_name", per.optString("person_id","(unknown)")); sb.append("• ").append(name).append("\n"); }
                requireActivity().runOnUiThread(() -> { header.setText("Details"); body.setText(sb); });
            } catch (Exception e) { requireActivity().runOnUiThread(() -> { header.setText("Error"); body.setText(e.getMessage()); }); }
        }).start();

        return d;
    }
}

