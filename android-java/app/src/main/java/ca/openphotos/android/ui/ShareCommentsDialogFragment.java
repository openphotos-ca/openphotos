package ca.openphotos.android.ui;

import android.os.Bundle;
import android.text.TextUtils;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.DialogFragment;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.e2ee.ShareE2EEManager;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.server.ShareModels;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/** Comments thread for a shared asset. */
public class ShareCommentsDialogFragment extends DialogFragment {
    public static final String KEY_COMMENTS_CHANGED = "share.comments.changed";

    private static final String ARG_SHARE_ID = "share_id";
    private static final String ARG_ASSET_ID = "asset_id";
    private static final String ARG_ALLOW_POST = "allow_post";

    private String shareId = "";
    private String assetId = "";
    private boolean allowPost = false;

    private RecyclerView list;
    private EditText etComment;
    private View inputRow;

    private final List<ShareModels.ShareComment> comments = new ArrayList<>();
    private CommentsAdapter adapter;

    public static ShareCommentsDialogFragment newInstance(String shareId, String assetId, boolean allowPost) {
        ShareCommentsDialogFragment f = new ShareCommentsDialogFragment();
        Bundle b = new Bundle();
        b.putString(ARG_SHARE_ID, shareId);
        b.putString(ARG_ASSET_ID, assetId);
        b.putBoolean(ARG_ALLOW_POST, allowPost);
        f.setArguments(b);
        return f;
    }

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        if (getArguments() != null) {
            shareId = getArguments().getString(ARG_SHARE_ID, "");
            assetId = getArguments().getString(ARG_ASSET_ID, "");
            allowPost = getArguments().getBoolean(ARG_ALLOW_POST, false);
        }

        View root = inflater.inflate(R.layout.dialog_comment_thread, container, false);
        root.findViewById(R.id.btn_done).setOnClickListener(v -> dismissAllowingStateLoss());
        list = root.findViewById(R.id.list);
        list.setLayoutManager(new LinearLayoutManager(requireContext()));
        adapter = new CommentsAdapter();
        list.setAdapter(adapter);

        inputRow = root.findViewById(R.id.input_row);
        etComment = root.findViewById(R.id.et_comment);
        ImageButton btnSend = root.findViewById(R.id.btn_send);
        if (!allowPost) inputRow.setVisibility(View.GONE);
        btnSend.setOnClickListener(v -> postComment());

        loadComments();
        return root;
    }

    @Override
    public void onStart() {
        super.onStart();
        if (getDialog() != null && getDialog().getWindow() != null) {
            getDialog().getWindow().setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            getDialog().getWindow().setBackgroundDrawableResource(R.color.app_surface);
        }
    }

    private void loadComments() {
        new Thread(() -> {
            try {
                List<ShareModels.ShareComment> out = new ServerPhotosService(requireContext().getApplicationContext())
                        .listShareComments(shareId, assetId, 200, null);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    comments.clear();
                    comments.addAll(out);
                    adapter.notifyDataSetChanged();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) {
                        getParentFragmentManager().setFragmentResult(ShareViewerFragment.KEY_VIEWER_AUTH_EXPIRED, new Bundle());
                        dismissAllowingStateLoss();
                    } else {
                        Toast.makeText(requireContext(), "Failed to load comments", Toast.LENGTH_LONG).show();
                    }
                });
            }
        }).start();
    }

    private void postComment() {
        String text = etComment.getText() != null ? etComment.getText().toString().trim() : "";
        if (TextUtils.isEmpty(text)) return;
        etComment.setEnabled(false);
        new Thread(() -> {
            try {
                ShareModels.ShareComment c = new ServerPhotosService(requireContext().getApplicationContext())
                        .createShareComment(shareId, assetId, text);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    comments.add(c);
                    adapter.notifyItemInserted(comments.size() - 1);
                    list.scrollToPosition(Math.max(0, comments.size() - 1));
                    etComment.setText("");
                    etComment.setEnabled(true);
                    notifyChanged();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    etComment.setEnabled(true);
                    if (ShareE2EEManager.isUnauthorizedError(e)) {
                        getParentFragmentManager().setFragmentResult(ShareViewerFragment.KEY_VIEWER_AUTH_EXPIRED, new Bundle());
                        dismissAllowingStateLoss();
                    } else {
                        Toast.makeText(requireContext(), "Failed to post comment", Toast.LENGTH_LONG).show();
                    }
                });
            }
        }).start();
    }

    private void deleteComment(ShareModels.ShareComment c) {
        new Thread(() -> {
            try {
                new ServerPhotosService(requireContext().getApplicationContext()).deleteShareComment(shareId, c.id);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    for (int i = 0; i < comments.size(); i++) {
                        if (comments.get(i).id.equals(c.id)) {
                            comments.remove(i);
                            adapter.notifyItemRemoved(i);
                            break;
                        }
                    }
                    notifyChanged();
                });
            } catch (Exception e) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (ShareE2EEManager.isUnauthorizedError(e)) {
                        getParentFragmentManager().setFragmentResult(ShareViewerFragment.KEY_VIEWER_AUTH_EXPIRED, new Bundle());
                        dismissAllowingStateLoss();
                    } else {
                        Toast.makeText(requireContext(), "Failed to delete comment", Toast.LENGTH_LONG).show();
                    }
                });
            }
        }).start();
    }

    private void notifyChanged() {
        Bundle b = new Bundle();
        b.putString("asset_id", assetId);
        getParentFragmentManager().setFragmentResult(KEY_COMMENTS_CHANGED, b);
    }

    private static String formatTime(long ts) {
        if (ts <= 0) return "";
        try {
            return new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(new Date(ts * 1000L));
        } catch (Exception ignored) {
            return String.valueOf(ts);
        }
    }

    private final class CommentsAdapter extends RecyclerView.Adapter<CommentsAdapter.VH> {
        private final String currentUserId = AuthManager.get(requireContext().getApplicationContext()).getUserId();

        @NonNull
        @Override
        public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_share_comment, parent, false);
            return new VH(v);
        }

        @Override
        public void onBindViewHolder(@NonNull VH h, int position) {
            ShareModels.ShareComment c = comments.get(position);
            h.author.setText(c.authorDisplayName);
            h.body.setText(c.body);
            h.time.setText(formatTime(c.createdAt));

            boolean canDelete = c.authorUserId != null && currentUserId != null && c.authorUserId.equals(currentUserId);
            h.btnDelete.setVisibility(canDelete ? View.VISIBLE : View.GONE);
            h.btnDelete.setOnClickListener(v -> deleteComment(c));
        }

        @Override
        public int getItemCount() {
            return comments.size();
        }

        final class VH extends RecyclerView.ViewHolder {
            final TextView author;
            final TextView body;
            final TextView time;
            final ImageButton btnDelete;

            VH(@NonNull View itemView) {
                super(itemView);
                author = itemView.findViewById(R.id.author);
                body = itemView.findViewById(R.id.body);
                time = itemView.findViewById(R.id.time);
                btnDelete = itemView.findViewById(R.id.btn_delete);
            }
        }
    }
}
