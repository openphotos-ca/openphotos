package ca.openphotos.android.ui;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;

import ca.openphotos.android.R;
import com.bumptech.glide.Glide;

/** Dedicated dialog for public-link QR + quick actions. */
public class PublicLinkQrDialogFragment extends DialogFragment {
    private static final String ARG_TITLE = "title";
    private static final String ARG_URL = "url";

    private String title = "Public Link";
    private String url = "";

    public static PublicLinkQrDialogFragment newInstance(@Nullable String title, @NonNull String url) {
        PublicLinkQrDialogFragment f = new PublicLinkQrDialogFragment();
        Bundle b = new Bundle();
        if (title != null) b.putString(ARG_TITLE, title);
        b.putString(ARG_URL, url);
        f.setArguments(b);
        return f;
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        if (getArguments() != null) {
            title = getArguments().getString(ARG_TITLE, "Public Link");
            url = getArguments().getString(ARG_URL, "");
        }

        View root = inflater.inflate(R.layout.dialog_public_link_qr, container, false);
        ((TextView) root.findViewById(R.id.tv_title)).setText(title == null || title.isEmpty() ? "Public Link" : title);
        ((TextView) root.findViewById(R.id.tv_url)).setText(url);

        ImageView qrImage = root.findViewById(R.id.qr_image);
        String qrEndpoint = "https://api.qrserver.com/v1/create-qr-code/?size=800x800&data=" + Uri.encode(url);
        try {
            Glide.with(this).load(qrEndpoint).into(qrImage);
        } catch (Exception ignored) {
        }

        root.findViewById(R.id.btn_copy).setOnClickListener(v -> copyUrl());
        root.findViewById(R.id.btn_open).setOnClickListener(v -> openUrl());
        root.findViewById(R.id.btn_share).setOnClickListener(v -> shareUrl());
        root.findViewById(R.id.btn_done).setOnClickListener(v -> dismissAllowingStateLoss());
        return root;
    }

    @Override
    public void onStart() {
        super.onStart();
        if (getDialog() != null && getDialog().getWindow() != null) {
            getDialog().getWindow().setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            getDialog().getWindow().setBackgroundDrawableResource(R.color.app_surface);
        }
    }

    private void copyUrl() {
        ClipboardManager cm = (ClipboardManager) requireContext().getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("public_link", url));
        Toast.makeText(requireContext(), "Copied", Toast.LENGTH_SHORT).show();
    }

    private void openUrl() {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (Exception e) {
            Toast.makeText(requireContext(), "Cannot open URL", Toast.LENGTH_SHORT).show();
        }
    }

    private void shareUrl() {
        Intent i = new Intent(Intent.ACTION_SEND);
        i.setType("text/plain");
        i.putExtra(Intent.EXTRA_TEXT, url);
        startActivity(Intent.createChooser(i, "Share public link"));
    }
}
