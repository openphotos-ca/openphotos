package ca.openphotos.android.ui;

import android.os.Bundle;
import android.os.SystemClock;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.navigation.fragment.NavHostFragment;

import com.google.android.material.button.MaterialButton;
import com.google.android.material.button.MaterialButtonToggleGroup;
import com.google.android.material.switchmaterial.SwitchMaterial;
import com.google.android.material.textfield.TextInputEditText;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;

public class NetworkSettingsFragment extends Fragment {
    private AuthManager auth;

    private TextView tvActiveUrl;
    private TextView tvRouting;
    private TextView tvTransport;
    private TextView tvProbe;
    private TextInputEditText etPublicUrl;
    private TextInputEditText etLocalUrl;
    private TextView tvPublicTest;
    private TextView tvLocalTest;
    private SwitchMaterial swAutoSwitch;
    private MaterialButtonToggleGroup toggleManualPreferred;
    private MaterialButton btnPreferPublic;
    private MaterialButton btnPreferLocal;
    private MaterialButton btnRefresh;
    private MaterialButton btnUseCurrent;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        return inflater.inflate(R.layout.fragment_network_settings, container, false);
    }

    @Override
    public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        auth = AuthManager.get(requireContext().getApplicationContext());

        tvActiveUrl = view.findViewById(R.id.tv_network_active_url);
        tvRouting = view.findViewById(R.id.tv_network_routing);
        tvTransport = view.findViewById(R.id.tv_network_transport);
        tvProbe = view.findViewById(R.id.tv_network_probe);
        etPublicUrl = view.findViewById(R.id.et_network_public_url);
        etLocalUrl = view.findViewById(R.id.et_network_local_url);
        tvPublicTest = view.findViewById(R.id.tv_network_public_test);
        tvLocalTest = view.findViewById(R.id.tv_network_local_test);
        swAutoSwitch = view.findViewById(R.id.sw_network_auto_switch);
        toggleManualPreferred = view.findViewById(R.id.toggle_network_manual_preferred);
        btnPreferPublic = view.findViewById(R.id.btn_network_prefer_public);
        btnPreferLocal = view.findViewById(R.id.btn_network_prefer_local);
        btnRefresh = view.findViewById(R.id.btn_network_refresh);
        btnUseCurrent = view.findViewById(R.id.btn_network_use_current);
        view.findViewById(R.id.btn_network_back).setOnClickListener(v -> NavHostFragment.findNavController(this).popBackStack());

        swAutoSwitch.setOnCheckedChangeListener((buttonView, isChecked) -> {
            auth.setAutoSwitchEnabled(isChecked);
            refreshUi();
        });
        toggleManualPreferred.addOnButtonCheckedListener((group, checkedId, isChecked) -> {
            if (!isChecked) return;
            if (checkedId == btnPreferLocal.getId()) {
                auth.setManualPreferredEndpoint(AuthManager.ManualPreferredEndpoint.LOCAL);
            } else {
                auth.setManualPreferredEndpoint(AuthManager.ManualPreferredEndpoint.PUBLIC);
            }
            refreshUi();
        });

        view.findViewById(R.id.btn_network_save_public).setOnClickListener(v -> saveExternalUrl());
        view.findViewById(R.id.btn_network_save_local).setOnClickListener(v -> saveLocalUrl());
        view.findViewById(R.id.btn_network_test_public).setOnClickListener(v -> testEndpoint(AuthManager.ManualPreferredEndpoint.PUBLIC));
        view.findViewById(R.id.btn_network_test_local).setOnClickListener(v -> testEndpoint(AuthManager.ManualPreferredEndpoint.LOCAL));
        btnRefresh.setOnClickListener(v -> {
            auth.refreshNetworkRouting();
            Toast.makeText(requireContext(), "Refreshing network route", Toast.LENGTH_SHORT).show();
            refreshUi();
        });
        btnUseCurrent.setOnClickListener(v -> {
            auth.useCurrentConnection();
            refreshUi();
        });

        refreshUi();
    }

    @Override
    public void onResume() {
        super.onResume();
        refreshUi();
    }

    private void saveExternalUrl() {
        String raw = fieldText(etPublicUrl).trim();
        if (!raw.isEmpty() && AuthManager.parseBaseUrl(raw) == null) {
            Toast.makeText(requireContext(), "External URL is invalid", Toast.LENGTH_SHORT).show();
            return;
        }
        String localRaw = fieldText(etLocalUrl).trim();
        if (!localRaw.isEmpty() && AuthManager.parseBaseUrl(localRaw) == null) {
            Toast.makeText(requireContext(), "Local URL is invalid", Toast.LENGTH_SHORT).show();
            return;
        }
        auth.saveConfiguredBaseUrlsWithoutRefreshing(raw, localRaw);
        Toast.makeText(requireContext(), "External URL saved", Toast.LENGTH_SHORT).show();
        refreshUi();
    }

    private void saveLocalUrl() {
        String raw = fieldText(etLocalUrl).trim();
        if (!raw.isEmpty() && AuthManager.parseBaseUrl(raw) == null) {
            Toast.makeText(requireContext(), "Local URL is invalid", Toast.LENGTH_SHORT).show();
            return;
        }
        String publicRaw = fieldText(etPublicUrl).trim();
        if (!publicRaw.isEmpty() && AuthManager.parseBaseUrl(publicRaw) == null) {
            Toast.makeText(requireContext(), "External URL is invalid", Toast.LENGTH_SHORT).show();
            return;
        }
        auth.saveConfiguredBaseUrlsWithoutRefreshing(publicRaw, raw);
        Toast.makeText(requireContext(), "Local URL saved", Toast.LENGTH_SHORT).show();
        refreshUi();
    }

    private void testEndpoint(AuthManager.ManualPreferredEndpoint endpoint) {
        TextView target = endpoint == AuthManager.ManualPreferredEndpoint.LOCAL ? tvLocalTest : tvPublicTest;
        target.setText("Testing…");
        new Thread(() -> {
            AuthManager.ProbeResult result = auth.testConfiguredEndpoint(endpoint);
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> {
                target.setText(result.message);
                target.setTextColor(ContextCompat.getColor(
                        requireContext(),
                        result.success ? R.color.app_success : R.color.app_text_secondary
                ));
                refreshUi();
            });
        }).start();
    }

    private void refreshUi() {
        if (!isAdded()) return;
        etPublicUrl.setText(auth.getPublicServerUrl());
        etLocalUrl.setText(auth.getLocalServerUrl());
        tvActiveUrl.setText(nonEmpty(auth.getEffectiveServerUrl(), "-"));
        tvRouting.setText(routingLabel());
        tvTransport.setText("Transport: " + transportLabel(auth.getNetworkTransport()));
        tvProbe.setText(probeLabel());
        swAutoSwitch.setChecked(auth.isAutoSwitchEnabled());
        toggleManualPreferred.setVisibility(auth.isAutoSwitchEnabled() ? View.GONE : View.VISIBLE);
        toggleManualPreferred.check(auth.getManualPreferredEndpoint() == AuthManager.ManualPreferredEndpoint.LOCAL
                ? btnPreferLocal.getId()
                : btnPreferPublic.getId());
        btnUseCurrent.setEnabled(auth.getActiveEndpoint() != AuthManager.ActiveEndpoint.NONE);
    }

    private String routingLabel() {
        switch (auth.getActiveEndpoint()) {
            case LOCAL:
                return "Using Local Network";
            case PUBLIC:
                return "Using External Network";
            default:
                return "Not Configured";
        }
    }

    private String transportLabel(AuthManager.NetworkTransportKind transport) {
        switch (transport) {
            case WIFI:
                return "Wi-Fi";
            case ETHERNET:
                return "Ethernet";
            case CELLULAR:
                return "Cellular";
            case OTHER:
                return "Other";
            default:
                return "Offline";
        }
    }

    private String probeLabel() {
        Boolean success = auth.getLastLocalProbeSucceeded();
        if (success == null) {
            return "Local probe: never";
        }
        String message = auth.getLastLocalProbeMessage();
        long at = auth.getLastLocalProbeAtElapsedMs();
        long ageSec = at > 0L ? Math.max(0L, (SystemClock.elapsedRealtime() - at) / 1000L) : 0L;
        return "Local probe: " + (success ? "ok" : "failed")
                + (message == null || message.trim().isEmpty() ? "" : " (" + message + ")")
                + (at > 0L ? " • " + ageSec + "s ago" : "");
    }

    @NonNull
    private String fieldText(@NonNull TextInputEditText editText) {
        return editText.getText() == null ? "" : editText.getText().toString();
    }

    @NonNull
    private String nonEmpty(@Nullable String value, @NonNull String fallback) {
        return value == null || value.trim().isEmpty() ? fallback : value;
    }
}
