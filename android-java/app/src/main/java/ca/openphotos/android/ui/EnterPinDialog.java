package ca.openphotos.android.ui;

import android.app.Dialog;
import android.os.Bundle;
import android.text.Editable;
import android.text.InputFilter;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.View;
import android.widget.EditText;
import android.widget.LinearLayout;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

/** Simple 8-character PIN dialog. Returns the PIN via a callback. */
public class EnterPinDialog extends DialogFragment {
    public interface Listener { void onPinEntered(String pin); }

    private Listener listener;
    public EnterPinDialog setListener(Listener l) { this.listener = l; return this; }

    @NonNull @Override public Dialog onCreateDialog(@Nullable Bundle savedInstanceState) {
        LinearLayout root = new LinearLayout(requireContext());
        root.setOrientation(LinearLayout.VERTICAL); int pad=24; root.setPadding(pad,pad,pad,pad);
        EditText pin = new EditText(requireContext());
        pin.setHint("Enter 8-character PIN");
        pin.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        pin.setFilters(new InputFilter[]{ new InputFilter.LengthFilter(8) });
        root.addView(pin, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        android.app.AlertDialog.Builder b = new android.app.AlertDialog.Builder(requireContext())
                .setTitle("Unlock Locked Items")
                .setView(root)
                .setPositiveButton("Unlock", null)
                .setNegativeButton("Cancel", null);
        android.app.AlertDialog dialog = b.create();
        dialog.setOnShowListener(d -> {
            final boolean[] submitted = { false };
            final Runnable submit = () -> {
                if (submitted[0]) return;
                String p = pin.getText() != null ? pin.getText().toString() : "";
                if (p.length() != 8) {
                    android.widget.Toast.makeText(requireContext(), "PIN must be 8 characters", android.widget.Toast.LENGTH_SHORT).show();
                    return;
                }
                submitted[0] = true;
                if (listener != null) listener.onPinEntered(p);
                dialog.dismiss();
            };

            android.widget.Button unlock = dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE);
            if (unlock != null) unlock.setOnClickListener(v -> submit.run());

            pin.addTextChangedListener(new TextWatcher() {
                @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
                @Override public void onTextChanged(CharSequence s, int start, int before, int count) {}
                @Override public void afterTextChanged(Editable s) {
                    if (s != null && s.length() == 8) pin.post(submit);
                }
            });
        });
        return dialog;
    }
}
