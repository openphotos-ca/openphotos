package ca.openphotos.android.ui;

import android.Manifest;
import android.app.Activity;
import android.app.DatePickerDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.MediaStore;
import android.provider.Settings;
import android.view.LayoutInflater;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.IntentSenderRequest;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.widget.PopupMenu;
import androidx.fragment.app.Fragment;
import androidx.lifecycle.ViewModelProvider;
import androidx.navigation.fragment.NavHostFragment;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.data.db.entities.PhotoEntity;
import ca.openphotos.android.media.AlbumPathUtil;
import ca.openphotos.android.ui.local.LocalAlbumCopyHelper;
import ca.openphotos.android.ui.local.LocalMediaItem;
import ca.openphotos.android.ui.local.LocalPhotosViewModel;
import ca.openphotos.android.ui.util.RecyclerItemClickListener;
import ca.openphotos.android.upload.TusUploadManager;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.button.MaterialButtonToggleGroup;
import com.google.android.material.chip.Chip;
import com.google.android.material.chip.ChipGroup;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * iOS-parity local Photos tab (bottom tab 2).
 */
public class LocalPhotosFragment extends Fragment {
    private LocalPhotosViewModel vm;

    private androidx.swiperefreshlayout.widget.SwipeRefreshLayout swipe;
    private RecyclerView grid;
    private TextView empty;
    private View permissionContainer;
    private View selectionBar;
    private View header;

    private MaterialButton btnSort;
    private MaterialButton btnCloud;
    private MaterialButton btnSelect;
    private MaterialButton btnAlbums;
    private MaterialButton btnFavorites;
    private MaterialButton btnFilter;
    private MaterialButton btnActions;
    private MaterialButton btnClearFilters;

    private MaterialButtonToggleGroup toggleView;
    private ChipGroup mediaTabs;
    private Chip chipAll;
    private Chip chipPhotos;
    private Chip chipVideos;
    private ChipGroup selectedFolderChips;
    private ChipGroup activeFilterChips;
    private View activeFiltersRow;
    private TextView cloudProgressText;
    private View cloudSmallProgress;

    private MediaGridAdapter gridAdapter;
    private TimelineAdapter timelineAdapter;
    private GridLayoutManager gridLayoutManager;
    private GridLayoutManager timelineLayoutManager;

    private final ArrayList<LocalMediaItem> visibleItems = new ArrayList<>();
    private final ArrayList<MediaGridAdapter.Cell> currentGridCells = new ArrayList<>();
    private final ArrayList<String> availableFolders = new ArrayList<>();

    private boolean timelineMode = false;
    private long lastAuthEvent = 0L;
    private String lastMessage = "";
    private int headerHeightPx = 0;

    private ActivityResultLauncher<String[]> permissionLauncher;
    private ActivityResultLauncher<IntentSenderRequest> deleteLauncher;
    private int pendingDeleteCount = 0;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container, @Nullable Bundle savedInstanceState) {
        View root = inflater.inflate(R.layout.fragment_local_photos, container, false);

        swipe = root.findViewById(R.id.swipe_local);
        grid = root.findViewById(R.id.local_grid);
        empty = root.findViewById(R.id.local_empty);
        permissionContainer = root.findViewById(R.id.local_permission_container);
        selectionBar = root.findViewById(R.id.local_selection_bar);
        header = root.findViewById(R.id.local_header_container);

        btnSort = root.findViewById(R.id.btn_local_sort);
        btnCloud = root.findViewById(R.id.btn_local_cloud);
        btnSelect = root.findViewById(R.id.btn_local_select);
        btnAlbums = root.findViewById(R.id.btn_local_albums);
        btnFavorites = root.findViewById(R.id.btn_local_favorites);
        btnFilter = root.findViewById(R.id.btn_local_filter);
        btnActions = root.findViewById(R.id.btn_local_actions);
        btnClearFilters = root.findViewById(R.id.btn_local_clear_filters);

        toggleView = root.findViewById(R.id.local_toggle_view);
        mediaTabs = root.findViewById(R.id.local_media_tabs);
        chipAll = root.findViewById(R.id.local_tab_all);
        chipPhotos = root.findViewById(R.id.local_tab_photos);
        chipVideos = root.findViewById(R.id.local_tab_videos);
        selectedFolderChips = root.findViewById(R.id.local_selected_folder_chips);
        activeFilterChips = root.findViewById(R.id.local_active_filter_chips);
        activeFiltersRow = root.findViewById(R.id.local_active_filters_row);
        cloudProgressText = root.findViewById(R.id.local_cloud_progress_text);
        cloudSmallProgress = root.findViewById(R.id.local_cloud_progress_small);

        vm = new ViewModelProvider(this).get(LocalPhotosViewModel.class);
        getParentFragmentManager().setFragmentResultListener(
                LocalAlbumPickerDialogFragment.KEY_SELECT_RESULT,
                this,
                (key, bundle) -> {
                    String path = bundle.getString(LocalAlbumPickerDialogFragment.RESULT_PATH, "");
                    if (path == null || path.trim().isEmpty()) return;
                    addSelectedItemsToAlbum(path);
                }
        );

        gridAdapter = new MediaGridAdapter();
        gridAdapter.setShowLabels(false);
        timelineAdapter = new TimelineAdapter();
        timelineAdapter.setRatingOverlayEnabled(false);

        gridLayoutManager = new GridLayoutManager(requireContext(), 4);
        timelineLayoutManager = new GridLayoutManager(requireContext(), 4);
        timelineLayoutManager.setSpanSizeLookup(new GridLayoutManager.SpanSizeLookup() {
            @Override
            public int getSpanSize(int position) {
                if (timelineAdapter == null) return 4;
                int vt = timelineAdapter.getItemViewType(position);
                return vt == TimelineAdapter.TYPE_PHOTO ? 1 : 4;
            }
        });

        applyLayoutMode();

        grid.addOnItemTouchListener(new RecyclerItemClickListener(requireContext(), grid, new RecyclerItemClickListener.OnItemClickListener() {
            @Override
            public void onItemClick(View view, int position) {
                if (timelineMode) {
                    onTimelineTap(position);
                } else {
                    onGridTap(position, view);
                }
            }

            @Override
            public void onLongItemClick(View view, int position) {
                if (timelineMode) {
                    onTimelineTap(position);
                } else {
                    onGridTap(position, view);
                }
            }
        }));

        timelineAdapter.setOnPhotoClickListener(cell -> {
            if (cell == null || cell.assetId == null) return;
            if (vm.isSelectionModeValue()) {
                vm.toggleSelection(cell.assetId);
            } else {
                openViewerForLocalId(cell.assetId, null);
            }
        });

        permissionLauncher = registerForActivityResult(new ActivityResultContracts.RequestMultiplePermissions(), r -> {
            if (hasMediaRead()) {
                permissionContainer.setVisibility(View.GONE);
                vm.start();
            } else {
                showPermissionUI();
            }
        });

        deleteLauncher = registerForActivityResult(new ActivityResultContracts.StartIntentSenderForResult(), result -> {
            if (result.getResultCode() == Activity.RESULT_OK) {
                Toast.makeText(requireContext(), "Deleted " + pendingDeleteCount + " item(s)", Toast.LENGTH_SHORT).show();
                vm.exitSelectionMode();
                vm.reload();
            } else {
                Toast.makeText(requireContext(), "Delete canceled", Toast.LENGTH_SHORT).show();
            }
            pendingDeleteCount = 0;
        });

        bindObservers(root);
        bindUiListeners(root);

        header.post(() -> {
            headerHeightPx = header.getHeight();
            updateGridInsets();
        });
        header.getViewTreeObserver().addOnGlobalLayoutListener(() -> {
            int h = header.getHeight();
            if (h != headerHeightPx) {
                headerHeightPx = h;
                updateGridInsets();
            }
        });
        grid.getViewTreeObserver().addOnGlobalLayoutListener(this::updateSpanCounts);

        return root;
    }

    @Override
    public void onStart() {
        super.onStart();
        if (hasMediaRead()) {
            permissionContainer.setVisibility(View.GONE);
            vm.start();
        } else {
            showPermissionUI();
        }
    }

    @Override
    public void onStop() {
        super.onStop();
        vm.stop();
    }

    private void bindObservers(@NonNull View root) {
        vm.loading().observe(getViewLifecycleOwner(), loading -> {
            boolean b = Boolean.TRUE.equals(loading);
            swipe.setRefreshing(b);
        });

        vm.error().observe(getViewLifecycleOwner(), err -> {
            if (err == null || err.isEmpty()) return;
            empty.setText(err);
            empty.setVisibility(View.VISIBLE);
        });

        vm.gridCells().observe(getViewLifecycleOwner(), cells -> {
            currentGridCells.clear();
            if (cells != null) currentGridCells.addAll(cells);
            if (!timelineMode) gridAdapter.submitList(new ArrayList<>(currentGridCells));
            refreshSelectionVisuals();
            updateEmptyState();
        });

        vm.timelineCells().observe(getViewLifecycleOwner(), cells -> {
            if (cells == null) {
                timelineAdapter.submitList(new ArrayList<>());
            } else {
                timelineAdapter.submitList(new ArrayList<>(cells));
            }
            refreshSelectionVisuals();
            updateEmptyState();
        });

        vm.visibleItems().observe(getViewLifecycleOwner(), list -> {
            visibleItems.clear();
            if (list != null) visibleItems.addAll(list);
            updateEmptyState();
        });

        vm.counts().observe(getViewLifecycleOwner(), counts -> {
            if (counts == null) return;
            chipAll.setText("All " + counts.all);
            chipPhotos.setText("Photos " + counts.photos);
            chipVideos.setText("Videos " + counts.videos);
        });

        vm.availableFolders().observe(getViewLifecycleOwner(), folders -> {
            availableFolders.clear();
            if (folders != null) availableFolders.addAll(folders);
        });

        vm.selectedFolders().observe(getViewLifecycleOwner(), folders -> rebuildSelectedFolderChips(folders));

        vm.selectionMode().observe(getViewLifecycleOwner(), enabled -> {
            boolean on = Boolean.TRUE.equals(enabled);
            selectionBar.setVisibility(on ? View.VISIBLE : View.GONE);
            btnSelect.setText(on ? "Cancel" : "Select");
            refreshSelectionVisuals();
            updateGridBottomPadding();
        });

        vm.selectedCount().observe(getViewLifecycleOwner(), count -> {
            int n = count == null ? 0 : count;
            btnActions.setEnabled(n > 0 || vm.isSelectionModeValue());
            btnActions.setText(n > 0 ? ("Actions (" + n + ")") : "Actions");
            refreshSelectionVisuals();
        });

        vm.activeFilters().observe(getViewLifecycleOwner(), active -> {
            boolean show = Boolean.TRUE.equals(active);
            activeFiltersRow.setVisibility(show ? View.VISIBLE : View.GONE);
            syncQuickFilterButtons();
            rebuildActiveFilterChips();
        });

        vm.cloudRunning().observe(getViewLifecycleOwner(), running -> {
            boolean on = Boolean.TRUE.equals(running);
            cloudSmallProgress.setVisibility(on ? View.VISIBLE : View.GONE);
            cloudProgressText.setVisibility(on ? View.VISIBLE : View.GONE);
            if (!on) cloudProgressText.setText("");
        });

        vm.cloudProgress().observe(getViewLifecycleOwner(), p -> {
            if (p == null) return;
            if (Boolean.TRUE.equals(vm.cloudRunning().getValue())) {
                cloudProgressText.setText(p.processed + "/" + p.total);
            }
        });

        vm.authExpiredEvent().observe(getViewLifecycleOwner(), signal -> {
            long s = signal == null ? 0L : signal;
            if (s <= 0 || s == lastAuthEvent) return;
            lastAuthEvent = s;
            try {
                AuthManager.get(requireContext()).logout();
                NavHostFragment.findNavController(this).navigate(R.id.serverLoginFragment);
            } catch (Exception ignored) {
            }
        });

        vm.messageEvent().observe(getViewLifecycleOwner(), msg -> {
            if (msg == null || msg.isEmpty()) return;
            if (msg.equals(lastMessage)) return;
            lastMessage = msg;
            Toast.makeText(requireContext(), msg, Toast.LENGTH_SHORT).show();
            rebuildActiveFilterChips();
        });

        // initialize controls from VM state
        applyVmStateToControls();
    }

    private void bindUiListeners(@NonNull View root) {
        root.findViewById(R.id.btn_local_permission).setOnClickListener(v -> requestMediaReadIfNeeded());

        swipe.setOnRefreshListener(vm::reload);

        btnSort.setOnClickListener(this::showSortMenu);

        toggleView.addOnButtonCheckedListener((group, checkedId, isChecked) -> {
            if (!isChecked) return;
            if (checkedId == R.id.btn_local_timeline) {
                vm.setLayoutOption(LocalPhotosViewModel.LayoutOption.TIMELINE);
            } else {
                vm.setLayoutOption(LocalPhotosViewModel.LayoutOption.GRID);
            }
            timelineMode = vm.getLayoutOption() == LocalPhotosViewModel.LayoutOption.TIMELINE;
            applyLayoutMode();
        });

        btnCloud.setOnClickListener(v -> {
            if (Boolean.TRUE.equals(vm.cloudRunning().getValue())) {
                new AlertDialog.Builder(requireContext())
                        .setTitle("Stop Cloud Check?")
                        .setMessage("Cloud check is still running. Stop now?")
                        .setPositiveButton("Stop", (d, w) -> vm.cancelCloudCheck())
                        .setNegativeButton("Continue", null)
                        .show();
                return;
            }
            PopupMenu pm = new PopupMenu(requireContext(), v);
            pm.getMenu().add(Menu.NONE, 1, 1, "Check all photos");
            pm.getMenu().add(Menu.NONE, 2, 2, "Check current selection");
            pm.getMenu().add(Menu.NONE, 3, 3, "Cancel");
            pm.setOnMenuItemClickListener(item -> {
                if (item.getItemId() == 1) vm.startCloudCheckAll();
                if (item.getItemId() == 2) vm.startCloudCheckCurrentSelection();
                if (item.getItemId() == 3) return true;
                return true;
            });
            pm.show();
        });

        btnSelect.setOnClickListener(v -> {
            if (vm.isSelectionModeValue()) vm.exitSelectionMode();
            else vm.enterSelectionMode();
        });

        btnAlbums.setOnClickListener(v -> showFolderPickerDialog());

        btnFavorites.setOnClickListener(v -> {
            vm.toggleFavoritesOnly();
            syncQuickFilterButtons();
        });

        btnFilter.setOnClickListener(this::showFilterMenu);

        mediaTabs.check(R.id.local_tab_all);
        mediaTabs.setOnCheckedStateChangeListener((group, checkedIds) -> {
            if (checkedIds == null || checkedIds.isEmpty()) return;
            int id = checkedIds.get(0);
            if (id == R.id.local_tab_photos) vm.setMediaType(LocalPhotosViewModel.MediaType.PHOTOS);
            else if (id == R.id.local_tab_videos) vm.setMediaType(LocalPhotosViewModel.MediaType.VIDEOS);
            else vm.setMediaType(LocalPhotosViewModel.MediaType.ALL);
        });

        btnClearFilters.setOnClickListener(v -> vm.clearAllFilters());

        btnActions.setOnClickListener(v -> showSelectionActionsMenu());
    }

    private void applyVmStateToControls() {
        syncQuickFilterButtons();

        LocalPhotosViewModel.LayoutOption lo = vm.getLayoutOption();
        timelineMode = lo == LocalPhotosViewModel.LayoutOption.TIMELINE;
        toggleView.check(timelineMode ? R.id.btn_local_timeline : R.id.btn_local_grid);
        applyLayoutMode();

        LocalPhotosViewModel.MediaType mt = vm.getMediaType();
        if (mt == LocalPhotosViewModel.MediaType.PHOTOS) mediaTabs.check(R.id.local_tab_photos);
        else if (mt == LocalPhotosViewModel.MediaType.VIDEOS) mediaTabs.check(R.id.local_tab_videos);
        else mediaTabs.check(R.id.local_tab_all);

        selectionBar.setVisibility(vm.isSelectionModeValue() ? View.VISIBLE : View.GONE);
        btnSelect.setText(vm.isSelectionModeValue() ? "Cancel" : "Select");
        updateGridBottomPadding();
    }

    private void applyLayoutMode() {
        updateSpanCounts();
        if (timelineMode) {
            grid.setLayoutManager(timelineLayoutManager);
            grid.setAdapter(timelineAdapter);
        } else {
            grid.setLayoutManager(gridLayoutManager);
            grid.setAdapter(gridAdapter);
        }
        refreshSelectionVisuals();
    }

    private void updateGridBottomPadding() {
        updateGridInsets();
    }

    private void onGridTap(int position, @Nullable View itemView) {
        if (position < 0 || position >= currentGridCells.size()) return;
        MediaGridAdapter.Cell cell = currentGridCells.get(position);
        String localId = cell.assetId != null && !cell.assetId.isEmpty() ? cell.assetId : cell.id;
        if (vm.isSelectionModeValue()) {
            vm.toggleSelection(localId);
            return;
        }
        openViewerAt(position, itemView);
    }

    private void onTimelineTap(int position) {
        if (position < 0) return;
        List<TimelineAdapter.Cell> cells = timelineAdapter.getCurrentList();
        if (position >= cells.size()) return;
        TimelineAdapter.Cell c = cells.get(position);
        if (c.type != TimelineAdapter.TYPE_PHOTO || c.assetId == null) return;
        if (vm.isSelectionModeValue()) {
            vm.toggleSelection(c.assetId);
        } else {
            openViewerForLocalId(c.assetId, null);
        }
    }

    private void openViewerForLocalId(@NonNull String localId, @Nullable View sharedImage) {
        int idx = -1;
        for (int i = 0; i < visibleItems.size(); i++) {
            if (localId.equals(visibleItems.get(i).localId)) { idx = i; break; }
        }
        if (idx < 0) return;
        openViewerAt(idx, sharedImage);
    }

    private void openViewerAt(int position, @Nullable View sharedImage) {
        if (position < 0 || position >= visibleItems.size()) return;
        ArrayList<String> uris = new ArrayList<>();
        ArrayList<String> assetIds = new ArrayList<>();
        for (LocalMediaItem it : visibleItems) {
            uris.add(it.uri);
            assetIds.add(it.localId);
        }
        Bundle args = new Bundle();
        args.putStringArrayList("uris", uris);
        args.putStringArrayList("assetIds", assetIds);
        args.putInt("index", position);
        args.putBoolean("isServer", false);

        try {
            if (sharedImage != null) {
                View hero = sharedImage.findViewById(R.id.image);
                if (hero == null) hero = sharedImage;
                androidx.navigation.fragment.FragmentNavigator.Extras extras =
                        new androidx.navigation.fragment.FragmentNavigator.Extras.Builder()
                                .addSharedElement(hero, "hero_image")
                                .build();
                NavHostFragment.findNavController(this).navigate(R.id.viewerFragment, args, null, extras);
            } else {
                NavHostFragment.findNavController(this).navigate(R.id.viewerFragment, args);
            }
        } catch (Exception ignored) {
            NavHostFragment.findNavController(this).navigate(R.id.viewerFragment, args);
        }
    }

    private void showSortMenu(@NonNull View anchor) {
        PopupMenu pm = new PopupMenu(requireContext(), anchor);
        pm.getMenu().add(Menu.NONE, 1, 1, LocalPhotosViewModel.sortDisplay(LocalPhotosViewModel.SortOption.NEWEST));
        pm.getMenu().add(Menu.NONE, 2, 2, LocalPhotosViewModel.sortDisplay(LocalPhotosViewModel.SortOption.OLDEST));
        pm.getMenu().add(Menu.NONE, 3, 3, LocalPhotosViewModel.sortDisplay(LocalPhotosViewModel.SortOption.LARGEST));
        pm.getMenu().add(Menu.NONE, 4, 4, LocalPhotosViewModel.sortDisplay(LocalPhotosViewModel.SortOption.RANDOM));
        pm.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1: vm.setSortOption(LocalPhotosViewModel.SortOption.NEWEST); break;
                case 2: vm.setSortOption(LocalPhotosViewModel.SortOption.OLDEST); break;
                case 3: vm.setSortOption(LocalPhotosViewModel.SortOption.LARGEST); break;
                case 4: vm.setSortOption(LocalPhotosViewModel.SortOption.RANDOM); break;
            }
            timelineMode = vm.getLayoutOption() == LocalPhotosViewModel.LayoutOption.TIMELINE;
            applyVmStateToControls();
            return true;
        });
        pm.show();
    }

    private void showFilterMenu(@NonNull View anchor) {
        PopupMenu pm = new PopupMenu(requireContext(), anchor);
        Menu m = pm.getMenu();
        MenuItem iDate = m.add(Menu.NONE, 1, 1, "Time Range");
        MenuItem iScreenshots = m.add(Menu.NONE, 2, 2, "Screenshots");
        MenuItem iLive = m.add(Menu.NONE, 3, 3, "Live Photos");
        MenuItem iMissing = m.add(Menu.NONE, 4, 4, "Missing in Cloud");

        iDate.setCheckable(false);
        iScreenshots.setCheckable(true).setChecked(vm.isFilterScreenshots());
        iLive.setCheckable(true).setChecked(vm.isFilterLive());
        iMissing.setCheckable(true).setChecked(vm.isFilterMissingCloud());

        pm.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == 1) {
                showDateRangeDialog();
                return true;
            }
            if (item.getItemId() == 2) {
                vm.setFilterScreenshots(!vm.isFilterScreenshots());
                return true;
            }
            if (item.getItemId() == 3) {
                vm.setFilterLive(!vm.isFilterLive());
                return true;
            }
            if (item.getItemId() == 4) {
                vm.setFilterMissingCloud(!vm.isFilterMissingCloud());
                return true;
            }
            return false;
        });
        pm.show();
    }

    private void showDateRangeDialog() {
        final Long[] from = new Long[]{vm.getDateFromSec()};
        final Long[] to = new Long[]{vm.getDateToSec()};

        View root = LayoutInflater.from(requireContext()).inflate(android.R.layout.simple_list_item_2, null, false);
        TextView t1 = root.findViewById(android.R.id.text1);
        TextView t2 = root.findViewById(android.R.id.text2);
        t1.setText("Set date range");
        t2.setText("Choose start and end date");

        AlertDialog dlg = new AlertDialog.Builder(requireContext())
                .setTitle("Time Range")
                .setView(root)
                .setPositiveButton("Apply", (d, w) -> vm.setDateRange(from[0], to[0]))
                .setNegativeButton("Cancel", null)
                .setNeutralButton("Clear", (d, w) -> vm.setDateRange(null, null))
                .create();
        dlg.setOnShowListener(d -> {
            root.setOnClickListener(v -> {
                pickDate(true, from[0], value -> {
                    from[0] = value;
                    pickDate(false, to[0], value2 -> to[0] = value2);
                });
            });
        });
        dlg.show();
    }

    private interface DateSetCb { void onDate(long sec); }

    private void pickDate(boolean isStart, @Nullable Long currentSec, @NonNull DateSetCb cb) {
        Calendar cal = Calendar.getInstance();
        if (currentSec != null && currentSec > 0) cal.setTimeInMillis(currentSec * 1000L);
        DatePickerDialog dp = new DatePickerDialog(requireContext(), (view, y, m, d) -> {
            Calendar c = Calendar.getInstance();
            c.set(Calendar.YEAR, y);
            c.set(Calendar.MONTH, m);
            c.set(Calendar.DAY_OF_MONTH, d);
            if (isStart) {
                c.set(Calendar.HOUR_OF_DAY, 0);
                c.set(Calendar.MINUTE, 0);
                c.set(Calendar.SECOND, 0);
            } else {
                c.set(Calendar.HOUR_OF_DAY, 23);
                c.set(Calendar.MINUTE, 59);
                c.set(Calendar.SECOND, 59);
            }
            cb.onDate(c.getTimeInMillis() / 1000L);
        }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH));
        dp.show();
    }

    private void showFolderPickerDialog() {
        List<String> folders = vm.availableFolders().getValue();
        if (folders == null || folders.isEmpty()) {
            Toast.makeText(requireContext(), "No folders found", Toast.LENGTH_SHORT).show();
            return;
        }

        String[] arr = folders.toArray(new String[0]);
        Set<String> selected = vm.selectedFolders().getValue() != null
                ? new LinkedHashSet<>(vm.selectedFolders().getValue())
                : new LinkedHashSet<>();
        boolean[] checked = new boolean[arr.length];
        for (int i = 0; i < arr.length; i++) checked[i] = selected.contains(arr[i]);

        new AlertDialog.Builder(requireContext())
                .setTitle("Choose Albums")
                .setMultiChoiceItems(arr, checked, (dialog, which, isChecked) -> {
                    if (which < 0 || which >= arr.length) return;
                    if (isChecked) selected.add(arr[which]); else selected.remove(arr[which]);
                })
                .setPositiveButton("Apply", (d, w) -> vm.setSelectedFolders(selected))
                .setNeutralButton("Clear", (d, w) -> vm.setSelectedFolders(new LinkedHashSet<>()))
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void rebuildSelectedFolderChips(@Nullable Set<String> folders) {
        selectedFolderChips.removeAllViews();
        if (folders == null || folders.isEmpty()) return;
        for (String folder : folders) {
            Chip c = new Chip(requireContext());
            c.setText(shortFolderLabel(folder));
            c.setCheckable(false);
            c.setCloseIconVisible(true);
            c.setOnCloseIconClickListener(v -> {
                Set<String> next = vm.selectedFolders().getValue() == null
                        ? new LinkedHashSet<>()
                        : new LinkedHashSet<>(vm.selectedFolders().getValue());
                next.remove(folder);
                vm.setSelectedFolders(next);
            });
            selectedFolderChips.addView(c);
        }
    }

    private void rebuildActiveFilterChips() {
        activeFilterChips.removeAllViews();
        List<String> labels = vm.activeFilterLabels();
        if (labels == null || labels.isEmpty()) {
            activeFiltersRow.setVisibility(View.GONE);
            syncQuickFilterButtons();
            return;
        }
        activeFiltersRow.setVisibility(View.VISIBLE);
        syncQuickFilterButtons();
        for (String label : labels) {
            Chip c = new Chip(requireContext());
            c.setText(label);
            c.setCheckable(false);
            activeFilterChips.addView(c);
        }
    }

    private void syncQuickFilterButtons() {
        if (btnFavorites == null || vm == null) return;
        btnFavorites.setAlpha(vm.isFavoritesOnly() ? 1.0f : 0.45f);
    }

    private void showSelectionActionsMenu() {
        PopupMenu pm = new PopupMenu(requireContext(), btnActions);
        pm.getMenu().add(Menu.NONE, 1, 1, "Sync");
        pm.getMenu().add(Menu.NONE, 2, 2, "Add to Album");
        pm.getMenu().add(Menu.NONE, 3, 3, "Select All");
        pm.getMenu().add(Menu.NONE, 4, 4, "Deselect All");
        pm.getMenu().add(Menu.NONE, 5, 5, "Delete");
        pm.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1:
                    syncSelectedItems();
                    return true;
                case 2:
                    showAddToAlbumPicker();
                    return true;
                case 3:
                    vm.selectAllVisible();
                    return true;
                case 4:
                    vm.deselectAllKeepMode();
                    return true;
                case 5:
                    confirmDeleteSelected();
                    return true;
                default:
                    return false;
            }
        });
        pm.show();
    }

    private void showAddToAlbumPicker() {
        Set<String> selected = vm.currentSelectedIds();
        if (selected.isEmpty()) {
            Toast.makeText(requireContext(), "No selection", Toast.LENGTH_SHORT).show();
            return;
        }
        if (availableFolders.isEmpty()) {
            Toast.makeText(requireContext(), "No local albums available", Toast.LENGTH_SHORT).show();
            return;
        }
        LocalAlbumPickerDialogFragment dialog =
                LocalAlbumPickerDialogFragment.newInstance(new ArrayList<>(availableFolders));
        dialog.show(getParentFragmentManager(), "local_album_picker");
    }

    private void addSelectedItemsToAlbum(@NonNull String targetPath) {
        Set<String> selected = vm.currentSelectedIds();
        if (selected.isEmpty()) {
            Toast.makeText(requireContext(), "No selection", Toast.LENGTH_SHORT).show();
            return;
        }

        List<LocalMediaItem> picked = new ArrayList<>();
        for (LocalMediaItem item : vm.currentVisibleSnapshot()) {
            if (selected.contains(item.localId)) picked.add(item);
        }
        if (picked.isEmpty()) {
            Toast.makeText(requireContext(), "No selected items", Toast.LENGTH_SHORT).show();
            return;
        }

        Toast.makeText(requireContext(), "Adding " + picked.size() + " item(s) to " + targetPath, Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            LocalAlbumCopyHelper.Result result = LocalAlbumCopyHelper.copyItemsToFolder(
                    requireContext().getApplicationContext(),
                    picked,
                    targetPath
            );
            requireActivity().runOnUiThread(() -> {
                String message = "Added to " + targetPath + ": "
                        + result.copied + " copied, "
                        + result.skipped + " skipped, "
                        + result.failed + " failed";
                Toast.makeText(requireContext(), message, Toast.LENGTH_LONG).show();
                vm.exitSelectionMode();
                vm.reload();
            });
        }).start();
    }

    private void syncSelectedItems() {
        if (!AuthManager.get(requireContext()).isAuthenticated()) {
            try { NavHostFragment.findNavController(this).navigate(R.id.serverLoginFragment); } catch (Exception ignored) {}
            return;
        }

        Set<String> selected = vm.currentSelectedIds();
        if (selected.isEmpty()) {
            Toast.makeText(requireContext(), "No selection", Toast.LENGTH_SHORT).show();
            return;
        }

        List<LocalMediaItem> picked = new ArrayList<>();
        for (LocalMediaItem it : vm.currentVisibleSnapshot()) {
            if (selected.contains(it.localId)) picked.add(it);
        }
        if (picked.isEmpty()) {
            Toast.makeText(requireContext(), "No selected items", Toast.LENGTH_SHORT).show();
            return;
        }

        Toast.makeText(requireContext(), "Syncing " + picked.size() + " item(s)...", Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            int ok = 0;
            int fail = 0;
            TusUploadManager tus = new TusUploadManager(requireContext().getApplicationContext());
            for (LocalMediaItem item : picked) {
                File tmp = null;
                try {
                    tmp = copyToCache(Uri.parse(item.uri), item.displayName, item.mimeType);
                    PhotoEntity p = new PhotoEntity();
                    p.contentId = stableContentId(item.localId);
                    p.contentUri = item.uri;
                    p.mediaType = item.isVideo ? 1 : 0;
                    p.creationTs = item.createdAtSec;
                    p.pixelWidth = item.width;
                    p.pixelHeight = item.height;
                    p.syncState = 0;
                    p.estimatedBytes = item.sizeBytes;
                    String albumPaths = AlbumPathUtil.pathsJsonFromRelativePath(item.relativePath);
                    tus.uploadUnlocked(tmp, p, albumPaths, item.displayName, item.mimeType);
                    ok++;
                } catch (Exception e) {
                    fail++;
                } finally {
                    if (tmp != null) {
                        try { tmp.delete(); } catch (Exception ignored) {}
                    }
                }
            }
            int finalOk = ok;
            int finalFail = fail;
            requireActivity().runOnUiThread(() -> {
                Toast.makeText(requireContext(), "Sync done: " + finalOk + " success, " + finalFail + " failed", Toast.LENGTH_LONG).show();
                vm.exitSelectionMode();
                vm.reload();
            });
        }).start();
    }

    private void confirmDeleteSelected() {
        Set<String> selected = vm.currentSelectedIds();
        if (selected.isEmpty()) {
            Toast.makeText(requireContext(), "No selection", Toast.LENGTH_SHORT).show();
            return;
        }
        List<Uri> targets = new ArrayList<>();
        for (LocalMediaItem item : vm.currentVisibleSnapshot()) {
            if (selected.contains(item.localId)) targets.add(Uri.parse(item.uri));
        }
        if (targets.isEmpty()) {
            Toast.makeText(requireContext(), "No selected items", Toast.LENGTH_SHORT).show();
            return;
        }

        new AlertDialog.Builder(requireContext())
                .setTitle("Delete Photos")
                .setMessage("Delete " + targets.size() + " selected item(s)?")
                .setPositiveButton("Delete", (d, w) -> deleteUris(targets))
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void deleteUris(@NonNull List<Uri> uris) {
        pendingDeleteCount = uris.size();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                IntentSenderRequest req = new IntentSenderRequest.Builder(
                        MediaStore.createDeleteRequest(requireContext().getContentResolver(), uris).getIntentSender()
                ).build();
                deleteLauncher.launch(req);
                return;
            } catch (Exception ignored) {
            }
        }

        new Thread(() -> {
            int ok = 0;
            for (Uri u : uris) {
                try {
                    int r = requireContext().getContentResolver().delete(u, null, null);
                    if (r > 0) ok++;
                } catch (Exception ignored) {
                }
            }
            int finalOk = ok;
            requireActivity().runOnUiThread(() -> {
                Toast.makeText(requireContext(), "Deleted " + finalOk + " item(s)", Toast.LENGTH_SHORT).show();
                vm.exitSelectionMode();
                vm.reload();
            });
        }).start();
    }

    private void refreshSelectionVisuals() {
        if (vm == null) return;
        Set<String> selected = vm.currentSelectedIds();
        boolean selectionMode = vm.isSelectionModeValue();
        gridAdapter.setSelectionMode(selectionMode, selected);
        timelineAdapter.setSelectionMode(selectionMode, selected);
    }

    private void updateEmptyState() {
        boolean noPermission = !hasMediaRead();
        if (noPermission) {
            empty.setVisibility(View.GONE);
            return;
        }
        boolean loading = Boolean.TRUE.equals(vm.loading().getValue());
        if (loading) {
            empty.setVisibility(View.GONE);
            return;
        }
        boolean isEmpty = visibleItems.isEmpty();
        empty.setVisibility(isEmpty ? View.VISIBLE : View.GONE);
        if (isEmpty) {
            String err = vm.error().getValue();
            empty.setText((err == null || err.isEmpty()) ? "No photos" : err);
        }
    }

    private boolean hasMediaRead() {
        if (Build.VERSION.SDK_INT >= 33) {
            return requireContext().checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
                    && requireContext().checkSelfPermission(Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED;
        }
        return requireContext().checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED;
    }

    private void requestMediaReadIfNeeded() {
        if (hasMediaRead()) {
            permissionContainer.setVisibility(View.GONE);
            vm.start();
            return;
        }
        if (Build.VERSION.SDK_INT >= 33) {
            permissionLauncher.launch(new String[]{Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO});
        } else {
            permissionLauncher.launch(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE});
        }
    }

    private void showPermissionUI() {
        permissionContainer.setVisibility(View.VISIBLE);
        empty.setVisibility(View.GONE);
        swipe.setRefreshing(false);
        vm.stop();
        View btn = permissionContainer.findViewById(R.id.btn_local_permission);
        if (btn != null) {
            btn.setOnLongClickListener(v -> {
                try {
                    Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                    i.setData(Uri.parse("package:" + requireContext().getPackageName()));
                    startActivity(i);
                } catch (Exception ignored) {
                }
                return true;
            });
        }
    }

    @NonNull
    private static String shortFolderLabel(@NonNull String fullPath) {
        if (fullPath.isEmpty()) return "Folder";
        String p = fullPath.endsWith("/") ? fullPath.substring(0, fullPath.length() - 1) : fullPath;
        int idx = p.lastIndexOf('/');
        return idx >= 0 ? p.substring(idx + 1) : p;
    }

    private File copyToCache(@NonNull Uri uri, @NonNull String displayName, @NonNull String mimeType) throws Exception {
        String ext = extensionFromNameOrMime(displayName, mimeType);
        File out = File.createTempFile("local_sync_", "." + ext, requireContext().getCacheDir());
        try (InputStream is = requireContext().getContentResolver().openInputStream(uri);
             FileOutputStream fos = new FileOutputStream(out)) {
            if (is == null) throw new IllegalStateException("Cannot open input");
            byte[] buf = new byte[8192];
            int n;
            while ((n = is.read(buf)) > 0) fos.write(buf, 0, n);
        }
        return out;
    }

    @NonNull
    private static String extensionFromNameOrMime(@NonNull String displayName, @NonNull String mimeType) {
        int dot = displayName.lastIndexOf('.');
        if (dot > 0 && dot < displayName.length() - 1) {
            return displayName.substring(dot + 1);
        }
        String lower = mimeType.toLowerCase(java.util.Locale.US);
        if (lower.contains("jpeg") || lower.contains("jpg")) return "jpg";
        if (lower.contains("png")) return "png";
        if (lower.contains("heic") || lower.contains("heif")) return "heic";
        if (lower.contains("dng")) return "dng";
        if (lower.contains("avif")) return "avif";
        if (lower.contains("mp4")) return "mp4";
        if (lower.contains("quicktime") || lower.contains("mov")) return "mov";
        return "bin";
    }

    @NonNull
    private static String stableContentId(@NonNull String localId) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("MD5");
            byte[] digest = md.digest(localId.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return ca.openphotos.android.util.Base58.encode(digest);
        } catch (Exception ignored) {
            return localId;
        }
    }

    private int dp(int value) {
        return Math.round(value * requireContext().getResources().getDisplayMetrics().density);
    }

    private void updateGridInsets() {
        int extra = vm != null && vm.isSelectionModeValue() ? dp(72) : 0;
        int top = Math.max(0, headerHeightPx);
        grid.setPadding(grid.getPaddingLeft(), top, grid.getPaddingRight(), dp(12) + extra);
    }

    private void updateSpanCounts() {
        int width = grid.getWidth();
        if (width <= 0) return;
        int desired = Math.max(4, width / dp(96));
        if (gridLayoutManager.getSpanCount() != desired) gridLayoutManager.setSpanCount(desired);
        if (timelineLayoutManager.getSpanCount() != desired) timelineLayoutManager.setSpanCount(desired);
    }
}
