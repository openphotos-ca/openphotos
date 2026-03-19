package ca.openphotos.android.ui;

import android.app.Dialog;
import android.os.Bundle;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.ListView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import ca.openphotos.android.server.ServerPhotosService;

/** Bottom sheet to add a person to the photo (manual entry via server API). */
public class AddPersonBottomSheet extends DialogFragment {
    public static AddPersonBottomSheet newInstance(String assetId) { AddPersonBottomSheet f = new AddPersonBottomSheet(); Bundle b = new Bundle(); b.putString("assetId", assetId); f.setArguments(b); return f; }

    @NonNull @Override public Dialog onCreateDialog(@Nullable Bundle savedInstanceState) {
        String aid = getArguments()!=null? getArguments().getString("assetId","") : "";
        ListView list = new ListView(requireContext());
        ArrayAdapter<String> adapter = new ArrayAdapter<>(requireContext(), android.R.layout.simple_list_item_1);
        list.setAdapter(adapter);
        Dialog d = new android.app.AlertDialog.Builder(requireContext()).setTitle("Add Person").setView(list).setNegativeButton("Close", null).create();

        list.setOnItemClickListener((parent, view, position, id) -> {
            String pid = adapter.getItem(position);
            new Thread(() -> { try { new ServerPhotosService(requireContext().getApplicationContext()).addPersonToPhoto(aid, pid); requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Added", android.widget.Toast.LENGTH_SHORT).show()); } catch (Exception e) { requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Add failed", android.widget.Toast.LENGTH_LONG).show()); } }).start();
        });

        new Thread(() -> {
            try { org.json.JSONArray persons = new ServerPhotosService(requireContext().getApplicationContext()).getPersons(); requireActivity().runOnUiThread(() -> { for (int i=0;i<persons.length();i++) { try { String id = persons.getJSONObject(i).optString("person_id"); String name = persons.getJSONObject(i).optString("display_name", id); adapter.add(name.equals(id)? id : name); } catch (Exception ignored) {} } adapter.notifyDataSetChanged(); }); } catch (Exception ignored) {}
        }).start();

        return d;
    }
}

