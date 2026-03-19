package ca.openphotos.android.ui;

import android.app.Dialog;
import android.os.Bundle;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.LinearLayout;
import android.widget.Spinner;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import ca.openphotos.android.server.ServerPhotosService;

/** Bottom sheet to assign a detected face to a person (or clear). */
public class UpdatePersonBottomSheet extends DialogFragment {
    public static UpdatePersonBottomSheet newInstance(String assetId) { UpdatePersonBottomSheet f = new UpdatePersonBottomSheet(); Bundle b = new Bundle(); b.putString("assetId", assetId); f.setArguments(b); return f; }

    @NonNull @Override public Dialog onCreateDialog(@Nullable Bundle savedInstanceState) {
        String aid = getArguments()!=null? getArguments().getString("assetId","") : "";
        LinearLayout root = new LinearLayout(requireContext()); root.setOrientation(LinearLayout.VERTICAL); int pad=24; root.setPadding(pad,pad,pad,pad);
        Spinner faces = new Spinner(requireContext()); Spinner persons = new Spinner(requireContext());
        root.addView(faces); root.addView(persons);
        ArrayAdapter<String> facesAdapter = new ArrayAdapter<>(requireContext(), android.R.layout.simple_spinner_dropdown_item); faces.setAdapter(facesAdapter);
        ArrayAdapter<String> personsAdapter = new ArrayAdapter<>(requireContext(), android.R.layout.simple_spinner_dropdown_item); persons.setAdapter(personsAdapter);

        Dialog d = new android.app.AlertDialog.Builder(requireContext()).setTitle("Update Person").setView(root).setPositiveButton("Assign", (di,w)->{
            String face = (String) faces.getSelectedItem(); String pid = (String) persons.getSelectedItem(); if (face==null) return; new Thread(() -> { try { new ServerPhotosService(requireContext().getApplicationContext()).assignFace(face, pid); requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Face updated", android.widget.Toast.LENGTH_SHORT).show()); } catch (Exception e) { requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Update failed", android.widget.Toast.LENGTH_LONG).show()); } }).start();
        }).setNegativeButton("Cancel", null).setNeutralButton("Clear", (di,w)->{ String face = (String) faces.getSelectedItem(); if (face==null) return; new Thread(() -> { try { new ServerPhotosService(requireContext().getApplicationContext()).assignFace(face, null); requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Cleared", android.widget.Toast.LENGTH_SHORT).show()); } catch (Exception e) { requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Clear failed", android.widget.Toast.LENGTH_LONG).show()); } }).start(); }).create();

        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONArray f = svc.getFacesForAsset(aid); org.json.JSONArray p = svc.getPersons();
                requireActivity().runOnUiThread(() -> {
                    for (int i=0;i<f.length();i++) { try { facesAdapter.add(f.getJSONObject(i).optString("face_id")); } catch (Exception ignored) {} }
                    for (int i=0;i<p.length();i++) { try { String id = p.getJSONObject(i).optString("person_id"); String name = p.getJSONObject(i).optString("display_name", id); personsAdapter.add(name.equals(id)? id : (name)); } catch (Exception ignored) {} }
                    facesAdapter.notifyDataSetChanged(); personsAdapter.notifyDataSetChanged();
                });
            } catch (Exception ignored) {}
        }).start();

        return d;
    }
}

