package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.DialogFragment;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.google.android.material.bottomsheet.BottomSheetDialogFragment;

import java.util.ArrayList;
import java.util.List;

/** Simple year picker bottom sheet used by the Timeline view on phones. */
public class YearPickerBottomSheet extends BottomSheetDialogFragment {
    public static final String KEY_RESULT = "year_picker.result";
    private static final String ARG_YEARS = "years";

    public static YearPickerBottomSheet newInstance(List<Integer> years) {
        YearPickerBottomSheet f = new YearPickerBottomSheet();
        Bundle b = new Bundle();
        int[] arr = new int[years.size()]; for (int i=0;i<years.size();i++) arr[i] = years.get(i);
        b.putIntArray(ARG_YEARS, arr);
        f.setArguments(b);
        return f;
    }

    @Nullable @Override public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        RecyclerView rv = new RecyclerView(requireContext());
        rv.setLayoutManager(new LinearLayoutManager(requireContext()));
        rv.setPadding(16,16,16,16);
        rv.setClipToPadding(false);
        rv.setBackgroundColor(ContextCompat.getColor(requireContext(), ca.openphotos.android.R.color.app_surface));
        int[] years = getArguments()!=null? getArguments().getIntArray(ARG_YEARS) : new int[0];
        List<Integer> list = new ArrayList<>(); if (years != null) for (int y: years) list.add(y);
        rv.setAdapter(new Adapter(list, y -> { Bundle b = new Bundle(); b.putInt("year", y); getParentFragmentManager().setFragmentResult(KEY_RESULT, b); dismissAllowingStateLoss(); }));
        return rv;
    }

    interface OnPick { void onPick(int year); }
    static class Adapter extends RecyclerView.Adapter<VH> {
        final List<Integer> years; final OnPick cb; Adapter(List<Integer> y, OnPick cb) { this.years = y; this.cb = cb; }
        @NonNull @Override public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            TextView t = new TextView(parent.getContext());
            t.setTextSize(18f); t.setPadding(16,20,16,20);
            t.setBackgroundResource(android.R.drawable.list_selector_background);
            t.setTextColor(ContextCompat.getColor(parent.getContext(), ca.openphotos.android.R.color.app_text_primary));
            return new VH(t);
        }
        @Override public void onBindViewHolder(@NonNull VH holder, int position) {
            int year = years.get(position); holder.t.setText(String.valueOf(year)); holder.t.setOnClickListener(v -> cb.onPick(year));
        }
        @Override public int getItemCount() { return years.size(); }
    }
    static class VH extends RecyclerView.ViewHolder { final TextView t; VH(@NonNull View itemView) { super(itemView); t = (TextView) itemView; } }
}
