package ca.openphotos.android.ui;

import android.content.Context;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import androidx.navigation.fragment.NavHostFragment;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.textfield.TextInputEditText;

/** Dedicated change-password screen aligned with iOS flow. */
public class ChangePasswordFragment extends Fragment {
    private AuthManager auth;

    private View cardDemoReadonly;
    private TextInputEditText etCurrent;
    private TextInputEditText etNew;
    private TextInputEditText etConfirm;
    private TextView tvError;
    private MaterialButton btnSubmit;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        return inflater.inflate(R.layout.fragment_change_password, container, false);
    }

    @Override
    public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        Context app = requireContext().getApplicationContext();
        auth = AuthManager.get(app);

        view.findViewById(R.id.btn_change_password_back).setOnClickListener(v -> NavHostFragment.findNavController(this).popBackStack());

        cardDemoReadonly = view.findViewById(R.id.card_change_password_demo_readonly);
        etCurrent = view.findViewById(R.id.et_current_password);
        etNew = view.findViewById(R.id.et_new_password);
        etConfirm = view.findViewById(R.id.et_confirm_password);
        tvError = view.findViewById(R.id.tv_change_password_error);
        btnSubmit = view.findViewById(R.id.btn_submit_change_password);

        btnSubmit.setOnClickListener(v -> submit());

        boolean demoReadOnly = auth.isDemoUser();
        cardDemoReadonly.setVisibility(demoReadOnly ? View.VISIBLE : View.GONE);
        setEditableEnabled(!demoReadOnly);
    }

    private void setEditableEnabled(boolean enabled) {
        etCurrent.setEnabled(enabled);
        etNew.setEnabled(enabled);
        etConfirm.setEnabled(enabled);
        btnSubmit.setEnabled(enabled);
    }

    private void submit() {
        String current = etCurrent.getText() != null ? etCurrent.getText().toString() : "";
        String next = etNew.getText() != null ? etNew.getText().toString() : "";
        String confirm = etConfirm.getText() != null ? etConfirm.getText().toString() : "";

        String err = validate(current, next, confirm);
        if (err != null) {
            showError(err);
            return;
        }
        showError(null);
        setSubmitting(true);

        new Thread(() -> {
            try {
                auth.changePassword(next, current);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    setSubmitting(false);
                    Toast.makeText(requireContext(), "Password changed. Please sign in again.", Toast.LENGTH_LONG).show();
                    NavHostFragment.findNavController(this).navigate(R.id.serverLoginFragment);
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    setSubmitting(false);
                    String msg = e.getMessage() != null && !e.getMessage().isEmpty()
                            ? e.getMessage()
                            : "Failed to change password";
                    showError(msg);
                });
            }
        }).start();
    }

    private void setSubmitting(boolean submitting) {
        etCurrent.setEnabled(!submitting);
        etNew.setEnabled(!submitting);
        etConfirm.setEnabled(!submitting);
        btnSubmit.setEnabled(!submitting && !auth.isDemoUser());
        btnSubmit.setText(submitting ? "Changing..." : "Change Password");
    }

    @Nullable
    private String validate(@NonNull String current, @NonNull String next, @NonNull String confirm) {
        if (current.trim().isEmpty()) return "Current password is required";
        if (next.length() < 6) return "Password must be at least 6 characters";
        if (!next.equals(confirm)) return "Passwords do not match";
        return null;
    }

    private void showError(@Nullable String msg) {
        if (msg == null || msg.trim().isEmpty()) {
            tvError.setVisibility(View.GONE);
            tvError.setText("");
            return;
        }
        tvError.setVisibility(View.VISIBLE);
        tvError.setText(msg);
    }
}
