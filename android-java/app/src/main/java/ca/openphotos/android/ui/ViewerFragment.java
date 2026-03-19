package ca.openphotos.android.ui;

import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.Fragment;
import androidx.transition.TransitionInflater;

import ca.openphotos.android.R;
import ca.openphotos.android.core.CapabilitiesService;
import ca.openphotos.android.core.AuthorizedHttpClient;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.e2ee.E2EEManager;
import ca.openphotos.android.e2ee.PAE3;
import ca.openphotos.android.media.MediaSaveHelper;
import ca.openphotos.android.media.MotionPhotoParser;
import ca.openphotos.android.media.MotionPhotoSupport;
import ca.openphotos.android.server.ServerPhotosService;
import com.google.android.exoplayer2.DefaultLoadControl;
import com.google.android.exoplayer2.ExoPlayer;
import com.google.android.exoplayer2.MediaItem;
import com.google.android.exoplayer2.Player;
import com.google.android.exoplayer2.source.DefaultMediaSourceFactory;
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource;
import com.google.android.exoplayer2.ui.PlayerView;

/**
 * Full-screen viewer (server Photos tab parity with iOS):
 * - Pinch/double-tap zoom via PhotoView
 * - Pan and swipe navigation (disabled while zoomed-in)
 * - Swipe down to save (image/video/live)
 * - Video overlay with play/pause, mute, and scrubber
 * - Actions popup: Favorite/Info/Lock/Download + Albums + People + Share (EE)
 */
public class ViewerFragment extends Fragment {
    private androidx.viewpager2.widget.ViewPager2 pager;
    private TextView info; private TextView title; private View btnMore;
    private View videoControls; private android.widget.ImageButton btnPlayPause, btnMute; private android.widget.SeekBar seek;
    private PlayerView playerView;

    private java.util.ArrayList<String> uris; private java.util.ArrayList<String> assetIds; private int index; private boolean isServer; private boolean eeEnabled;
    private final java.util.Map<String, org.json.JSONObject> metaByAsset = new java.util.HashMap<>();
    private final java.util.Map<String, LocalMotionMeta> localMetaByUri = new java.util.HashMap<>();
    private final java.util.List<java.io.File> tempMotionFiles = new java.util.ArrayList<>();
    private ExoPlayer player; private boolean playerMuted; private boolean draggingSeek; private boolean suppressSeek;
    private boolean livePlaybackMode = false;
    private String livePlaybackKey = null;
    private boolean liveAutoPlayPending = true;
    private String liveAutoPlayPageKey = null;
    private float touchStartY; private float touchAccumY;

    @Nullable @Override public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        setSharedElementEnterTransition(TransitionInflater.from(requireContext()).inflateTransition(android.R.transition.move));
        setSharedElementReturnTransition(TransitionInflater.from(requireContext()).inflateTransition(android.R.transition.move));
        postponeEnterTransition();

        View root = inflater.inflate(R.layout.fragment_viewer, container, false);
        pager = root.findViewById(R.id.pager); info = root.findViewById(R.id.info); title = root.findViewById(R.id.title); btnMore = root.findViewById(R.id.btn_more);
        videoControls = root.findViewById(R.id.video_controls); btnPlayPause = root.findViewById(R.id.btn_play_pause); btnMute = root.findViewById(R.id.btn_mute); seek = root.findViewById(R.id.seek);
        playerView = root.findViewById(R.id.player_view);

        String uri = getArguments() != null ? getArguments().getString("uri", "") : "";
        isServer = getArguments() != null && getArguments().getBoolean("isServer", false);
        String assetId = getArguments() != null ? getArguments().getString("assetId", "") : "";
        uris = getArguments() != null ? getArguments().getStringArrayList("uris") : null;
        assetIds = getArguments() != null ? getArguments().getStringArrayList("assetIds") : null;
        index = getArguments() != null ? getArguments().getInt("index", 0) : 0;
        java.util.ArrayList<String> useUris = uris; java.util.ArrayList<String> useAssetIds = assetIds;
        if (useUris == null || useUris.isEmpty()) { useUris = new java.util.ArrayList<>(); if (uri != null && !uri.isEmpty()) useUris.add(uri); useAssetIds = new java.util.ArrayList<>(); useAssetIds.add(assetId); index = 0; }
        title.setText(isServer ? (useAssetIds != null && index < useAssetIds.size() ? useAssetIds.get(index) : assetId) : "");
        info.setVisibility(View.GONE);
        if (btnMore != null) btnMore.setVisibility(isServer ? View.VISIBLE : View.GONE);

        ViewerPagerAdapter pad = new ViewerPagerAdapter(useUris, useAssetIds, isServer);
        pager.setAdapter(pad); pager.setUserInputEnabled(true);
        pad.setOnScaleChangeListener(scale -> pager.setUserInputEnabled(scale <= 1.05f));
        if (index >= 0 && index < useUris.size()) pager.setCurrentItem(index, false);
        liveAutoPlayPageKey = currentItemKey();
        liveAutoPlayPending = true;

        pager.getViewTreeObserver().addOnPreDrawListener(new android.view.ViewTreeObserver.OnPreDrawListener() { @Override public boolean onPreDraw() { pager.getViewTreeObserver().removeOnPreDrawListener(this); startPostponedEnterTransition(); return true; } });

        final View topBar = root.findViewById(R.id.top_bar); topBar.bringToFront(); final boolean[] chrome = { true };
        View liveBadge = root.findViewById(R.id.live_badge);
        if (liveBadge != null) liveBadge.setOnClickListener(v -> openCurrentLiveMotion());
        pad.setOnTapListener(() -> {
            boolean quickPlayLive = liveBadge != null && liveBadge.getVisibility() == View.VISIBLE && isCurrentLive();
            if (quickPlayLive) {
                openCurrentLiveMotion();
                return;
            }
            chrome[0] = !chrome[0];
            topBar.setVisibility(chrome[0] ? View.VISIBLE : View.GONE);
            videoControls.setVisibility(chrome[0] && isCurrentVideo() ? View.VISIBLE : View.GONE);
        });
        pad.setOnLongPressListener(() -> {
            if (isCurrentVideo()) return false;
            openCurrentLiveMotion();
            return true;
        });
        topBar.setClickable(true); topBar.setFocusable(true);

        final java.util.ArrayList<String> finalUseAssetIds = useAssetIds;
        pager.registerOnPageChangeCallback(new androidx.viewpager2.widget.ViewPager2.OnPageChangeCallback() {
            @Override public void onPageSelected(int position) {
                releasePlayer(); index = position;
                if (isServer && finalUseAssetIds != null && position < finalUseAssetIds.size()) title.setText(finalUseAssetIds.get(position));
                liveAutoPlayPageKey = currentItemKey();
                liveAutoPlayPending = true;
                ensureMetadataForCurrent(false);
                videoControls.setVisibility(chrome[0] && isCurrentVideo() ? View.VISIBLE : View.GONE);
                maybeLoadNextPage();
                updateLiveBadgeVisibility();
            }
        });

        btnMore.setOnClickListener(v -> {
            String currentAid = (assetIds != null && index < assetIds.size()) ? assetIds.get(index) : assetId;
            if (!isServer || currentAid == null || currentAid.isEmpty()) {
                android.widget.Toast.makeText(requireContext(), "No server item", android.widget.Toast.LENGTH_SHORT).show();
                return;
            }
            showActionsMenu(currentAid, v);
        });
        View btnClose = root.findViewById(R.id.btn_close);
        if (btnClose != null) btnClose.setOnClickListener(v -> {
            try { androidx.navigation.fragment.NavHostFragment.findNavController(this).navigateUp(); } catch (Exception ignored) { requireActivity().onBackPressed(); }
        });

        pager.setOnTouchListener((vv,e)->{ switch(e.getActionMasked()){ case android.view.MotionEvent.ACTION_DOWN: touchStartY=e.getY(); touchAccumY=0; break; case android.view.MotionEvent.ACTION_MOVE: touchAccumY=e.getY()-touchStartY; break; case android.view.MotionEvent.ACTION_UP: if (touchAccumY>160 && pager.isUserInputEnabled()) { String aidNow = assetIds!=null && index<assetIds.size()? assetIds.get(index): assetId; saveCurrent(aidNow);} break;} return false; });

        btnPlayPause.setOnClickListener(v -> togglePlayPause()); btnMute.setOnClickListener(v -> toggleMute());
        seek.setOnSeekBarChangeListener(new android.widget.SeekBar.OnSeekBarChangeListener(){ @Override public void onProgressChanged(android.widget.SeekBar s,int p,boolean fromUser){ if(fromUser&&player!=null&&!suppressSeek) player.seekTo(p);} @Override public void onStartTrackingTouch(android.widget.SeekBar s){draggingSeek=true;} @Override public void onStopTrackingTouch(android.widget.SeekBar s){draggingSeek=false;}});

        new Thread(() -> { eeEnabled = CapabilitiesService.get(requireContext().getApplicationContext()).ee; }).start();
        ensureMetadataForCurrent(false);
        updateLiveBadgeVisibility();
        return root;
    }

    // ---- Continuous paging (loads next page near the end if paging extras provided) ----
    private void maybeLoadNextPage() {
        if (getArguments() == null) return;
        int nextPage = getArguments().getInt("paging_next_page", -1);
        int limit = getArguments().getInt("paging_limit", 0);
        if (nextPage <= 0 || limit <= 0) return; // no paging context
        if (assetIds == null) return;
        if (index < Math.max(0, assetIds.size() - 2)) return; // only when near end
        // Snapshot arguments for async
        String media = getArguments().getString("paging_media", "all");
        boolean favOnly = getArguments().getBoolean("paging_favorite_only", false);
        boolean includeSubtree = getArguments().getBoolean("paging_include_subtree", false);
        int[] albumIdsArr = getArguments().getIntArray("paging_album_ids");
        Boolean locked = getArguments().containsKey("paging_locked") ? getArguments().getBoolean("paging_locked") : null;
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                java.util.List<Integer> albumIds = new java.util.ArrayList<>(); if (albumIdsArr != null) for (int id : albumIdsArr) albumIds.add(id);
                String mediaParam = media.equals("photos") ? "photos"
                        : (media.equals("videos") ? "videos"
                        : (media.equals("trash") ? "trash" : null));
                org.json.JSONObject resp = svc.listPhotos(null, albumIds, mediaParam, locked, favOnly, nextPage, limit, null, includeSubtree);
                org.json.JSONArray photos = resp.has("photos") ? resp.getJSONArray("photos") : new org.json.JSONArray();
                if (photos.length() == 0) return;
                java.util.ArrayList<String> newUris = new java.util.ArrayList<>();
                java.util.ArrayList<String> newAssetIds = new java.util.ArrayList<>();
                for (int i=0;i<photos.length();i++) {
                    org.json.JSONObject p = photos.getJSONObject(i);
                    String id = p.optString("asset_id"); newAssetIds.add(id); newUris.add(svc.imageUrl(id));
                }
                requireActivity().runOnUiThread(() -> {
                    // Append to current lists backing the adapter
                    java.util.ArrayList<String> mergedUris = new java.util.ArrayList<>(uris); mergedUris.addAll(newUris); uris = mergedUris;
                    java.util.ArrayList<String> mergedIds = new java.util.ArrayList<>(assetIds); mergedIds.addAll(newAssetIds); assetIds = mergedIds;
                    ViewerPagerAdapter adapter = new ViewerPagerAdapter(uris, assetIds, true); pager.setAdapter(adapter); pager.setCurrentItem(index, false);
                    // Increment next page for subsequent loads
                    getArguments().putInt("paging_next_page", nextPage + 1);
                });
            } catch (Exception ignored) {}
        }).start();
    }

    private void showActionsMenu(String aid, View anchor) {
        androidx.appcompat.widget.PopupMenu pm = new androidx.appcompat.widget.PopupMenu(requireContext(), anchor);
        pm.getMenu().add("Favorite"); pm.getMenu().add("Info"); pm.getMenu().add("Lock"); pm.getMenu().add("Download to Photos");
        // Albums section if we have membership data
        org.json.JSONObject meta = metaByAsset.get(aid);
        if (meta != null && meta.has("_albums")) {
            android.view.SubMenu sub = pm.getMenu().addSubMenu("Albums");
            try { org.json.JSONArray arr = meta.getJSONArray("_albums"); for (int i=0;i<arr.length();i++){ String name = arr.getJSONObject(i).optString("name"); sub.add("Remove: "+name); } } catch (Exception ignored) {}
        }
        pm.getMenu().add("Add to Album…"); pm.getMenu().add("Update Person…"); pm.getMenu().add("Add Person…"); if (eeEnabled) pm.getMenu().add("Share…");
        pm.setOnMenuItemClickListener(item -> { String t = String.valueOf(item.getTitle()); if (t.equals("Favorite")) { toggleFavorite(aid); return true; } if (t.equals("Info")) { InfoBottomSheet.newInstance(aid).show(getParentFragmentManager(), "info"); return true; } if (t.equals("Lock")) { doLock(aid); return true; } if (t.equals("Download to Photos")) { saveCurrent(aid); return true; } if (t.equals("Add to Album…")) { openAlbumTree(aid); return true; } if (t.equals("Update Person…")) { UpdatePersonBottomSheet.newInstance(aid).show(getParentFragmentManager(), "updPerson"); return true; } if (t.equals("Add Person…")) { AddPersonBottomSheet.newInstance(aid).show(getParentFragmentManager(), "addPerson"); return true; } if (t.equals("Share…")) { shareCurrent(aid); return true; } return false; });
        ensureMetadataForCurrent(true);
        pm.show();
    }

    private void removeFromAlbumByLabel(String label) {
        try {
            String name = label.substring("Remove: ".length()).trim();
            String aid = assetIds.get(index);
            org.json.JSONObject meta = metaByAsset.get(aid);
            if (meta == null || !meta.has("_albums")) return;
            org.json.JSONArray arr = meta.getJSONArray("_albums");
            for (int i=0;i<arr.length();i++) {
                org.json.JSONObject a = arr.getJSONObject(i);
                if (name.equals(a.optString("name"))) {
                    int albumId = a.optInt("id", 0);
                    int pid = meta.optInt("id", 0);
                    if (albumId > 0 && pid > 0) {
                        new Thread(() -> {
                            try { new ServerPhotosService(requireContext().getApplicationContext()).removePhotosFromAlbum(albumId, java.util.Collections.singletonList(pid)); requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Removed from album", android.widget.Toast.LENGTH_SHORT).show()); }
                            catch (Exception e) { requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Remove failed", android.widget.Toast.LENGTH_LONG).show()); }
                        }).start();
                    }
                    break;
                }
            }
        } catch (Exception ignored) {}
    }

    private void ensureMetadataForCurrent(boolean withAlbums) {
        if (!isServer) {
            ensureLocalLiveForCurrent();
            return;
        }
        if (assetIds == null || index >= assetIds.size()) return;
        String aid = assetIds.get(index);
        if (metaByAsset.containsKey(aid) && !withAlbums) {
            if (isAdded()) requireActivity().runOnUiThread(this::updateLiveBadgeVisibility);
            return;
        }
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONArray arr = svc.getPhotosByAssetIds(java.util.Collections.singletonList(aid), true);
                org.json.JSONObject p = arr.length() > 0 ? arr.getJSONObject(0) : null;
                if (p != null) metaByAsset.put(aid, p);
                if (p != null) {
                    try {
                        android.util.Log.i("OpenPhotos", "[VIEWER] meta aid=" + aid
                                + " live=" + p.optBoolean("is_live_photo", false)
                                + " video=" + p.optBoolean("is_video", false)
                                + " locked=" + p.optBoolean("locked", false));
                    } catch (Exception ignored) {}
                }
                if (withAlbums && p != null && p.has("id") && !p.isNull("id")) {
                    int nid = p.optInt("id", 0);
                    org.json.JSONArray alb = svc.getAlbumsForPhoto(nid);
                    p.put("_albums", alb);
                }
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    videoControls.setVisibility(isCurrentVideo() ? View.VISIBLE : View.GONE);
                    updateLiveBadgeVisibility();
                });
            } catch (Exception ignored) {
            }
        }).start();
    }

    private void ensureLocalLiveForCurrent() {
        if (isServer || uris == null || index < 0 || index >= uris.size()) return;
        String currentUri = uris.get(index);
        if (currentUri == null || currentUri.isEmpty()) return;
        if (localMetaByUri.containsKey(currentUri)) {
            if (isAdded()) requireActivity().runOnUiThread(this::updateLiveBadgeVisibility);
            return;
        }
        new Thread(() -> {
            LocalMotionMeta meta = loadLocalMotionMeta(currentUri);
            synchronized (localMetaByUri) {
                localMetaByUri.put(currentUri, meta);
            }
            if (!isAdded()) return;
            requireActivity().runOnUiThread(this::updateLiveBadgeVisibility);
        }).start();
    }

    private LocalMotionMeta loadLocalMotionMeta(@NonNull String uriString) {
        String displayName = null;
        String mime = null;
        try {
            android.net.Uri uri = android.net.Uri.parse(uriString);
            try (android.database.Cursor c = requireContext().getContentResolver().query(
                    uri,
                    new String[]{
                            android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
                            android.provider.MediaStore.MediaColumns.MIME_TYPE,
                            android.provider.MediaStore.MediaColumns.RELATIVE_PATH
                    },
                    null,
                    null,
                    null
            )) {
                if (c != null && c.moveToFirst()) {
                    displayName = c.getString(0);
                    mime = c.getString(1);
                    String relativePath = c.getString(2);
                    android.net.Uri sidecar = findLocalSidecarVideoUri(displayName, relativePath);
                    if (sidecar != null) {
                        return new LocalMotionMeta(displayName, mime, true, sidecar);
                    }
                }
            }
        } catch (Exception ignored) {
        }
        boolean isLive = MotionPhotoSupport.isLikelyMotionPhoto(displayName, mime);
        if (!isLive) {
            try {
                MotionPhotoParser.Result probe = MotionPhotoParser.detectAndExtract(
                        requireContext().getApplicationContext(),
                        android.net.Uri.parse(uriString)
                );
                isLive = probe != null && probe.isMotion;
                if (probe != null && probe.mp4 != null && probe.mp4.exists()) {
                    //noinspection ResultOfMethodCallIgnored
                    probe.mp4.delete();
                }
            } catch (Exception ignored) {
            }
        }
        return new LocalMotionMeta(displayName, mime, isLive, null);
    }

    @Nullable
    private android.net.Uri findLocalSidecarVideoUri(@Nullable String displayName, @Nullable String relativePath) {
        if (displayName == null || displayName.trim().isEmpty()) return null;
        String base = displayName;
        int dot = base.lastIndexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        if (base.trim().isEmpty()) return null;

        String[] candidates = new String[]{base + ".mp4", base + ".MP4", base + ".mov", base + ".MOV"};
        StringBuilder sel = new StringBuilder(android.provider.MediaStore.MediaColumns.DISPLAY_NAME + " IN (?,?,?,?)");
        java.util.ArrayList<String> args = new java.util.ArrayList<>();
        java.util.Collections.addAll(args, candidates);
        if (relativePath != null && !relativePath.isEmpty()) {
            sel.append(" AND ").append(android.provider.MediaStore.MediaColumns.RELATIVE_PATH).append("=?");
            args.add(relativePath);
        }
        try (android.database.Cursor c = requireContext().getContentResolver().query(
                android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                new String[]{android.provider.MediaStore.Video.Media._ID},
                sel.toString(),
                args.toArray(new String[0]),
                null
        )) {
            if (c != null && c.moveToFirst()) {
                long id = c.getLong(0);
                return android.content.ContentUris.withAppendedId(android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id);
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    private void updateLiveBadgeVisibility() {
        View root = getView();
        if (root == null) return;
        View live = root.findViewById(R.id.live_badge);
        if (live == null) return;
        boolean show = isCurrentLive() && !isCurrentVideo() && player == null;
        live.setVisibility(show ? View.VISIBLE : View.GONE);
        live.setEnabled(show);
        android.util.Log.i("OpenPhotos", "[VIEWER] updateLiveBadge show=" + show + " isLive=" + isCurrentLive() + " isVideo=" + isCurrentVideo());
        maybeAutoPlayLive();
    }

    private void maybeAutoPlayLive() {
        if (!liveAutoPlayPending) return;
        if (isCurrentVideo()) return;
        String key = currentItemKey();
        if (key == null || key.isEmpty()) return;
        if (liveAutoPlayPageKey == null || !liveAutoPlayPageKey.equals(key)) return;
        if (!isCurrentLive()) return;
        liveAutoPlayPending = false;
        openCurrentLiveMotion(false);
    }

    private boolean isCurrentVideo() {
        if (!isServer || assetIds == null || index >= assetIds.size()) return false;
        org.json.JSONObject p = metaByAsset.get(assetIds.get(index));
        return p != null && p.optBoolean("is_video", false);
    }

    private boolean isCurrentLive() {
        if (isServer) {
            if (assetIds == null || index >= assetIds.size()) return false;
            org.json.JSONObject p = metaByAsset.get(assetIds.get(index));
            return p != null && p.optBoolean("is_live_photo", false);
        }
        if (uris == null || index < 0 || index >= uris.size()) return false;
        String currentUri = uris.get(index);
        LocalMotionMeta meta;
        synchronized (localMetaByUri) {
            meta = localMetaByUri.get(currentUri);
        }
        if (meta == null) {
            ensureLocalLiveForCurrent();
            return false;
        }
        return meta.isLive;
    }

    private void openCurrentLiveMotion() {
        openCurrentLiveMotion(true);
    }

    private void openCurrentLiveMotion(boolean userInitiated) {
        android.util.Log.i("OpenPhotos", "[VIEWER] openCurrentLiveMotion isServer=" + isServer + " index=" + index + " userInitiated=" + userInitiated);
        String key = currentItemKey();
        if (key == null || key.isEmpty()) {
            if (userInitiated) {
                android.widget.Toast.makeText(requireContext(), "Live motion not available", android.widget.Toast.LENGTH_SHORT).show();
            }
            return;
        }
        if (isServer) {
            openServerLiveMotion(key, userInitiated);
        } else {
            openLocalLiveMotion(key, userInitiated);
        }
    }

    private void openLocalLiveMotion(@NonNull String expectedKey, boolean userInitiated) {
        if (uris == null || index < 0 || index >= uris.size()) {
            if (userInitiated) {
                android.widget.Toast.makeText(requireContext(), "Live motion not available", android.widget.Toast.LENGTH_SHORT).show();
            }
            return;
        }
        String currentUri = uris.get(index);
        android.util.Log.i("OpenPhotos", "[VIEWER] openLocalLiveMotion uri=" + currentUri);
        new Thread(() -> {
            try {
                LocalMotionMeta meta;
                synchronized (localMetaByUri) {
                    meta = localMetaByUri.get(currentUri);
                }
                if (meta == null) {
                    meta = loadLocalMotionMeta(currentUri);
                    synchronized (localMetaByUri) {
                        localMetaByUri.put(currentUri, meta);
                    }
                }
                if (meta != null && meta.sidecarVideoUri != null) {
                    playInlineLive(meta.sidecarVideoUri, expectedKey, userInitiated);
                    return;
                }
                java.io.File motion = MotionPhotoSupport.extractMotionIfLikely(
                        requireContext().getApplicationContext(),
                        android.net.Uri.parse(currentUri),
                        meta.displayName,
                        meta.mimeType,
                        currentUri,
                        "viewer"
                );
                if (motion == null || !motion.exists() || motion.length() <= 0) {
                    try {
                        ca.openphotos.android.media.MotionPhotoParser.Result parsed =
                                ca.openphotos.android.media.MotionPhotoParser.detectAndExtract(
                                        requireContext().getApplicationContext(),
                                        android.net.Uri.parse(currentUri)
                                );
                        if (parsed != null && parsed.isMotion && parsed.mp4 != null && parsed.mp4.exists() && parsed.mp4.length() > 0) {
                            motion = parsed.mp4;
                        }
                    } catch (Exception ignored) {
                    }
                }
                if (motion == null || !motion.exists() || motion.length() <= 0) {
                    android.util.Log.i("OpenPhotos", "[VIEWER] local live motion unavailable uri=" + currentUri);
                    if (userInitiated && isAdded()) {
                        requireActivity().runOnUiThread(() ->
                                android.widget.Toast.makeText(requireContext(), "Live motion not available", android.widget.Toast.LENGTH_SHORT).show());
                    }
                    return;
                }
                synchronized (tempMotionFiles) {
                    tempMotionFiles.add(motion);
                }
                playInlineLive(android.net.Uri.fromFile(motion), expectedKey, userInitiated);
            } catch (Exception e) {
                android.util.Log.w("OpenPhotos", "[VIEWER] openLocalLiveMotion failed: " + e.getMessage(), e);
                if (userInitiated && isAdded()) {
                    requireActivity().runOnUiThread(() ->
                            android.widget.Toast.makeText(requireContext(), "Failed to open Live motion", android.widget.Toast.LENGTH_LONG).show());
                }
            }
        }).start();
    }

    private void openServerLiveMotion(@NonNull String expectedKey, boolean userInitiated) {
        if (assetIds == null || index < 0 || index >= assetIds.size()) {
            if (userInitiated) {
                android.widget.Toast.makeText(requireContext(), "Live motion not available", android.widget.Toast.LENGTH_SHORT).show();
            }
            return;
        }
        String aid = assetIds.get(index);
        android.util.Log.i("OpenPhotos", "[VIEWER] openServerLiveMotion aid=" + aid);
        new Thread(() -> {
            try {
                long startedAt = android.os.SystemClock.elapsedRealtime();
                org.json.JSONObject meta = metaByAsset.get(aid);
                if (meta == null) {
                    ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                    org.json.JSONArray arr = svc.getPhotosByAssetIds(java.util.Collections.singletonList(aid), true);
                    if (arr.length() > 0) {
                        meta = arr.getJSONObject(0);
                        metaByAsset.put(aid, meta);
                    }
                }
                boolean lockedHint = meta != null && meta.optBoolean("locked", false);
                if (!lockedHint) {
                    ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                    String liveUrl = svc.liveUrl(aid);
                    if (!liveUrl.contains("?")) liveUrl = liveUrl + "?compat=1";
                    else liveUrl = liveUrl + "&compat=1";
                    String token = AuthManager.get(requireContext().getApplicationContext()).getToken();
                    android.util.Log.i("OpenPhotos", "[VIEWER] streaming server live aid=" + aid + " afterMs=" + (android.os.SystemClock.elapsedRealtime() - startedAt));
                    playInlineLiveRemoteUrl(
                            liveUrl,
                            token,
                            expectedKey,
                            userInitiated,
                            () -> new Thread(() -> {
                                android.util.Log.i("OpenPhotos", "[VIEWER] stream fallback -> download live aid=" + aid);
                                downloadAndPlayServerLive(aid, expectedKey, userInitiated, false);
                            }).start()
                    );
                    return;
                }
                downloadAndPlayServerLive(aid, expectedKey, userInitiated, true);
            } catch (Exception e) {
                android.util.Log.w("OpenPhotos", "[VIEWER] openServerLiveMotion failed aid=" + aid + " err=" + e.getMessage(), e);
                if (userInitiated && isAdded()) {
                    requireActivity().runOnUiThread(() ->
                            android.widget.Toast.makeText(requireContext(), "Failed to open Live motion", android.widget.Toast.LENGTH_LONG).show());
                }
            }
        }).start();
    }

    private void downloadAndPlayServerLive(@NonNull String aid, @NonNull String expectedKey, boolean userInitiated, boolean preferLockedFirst) {
        java.io.File payload = null;
        java.io.File dec = null;
        long startedAt = android.os.SystemClock.elapsedRealtime();
        try {
            ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
            java.util.ArrayList<String> urls = new java.util.ArrayList<>();
            if (preferLockedFirst) {
                urls.add(svc.liveLockedUrl(aid));
                urls.add(svc.liveUrl(aid));
            } else {
                urls.add(svc.liveUrl(aid));
                urls.add(svc.liveLockedUrl(aid));
            }

            String contentType = null;
            java.io.IOException lastHttpErr = null;
            for (String url : urls) {
                okhttp3.Request req = new okhttp3.Request.Builder().url(url).get().build();
                try (okhttp3.Response r = AuthorizedHttpClient.get(requireContext().getApplicationContext()).raw().newCall(req).execute()) {
                    if (!r.isSuccessful() || r.body() == null) {
                        lastHttpErr = new java.io.IOException("HTTP " + r.code() + " for " + url);
                        continue;
                    }
                    contentType = r.header("Content-Type", "");
                    payload = java.io.File.createTempFile("live_", ".bin", requireContext().getCacheDir());
                    try (java.io.InputStream is = r.body().byteStream(); java.io.FileOutputStream fos = new java.io.FileOutputStream(payload)) {
                        byte[] buf = new byte[8192];
                        int n;
                        while ((n = is.read(buf)) > 0) fos.write(buf, 0, n);
                    }
                    break;
                }
            }
            if (payload == null || !payload.exists() || payload.length() <= 0) {
                if (lastHttpErr != null) throw lastHttpErr;
                throw new java.io.IOException("Live payload unavailable");
            }

            java.io.File playable = payload;
            if ("application/octet-stream".equalsIgnoreCase(contentType)) {
                E2EEManager e2 = new E2EEManager(requireContext().getApplicationContext());
                byte[] umk = e2.getUmk();
                String uid = AuthManager.get(requireContext().getApplicationContext()).getUserId();
                if (umk == null || uid == null || uid.isEmpty()) {
                    throw new IllegalStateException("Unlock required");
                }
                dec = java.io.File.createTempFile("live_", ".mp4", requireContext().getCacheDir());
                PAE3.decryptToFile(umk, uid.getBytes(java.nio.charset.StandardCharsets.UTF_8), payload, dec);
                playable = dec;
            }
            synchronized (tempMotionFiles) {
                tempMotionFiles.add(playable);
                if (payload != null && payload != playable) tempMotionFiles.add(payload);
            }
            android.util.Log.i("OpenPhotos", "[VIEWER] download live ready aid=" + aid + " inMs=" + (android.os.SystemClock.elapsedRealtime() - startedAt));
            playInlineLive(android.net.Uri.fromFile(playable), expectedKey, userInitiated);
        } catch (Exception e) {
            android.util.Log.w("OpenPhotos", "[VIEWER] downloadAndPlayServerLive failed aid=" + aid + " err=" + e.getMessage(), e);
            if (userInitiated && isAdded()) {
                requireActivity().runOnUiThread(() ->
                        android.widget.Toast.makeText(requireContext(), "Failed to open Live motion", android.widget.Toast.LENGTH_LONG).show());
            }
        }
    }

    private void playInlineLiveRemoteUrl(
            @NonNull String url,
            @Nullable String bearerToken,
            @NonNull String expectedKey,
            boolean userInitiated,
            @Nullable Runnable onErrorFallback
    ) {
        if (!isAdded()) return;
        requireActivity().runOnUiThread(() -> {
            String currentKey = currentItemKey();
            if (currentKey == null || !currentKey.equals(expectedKey)) return;
            final java.util.concurrent.atomic.AtomicBoolean fallbackTriggered = new java.util.concurrent.atomic.AtomicBoolean(false);
            try {
                releasePlayer();
                if (playerView == null) return;

                DefaultHttpDataSource.Factory httpFactory = new DefaultHttpDataSource.Factory();
                java.util.Map<String, String> headers = new java.util.HashMap<>();
                if (bearerToken != null && !bearerToken.trim().isEmpty()) {
                    headers.put("Authorization", "Bearer " + bearerToken.trim());
                }
                httpFactory.setDefaultRequestProperties(headers);
                DefaultMediaSourceFactory mediaSourceFactory = new DefaultMediaSourceFactory(httpFactory);

                player = new ExoPlayer.Builder(requireContext())
                        .setLoadControl(newLiveLoadControl())
                        .setMediaSourceFactory(mediaSourceFactory)
                        .build();
                playerView.setPlayer(player);
                playerView.setUseController(false);
                playerView.setVisibility(View.VISIBLE);
                livePlaybackMode = true;
                livePlaybackKey = expectedKey;
                videoControls.setVisibility(View.GONE);

                MediaItem item = MediaItem.fromUri(url);
                player.setMediaItem(item);
                player.setRepeatMode(Player.REPEAT_MODE_OFF);
                player.prepare();
                player.play();
                player.addListener(new Player.Listener() {
                    @Override
                    public void onPlaybackStateChanged(int state) {
                        if (state == Player.STATE_ENDED) {
                            stopInlineLivePlayback(expectedKey);
                        }
                    }

                    @Override
                    public void onPlayerError(com.google.android.exoplayer2.PlaybackException error) {
                        stopInlineLivePlayback(expectedKey);
                        if (onErrorFallback != null && fallbackTriggered.compareAndSet(false, true)) {
                            onErrorFallback.run();
                            return;
                        }
                        if (userInitiated && isAdded()) {
                            requireActivity().runOnUiThread(() ->
                                    android.widget.Toast.makeText(requireContext(), "Failed to play Live motion", android.widget.Toast.LENGTH_LONG).show());
                        }
                    }
                });
                updateLiveBadgeVisibility();
            } catch (Exception e) {
                stopInlineLivePlayback(expectedKey);
                if (onErrorFallback != null && fallbackTriggered.compareAndSet(false, true)) {
                    onErrorFallback.run();
                    return;
                }
                if (userInitiated && isAdded()) {
                    android.widget.Toast.makeText(requireContext(), "Failed to play Live motion", android.widget.Toast.LENGTH_LONG).show();
                }
            }
        });
    }

    private void playInlineLive(@NonNull android.net.Uri uri, @NonNull String expectedKey, boolean userInitiated) {
        if (!isAdded()) return;
        requireActivity().runOnUiThread(() -> {
            String currentKey = currentItemKey();
            if (currentKey == null || !currentKey.equals(expectedKey)) return;
            try {
                releasePlayer();
                if (playerView == null) return;
                player = new ExoPlayer.Builder(requireContext())
                        .setLoadControl(newLiveLoadControl())
                        .build();
                playerView.setPlayer(player);
                playerView.setUseController(false);
                playerView.setVisibility(View.VISIBLE);
                livePlaybackMode = true;
                livePlaybackKey = expectedKey;
                videoControls.setVisibility(View.GONE);

                MediaItem item = MediaItem.fromUri(uri);
                player.setMediaItem(item);
                player.setRepeatMode(Player.REPEAT_MODE_OFF);
                player.prepare();
                player.play();
                player.addListener(new Player.Listener() {
                    @Override
                    public void onPlaybackStateChanged(int state) {
                        if (state == Player.STATE_ENDED) {
                            stopInlineLivePlayback(expectedKey);
                        }
                    }

                    @Override
                    public void onPlayerError(com.google.android.exoplayer2.PlaybackException error) {
                        stopInlineLivePlayback(expectedKey);
                        if (userInitiated && isAdded()) {
                            requireActivity().runOnUiThread(() ->
                                    android.widget.Toast.makeText(requireContext(), "Failed to play Live motion", android.widget.Toast.LENGTH_LONG).show());
                        }
                    }
                });
                updateLiveBadgeVisibility();
            } catch (Exception e) {
                stopInlineLivePlayback(expectedKey);
                if (userInitiated && isAdded()) {
                    android.widget.Toast.makeText(requireContext(), "Failed to play Live motion", android.widget.Toast.LENGTH_LONG).show();
                }
            }
        });
    }

    @NonNull
    private DefaultLoadControl newLiveLoadControl() {
        return new DefaultLoadControl.Builder()
                .setBufferDurationsMs(
                        500,   // minBufferMs
                        2000,  // maxBufferMs
                        200,   // bufferForPlaybackMs
                        500    // bufferForPlaybackAfterRebufferMs
                )
                .setPrioritizeTimeOverSizeThresholds(true)
                .build();
    }

    private void stopInlineLivePlayback(@Nullable String expectedKey) {
        if (!isAdded()) return;
        requireActivity().runOnUiThread(() -> {
            if (expectedKey != null && livePlaybackKey != null && !expectedKey.equals(livePlaybackKey)) return;
            releasePlayer();
            livePlaybackMode = false;
            livePlaybackKey = null;
            if (playerView != null) {
                playerView.setPlayer(null);
                playerView.setVisibility(View.GONE);
            }
            updateLiveBadgeVisibility();
        });
    }

    private void toggleFavorite(String aid){
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                org.json.JSONObject p = metaByAsset.get(aid);
                boolean currentFav = p != null && p.optInt("favorites", 0) > 0;
                boolean nextFav = !currentFav;
                org.json.JSONObject res = svc.setFavorite(aid, nextFav);
                if (p != null) p.put("favorites", res.optInt("favorites", nextFav ? 1 : 0));
                final String msg = nextFav ? "Favorited" : "Unfavorited";
                requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), msg, android.widget.Toast.LENGTH_SHORT).show());
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Favorite failed", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private void doLock(String aid){ E2EEManager e2 = new E2EEManager(requireContext().getApplicationContext()); if (e2.getUmk()==null) { new EnterPinDialog().setListener(pin -> { new Thread(() -> { boolean ok = e2.unlockWithPin(pin); requireActivity().runOnUiThread(() -> { if (!ok) android.widget.Toast.makeText(requireContext(), "Unlock failed", android.widget.Toast.LENGTH_LONG).show(); else lockNow(aid); }); }).start(); }).show(getParentFragmentManager(), "pin"); } else { lockNow(aid);} }
    private void lockNow(String aid){ new Thread(() -> { try { new ServerPhotosService(requireContext().getApplicationContext()).lockPhoto(aid); requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Locked", android.widget.Toast.LENGTH_SHORT).show()); } catch (Exception e) { requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Lock failed", android.widget.Toast.LENGTH_LONG).show()); } }).start(); }

    private void saveCurrent(String aid){ new Thread(() -> { try { if (isCurrentLive()) MediaSaveHelper.saveLive(requireContext().getApplicationContext(), aid, null); else if (isCurrentVideo()) MediaSaveHelper.saveVideo(requireContext().getApplicationContext(), aid, null); else MediaSaveHelper.saveImage(requireContext().getApplicationContext(), aid, null); requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Saved to Photos", android.widget.Toast.LENGTH_SHORT).show()); } catch (Exception e) { requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Save failed: "+e.getMessage(), android.widget.Toast.LENGTH_LONG).show()); } }).start(); }

    private void shareCurrent(String aid){ org.json.JSONObject p = metaByAsset.get(aid); if (p != null && p.optBoolean("locked",false)) { android.widget.Toast.makeText(requireContext(), "Share unavailable for locked items", android.widget.Toast.LENGTH_LONG).show(); return; } try { java.io.File f = ca.openphotos.android.media.DiskImageCache.get(requireContext()).readFile(ca.openphotos.android.media.DiskImageCache.Bucket.IMAGES, aid); if (f==null||!f.exists()) { android.widget.Toast.makeText(requireContext(), "Original not cached yet", android.widget.Toast.LENGTH_SHORT).show(); return; } android.net.Uri uri = androidx.core.content.FileProvider.getUriForFile(requireContext(), requireContext().getPackageName()+".provider", f); android.content.Intent i = new android.content.Intent(android.content.Intent.ACTION_SEND); i.setType("image/*"); i.putExtra(android.content.Intent.EXTRA_STREAM, uri); i.addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION); startActivity(android.content.Intent.createChooser(i, "Share")); } catch (Exception e) { android.widget.Toast.makeText(requireContext(), "Share failed", android.widget.Toast.LENGTH_LONG).show(); } }

    private void openAlbumTree(String aid){ AlbumTreeDialogFragment f = AlbumTreeDialogFragment.newInstance(true); getParentFragmentManager().setFragmentResultListener(AlbumTreeDialogFragment.KEY_SELECT_RESULT, this, (key,b)->{ int albumId = b.getInt("album_id",0); new Thread(() -> { try { ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext()); org.json.JSONArray arr = svc.getPhotosByAssetIds(java.util.Collections.singletonList(aid), false); int nid = (arr.length()>0)? arr.getJSONObject(0).optInt("id",0):0; if (nid>0) svc.addPhotosToAlbum(albumId, java.util.Collections.singletonList(nid)); requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Added to album", android.widget.Toast.LENGTH_SHORT).show()); } catch (Exception e) { requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Add failed", android.widget.Toast.LENGTH_LONG).show()); } }).start(); }); f.show(getParentFragmentManager(), "albumTree"); }

    private void preparePlayer(){ if(!isCurrentVideo()){ releasePlayer(); return; } if(player!=null) return; player = new ExoPlayer.Builder(requireContext()).build(); if (playerView != null) { playerView.setPlayer(player); playerView.setUseController(false); playerView.setVisibility(View.VISIBLE); } String aid = assetIds.get(index); String url = new ServerPhotosService(requireContext().getApplicationContext()).imageUrl(aid); MediaItem item = MediaItem.fromUri(url); player.setMediaItem(item); player.prepare(); player.play(); btnPlayPause.setImageResource(android.R.drawable.ic_media_pause); player.addListener(new com.google.android.exoplayer2.Player.Listener(){ @Override public void onIsPlayingChanged(boolean p){ btnPlayPause.setImageResource(p? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play);} @Override public void onPlaybackStateChanged(int state){ int dur = (int)Math.max(0, player.getDuration()); suppressSeek=true; seek.setMax(dur); suppressSeek=false; }}); pager.postDelayed(new Runnable(){ @Override public void run(){ if(player!=null && !draggingSeek){ suppressSeek=true; seek.setProgress((int)player.getCurrentPosition()); suppressSeek=false; } if(player!=null) pager.postDelayed(this,300); }},300); }
    private void togglePlayPause(){ if(player==null){ preparePlayer(); return; } if(player.isPlaying()) player.pause(); else player.play(); }
    private void toggleMute(){ if(player==null) return; playerMuted=!playerMuted; player.setVolume(playerMuted?0f:1f); btnMute.setImageResource(playerMuted? android.R.drawable.ic_lock_silent_mode : android.R.drawable.ic_lock_silent_mode_off); }
    private void releasePlayer(){ try{ if(player!=null){ player.release(); player=null; } } catch(Exception ignored){} if (playerView != null) { try { playerView.setPlayer(null); playerView.setVisibility(View.GONE); } catch (Exception ignored) {} } livePlaybackMode = false; livePlaybackKey = null; }

    @Nullable
    private String currentItemKey() {
        try {
            if (isServer) {
                if (assetIds == null || index < 0 || index >= assetIds.size()) return null;
                return "s:" + assetIds.get(index);
            }
            if (uris == null || index < 0 || index >= uris.size()) return null;
            return "l:" + uris.get(index);
        } catch (Exception ignored) {
            return null;
        }
    }

    private void cleanupTempMotionFiles() {
        synchronized (tempMotionFiles) {
            for (java.io.File f : tempMotionFiles) {
                try {
                    if (f != null && f.exists()) {
                        //noinspection ResultOfMethodCallIgnored
                        f.delete();
                    }
                } catch (Exception ignored) {
                }
            }
            tempMotionFiles.clear();
        }
    }

    @Override public void onDestroyView(){ super.onDestroyView(); releasePlayer(); cleanupTempMotionFiles(); }

    private static final class LocalMotionMeta {
        final String displayName;
        final String mimeType;
        final boolean isLive;
        final @Nullable android.net.Uri sidecarVideoUri;

        LocalMotionMeta(@Nullable String displayName, @Nullable String mimeType, boolean isLive, @Nullable android.net.Uri sidecarVideoUri) {
            this.displayName = displayName;
            this.mimeType = mimeType;
            this.isLive = isLive;
            this.sidecarVideoUri = sidecarVideoUri;
        }
    }
}
