package ca.openphotos.android.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.os.Bundle;
import android.security.keystore.UserNotAuthenticatedException;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.RadioGroup;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import androidx.navigation.fragment.NavHostFragment;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.e2ee.DeviceUMKStore;
import ca.openphotos.android.e2ee.E2EEManager;
import ca.openphotos.android.prefs.SecurityPreferences;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.switchmaterial.SwitchMaterial;
import com.google.android.material.textfield.TextInputEditText;

import org.json.JSONObject;

import java.security.SecureRandom;

import javax.crypto.Cipher;

/** Security settings parity screen (PIN flow, metadata toggles, remember-unlock duration). */
public class SecuritySettingsFragment extends Fragment {
    private static final int TTL_15_MIN = 15 * 60;
    private static final int TTL_1_HOUR = 60 * 60;
    private static final int TTL_24_HOURS = 24 * 60 * 60;

    private SecurityPreferences securityPrefs;
    private AuthManager auth;
    private Context appContext;
    private MaterialButton btnSetChangePin;
    private SwitchMaterial swLocation;
    private SwitchMaterial swDescription;
    private SwitchMaterial swCaption;
    private RadioGroup rgTtl;
    private View cardDemoReadonly;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        return inflater.inflate(R.layout.fragment_security_settings, container, false);
    }

    @Override
    public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        appContext = requireContext().getApplicationContext();
        securityPrefs = new SecurityPreferences(appContext);
        auth = AuthManager.get(appContext);

        view.findViewById(R.id.btn_security_back).setOnClickListener(v -> NavHostFragment.findNavController(this).popBackStack());

        btnSetChangePin = view.findViewById(R.id.btn_set_change_pin);
        swLocation = view.findViewById(R.id.sw_security_location);
        swDescription = view.findViewById(R.id.sw_security_description);
        swCaption = view.findViewById(R.id.sw_security_caption);
        rgTtl = view.findViewById(R.id.rg_security_unlock_ttl);
        cardDemoReadonly = view.findViewById(R.id.card_security_demo_readonly);

        swLocation.setChecked(securityPrefs.includeLocation());
        swDescription.setChecked(securityPrefs.includeDescription());
        swCaption.setChecked(securityPrefs.includeCaption());

        swLocation.setOnCheckedChangeListener((b, checked) -> securityPrefs.setIncludeLocation(checked));
        swDescription.setOnCheckedChangeListener((b, checked) -> securityPrefs.setIncludeDescription(checked));
        swCaption.setOnCheckedChangeListener((b, checked) -> securityPrefs.setIncludeCaption(checked));

        bindTtlSelection();
        rgTtl.setOnCheckedChangeListener((group, checkedId) -> {
            if (checkedId == R.id.rb_ttl_15m) securityPrefs.setRememberUnlockSeconds(TTL_15_MIN);
            else if (checkedId == R.id.rb_ttl_1h) securityPrefs.setRememberUnlockSeconds(TTL_1_HOUR);
            else if (checkedId == R.id.rb_ttl_24h) securityPrefs.setRememberUnlockSeconds(TTL_24_HOURS);
        });

        btnSetChangePin.setOnClickListener(v -> startPinFlow());

        boolean demoReadOnly = auth.isDemoUser();
        cardDemoReadonly.setVisibility(demoReadOnly ? View.VISIBLE : View.GONE);
        setEditableEnabled(!demoReadOnly);
    }

    @Override
    public void onResume() {
        super.onResume();
        bindTtlSelection();
    }

    private void bindTtlSelection() {
        int ttl = securityPrefs.rememberUnlockSeconds();
        if (ttl <= TTL_15_MIN) {
            rgTtl.check(R.id.rb_ttl_15m);
        } else if (ttl <= TTL_1_HOUR) {
            rgTtl.check(R.id.rb_ttl_1h);
        } else {
            rgTtl.check(R.id.rb_ttl_24h);
        }
    }

    private void setEditableEnabled(boolean enabled) {
        btnSetChangePin.setEnabled(enabled);
        swLocation.setEnabled(enabled);
        swDescription.setEnabled(enabled);
        swCaption.setEnabled(enabled);
        for (int i = 0; i < rgTtl.getChildCount(); i++) {
            View child = rgTtl.getChildAt(i);
            if (child != null) child.setEnabled(enabled);
        }
        rgTtl.setEnabled(enabled);
    }

    private void startPinFlow() {
        if (auth.isDemoUser()) {
            Toast.makeText(requireContext(), "Demo account is read-only", Toast.LENGTH_SHORT).show();
            return;
        }
        btnSetChangePin.setEnabled(false);
        new Thread(() -> {
            try {
                E2EEManager e2 = new E2EEManager(appContext);
                JSONObject env = e2.loadEnvelopeLocal();
                if (env == null) {
                    JSONObject serverEnv = e2.fetchEnvelopeFromServer();
                    if (serverEnv != null) {
                        e2.saveEnvelopeLocal(serverEnv);
                        env = serverEnv;
                    }
                }
                final boolean hasEnvelope = env != null;
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    btnSetChangePin.setEnabled(true);
                    if (hasEnvelope) {
                        requireUnlockThenShowPinDialog();
                    } else {
                        showSetPinDialog(false);
                    }
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    btnSetChangePin.setEnabled(true);
                    Toast.makeText(requireContext(), "Failed to prepare PIN flow", Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }

    private void requireUnlockThenShowPinDialog() {
        new EnterPinDialog().setListener(pin -> {
            btnSetChangePin.setEnabled(false);
            new Thread(() -> {
                boolean ok = false;
                try {
                    ok = new E2EEManager(appContext).unlockWithPin(pin);
                } catch (Exception ignored) {
                }
                final boolean unlocked = ok;
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    btnSetChangePin.setEnabled(true);
                    if (!unlocked) {
                        Toast.makeText(requireContext(), "Unlock failed", Toast.LENGTH_LONG).show();
                    } else {
                        showSetPinDialog(true);
                    }
                });
            }).start();
        }).show(getParentFragmentManager(), "security_unlock_before_pin_change");
    }

    private void showSetPinDialog(boolean changingExistingPin) {
        View dialogView = LayoutInflater.from(requireContext()).inflate(R.layout.dialog_set_pin, null, false);
        TextInputEditText etNew = dialogView.findViewById(R.id.et_new_pin);
        TextInputEditText etConfirm = dialogView.findViewById(R.id.et_confirm_pin);
        TextView tvError = dialogView.findViewById(R.id.tv_pin_error);

        AlertDialog dialog = new AlertDialog.Builder(requireContext())
                .setTitle(changingExistingPin ? "Change PIN" : "Set PIN")
                .setView(dialogView)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Save", null)
                .create();

        dialog.setOnShowListener(d -> {
            Button saveButton = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            saveButton.setOnClickListener(v -> {
                String newPin = etNew.getText() != null ? etNew.getText().toString() : "";
                String confirmPin = etConfirm.getText() != null ? etConfirm.getText().toString() : "";
                if (newPin.length() != 8 || confirmPin.length() != 8) {
                    tvError.setText("PIN must be exactly 8 characters");
                    tvError.setVisibility(View.VISIBLE);
                    return;
                }
                if (!newPin.equals(confirmPin)) {
                    tvError.setText("PINs do not match");
                    tvError.setVisibility(View.VISIBLE);
                    return;
                }
                tvError.setVisibility(View.GONE);
                saveButton.setEnabled(false);
                submitPin(newPin, changingExistingPin, dialog, saveButton, tvError);
            });
        });

        dialog.show();
    }

    private void submitPin(
            @NonNull String pin,
            boolean changingExistingPin,
            @NonNull AlertDialog dialog,
            @NonNull Button saveButton,
            @NonNull TextView tvError
    ) {
        new Thread(() -> {
            try {
                E2EEManager e2 = new E2EEManager(appContext);
                byte[] umk = e2.getUmk();
                if (umk == null || umk.length != 32) {
                    byte[] generated = new byte[32];
                    new SecureRandom().nextBytes(generated);
                    e2.installNewUmk(generated);
                    umk = generated;
                }

                JSONObject env = e2.wrapUMKForPassword(
                        umk,
                        pin,
                        null,
                        auth.getUserId(),
                        128,
                        3,
                        1
                );
                boolean serverSaved = e2.saveEnvelopeToServer(env);
                boolean quickUnlockSaved = saveDeviceWrappedUmk(appContext, umk);

                if (!isAdded()) return;
                final boolean pushed = serverSaved;
                final boolean quickSaved = quickUnlockSaved;
                requireActivity().runOnUiThread(() -> {
                    dialog.dismiss();
                    String msg = changingExistingPin ? "PIN updated" : "PIN set";
                    if (!pushed) msg += " (server update failed)";
                    else if (!quickSaved) msg += " (quick unlock unavailable)";
                    Toast.makeText(requireContext(), msg, Toast.LENGTH_LONG).show();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    saveButton.setEnabled(true);
                    tvError.setText("Failed to save PIN");
                    tvError.setVisibility(View.VISIBLE);
                });
            }
        }).start();
    }

    private boolean saveDeviceWrappedUmk(@NonNull Context app, @NonNull byte[] umk) {
        try {
            DeviceUMKStore store = new DeviceUMKStore(app);
            Cipher cipher = store.createEncryptCipher();
            store.saveUMK(umk, cipher);
            return true;
        } catch (UserNotAuthenticatedException e) {
            return false;
        } catch (Exception e) {
            return false;
        }
    }
}
