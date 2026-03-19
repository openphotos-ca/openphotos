package ca.openphotos.android.ui;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.fragment.app.DialogFragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.ServerPhotosService;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.button.MaterialButtonToggleGroup;
import com.google.android.material.chip.Chip;
import com.google.android.material.chip.ChipGroup;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Photos tab home screen, modeled after the iOS Photos tab.
 * - Row 2 actions: Search, Sort, Grid/Timeline toggle, Select, More
 * - Row 3 filters: Filter (stub), Album tree (stub), Favorite, Locked, Album chips
 * - Row 4 segments: All | Photos | Videos | Trash with counts
 * - Grid with pull-to-refresh and endless scroll
 */
public class PhotosHomeFragment extends Fragment {
    private static final String PREFS = "photos.ui";
    private static final String KEY_GRID_SPAN = "grid.span";
    private static final String KEY_VIEW_MODE = "view.mode"; // grid|timeline

    private MediaGridAdapter adapter; // grid adapter
    private TimelineAdapter timelineAdapter; // timeline adapter
    private RecyclerView grid;
    private androidx.swiperefreshlayout.widget.SwipeRefreshLayout swipe;
    private TextView empty;
    private GridLayoutManager layoutManager; // for grid mode
    private GridLayoutManager tlLayoutManager; // for timeline mode
    // Multi-select albums (match iOS/Web). When empty => all albums.
    private final java.util.LinkedHashSet<Integer> selectedAlbumIds = new java.util.LinkedHashSet<>();
    private boolean sortAscending = false; // false = newest first

    // Filters
    private String mediaFilter = "all"; // all|photos|videos|trash
    private Boolean lockedFilter = null; // null=all
    private boolean favoriteOnly = false;
    private int trashCount = 0;
    // Include sub‑albums when filtering by album(s). Default OFF and not persisted.
    private boolean includeAlbumSubtree = false;
    // Advanced Filters (Faces / Date / Type / Rating / Location)
    private ca.openphotos.android.server.FilterParams filters = new ca.openphotos.android.server.FilterParams();

    // Paging
    private final ArrayList<MediaGridAdapter.Cell> all = new ArrayList<>(); // grid photos
    private final java.util.ArrayList<org.json.JSONObject> allPhotosJson = new java.util.ArrayList<>(); // timeline photos
    private final java.util.ArrayList<TimelineAdapter.Cell> timelineCells = new java.util.ArrayList<>();
    private int page = 1; private final int limit = 60; private boolean hasMore = true; private boolean loading = false;

    // Selection
    private boolean selectionMode = false;
    private final Set<String> selectedIds = new HashSet<>();
    private View selectionBottomBar;
    private MaterialButton btnSelectAll;
    private MaterialButton btnDeselectAll;
    private MaterialButton btnSelectionActions;
    private int gridBaseBottomPadding = 0;
    private int selectionBarHeight = 0;

    // Header container (overlay) + collapse state
    private View headerContainer; private int headerHeight = 0; private boolean headersShown = true;
    private boolean trackingScroll = false; private int lastScrollOffset = 0; private float dirAccum = 0f; private int lastDir = 0; // 1 down, -1 up

    // View mode
    private boolean timelineMode = false;

    // Years navigation
    private java.util.List<Integer> years = new java.util.ArrayList<>();
    private View yearRail; private MaterialButton btnYears;

    // Inline search UI state
    private boolean searchMode = false;
    private android.widget.EditText searchField;
    private View btnSearchSubmit;
    private MaterialButton btnSearch, btnSort, btnSelect, btnMore;
    private com.google.android.material.button.MaterialButtonToggleGroup toggleView;
    private View spacerActions;
    private MaterialButton btnSegmentsReload;
    private Chip chipAll, chipPhotos, chipVideos, chipTrash;

    // Menu/feature flags
    private boolean isEnterpriseEdition = false;
    private static final int ALBUM_PICK_FILTER = 1;
    private static final int ALBUM_PICK_BULK_ADD = 2;
    private int pendingAlbumPickMode = ALBUM_PICK_FILTER;
    private static final int MENU_MORE_SLIDESHOW = 1001;
    private static final int MENU_MORE_SHARING = 1002;
    private static final int MENU_MORE_USERS_GROUPS = 1003;
    private static final int MENU_MORE_MANAGE_FACES = 1004;
    private static final int MENU_MORE_SIMILAR = 1005;
    private static final int MENU_MORE_SIGN_OUT = 1006;
    private static final int MENU_ACTION_ADD_TO_ALBUM = 2001;
    private static final int MENU_ACTION_SHARE = 2002;
    private static final int MENU_ACTION_LOCK = 2003;
    private static final int MENU_ACTION_FAVORITE = 2004;
    private static final int MENU_ACTION_DELETE = 2005;
    private static final int MENU_ACTION_CLEAR_RATING = 2006;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_photos_home, container, false);

        // Auth gate: if token is missing, navigate to login
        if (!AuthManager.get(requireContext()).isAuthenticated()) {
            try { androidx.navigation.fragment.NavHostFragment.findNavController(this).navigate(R.id.serverLoginFragment); } catch (Exception ignored) {}
            return root;
        }

        // Row 2: actions
        btnSearch = root.findViewById(R.id.btn_search);
        btnSort = root.findViewById(R.id.btn_sort);
        btnSelect = root.findViewById(R.id.btn_select);
        btnMore = root.findViewById(R.id.btn_more);
        toggleView = root.findViewById(R.id.toggle_view_mode);
        searchField = root.findViewById(R.id.search_field);
        btnSearchSubmit = root.findViewById(R.id.btn_search_submit);
        spacerActions = root.findViewById(R.id.spacer_actions);
        selectionBottomBar = root.findViewById(R.id.selection_bottom_bar);
        btnSelectAll = root.findViewById(R.id.btn_select_all);
        btnDeselectAll = root.findViewById(R.id.btn_deselect_all);
        btnSelectionActions = root.findViewById(R.id.btn_selection_actions);
        btnSegmentsReload = root.findViewById(R.id.btn_segments_reload);
        // Load last view mode
        timelineMode = readViewMode(requireContext()).equals("timeline");
        toggleView.check(timelineMode ? R.id.btn_timeline : R.id.btn_grid);
        btnSearch.setOnClickListener(v -> toggleSearchMode(true));
        btnMore.setOnClickListener(this::showMoreMenu);
        btnSearchSubmit.setOnClickListener(v -> submitSearch());
        searchField.setOnEditorActionListener((tv, actionId, ev) -> { submitSearch(); return true; });
        searchField.addTextChangedListener(new android.text.TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) { updateSearchButtons(); updateClearIcon(); }
            @Override public void afterTextChanged(android.text.Editable s) {}
        });
        // Inline clear icon behavior
        searchField.setOnTouchListener((v, ev) -> {
            if (ev.getAction() == android.view.MotionEvent.ACTION_UP) {
                android.graphics.drawable.Drawable right = searchField.getCompoundDrawables()[2];
                if (right != null) {
                    int touchAreaStart = searchField.getWidth() - searchField.getPaddingRight() - right.getBounds().width();
                    if (ev.getX() >= touchAreaStart) { searchField.setText(""); return true; }
                }
            }
            return false;
        });
        btnSort.setOnClickListener(v -> {
            android.widget.PopupMenu pm = new android.widget.PopupMenu(requireContext(), v);
            pm.getMenu().add(0,1,0, "Newest first");
            pm.getMenu().add(0,2,1, "Oldest first");
            pm.setOnMenuItemClickListener(item -> { sortAscending = (item.getItemId()==2); refresh(true); return true; });
            pm.show();
        });
        toggleView.addOnButtonCheckedListener((group, checkedId, isChecked) -> {
            if (!isChecked) return;
            boolean wantTimeline = (checkedId == R.id.btn_timeline);
            if (wantTimeline == timelineMode) return;
            timelineMode = wantTimeline; saveViewMode(requireContext(), timelineMode ? "timeline" : "grid");
            configureRecyclerForMode();
            refresh(true);
        });
        btnSelect.setOnClickListener(v -> setSelectionMode(!selectionMode, true));
        btnSelectAll.setOnClickListener(v -> selectAllCurrent());
        btnDeselectAll.setOnClickListener(v -> clearSelection());
        btnSelectionActions.setOnClickListener(this::showSelectionActionsMenu);
        // Ensure initial text state
        updateSelectButtonText();
        updateSearchButtons();
        updateSelectionBarUi();

        // Handle back press to collapse search
        requireActivity().getOnBackPressedDispatcher().addCallback(getViewLifecycleOwner(), new androidx.activity.OnBackPressedCallback(true) {
            @Override public void handleOnBackPressed() {
                if (searchMode) { toggleSearchMode(false); }
                else if (selectionMode) { setSelectionMode(false, true); }
                else { setEnabled(false); requireActivity().onBackPressed(); setEnabled(true); }
            }
        });

        // Chips
        chipAll = root.findViewById(R.id.chip_all);
        chipPhotos = root.findViewById(R.id.chip_photos);
        chipVideos = root.findViewById(R.id.chip_videos);
        chipTrash = root.findViewById(R.id.chip_trash);
        View.OnClickListener segL = v -> {
            if (v == chipAll) mediaFilter = "all";
            else if (v == chipPhotos) mediaFilter = "photos";
            else if (v == chipVideos) mediaFilter = "videos";
            else mediaFilter = "trash";
            updateTrashUi();
            refresh(true);
        };
        chipAll.setOnClickListener(segL);
        chipPhotos.setOnClickListener(segL);
        chipVideos.setOnClickListener(segL);
        chipTrash.setOnClickListener(segL);
        chipTrash.setOnCloseIconClickListener(v -> confirmEmptyTrash());
        btnSegmentsReload.setOnClickListener(v -> reloadCurrentDatasetFromServer());
        updateTrashUi();

        // Row 3: filters + albums
        MaterialButton btnFilter = root.findViewById(R.id.btn_filter);
        MaterialButton btnAlbums = root.findViewById(R.id.btn_albums);
        MaterialButton btnFav = root.findViewById(R.id.btn_favorites);
        MaterialButton btnLocked = root.findViewById(R.id.btn_locked);
        ChipGroup albumsChips = root.findViewById(R.id.albums_chips);
        btnFilter.setOnClickListener(v -> openFiltersDialog());
        btnAlbums.setOnClickListener(v -> {
            pendingAlbumPickMode = ALBUM_PICK_FILTER;
            AlbumTreeDialogFragment dlg = AlbumTreeDialogFragment.newInstance(includeAlbumSubtree);
            dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
            dlg.show(getParentFragmentManager(), "album_tree");
        });
        btnFav.setOnClickListener(v -> {
            favoriteOnly = !favoriteOnly;
            syncQuickFilterButtons(root);
            requestCountsAsync(chipAll, chipPhotos, chipVideos);
            updateActiveFilterRow();
            refresh(true);
        });
        btnLocked.setOnClickListener(v -> {
            try { android.util.Log.i("OpenPhotos", "[UI] Lock toggle tapped. current=" + lockedFilter); } catch (Exception ignored) {}
            // Always enable server-side locked-only query immediately when tapping the lock button
            lockedFilter = (lockedFilter == null || !lockedFilter) ? Boolean.TRUE : null; // toggle
            syncQuickFilterButtons(root);
            updateActiveFilterRow();
            refresh(true); // triggers /api/photos?...filter_locked_only=true&include_locked=true when on

            // If UMK is missing, prompt for PIN so we can decrypt thumbnails; results still list locked rows
            ca.openphotos.android.e2ee.E2EEManager e2 = new ca.openphotos.android.e2ee.E2EEManager(requireContext());
            if (lockedFilter == Boolean.TRUE && e2.getUmk() == null) {
                new EnterPinDialog().setListener(pin -> {
                    // Network call must run on background thread to avoid NetworkOnMainThreadException
                    new Thread(() -> {
                        boolean ok = e2.unlockWithPin(pin);
                        // Post results back to UI thread
                        requireActivity().runOnUiThread(() -> {
                            if (ok) {
                                android.widget.Toast.makeText(requireContext(), "Unlocked", android.widget.Toast.LENGTH_SHORT).show();
                                // Force a full refresh so adapter can decrypt visible thumbnails
                                try { android.util.Log.i("OpenPhotos","[UI] Unlock ok, refreshing to decrypt thumbs"); } catch (Exception ignored) {}
                                refresh(true);
                            } else {
                                android.widget.Toast.makeText(requireContext(), "Unlock failed", android.widget.Toast.LENGTH_LONG).show();
                            }
                        });
                    }).start();
                }).show(getParentFragmentManager(), "pin");
            }
        });
        syncQuickFilterButtons(root);
        populateAlbumChips(albumsChips);

        // Grid / Timeline common views
        headerContainer = root.findViewById(R.id.photos_header_container);
        // Use dynamic lookup for year_rail to avoid compile-time R symbol mismatch on some AGP setups
        try {
            int rid = getResources().getIdentifier("year_rail", "id", requireContext().getPackageName());
            yearRail = root.findViewById(rid);
        } catch (Exception ignored) { yearRail = null; }
        btnYears = root.findViewById(R.id.btn_years);

        // Recycler
        grid = root.findViewById(R.id.grid);
        gridBaseBottomPadding = grid.getPaddingBottom();
        configureRecyclerForMode();
        selectionBottomBar.post(() -> {
            selectionBarHeight = selectionBottomBar.getHeight();
            updateSelectionBarUi();
        });
        selectionBottomBar.getViewTreeObserver().addOnGlobalLayoutListener(() -> {
            int h = selectionBottomBar.getHeight();
            if (h != selectionBarHeight) {
                selectionBarHeight = h;
                updateSelectionBarUi();
            }
        });

        // Swipe to refresh + endless scroll
        swipe = root.findViewById(R.id.swipe);
        swipe.setOnRefreshListener(() -> refresh(true));
        grid.addOnScrollListener(new RecyclerView.OnScrollListener() {
            @Override public void onScrolled(@NonNull RecyclerView recyclerView, int dx, int dy) {
                super.onScrolled(recyclerView, dx, dy);
                // Paging trigger
                int last;
                if (timelineMode) { last = tlLayoutManager.findLastVisibleItemPosition(); }
                else { last = layoutManager.findLastVisibleItemPosition(); }
                int approxTotal = timelineMode ? timelineCells.size() : all.size();
                if (hasMore && !loading && last >= Math.max(0, approxTotal - 6)) { loadNext(); }

                // Enable pull-to-refresh only at top
                int off = recyclerView.computeVerticalScrollOffset();
                swipe.setEnabled(off <= 0);

                // Header collapse (disabled in selection mode)
                if (selectionMode) { if (!headersShown) applyHeaderVisibility(true, true); trackingScroll = false; return; }
                handleScrollForHeader(off);
            }
        });

        empty = root.findViewById(R.id.empty);

        // Measure header height and apply initial top inset matching current visibility
        headerContainer.post(() -> {
            headerHeight = headerContainer.getHeight();
            setRecyclerTopPadding(headersShown ? headerHeight : 0);
        });
        // Re-apply inset if header height changes (rotation, font scale, etc.)
        headerContainer.getViewTreeObserver().addOnGlobalLayoutListener(() -> {
            int h = headerContainer.getHeight();
            if (h != headerHeight) { headerHeight = h; setRecyclerTopPadding(headersShown ? headerHeight : 0); }
        });

        // Years navigation wiring
        btnYears.setOnClickListener(v -> {
            if (years.isEmpty()) {
                android.widget.Toast.makeText(requireContext(), "Loading years…", android.widget.Toast.LENGTH_SHORT).show();
                requestYearBucketsAsync();
                return;
            }
            YearPickerBottomSheet sheet = YearPickerBottomSheet.newInstance(years);
            sheet.show(getParentFragmentManager(), "years");
        });
        getParentFragmentManager().setFragmentResultListener(YearPickerBottomSheet.KEY_RESULT, this, (k, b) -> {
            int y = b.getInt("year", -1); if (y > 0) scrollToYear(y);
        });
        requestYearBucketsAsync();

        // Initial data + counts (ensure token is available to avoid a 401 race right after login)
        // Listen for Filters dialog results (apply on Done)
        getParentFragmentManager().setFragmentResultListener(FiltersDialogFragment.KEY_RESULT, this, (key, bundle) -> {
            ca.openphotos.android.server.FilterParams p = bundle.getParcelable(FiltersDialogFragment.KEY_RESULT);
            if (p != null) { filters = p; requestCountsAsync(chipAll, chipPhotos, chipVideos); updateActiveFilterRow(); refresh(true); }
        });
        // Listen for Manage Faces requests from the dialog
        getParentFragmentManager().setFragmentResultListener(FiltersDialogFragment.KEY_MANAGE_FACES, this, (key, bundle) -> {
            openManageFacesDialog();
        });
        // Listen for AlbumTreeDialog results
        getParentFragmentManager().setFragmentResultListener(AlbumTreeDialogFragment.KEY_SELECT_RESULT, this, (key, bundle) -> {
            if (bundle == null) return;
            int pickedId = bundle.getInt("album_id", -1);
            if (pendingAlbumPickMode == ALBUM_PICK_BULK_ADD) {
                pendingAlbumPickMode = ALBUM_PICK_FILTER;
                if (pickedId > 0) runBulkAddToAlbum(pickedId);
                return;
            }

            includeAlbumSubtree = bundle.getBoolean("include_subtree", false);
            if (pickedId > 0) {
                if (selectedAlbumIds.contains(pickedId)) selectedAlbumIds.remove(pickedId); else selectedAlbumIds.add(pickedId);
                updateActiveFilterRow();
                requestCountsAsync((Chip) getView().findViewById(R.id.chip_all), (Chip) getView().findViewById(R.id.chip_photos), (Chip) getView().findViewById(R.id.chip_videos));
                refresh(true);
            }
        });
        getParentFragmentManager().setFragmentResultListener(AlbumTreeDialogFragment.KEY_ALBUMS_UPDATED, this, (key, bundle) -> {
            ChipGroup chips = getView() != null ? getView().findViewById(R.id.albums_chips) : null;
            if (chips != null) populateAlbumChips(chips);
        });

        ensureAuthenticatedThenLoad(() -> {
            refreshEnterpriseCapabilitiesAsync();
            requestCountsAsync(chipAll, chipPhotos, chipVideos);
            updateActiveFilterRow();
            refresh(true);
        });
        return root;
    }

    private void toggleSearchMode(boolean enable) {
        if (searchMode == enable) return;
        searchMode = enable;
        if (enable) {
            // Hide other actions, show field + controls, change icon to back
            btnSort.setVisibility(View.GONE);
            toggleView.setVisibility(View.GONE);
            btnSelect.setVisibility(View.GONE);
            btnMore.setVisibility(View.GONE);
            if (spacerActions != null) spacerActions.setVisibility(View.GONE);
            searchField.setVisibility(View.VISIBLE);
            btnSearchSubmit.setVisibility(View.VISIBLE);
            updateSearchButtons();
            btnSearch.setIconResource(ca.openphotos.android.R.drawable.ic_arrow_back_24);
            btnSearch.setOnClickListener(v -> toggleSearchMode(false));
            searchField.requestFocus();
            showKeyboard(searchField);
        } else {
            hideKeyboard(searchField);
            btnSort.setVisibility(View.VISIBLE);
            toggleView.setVisibility(View.VISIBLE);
            btnSelect.setVisibility(View.VISIBLE);
            btnMore.setVisibility(View.VISIBLE);
            if (spacerActions != null) spacerActions.setVisibility(View.VISIBLE);
            searchField.setVisibility(View.GONE);
            btnSearchSubmit.setVisibility(View.GONE);
            btnSearch.setIconResource(android.R.drawable.ic_menu_search);
            btnSearch.setOnClickListener(v -> toggleSearchMode(true));
            // Clear and restore grid
            searchField.setText("");
            refresh(true);
        }
    }

    private void updateSearchButtons() {
        String q = searchField != null ? searchField.getText().toString() : "";
        btnSearchSubmit.setEnabled(q.length() >= 2);
    }

    private void updateClearIcon() {
        String q = searchField != null ? searchField.getText().toString() : "";
        android.graphics.drawable.Drawable clear = q.isEmpty() ? null : requireContext().getDrawable(android.R.drawable.ic_menu_close_clear_cancel);
        if (clear != null) {
            clear.setTint(ContextCompat.getColor(requireContext(), R.color.app_text_secondary));
            clear.setBounds(0,0,clear.getIntrinsicWidth(), clear.getIntrinsicHeight());
        }
        searchField.setCompoundDrawablesWithIntrinsicBounds(null, null, clear, null);
    }

    private void submitSearch() {
        if (!searchMode) return; String q = searchField.getText()!=null? searchField.getText().toString():"";
        if (q.length() < 2) { android.widget.Toast.makeText(requireContext(), "Enter at least 2 characters", android.widget.Toast.LENGTH_SHORT).show(); return; }
        // Reset paging and lists; show results in grid
        timelineMode = false; page = 1; hasMore = true; loading = false; all.clear(); adapter.submitList(new ArrayList<>(all));
        performSearch(q, page, false);
    }

    private void performSearch(String query, int page, boolean append) {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                String media = mediaFilter.equals("photos") ? "photos" : (mediaFilter.equals("videos") ? "videos" : null);
                boolean trashOnly = "trash".equals(mediaFilter);
                // Server search API supports filters per our server docs; we pass what exists.
                JSONObject resp = svc.search(query, media, lockedFilter, null, null, page, limit);
                boolean more = resp.optBoolean("has_more", false);
                java.util.List<String> ids = new java.util.ArrayList<>();
                if (resp.has("items")) {
                    org.json.JSONArray arr = resp.getJSONArray("items");
                    for (int i=0;i<arr.length();i++) {
                        org.json.JSONObject it = arr.getJSONObject(i);
                        String aid = it.optString("asset_id");
                        if (aid != null && !aid.isEmpty()) ids.add(aid);
                    }
                }
                // Hydrate
                java.util.ArrayList<MediaGridAdapter.Cell> list = new java.util.ArrayList<>();
                if (!ids.isEmpty()) {
                    // server returns list, hydrate in one go (limit already applied server-side)
                    org.json.JSONArray photos = svc.getPhotosByAssetIds(ids, false);
                    for (int i=0;i<photos.length();i++) {
                        org.json.JSONObject p = photos.getJSONObject(i);
                        if (trashOnly && p.optLong("delete_time", 0L) <= 0L) continue;
                        String assetId = p.optString("asset_id"); boolean isVideo = p.optBoolean("is_video", false); boolean locked = p.optBoolean("locked", false); int rating = p.optInt("rating", 0); String imgUrl = svc.thumbnailUrl(assetId);
                        list.add(new MediaGridAdapter.Cell("search-"+assetId, p.optString("filename", assetId), locked, imgUrl, isVideo, assetId, rating));
                    }
                }
                requireActivity().runOnUiThread(() -> {
                    if (!append) all.clear();
                    all.addAll(list);
                    adapter.submitList(new ArrayList<>(all));
                    hasMore = more; loading = false; swipe.setRefreshing(false);
                    empty.setVisibility(all.isEmpty()? View.VISIBLE : View.GONE);
                });
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> { swipe.setRefreshing(false); empty.setText("Search failed"); empty.setVisibility(View.VISIBLE); });
            }
        }).start();
    }

    private void showKeyboard(View v) {
        try { v.post(() -> { android.view.inputmethod.InputMethodManager im = (android.view.inputmethod.InputMethodManager) requireContext().getSystemService(Context.INPUT_METHOD_SERVICE); if (im != null) im.showSoftInput(v, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT); }); } catch (Exception ignored) {}
    }
    private void hideKeyboard(View v) {
        try { android.view.inputmethod.InputMethodManager im = (android.view.inputmethod.InputMethodManager) requireContext().getSystemService(Context.INPUT_METHOD_SERVICE); if (im != null) im.hideSoftInputFromWindow(v.getWindowToken(), 0); } catch (Exception ignored) {}
    }

    private void ensureAuthenticatedThenLoad(Runnable work) {
        // Avoid an early 401 immediately after login by waiting until token is present
        ca.openphotos.android.core.AuthManager auth = ca.openphotos.android.core.AuthManager.get(requireContext());
        if (auth.isAuthenticated() && auth.getToken() != null && !auth.getToken().isEmpty()) { work.run(); return; }
        grid.postDelayed(new Runnable() {
            @Override public void run() {
                ca.openphotos.android.core.AuthManager a = ca.openphotos.android.core.AuthManager.get(requireContext());
                if (a.isAuthenticated() && a.getToken() != null && !a.getToken().isEmpty()) { work.run(); }
                else { grid.postDelayed(this, 300); }
            }
        }, 300);
    }


    private void toggleSelection(int position) {
        if (timelineMode) {
            if (position < 0 || position >= timelineCells.size()) return;
            TimelineAdapter.Cell c = timelineCells.get(position);
            if (c.type != TimelineAdapter.TYPE_PHOTO) return;
            String id = c.assetId;
            if (id == null || id.isEmpty()) return;
            if (selectedIds.contains(id)) selectedIds.remove(id); else selectedIds.add(id);
            timelineAdapter.notifyItemChanged(position);
        } else {
            java.util.List<MediaGridAdapter.Cell> list = adapter.getCurrentList();
            if (position < 0 || position >= list.size()) return;
            String id = list.get(position).assetId;
            if (id == null || id.isEmpty()) return;
            if (selectedIds.contains(id)) selectedIds.remove(id); else selectedIds.add(id);
            adapter.notifyItemChanged(position);
        }
        updateSelectionBarUi();
    }

    private void setSelectionMode(boolean enabled, boolean clearSelection) {
        selectionMode = enabled;
        if (clearSelection) selectedIds.clear();
        if (adapter != null) adapter.setSelectionMode(selectionMode, selectedIds);
        if (timelineAdapter != null) timelineAdapter.setSelectionMode(selectionMode, selectedIds);
        updateSelectButtonText();
        updateSelectionBarUi();
        if (selectionMode) applyHeaderVisibility(true, true);
    }

    private void clearSelection() {
        selectedIds.clear();
        if (adapter != null) adapter.setSelectionMode(selectionMode, selectedIds);
        if (timelineAdapter != null) timelineAdapter.setSelectionMode(selectionMode, selectedIds);
        updateSelectionBarUi();
    }

    private void selectAllCurrent() {
        selectedIds.clear();
        if (timelineMode) {
            for (JSONObject p : allPhotosJson) {
                String aid = p.optString("asset_id");
                if (aid != null && !aid.isEmpty()) selectedIds.add(aid);
            }
        } else {
            for (MediaGridAdapter.Cell c : all) {
                if (c.assetId != null && !c.assetId.isEmpty()) selectedIds.add(c.assetId);
            }
        }
        if (adapter != null) adapter.setSelectionMode(selectionMode, selectedIds);
        if (timelineAdapter != null) timelineAdapter.setSelectionMode(selectionMode, selectedIds);
        updateSelectionBarUi();
    }

    private List<String> selectedAssetIds() {
        List<String> out = new ArrayList<>();
        for (String id : selectedIds) {
            if (id != null && !id.isEmpty()) out.add(id);
        }
        Collections.sort(out);
        return out;
    }

    @Nullable
    private String firstSelectedAssetIdInCurrentOrder() {
        if (timelineMode) {
            for (JSONObject p : allPhotosJson) {
                String aid = p.optString("asset_id");
                if (aid != null && !aid.isEmpty() && selectedIds.contains(aid)) return aid;
            }
        } else {
            for (MediaGridAdapter.Cell c : all) {
                String aid = c.assetId;
                if (aid != null && !aid.isEmpty() && selectedIds.contains(aid)) return aid;
            }
        }
        for (String aid : selectedIds) {
            if (aid != null && !aid.isEmpty()) return aid;
        }
        return null;
    }

    private void updateSelectionBarUi() {
        if (selectionBottomBar == null) return;
        boolean showBar = selectionMode || !selectedIds.isEmpty();
        selectionBottomBar.setVisibility(showBar ? View.VISIBLE : View.GONE);
        if (btnSelectionActions != null) {
            btnSelectionActions.setVisibility(selectionMode && !selectedIds.isEmpty() ? View.VISIBLE : View.GONE);
        }
        updateRecyclerBottomPadding();
    }

    private void updateRecyclerBottomPadding() {
        if (grid == null) return;
        int extra = (selectionBottomBar != null && selectionBottomBar.getVisibility() == View.VISIBLE) ? selectionBarHeight : 0;
        int targetBottom = gridBaseBottomPadding + extra;
        grid.setPadding(grid.getPaddingLeft(), grid.getPaddingTop(), grid.getPaddingRight(), targetBottom);
    }

    private void updateTrashUi() {
        if (chipTrash == null) return;
        boolean inTrash = "trash".equals(mediaFilter);
        chipTrash.setCloseIconVisible(inTrash);
        chipTrash.setCloseIconTint(android.content.res.ColorStateList.valueOf(ContextCompat.getColor(requireContext(),
                trashCount > 0 ? R.color.app_accent : R.color.app_text_tertiary)));
    }

    private void reloadCurrentDatasetFromServer() {
        if (swipe != null) swipe.setRefreshing(true);
        if (searchMode) {
            String q = searchField != null && searchField.getText() != null ? searchField.getText().toString() : "";
            if (q.length() >= 2) {
                page = 1;
                hasMore = true;
                loading = false;
                all.clear();
                if (adapter != null) adapter.submitList(new ArrayList<>(all));
                performSearch(q, page, false);
            } else {
                refresh(true);
            }
        } else {
            refresh(true);
        }
        if (chipAll != null && chipPhotos != null && chipVideos != null) {
            requestCountsAsync(chipAll, chipPhotos, chipVideos);
        }
    }

    private void confirmEmptyTrash() {
        if (trashCount <= 0) {
            android.widget.Toast.makeText(requireContext(), "Trash is already empty", android.widget.Toast.LENGTH_SHORT).show();
            return;
        }
        String msg = "This will permanently delete " + trashCount + " item" + (trashCount == 1 ? "" : "s") + " from Trash.";
        new android.app.AlertDialog.Builder(requireContext())
                .setTitle("Empty Trash?")
                .setMessage(msg)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Empty", (d, w) -> runEmptyTrash())
                .show();
    }

    private void runEmptyTrash() {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                JSONObject resp = svc.purgeAllTrash();
                int purged = resp.optInt("purged", 0);
                requireActivity().runOnUiThread(() -> {
                    android.widget.Toast.makeText(requireContext(), "Trash cleared (" + purged + ")", android.widget.Toast.LENGTH_SHORT).show();
                    View v = getView();
                    if (v != null) {
                        requestCountsAsync((Chip) v.findViewById(R.id.chip_all), (Chip) v.findViewById(R.id.chip_photos), (Chip) v.findViewById(R.id.chip_videos));
                    }
                    refresh(true);
                });
            } catch (Exception e) {
                requireActivity().runOnUiThread(() ->
                        android.widget.Toast.makeText(requireContext(), "Failed to empty trash", android.widget.Toast.LENGTH_LONG).show()
                );
            }
        }).start();
    }

    private void requestCountsAsync(Chip chipAll, Chip chipPhotos, Chip chipVideos) {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                java.util.List<Integer> albumIds = new java.util.ArrayList<>(selectedAlbumIds);
                JSONObject counts = svc.mediaCounts(favoriteOnly, null, lockedFilter, albumIds, filters, includeAlbumSubtree);
                int allCount = counts.optInt("all", 0);
                int photosCount = counts.optInt("photos", 0);
                int videosCount = counts.optInt("videos", 0);
                int trash = counts.optInt("trash", 0);
                requireActivity().runOnUiThread(() -> {
                    chipAll.setText("All " + allCount);
                    chipPhotos.setText("Photos " + photosCount);
                    chipVideos.setText("Videos " + videosCount);
                    if (chipTrash != null) chipTrash.setText("Trash " + trash);
                    trashCount = trash;
                    updateTrashUi();
                });
            } catch (Exception ignored) {}
        }).start();
    }

    private void refresh(boolean reset) {
        if (reset) {
            page = 1; hasMore = true; loading = false; empty.setVisibility(View.GONE);
            all.clear(); allPhotosJson.clear(); timelineCells.clear();
            if (timelineMode) timelineAdapter.submitList(new java.util.ArrayList<>(timelineCells)); else adapter.submitList(new ArrayList<>(all));
        }
        new Thread(() -> {
            try {
                loading = true;
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                String media = mediaFilter.equals("photos") ? "photos"
                        : (mediaFilter.equals("videos") ? "videos"
                        : (mediaFilter.equals("trash") ? "trash" : null));
                java.util.List<Integer> albumIds = new java.util.ArrayList<>(selectedAlbumIds);
                 org.json.JSONObject resp = svc.listPhotos(null, albumIds, media, lockedFilter, favoriteOnly, page, limit, filters, includeAlbumSubtree);
                 try { android.util.Log.i("OpenPhotos","[PHOTOS/UI] resp has_more="+resp.optBoolean("has_more")+" page="+page+" size="+ (resp.has("photos")?resp.getJSONArray("photos").length():0)); } catch (Exception ignored) {}
                JSONArray photos = resp.has("photos") ? resp.getJSONArray("photos") : new JSONArray();
                hasMore = resp.optBoolean("has_more", false);
                // Optional client-side sort when requested
                java.util.List<org.json.JSONObject> tmp = new java.util.ArrayList<>();
                for (int i=0;i<photos.length();i++) tmp.add(photos.getJSONObject(i));
                tmp.sort((a,b)->{
                    long ca = a.optLong("created_at", 0L); long cb = b.optLong("created_at", 0L);
                    int cmp = Long.compare(cb, ca); // newest first
                    return sortAscending ? -cmp : cmp;
                });
                if (timelineMode) {
                    allPhotosJson.addAll(tmp);
                    // Rebuild timeline cells from all loaded photos
                    java.util.List<TimelineAdapter.Cell> built = buildTimelineCells(allPhotosJson, !sortAscending);
                    timelineCells.clear(); timelineCells.addAll(built);
                    requireActivity().runOnUiThread(() -> {
                        timelineAdapter.submitList(new java.util.ArrayList<>(timelineCells));
                        swipe.setRefreshing(false);
                        empty.setVisibility(timelineCells.isEmpty() ? View.VISIBLE : View.GONE);
                    });
                } else {
                    ArrayList<MediaGridAdapter.Cell> list = new ArrayList<>();
                    for (org.json.JSONObject p : tmp) {
                        String assetId = p.optString("asset_id");
                        boolean isVideo = p.optBoolean("is_video", false);
                        boolean locked = p.optBoolean("locked", false);
                        int rating = p.optInt("rating", 0);
                        String imgUrl = svc.thumbnailUrl(assetId);
                        list.add(new MediaGridAdapter.Cell("server-"+assetId, p.optString("filename", assetId), locked, imgUrl, isVideo, assetId, rating));
                    }
                    all.addAll(list);
                    requireActivity().runOnUiThread(() -> {
                        adapter.submitList(new ArrayList<>(all));
                        swipe.setRefreshing(false);
                        empty.setVisibility(all.isEmpty() ? View.VISIBLE : View.GONE);
                    });
                }
            } catch (Exception e) {
                String msg = e.getMessage();
                boolean unauthorized = msg != null && msg.contains("HTTP 401");
                try { android.util.Log.w("OpenPhotos","[PHOTOS/UI] load error "+msg, e); } catch (Exception ignored) {}
                requireActivity().runOnUiThread(() -> {
                    swipe.setRefreshing(false);
                    if (unauthorized && !AuthManager.get(requireContext()).isAuthenticated()) {
                        try {
                            androidx.navigation.NavController nav = androidx.navigation.fragment.NavHostFragment.findNavController(PhotosHomeFragment.this);
                            if (nav.getCurrentDestination() == null || nav.getCurrentDestination().getId() != R.id.serverLoginFragment) {
                                nav.navigate(R.id.serverLoginFragment);
                                return;
                            }
                        } catch (Exception ignored) {}
                    }
                    empty.setText(msg!=null&&msg.contains("HTTP")? ("Server error: "+msg) : "Load failed — Pull to retry");
                    empty.setVisibility(View.VISIBLE);
                });
            } finally { loading = false; }
        }).start();
    }

    private void loadNext() {
        if (!hasMore || loading) return;
        page += 1;
        if (searchMode) {
            String q = searchField.getText()!=null? searchField.getText().toString():"";
            if (q.length() >= 2) performSearch(q, page, true);
        } else {
            refresh(false);
        }
    }

    private int readGridSpan(Context ctx) { SharedPreferences sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE); return sp.getInt(KEY_GRID_SPAN, 3); }
    private void saveGridSpan(Context ctx, int span) { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt(KEY_GRID_SPAN, span).apply(); }

    private View getImageForPosition(RecyclerView rv, int position) {
        RecyclerView.ViewHolder vh = rv.findViewHolderForAdapterPosition(position);
        if (vh == null) return null; return vh.itemView.findViewById(R.id.image);
    }

    /** Open the full-screen Filters panel. State is applied only on Done. */
    private void openFiltersDialog() {
        FiltersDialogFragment dlg = FiltersDialogFragment.newInstance(filters);
        dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
        dlg.show(getParentFragmentManager(), "filters");
    }

    private void showMoreMenu(View anchor) {
        android.widget.PopupMenu pm = new android.widget.PopupMenu(requireContext(), anchor);
        pm.getMenu().add(0, MENU_MORE_SLIDESHOW, 0, "Slideshow");
        if (isEnterpriseEdition) {
            pm.getMenu().add(0, MENU_MORE_SHARING, 1, "Sharing");
            pm.getMenu().add(0, MENU_MORE_USERS_GROUPS, 2, "Users & Groups");
        }
        pm.getMenu().add(0, MENU_MORE_MANAGE_FACES, 3, "Manage Faces");
        pm.getMenu().add(0, MENU_MORE_SIMILAR, 4, "Similar Media");
        pm.getMenu().add(0, MENU_MORE_SIGN_OUT, 5, "Sign out");
        pm.setOnMenuItemClickListener(this::handleMoreMenuClick);
        pm.show();
    }

    private boolean handleMoreMenuClick(MenuItem item) {
        int id = item.getItemId();
        if (id == MENU_MORE_SLIDESHOW) { launchSlideshow(); return true; }
        if (id == MENU_MORE_SHARING) {
            try {
                SharingDialogFragment dlg = SharingDialogFragment.newInstance();
                dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
                dlg.show(getParentFragmentManager(), "sharing_hub");
            } catch (Exception e) {
                android.widget.Toast.makeText(requireContext(), "Failed to open Sharing", android.widget.Toast.LENGTH_SHORT).show();
            }
            return true;
        }
        if (id == MENU_MORE_USERS_GROUPS) {
            try {
                UsersGroupsDialogFragment dlg = UsersGroupsDialogFragment.newInstance();
                dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
                dlg.show(getParentFragmentManager(), "users_groups_hub");
            } catch (Exception e) {
                android.widget.Toast.makeText(requireContext(), "Failed to open Users & Groups", android.widget.Toast.LENGTH_SHORT).show();
            }
            return true;
        }
        if (id == MENU_MORE_MANAGE_FACES) {
            openManageFacesDialog();
            return true;
        }
        if (id == MENU_MORE_SIMILAR) { openSimilarMediaDialog(); return true; }
        if (id == MENU_MORE_SIGN_OUT) { performSignOut(); return true; }
        return false;
    }

    private void performSignOut() {
        try {
            AuthManager.get(requireContext()).logoutAndForgetCredentials();
            setSelectionMode(false, true);
            android.widget.Toast.makeText(requireContext(), "Signed out", android.widget.Toast.LENGTH_SHORT).show();
            androidx.navigation.fragment.NavHostFragment.findNavController(this).navigate(R.id.serverLoginFragment);
        } catch (Exception ignored) {}
    }

    private void launchSlideshow() {
        if (all.isEmpty() && allPhotosJson.isEmpty()) {
            android.widget.Toast.makeText(requireContext(), "No photos to display", android.widget.Toast.LENGTH_SHORT).show();
            return;
        }
        ArrayList<String> assetIds = new ArrayList<>();
        if (timelineMode) {
            for (JSONObject p : allPhotosJson) {
                String assetId = p.optString("asset_id");
                boolean isVideo = p.optBoolean("is_video", false);
                if (assetId != null && !assetId.isEmpty() && !isVideo) assetIds.add(assetId);
            }
        } else {
            for (MediaGridAdapter.Cell cell : all) {
                if (cell.assetId != null && !cell.assetId.isEmpty() && !cell.isVideo) assetIds.add(cell.assetId);
            }
        }
        if (assetIds.isEmpty()) {
            android.widget.Toast.makeText(requireContext(), "No photos to display", android.widget.Toast.LENGTH_SHORT).show();
            return;
        }
        Intent slideshowIntent = new Intent(requireContext(), SlideshowActivity.class);
        slideshowIntent.putStringArrayListExtra("asset_ids", assetIds);
        slideshowIntent.putExtra("start_index", Integer.valueOf(0));
        startActivity(slideshowIntent);
    }

    private void openManageFacesDialog() {
        try {
            ManageFacesDialogFragment dlg = ManageFacesDialogFragment.newInstance();
            dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
            dlg.show(getParentFragmentManager(), "manage_faces_hub");
        } catch (Exception e) {
            android.widget.Toast.makeText(requireContext(), "Failed to open Manage Faces", android.widget.Toast.LENGTH_SHORT).show();
        }
    }

    private void openSimilarMediaDialog() {
        try {
            SimilarMediaDialogFragment dlg = SimilarMediaDialogFragment.newInstance();
            dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
            dlg.show(getParentFragmentManager(), "similar_media_hub");
        } catch (Exception e) {
            android.widget.Toast.makeText(requireContext(), "Failed to open Similar Media", android.widget.Toast.LENGTH_SHORT).show();
        }
    }

    private void showSelectionActionsMenu(View anchor) {
        if (selectedIds.isEmpty()) return;
        android.widget.PopupMenu pm = new android.widget.PopupMenu(requireContext(), anchor);
        pm.getMenu().add(0, MENU_ACTION_ADD_TO_ALBUM, 0, "Add to Album");
        pm.getMenu().add(0, MENU_ACTION_SHARE, 1, "Share");
        pm.getMenu().add(0, MENU_ACTION_LOCK, 2, "Lock");
        pm.getMenu().add(0, MENU_ACTION_FAVORITE, 3, "Add to Favorites");
        pm.getMenu().add(0, MENU_ACTION_DELETE, 4, "Delete");
        pm.getMenu().add(0, MENU_ACTION_CLEAR_RATING, 5, "Clear Rating");
        pm.setOnMenuItemClickListener(this::handleSelectionActionClick);
        pm.show();
    }

    private boolean handleSelectionActionClick(MenuItem item) {
        int id = item.getItemId();
        if (id == MENU_ACTION_ADD_TO_ALBUM) {
            pendingAlbumPickMode = ALBUM_PICK_BULK_ADD;
            AlbumTreeDialogFragment dlg = AlbumTreeDialogFragment.newInstance(false);
            dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
            dlg.show(getParentFragmentManager(), "album_tree");
            return true;
        }
        if (id == MENU_ACTION_SHARE) { runBulkShare(); return true; }
        if (id == MENU_ACTION_LOCK) { runBulkLock(); return true; }
        if (id == MENU_ACTION_FAVORITE) { runBulkFavorite(); return true; }
        if (id == MENU_ACTION_DELETE) { runBulkDelete(); return true; }
        if (id == MENU_ACTION_CLEAR_RATING) { runBulkClearRating(); return true; }
        return false;
    }

    private void runBulkAddToAlbum(int albumId) {
        List<String> assetIds = selectedAssetIds();
        if (assetIds.isEmpty()) return;
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                List<Integer> photoIds = resolvePhotoIds(svc, assetIds, true);
                if (photoIds.isEmpty()) throw new IllegalStateException("No selectable photos");
                svc.addPhotosToAlbum(albumId, photoIds);
                requireActivity().runOnUiThread(() -> finishMutationSuccess("Added to album (" + photoIds.size() + ")"));
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Add to album failed", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private void runBulkFavorite() {
        List<String> assetIds = selectedAssetIds();
        if (assetIds.isEmpty()) return;
        new Thread(() -> {
            int ok = 0;
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                for (String id : assetIds) {
                    try { svc.setFavorite(id, true); ok++; } catch (Exception ignored) {}
                }
                final int done = ok;
                requireActivity().runOnUiThread(() -> finishMutationSuccess("Favorited " + done + " item" + (done == 1 ? "" : "s")));
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Favorite failed", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private void runBulkClearRating() {
        List<String> assetIds = selectedAssetIds();
        if (assetIds.isEmpty()) return;
        new Thread(() -> {
            int ok = 0;
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                for (String id : assetIds) {
                    try { svc.updateRating(id, null); ok++; } catch (Exception ignored) {}
                }
                final int done = ok;
                requireActivity().runOnUiThread(() -> finishMutationSuccess("Cleared rating for " + done + " item" + (done == 1 ? "" : "s")));
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Clear rating failed", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private void runBulkDelete() {
        List<String> assetIds = selectedAssetIds();
        if (assetIds.isEmpty()) return;
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                JSONObject res = svc.deletePhotos(assetIds);
                int deleted = res.optInt("deleted", 0);
                requireActivity().runOnUiThread(() -> finishMutationSuccess("Deleted " + deleted + " item" + (deleted == 1 ? "" : "s")));
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Delete failed", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private void runBulkLock() {
        List<String> assetIds = selectedAssetIds();
        if (assetIds.isEmpty()) return;
        ca.openphotos.android.e2ee.E2EEManager e2 = new ca.openphotos.android.e2ee.E2EEManager(requireContext().getApplicationContext());
        Runnable lockTask = () -> new Thread(() -> {
            int ok = 0;
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                for (String id : assetIds) {
                    try { svc.lockPhoto(id); ok++; } catch (Exception ignored) {}
                }
                final int done = ok;
                requireActivity().runOnUiThread(() -> finishMutationSuccess("Locked " + done + " item" + (done == 1 ? "" : "s")));
            } catch (Exception e) {
                requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Lock failed", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();

        if (e2.getUmk() == null) {
            new EnterPinDialog().setListener(pin -> new Thread(() -> {
                boolean ok = e2.unlockWithPin(pin);
                requireActivity().runOnUiThread(() -> {
                    if (!ok) {
                        android.widget.Toast.makeText(requireContext(), "Unlock failed", android.widget.Toast.LENGTH_LONG).show();
                    } else {
                        lockTask.run();
                    }
                });
            }).start()).show(getParentFragmentManager(), "pin");
            return;
        }
        lockTask.run();
    }

    private void runBulkShare() {
        if (!isEnterpriseEdition) {
            android.widget.Toast.makeText(requireContext(), "Sharing requires Enterprise server", android.widget.Toast.LENGTH_LONG).show();
            return;
        }
        List<String> assetIds = selectedAssetIds();
        if (assetIds.isEmpty()) return;
        String firstSelectedAssetId = firstSelectedAssetIdInCurrentOrder();
        if (firstSelectedAssetId == null && !assetIds.isEmpty()) firstSelectedAssetId = assetIds.get(0);
        if (assetIds.size() == 1) {
            String aid = firstSelectedAssetId != null ? firstSelectedAssetId : assetIds.get(0);
            setSelectionMode(false, true);
            openCreateShareDialog("asset", aid, "Selected photo", 1, null, aid);
            return;
        }

        android.widget.Toast.makeText(requireContext(), "Preparing selection for sharing…", android.widget.Toast.LENGTH_SHORT).show();
        String firstAssetForShare = firstSelectedAssetId;
        new Thread(() -> {
            Integer tempAlbumId = null;
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                String albumName = "Shared Selection (" + assetIds.size() + " photos)";
                JSONObject album = svc.createAlbum(albumName, "Share snapshot", null);
                tempAlbumId = album.optInt("id", 0);
                if (tempAlbumId == null || tempAlbumId <= 0) throw new IllegalStateException("Album create failed");
                List<Integer> photoIds = resolvePhotoIds(svc, assetIds, true);
                if (photoIds.isEmpty()) throw new IllegalStateException("No photos to share");
                svc.addPhotosToAlbum(tempAlbumId, photoIds);
                Integer finalTempAlbumId = tempAlbumId;
                String finalFirstAssetForShare = firstAssetForShare;
                requireActivity().runOnUiThread(() -> {
                    setSelectionMode(false, true);
                    openCreateShareDialog("album", String.valueOf(finalTempAlbumId), albumName, assetIds.size(), finalTempAlbumId, finalFirstAssetForShare);
                });
            } catch (Exception e) {
                Integer cleanupId = tempAlbumId;
                if (cleanupId != null && cleanupId > 0) {
                    try { new ServerPhotosService(requireContext().getApplicationContext()).deleteAlbum(cleanupId); } catch (Exception ignored) {}
                }
                requireActivity().runOnUiThread(() -> android.widget.Toast.makeText(requireContext(), "Share prepare failed", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private void openCreateShareDialog(String objectKind, String objectId, String objectName, int selectionCount, @Nullable Integer tempAlbumId, @Nullable String firstSelectedAssetId) {
        CreateShareDialogFragment dlg = CreateShareDialogFragment.newInstance(objectKind, objectId, objectName, selectionCount, tempAlbumId, firstSelectedAssetId);
        dlg.setStyle(DialogFragment.STYLE_NORMAL, R.style.AppTheme_FullscreenDialog);
        dlg.show(getParentFragmentManager(), "create_share");
    }

    private List<Integer> resolvePhotoIds(ServerPhotosService svc, List<String> assetIds, boolean includeLocked) throws Exception {
        JSONArray arr = svc.getPhotosByAssetIds(assetIds, includeLocked);
        List<Integer> ids = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject p = arr.getJSONObject(i);
            int id = p.optInt("id", 0);
            if (id > 0) ids.add(id);
        }
        return ids;
    }

    private void finishMutationSuccess(String message) {
        android.widget.Toast.makeText(requireContext(), message, android.widget.Toast.LENGTH_SHORT).show();
        setSelectionMode(false, true);
        View v = getView();
        if (v != null) {
            requestCountsAsync((Chip) v.findViewById(R.id.chip_all), (Chip) v.findViewById(R.id.chip_photos), (Chip) v.findViewById(R.id.chip_videos));
        }
        refresh(true);
    }

    private void refreshEnterpriseCapabilitiesAsync() {
        new Thread(() -> {
            boolean ee = ca.openphotos.android.core.CapabilitiesService.get(requireContext().getApplicationContext()).ee;
            if (!isAdded()) return;
            requireActivity().runOnUiThread(() -> isEnterpriseEdition = ee);
        }).start();
    }

    private void updateSelectButtonText() {
        View v = getView(); if (v == null) return; MaterialButton b = v.findViewById(R.id.btn_select); if (b != null) b.setText(selectionMode?"Cancel":"Select");
    }

    /** Populate horizontally scrollable album chips. */
    private void populateAlbumChips(ChipGroup group) {
        group.removeAllViews();
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                JSONArray arr = svc.listAlbums();
                java.util.ArrayList<org.json.JSONObject> cache = new java.util.ArrayList<>();
                for (int i=0;i<arr.length();i++) { try { cache.add(arr.getJSONObject(i)); } catch (Exception ignored) {} }
                requireActivity().runOnUiThread(() -> {
                    for (org.json.JSONObject a : cache) {
                        try {
                            final int id = a.optInt("id");
                            String name = a.optString("name"); int cnt = a.optInt("photo_count", 0);
                            Chip c = new Chip(requireContext());
                            c.setText(cnt>0 ? name + " ("+cnt+")" : name);
                            c.setCheckable(true);
                            c.setChecked(selectedAlbumIds.contains(id));
                            c.setOnClickListener(v -> {
                                if (selectedAlbumIds.contains(id)) selectedAlbumIds.remove(id); else selectedAlbumIds.add(id);
                                updateActiveFilterRow();
                                requestCountsAsync((Chip) getView().findViewById(R.id.chip_all), (Chip) getView().findViewById(R.id.chip_photos), (Chip) getView().findViewById(R.id.chip_videos));
                                refresh(true);
                            });
                            group.addView(c);
                        } catch (Exception ignored) {}
                    }
                    // Cache albums for chip row resolution
                    albumsCache = cache;
                });
            } catch (Exception ignored) {}
        }).start();
    }

    // ==== Timeline helpers ====
    private ca.openphotos.android.ui.util.RecyclerItemClickListener gridTouchListener;

    private void configureRecyclerForMode() {
        // On mode switches, keep headers visible and reset scroll tracking to avoid
        // an immediate hide due to stale deltas from the previous layout.
        applyHeaderVisibility(true, false);
        trackingScroll = false; lastScrollOffset = 0; dirAccum = 0f; lastDir = 0;
        // Clear any previous adapter to force layout recalculation cleanly
        if (grid != null) grid.setAdapter(null);
        if (grid == null) return;
        if (!timelineMode) {
            int span = readGridSpan(requireContext());
            layoutManager = new GridLayoutManager(requireContext(), span);
            grid.setLayoutManager(layoutManager);
            if (adapter == null) adapter = new MediaGridAdapter();
            adapter.setShowLabels(false);
            grid.setAdapter(adapter);
            // Legacy item click behavior for grid
            if (gridTouchListener != null) { grid.removeOnItemTouchListener(gridTouchListener); gridTouchListener = null; }
            gridTouchListener = new ca.openphotos.android.ui.util.RecyclerItemClickListener(requireContext(), grid, new ca.openphotos.android.ui.util.RecyclerItemClickListener.OnItemClickListener() {
                @Override public void onItemClick(View view, int position) {
                    if (selectionMode) { toggleSelection(position); return; }
                    java.util.List<MediaGridAdapter.Cell> list = adapter.getCurrentList();
                    if (position >= 0 && position < list.size()) {
                        MediaGridAdapter.Cell tapped = list.get(position);
                        androidx.navigation.NavController nav = androidx.navigation.fragment.NavHostFragment.findNavController(PhotosHomeFragment.this);
                        android.os.Bundle args = new android.os.Bundle();
                        java.util.ArrayList<String> uris = new java.util.ArrayList<>();
                        java.util.ArrayList<String> assetIds = new java.util.ArrayList<>();
                        for (MediaGridAdapter.Cell it : all) { uris.add(it.uri); assetIds.add(it.assetId); }
                        args.putStringArrayList("uris", uris);
                        args.putStringArrayList("assetIds", assetIds);
                        args.putInt("index", position);
                        args.putBoolean("isServer", true);
                        // Continuous paging parameters (pass current filters/state)
                        args.putString("paging_media", mediaFilter);
                        if (lockedFilter != null) args.putBoolean("paging_locked", lockedFilter);
                        args.putBoolean("paging_favorite_only", favoriteOnly);
                        int[] albumIds = selectedAlbumIds.stream().mapToInt(Integer::intValue).toArray();
                        args.putIntArray("paging_album_ids", albumIds);
                        args.putBoolean("paging_include_subtree", includeAlbumSubtree);
                        args.putInt("paging_next_page", page + 1);
                        args.putInt("paging_limit", limit);
                        android.view.View image = getImageForPosition(grid, position);
                        if (image != null) {
                            androidx.navigation.fragment.FragmentNavigator.Extras extras = new androidx.navigation.fragment.FragmentNavigator.Extras.Builder().addSharedElement(image, "hero_image").build();
                            nav.navigate(ca.openphotos.android.R.id.viewerFragment, args, null, extras);
                        } else { nav.navigate(ca.openphotos.android.R.id.viewerFragment, args); }
                    }
                }
                @Override public void onLongItemClick(View view, int position) {
                    if (!selectionMode) {
                        setSelectionMode(true, false);
                        toggleSelection(position);
                        // Keep header visible while in selection mode (match Timeline behavior)
                        applyHeaderVisibility(true, true);
                    }
                }
            });
            grid.addOnItemTouchListener(gridTouchListener);

            // Hide years UI in grid mode
            if (btnYears != null) btnYears.setVisibility(View.GONE);
            if (yearRail != null) yearRail.setVisibility(View.GONE);
        } else {
            // Timeline
            int span = computeSpanForWidth(grid.getWidth());
            if (span <= 0) span = 4;
            tlLayoutManager = new GridLayoutManager(requireContext(), span);
            tlLayoutManager.setSpanSizeLookup(new GridLayoutManager.SpanSizeLookup() {
                @Override public int getSpanSize(int position) {
                    if (position < 0 || position >= timelineCells.size()) return 1;
                    int t = timelineCells.get(position).type;
                    return (t == TimelineAdapter.TYPE_PHOTO) ? 1 : tlLayoutManager.getSpanCount();
                }
            });
            grid.setLayoutManager(tlLayoutManager);
            timelineAdapter = new TimelineAdapter();
            timelineAdapter.setSelectionMode(selectionMode, selectedIds);
            timelineAdapter.setRatingOverlayEnabled(true);
            timelineAdapter.setOnPhotoClickListener(c -> {
                if (selectionMode) {
                    // Toggle selection for clicked item
                    String id = c.assetId;
                    if (id == null || id.isEmpty()) return;
                    if (selectedIds.contains(id)) selectedIds.remove(id); else selectedIds.add(id);
                    timelineAdapter.notifyDataSetChanged();
                    updateSelectionBarUi();
                    return;
                }
                // Open viewer with all loaded assets
                androidx.navigation.NavController nav = androidx.navigation.fragment.NavHostFragment.findNavController(PhotosHomeFragment.this);
                android.os.Bundle args = new android.os.Bundle();
                java.util.ArrayList<String> uris = new java.util.ArrayList<>();
                java.util.ArrayList<String> assetIds = new java.util.ArrayList<>();
                for (org.json.JSONObject p : allPhotosJson) { String id = p.optString("asset_id"); uris.add(new ca.openphotos.android.server.ServerPhotosService(requireContext()).imageUrl(id)); assetIds.add(id); }
                args.putStringArrayList("uris", uris);
                args.putStringArrayList("assetIds", assetIds);
                // Compute index of clicked assetId in allPhotosJson
                int idx = 0; for (int i=0;i<allPhotosJson.size();i++) { if (allPhotosJson.get(i).optString("asset_id").equals(c.assetId)) { idx = i; break; } }
                args.putInt("index", idx);
                args.putBoolean("isServer", true);
                // Continuous paging parameters
                args.putString("paging_media", mediaFilter);
                if (lockedFilter != null) args.putBoolean("paging_locked", lockedFilter);
                args.putBoolean("paging_favorite_only", favoriteOnly);
                int[] albumIds = selectedAlbumIds.stream().mapToInt(Integer::intValue).toArray();
                args.putIntArray("paging_album_ids", albumIds);
                args.putBoolean("paging_include_subtree", includeAlbumSubtree);
                args.putInt("paging_next_page", page + 1);
                args.putInt("paging_limit", limit);
                nav.navigate(ca.openphotos.android.R.id.viewerFragment, args);
            });
            grid.setAdapter(timelineAdapter);

            // Adaptive span count on layout changes
            grid.getViewTreeObserver().addOnGlobalLayoutListener(() -> {
                if (tlLayoutManager == null) return;
                int newSpan = computeSpanForWidth(grid.getWidth()); if (newSpan <= 0) newSpan = 4;
                if (tlLayoutManager.getSpanCount() != newSpan) tlLayoutManager.setSpanCount(newSpan);
            });

            // Years UI
            if (isTablet()) {
                renderYearRail();
                yearRail.setVisibility(years.isEmpty()? View.GONE : View.VISIBLE);
                btnYears.setVisibility(View.GONE);
            } else {
                // Always show the button in Timeline mode (even while buckets load)
                btnYears.setVisibility(View.VISIBLE);
                if (yearRail != null) yearRail.setVisibility(View.GONE);
            }
        }
        // Ensure list top inset reflects current header state after mode switch
        setRecyclerTopPadding(headersShown ? headerHeight : 0);
        updateSelectionBarUi();
    }

    private int computeSpanForWidth(int widthPx) {
        if (widthPx <= 0) return 4;
        float min = getResources().getDisplayMetrics().density * 70f; // 70dp min tile size
        int span = Math.max(1, (int) Math.floor(widthPx / (min + (getResources().getDisplayMetrics().density*2)))) ; // include 2dp gap approx
        return Math.min(Math.max(span, 2), 8);
    }

    private java.util.List<TimelineAdapter.Cell> buildTimelineCells(java.util.List<org.json.JSONObject> photos, boolean newestFirst) {
        java.util.LinkedHashMap<Integer, java.util.LinkedHashMap<String, java.util.LinkedHashMap<String, java.util.List<org.json.JSONObject>>>> map = new java.util.LinkedHashMap<>();
        java.util.Calendar cal = java.util.Calendar.getInstance();
        // Build nested grouping Year -> MonthKey(yyyy-MM) -> DayKey(yyyy-MM-dd)
        for (org.json.JSONObject p : photos) {
            long ts = p.optLong("created_at", 0L);
            java.util.Date d = new java.util.Date(ts * 1000L);
            cal.setTime(d);
            int y = cal.get(java.util.Calendar.YEAR);
            int m = cal.get(java.util.Calendar.MONTH)+1;
            int day = cal.get(java.util.Calendar.DAY_OF_MONTH);
            String monthKey = String.format(java.util.Locale.US, "%04d-%02d", y, m);
            String dayKey = String.format(java.util.Locale.US, "%04d-%02d-%02d", y, m, day);
            map.computeIfAbsent(y, k -> new java.util.LinkedHashMap<>())
               .computeIfAbsent(monthKey, k -> new java.util.LinkedHashMap<>())
               .computeIfAbsent(dayKey, k -> new java.util.ArrayList<>())
               .add(p);
        }
        java.util.List<Integer> yearsOrdered = new java.util.ArrayList<>(map.keySet());
        yearsOrdered.sort((a,b)-> newestFirst? Integer.compare(b,a): Integer.compare(a,b));
        java.util.List<TimelineAdapter.Cell> out = new java.util.ArrayList<>();
        for (int y : yearsOrdered) {
            out.add(TimelineAdapter.Cell.yearAnchor(y));
            java.util.List<String> months = new java.util.ArrayList<>(map.get(y).keySet());
            months.sort((a,b)-> newestFirst? a.compareTo(b) < 0 ? 1 : -1 : a.compareTo(b));
            for (String mk : months) {
                // month header label
                long ts = 0L; try {
                    java.text.SimpleDateFormat p = new java.text.SimpleDateFormat("yyyy-MM", java.util.Locale.US);
                    ts = p.parse(mk).getTime()/1000L;
                } catch (Exception ignored) {}
                out.add(TimelineAdapter.Cell.monthHeader(TimelineAdapter.monthHeaderFor(ts), ts));
                java.util.List<String> days = new java.util.ArrayList<>(map.get(y).get(mk).keySet());
                days.sort((a,b)-> newestFirst? a.compareTo(b) < 0 ? 1 : -1 : a.compareTo(b));
                for (String dk : days) {
                    long tsd = 0L; try {
                        java.text.SimpleDateFormat p2 = new java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US);
                        tsd = p2.parse(dk).getTime()/1000L;
                    } catch (Exception ignored) {}
                    out.add(TimelineAdapter.Cell.dayHeader(TimelineAdapter.dayHeaderFor(tsd), tsd));
                    java.util.List<org.json.JSONObject> items = map.get(y).get(mk).get(dk);
                    items.sort((a,b)-> newestFirst? Long.compare(b.optLong("created_at",0L), a.optLong("created_at",0L)) : Long.compare(a.optLong("created_at",0L), b.optLong("created_at",0L)));
                    for (org.json.JSONObject p : items) {
                        String assetId = p.optString("asset_id"); boolean isVideo = p.optBoolean("is_video", false); boolean locked = p.optBoolean("locked", false); int rating = p.optInt("rating", 0);
                        String imgUrl = new ca.openphotos.android.server.ServerPhotosService(requireContext().getApplicationContext()).thumbnailUrl(assetId);
                        out.add(TimelineAdapter.Cell.photo(assetId, isVideo, locked, rating, imgUrl, p.optLong("created_at", 0L)));
                    }
                }
            }
        }
        return out;
    }

    private void handleScrollForHeader(int scrollOffset) {
        if (!trackingScroll) { trackingScroll = true; lastScrollOffset = scrollOffset; dirAccum = 0f; lastDir = 0; return; }
        int delta = scrollOffset - lastScrollOffset; lastScrollOffset = scrollOffset;
        if (scrollOffset < 10) { if (!headersShown) applyHeaderVisibility(true, true); dirAccum = 0f; lastDir = 0; return; }
        if (Math.abs(delta) < 1) return; // jitter guard
        int dir = delta > 0 ? 1 : -1; if (dir != lastDir) { dirAccum = 0f; lastDir = dir; }
        dirAccum += Math.abs(delta);
        final float hideTh = 18f; final float showTh = 12f;
        if (dir > 0) { if (headersShown && dirAccum >= hideTh) { applyHeaderVisibility(false, true); dirAccum = 0f; } }
        else { if (!headersShown && dirAccum >= showTh) { applyHeaderVisibility(true, true); dirAccum = 0f; } }
    }

    private void applyHeaderVisibility(boolean show, boolean animated) {
        if (headerContainer == null) return; headersShown = show;
        int targetPad = show ? headerHeight : 0;
        float targetTrans = show ? 0f : -headerHeight;
        if (!animated) {
            headerContainer.setTranslationY(targetTrans);
            setRecyclerTopPadding(targetPad);
            return;
        }
        // Animate both translationY and paddingTop
        headerContainer.animate().translationY(targetTrans).setDuration(180).start();
        final int startPad = grid.getPaddingTop();
        android.animation.ValueAnimator va = android.animation.ValueAnimator.ofInt(startPad, targetPad);
        va.setDuration(180);
        va.addUpdateListener(a -> setRecyclerTopPadding((Integer) a.getAnimatedValue()));
        va.start();
    }

    private void setRecyclerTopPadding(int pad) { grid.setPadding(grid.getPaddingLeft(), pad, grid.getPaddingRight(), grid.getPaddingBottom()); }

    private void requestYearBucketsAsync() {
        new Thread(() -> {
            try {
                ServerPhotosService svc = new ServerPhotosService(requireContext().getApplicationContext());
                JSONArray arr = svc.getYearBuckets();
                java.util.List<Integer> out = new java.util.ArrayList<>();
                for (int i=0;i<arr.length();i++) { org.json.JSONObject o = arr.getJSONObject(i); out.add(o.optInt("year")); }
                requireActivity().runOnUiThread(() -> {
                    years = out;
                    if (sortAscending) java.util.Collections.reverse(years); // mirror current sort order for UI
                    if (timelineMode) {
                        if (isTablet()) { renderYearRail(); if (yearRail != null) yearRail.setVisibility(years.isEmpty()? View.GONE : View.VISIBLE); }
                        else { if (btnYears != null) btnYears.setVisibility(years.isEmpty()? View.GONE : View.VISIBLE); }
                    }
                });
            } catch (Exception ignored) {}
        }).start();
    }

    private void renderYearRail() {
        if (yearRail == null) return; ((ViewGroup) yearRail).removeAllViews();
        android.content.Context ctx = requireContext();
        for (int y : years) {
            com.google.android.material.button.MaterialButton b = new com.google.android.material.button.MaterialButton(ctx, null, com.google.android.material.R.attr.materialButtonOutlinedStyle);
            b.setText(String.valueOf(y)); b.setTextSize(12f);
            ViewGroup.MarginLayoutParams lp = new ViewGroup.MarginLayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.topMargin = (int)(getResources().getDisplayMetrics().density * 6);
            b.setLayoutParams(lp);
            b.setOnClickListener(v -> scrollToYear(y));
            ((ViewGroup) yearRail).addView(b);
        }
    }

    private void scrollToYear(int y) {
        // Find first position of that year anchor
        int pos = -1;
        for (int i=0;i<timelineCells.size();i++) { TimelineAdapter.Cell c = timelineCells.get(i); if (c.type == TimelineAdapter.TYPE_YEAR_ANCHOR && c.year != null && c.year == y) { pos = i; break; } }
        if (pos >= 0) { tlLayoutManager.scrollToPositionWithOffset(pos, headersShown ? headerHeight : 0); }
    }

    private boolean isTablet() { return getResources().getConfiguration().smallestScreenWidthDp >= 600; }

    private String readViewMode(Context ctx) { return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_VIEW_MODE, "grid"); }
    private void saveViewMode(Context ctx, String mode) { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_VIEW_MODE, mode).apply(); }

    // Cache of albums to resolve names/covers
    private java.util.List<org.json.JSONObject> albumsCache = new java.util.ArrayList<>();
    private org.json.JSONObject findAlbum(int id) {
        for (org.json.JSONObject a : albumsCache) { if (a.optInt("id") == id) return a; }
        return null;
    }

    /** Build or refresh the Active Filter Row chips. */
    private void updateActiveFilterRow() {
        View root = getView(); if (root == null) return;
        syncQuickFilterButtons(root);
        com.google.android.material.chip.ChipGroup chips = root.findViewById(R.id.active_filter_chips);
        View container = root.findViewById(R.id.row_active_filters);
        if (chips == null || container == null) return;
        chips.removeAllViews();

        int chipsCount = 0;

        // Album chips (multi)
        for (Integer id : selectedAlbumIds) {
            org.json.JSONObject a = findAlbum(id);
            String label = a != null ? a.optString("name", "Album " + id) : ("Album " + id);
            Chip c = new Chip(requireContext());
            c.setText(label);
            c.setCloseIconVisible(true);
            c.setOnCloseIconClickListener(v -> { selectedAlbumIds.remove(id); updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(c); chipsCount++;
        }

        // Favorites
        if (favoriteOnly) {
            Chip fav = new Chip(requireContext()); fav.setText("Favorites"); fav.setCloseIconVisible(true);
            fav.setOnCloseIconClickListener(v -> { favoriteOnly = false; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(fav); chipsCount++;
        }
        // Locked-only
        if (lockedFilter != null && lockedFilter) {
            Chip lock = new Chip(requireContext()); lock.setText("Locked"); lock.setCloseIconVisible(true);
            lock.setOnCloseIconClickListener(v -> { lockedFilter = null; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(lock); chipsCount++;
        }

        // Rating
        if (filters.ratingMin != null && filters.ratingMin > 0) {
            Chip r = new Chip(requireContext()); r.setText("★≥" + filters.ratingMin); r.setCloseIconVisible(true);
            r.setOnCloseIconClickListener(v -> { filters.ratingMin = null; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(r); chipsCount++;
        }

        // Type
        if (filters.screenshots) {
            Chip t = new Chip(requireContext()); t.setText("Screenshots"); t.setCloseIconVisible(true);
            t.setOnCloseIconClickListener(v -> { filters.screenshots = false; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(t); chipsCount++;
        }
        if (filters.livePhotos) {
            Chip t = new Chip(requireContext()); t.setText("Live Photos"); t.setCloseIconVisible(true);
            t.setOnCloseIconClickListener(v -> { filters.livePhotos = false; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(t); chipsCount++;
        }

        // Dates
        if (filters.dateFrom != null || filters.dateTo != null) {
            java.text.SimpleDateFormat fmt = new java.text.SimpleDateFormat("MMM d, yyyy", java.util.Locale.US);
            String s = filters.dateFrom != null ? fmt.format(new java.util.Date(filters.dateFrom*1000L)) : "";
            String e = filters.dateTo != null ? fmt.format(new java.util.Date(filters.dateTo*1000L)) : "";
            Chip d = new Chip(requireContext()); d.setText("" + (s.isEmpty()?"":s) + (e.isEmpty()?"":" → "+e)); d.setCloseIconVisible(true);
            d.setOnCloseIconClickListener(v -> { filters.dateFrom = null; filters.dateTo = null; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(d); chipsCount++;
        }

        // Location
        if (filters.country != null && !filters.country.isEmpty()) {
            Chip c = new Chip(requireContext()); c.setText("Country " + filters.country); c.setCloseIconVisible(true);
            c.setOnCloseIconClickListener(v -> { filters.country = null; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(c); chipsCount++;
        }
        if (filters.region != null && !filters.region.isEmpty()) {
            Chip c = new Chip(requireContext()); c.setText("Region " + filters.region); c.setCloseIconVisible(true);
            c.setOnCloseIconClickListener(v -> { filters.region = null; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(c); chipsCount++;
        }
        if (filters.city != null && !filters.city.isEmpty()) {
            Chip c = new Chip(requireContext()); c.setText("City " + filters.city); c.setCloseIconVisible(true);
            c.setOnCloseIconClickListener(v -> { filters.city = null; updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
            chips.addView(c); chipsCount++;
        }

        // Faces: up to 3 with +N indicator
        if (!filters.faces.isEmpty()) {
            int shown = 0; int total = filters.faces.size();
            for (String pid : filters.faces) {
                if (shown >= 3) break; shown++;
                Chip face = new Chip(requireContext());
                face.setText("");
                face.setCloseIconVisible(true);
                face.setOnCloseIconClickListener(v -> { filters.faces.remove(pid); updateActiveFilterRow(); requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos)); refresh(true); });
                // Load circular face icon into chip
                try {
                    String u = new ca.openphotos.android.server.ServerPhotosService(requireContext().getApplicationContext()).faceThumbnailUrl(pid);
                    String t = ca.openphotos.android.core.AuthManager.get(requireContext()).getToken();
                    Object model = (t != null && !t.isEmpty()) ? new com.bumptech.glide.load.model.GlideUrl(u, new com.bumptech.glide.load.model.LazyHeaders.Builder().addHeader("Authorization", "Bearer " + t).build()) : u;
                    com.bumptech.glide.Glide.with(this)
                            .asDrawable()
                            .load(model)
                            .circleCrop()
                            .into(new com.bumptech.glide.request.target.CustomTarget<android.graphics.drawable.Drawable>() {
                                @Override public void onResourceReady(@NonNull android.graphics.drawable.Drawable resource, @Nullable com.bumptech.glide.request.transition.Transition<? super android.graphics.drawable.Drawable> transition) { face.setChipIcon(resource); face.setChipIconVisible(true); }
                                @Override public void onLoadCleared(@Nullable android.graphics.drawable.Drawable placeholder) { }
                            });
                } catch (Exception ignored) {}
                chips.addView(face); chipsCount++;
            }
            if (total > shown) {
                Chip extra = new Chip(requireContext()); extra.setText("+" + (total - shown)); extra.setCloseIconVisible(false);
                chips.addView(extra); chipsCount++;
            }
        }

        container.setVisibility(chipsCount > 0 ? View.VISIBLE : View.GONE);

        // Wire the clear-all button
        View clear = root.findViewById(R.id.btn_clear_all_filters);
        if (clear != null) {
            clear.setOnClickListener(v -> {
                selectedAlbumIds.clear(); favoriteOnly = false; lockedFilter = null; filters = new ca.openphotos.android.server.FilterParams();
                updateActiveFilterRow();
                requestCountsAsync((Chip) root.findViewById(R.id.chip_all), (Chip) root.findViewById(R.id.chip_photos), (Chip) root.findViewById(R.id.chip_videos));
                refresh(true);
            });
        }
    }

    private void syncQuickFilterButtons(@Nullable View root) {
        View resolvedRoot = root != null ? root : getView();
        if (resolvedRoot == null) return;
        MaterialButton btnFav = resolvedRoot.findViewById(R.id.btn_favorites);
        MaterialButton btnLocked = resolvedRoot.findViewById(R.id.btn_locked);
        if (btnFav != null) btnFav.setAlpha(favoriteOnly ? 1f : 0.45f);
        if (btnLocked != null) btnLocked.setAlpha(Boolean.TRUE.equals(lockedFilter) ? 1f : 0.45f);
    }
}
