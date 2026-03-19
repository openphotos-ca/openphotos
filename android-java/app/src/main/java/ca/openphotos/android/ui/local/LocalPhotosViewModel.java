package ca.openphotos.android.ui.local;

import android.app.Application;
import android.content.Context;
import android.content.SharedPreferences;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.lifecycle.AndroidViewModel;
import androidx.lifecycle.LiveData;
import androidx.lifecycle.MutableLiveData;

import ca.openphotos.android.ui.MediaGridAdapter;
import ca.openphotos.android.ui.TimelineAdapter;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * ViewModel backing Android local Photos tab with iOS-like filters/sort/layout/selection.
 */
public final class LocalPhotosViewModel extends AndroidViewModel {
    public enum SortOption { NEWEST, OLDEST, LARGEST, RANDOM }
    public enum LayoutOption { GRID, TIMELINE }
    public enum MediaType { ALL, PHOTOS, VIDEOS }

    public static final class Counts {
        public final int all;
        public final int photos;
        public final int videos;
        public Counts(int all, int photos, int videos) { this.all = all; this.photos = photos; this.videos = videos; }
    }

    public static final class Progress {
        public final int processed;
        public final int total;
        public Progress(int processed, int total) { this.processed = processed; this.total = total; }
    }

    private static final String PREF = "local.photos.ui.v1";
    private static final String K_SORT = "sort";
    private static final String K_LAYOUT = "layout";
    private static final String K_MEDIA_TYPE = "media_type";
    private static final String K_FAVORITES = "favorites_only";
    private static final String K_FILTER_SS = "filter_screenshots";
    private static final String K_FILTER_LIVE = "filter_live";
    private static final String K_FILTER_MISSING = "filter_missing_cloud";
    private static final String K_DATE_FROM = "date_from";
    private static final String K_DATE_TO = "date_to";

    private final Object lock = new Object();

    private final LocalMediaRepository repository;
    private final LocalCloudCacheStore cloudCache;
    private final LocalCloudCheckService cloudCheckService;
    private final SharedPreferences prefs;
    private final ExecutorService io = Executors.newSingleThreadExecutor();

    private final MutableLiveData<List<MediaGridAdapter.Cell>> gridCellsLive = new MutableLiveData<>(new ArrayList<>());
    private final MutableLiveData<List<TimelineAdapter.Cell>> timelineCellsLive = new MutableLiveData<>(new ArrayList<>());
    private final MutableLiveData<List<LocalMediaItem>> visibleItemsLive = new MutableLiveData<>(new ArrayList<>());
    private final MutableLiveData<Counts> countsLive = new MutableLiveData<>(new Counts(0, 0, 0));
    private final MutableLiveData<List<String>> availableFoldersLive = new MutableLiveData<>(new ArrayList<>());
    private final MutableLiveData<Set<String>> selectedFoldersLive = new MutableLiveData<>(new LinkedHashSet<>());

    private final MutableLiveData<Boolean> loadingLive = new MutableLiveData<>(false);
    private final MutableLiveData<String> errorLive = new MutableLiveData<>("");
    private final MutableLiveData<Boolean> selectionModeLive = new MutableLiveData<>(false);
    private final MutableLiveData<Integer> selectedCountLive = new MutableLiveData<>(0);
    private final MutableLiveData<Boolean> activeFiltersLive = new MutableLiveData<>(false);

    private final MutableLiveData<Boolean> cloudRunningLive = new MutableLiveData<>(false);
    private final MutableLiveData<Progress> cloudProgressLive = new MutableLiveData<>(new Progress(0, 0));
    private final MutableLiveData<Long> authExpiredEventLive = new MutableLiveData<>(0L);
    private final MutableLiveData<String> messageEventLive = new MutableLiveData<>("");

    private List<LocalMediaItem> allItems = new ArrayList<>();
    private List<LocalMediaItem> visibleItemsCache = new ArrayList<>();

    private final Set<String> selectedIds = new LinkedHashSet<>();
    private final Set<String> selectedFolders = new LinkedHashSet<>();
    private final Map<String, Integer> cloudStateByLocalId = new HashMap<>(); // -1 unknown, 0 missing, 1 backed

    private SortOption sortOption = SortOption.NEWEST;
    private LayoutOption layoutOption = LayoutOption.GRID;
    private MediaType mediaType = MediaType.ALL;
    private boolean favoritesOnly = false;
    private boolean filterScreenshots = false;
    private boolean filterLive = false;
    private boolean filterMissingCloud = false;
    @Nullable private Long dateFromSec = null;
    @Nullable private Long dateToSec = null;
    private boolean selectionMode = false;

    private int randomSeed = new Random().nextInt();

    public LocalPhotosViewModel(@NonNull Application app) {
        super(app);
        repository = new LocalMediaRepository(app);
        cloudCache = new LocalCloudCacheStore(app);
        cloudCheckService = new LocalCloudCheckService(app);
        prefs = app.getSharedPreferences(PREF, Context.MODE_PRIVATE);
        restorePrefs();
    }

    // region LiveData
    public LiveData<List<MediaGridAdapter.Cell>> gridCells() { return gridCellsLive; }
    public LiveData<List<TimelineAdapter.Cell>> timelineCells() { return timelineCellsLive; }
    public LiveData<List<LocalMediaItem>> visibleItems() { return visibleItemsLive; }
    public LiveData<Counts> counts() { return countsLive; }
    public LiveData<List<String>> availableFolders() { return availableFoldersLive; }
    public LiveData<Set<String>> selectedFolders() { return selectedFoldersLive; }

    public LiveData<Boolean> loading() { return loadingLive; }
    public LiveData<String> error() { return errorLive; }
    public LiveData<Boolean> selectionMode() { return selectionModeLive; }
    public LiveData<Integer> selectedCount() { return selectedCountLive; }
    public LiveData<Boolean> activeFilters() { return activeFiltersLive; }

    public LiveData<Boolean> cloudRunning() { return cloudRunningLive; }
    public LiveData<Progress> cloudProgress() { return cloudProgressLive; }
    public LiveData<Long> authExpiredEvent() { return authExpiredEventLive; }
    public LiveData<String> messageEvent() { return messageEventLive; }
    // endregion

    // region state getters
    public SortOption getSortOption() { synchronized (lock) { return sortOption; } }
    public LayoutOption getLayoutOption() { synchronized (lock) { return layoutOption; } }
    public MediaType getMediaType() { synchronized (lock) { return mediaType; } }
    public boolean isFavoritesOnly() { synchronized (lock) { return favoritesOnly; } }
    public boolean isFilterScreenshots() { synchronized (lock) { return filterScreenshots; } }
    public boolean isFilterLive() { synchronized (lock) { return filterLive; } }
    public boolean isFilterMissingCloud() { synchronized (lock) { return filterMissingCloud; } }
    @Nullable public Long getDateFromSec() { synchronized (lock) { return dateFromSec; } }
    @Nullable public Long getDateToSec() { synchronized (lock) { return dateToSec; } }

    public boolean isSelectionModeValue() { synchronized (lock) { return selectionMode; } }

    @NonNull
    public List<LocalMediaItem> currentVisibleSnapshot() {
        synchronized (lock) {
            return new ArrayList<>(visibleItemsCache);
        }
    }

    public boolean isCloudBackedUp(@NonNull String localId) {
        synchronized (lock) {
            Integer s = cloudStateByLocalId.get(localId);
            return s != null && s == 1;
        }
    }

    @NonNull
    public Set<String> currentSelectedIds() {
        synchronized (lock) {
            return new LinkedHashSet<>(selectedIds);
        }
    }

    @NonNull
    public List<String> activeFilterLabels() {
        ArrayList<String> labels = new ArrayList<>();
        synchronized (lock) {
            if (favoritesOnly) labels.add("Favorites");
            if (filterScreenshots) labels.add("Screenshots");
            if (filterLive) labels.add("Live Photos");
            if (filterMissingCloud) labels.add("Missing in Cloud");
            if (dateFromSec != null || dateToSec != null) {
                SimpleDateFormat f = new SimpleDateFormat("MMM d, yyyy", Locale.US);
                String from = dateFromSec != null ? f.format(new Date(dateFromSec * 1000L)) : "-";
                String to = dateToSec != null ? f.format(new Date(dateToSec * 1000L)) : "-";
                labels.add(from + " to " + to);
            }
            if (sortOption != SortOption.NEWEST) {
                labels.add(sortDisplay(sortOption));
            }
        }
        return labels;
    }
    // endregion

    public void start() {
        reload();
        repository.startObserving(this::reload);
    }

    public void stop() {
        repository.stopObserving();
        cloudCheckService.cancel();
    }

    public void reload() {
        loadingLive.postValue(true);
        io.execute(() -> {
            try {
                List<LocalMediaItem> loaded = repository.loadAll();
                synchronized (lock) {
                    allItems = loaded;
                    hydrateCloudStatesLocked(loaded);
                }
                recomputeAndPublish();
                loadingLive.postValue(false);
                errorLive.postValue("");
            } catch (Exception e) {
                loadingLive.postValue(false);
                errorLive.postValue(e.getMessage() == null ? "Load failed" : e.getMessage());
            }
        });
    }

    public void setSortOption(@NonNull SortOption option) {
        synchronized (lock) {
            sortOption = option;
            if (sortOption == SortOption.RANDOM) randomSeed = new Random().nextInt();
            if (layoutOption == LayoutOption.TIMELINE && !(sortOption == SortOption.NEWEST || sortOption == SortOption.OLDEST)) {
                layoutOption = LayoutOption.GRID;
            }
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void setLayoutOption(@NonNull LayoutOption option) {
        synchronized (lock) {
            if (option == LayoutOption.TIMELINE && !(sortOption == SortOption.NEWEST || sortOption == SortOption.OLDEST)) {
                layoutOption = LayoutOption.GRID;
            } else {
                layoutOption = option;
            }
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void setMediaType(@NonNull MediaType type) {
        synchronized (lock) {
            mediaType = type;
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void toggleFavoritesOnly() {
        synchronized (lock) {
            favoritesOnly = !favoritesOnly;
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void setFilterScreenshots(boolean on) {
        synchronized (lock) {
            filterScreenshots = on;
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void setFilterLive(boolean on) {
        synchronized (lock) {
            filterLive = on;
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void setFilterMissingCloud(boolean on) {
        synchronized (lock) {
            filterMissingCloud = on;
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void setDateRange(@Nullable Long fromSec, @Nullable Long toSec) {
        synchronized (lock) {
            dateFromSec = fromSec;
            dateToSec = toSec;
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void clearAllFilters() {
        synchronized (lock) {
            favoritesOnly = false;
            filterScreenshots = false;
            filterLive = false;
            filterMissingCloud = false;
            selectedFolders.clear();
            dateFromSec = null;
            dateToSec = null;
            sortOption = SortOption.NEWEST;
            mediaType = MediaType.ALL;
            persistPrefsLocked();
        }
        recomputeAndPublish();
    }

    public void setSelectedFolders(@NonNull Set<String> folders) {
        synchronized (lock) {
            selectedFolders.clear();
            selectedFolders.addAll(folders);
        }
        recomputeAndPublish();
    }

    public void enterSelectionMode() {
        synchronized (lock) {
            selectionMode = true;
        }
        selectionModeLive.postValue(true);
    }

    public void exitSelectionMode() {
        synchronized (lock) {
            selectionMode = false;
            selectedIds.clear();
        }
        selectionModeLive.postValue(false);
        selectedCountLive.postValue(0);
        recomputeAndPublish();
    }

    public void toggleSelection(@NonNull String localId) {
        synchronized (lock) {
            if (selectedIds.contains(localId)) selectedIds.remove(localId); else selectedIds.add(localId);
            if (!selectionMode) selectionMode = true;
        }
        selectionModeLive.postValue(true);
        selectedCountLive.postValue(currentSelectedIds().size());
        recomputeAndPublish();
    }

    public void selectAllVisible() {
        synchronized (lock) {
            selectedIds.clear();
            for (LocalMediaItem it : visibleItemsCache) selectedIds.add(it.localId);
            selectionMode = true;
        }
        selectionModeLive.postValue(true);
        selectedCountLive.postValue(currentSelectedIds().size());
        recomputeAndPublish();
    }

    public void deselectAllKeepMode() {
        synchronized (lock) {
            selectedIds.clear();
            selectionMode = true;
        }
        selectionModeLive.postValue(true);
        selectedCountLive.postValue(0);
        recomputeAndPublish();
    }

    public void startCloudCheckAll() {
        List<LocalMediaItem> snapshot;
        synchronized (lock) { snapshot = new ArrayList<>(allItems); }
        startCloudCheck(snapshot);
    }

    public void startCloudCheckCurrentSelection() {
        List<LocalMediaItem> snapshot = currentVisibleSnapshot();
        startCloudCheck(snapshot);
    }

    public void cancelCloudCheck() {
        cloudCheckService.cancel();
    }

    private void startCloudCheck(@NonNull List<LocalMediaItem> snapshot) {
        if (snapshot.isEmpty()) {
            messageEventLive.postValue("No photos to check");
            return;
        }
        boolean started = cloudCheckService.startCheck(snapshot, cloudCache, new LocalCloudCheckService.Listener() {
            @Override
            public void onStart(int total) {
                cloudRunningLive.postValue(true);
                cloudProgressLive.postValue(new Progress(0, total));
            }

            @Override
            public void onProgress(int processed, int total) {
                cloudProgressLive.postValue(new Progress(processed, total));
            }

            @Override
            public void onItemResult(@NonNull String localId, int cloudState) {
                synchronized (lock) {
                    cloudStateByLocalId.put(localId, cloudState);
                }
            }

            @Override
            public void onFinished(@NonNull LocalCloudCheckService.Stats stats) {
                cloudRunningLive.postValue(false);
                cloudProgressLive.postValue(new Progress(stats.checked + stats.skipped, stats.checked + stats.skipped));
                messageEventLive.postValue("Cloud check: " + stats.backedUp + " backed up, " + stats.missing + " missing, " + stats.skipped + " skipped");
                recomputeAndPublish();
            }

            @Override
            public void onCanceled() {
                cloudRunningLive.postValue(false);
                messageEventLive.postValue("Cloud check canceled");
                recomputeAndPublish();
            }

            @Override
            public void onError(@NonNull String message, boolean authExpired) {
                cloudRunningLive.postValue(false);
                messageEventLive.postValue(message);
                if (authExpired) authExpiredEventLive.postValue(System.currentTimeMillis());
                recomputeAndPublish();
            }
        });
        if (!started) {
            messageEventLive.postValue("Cloud check already running");
        }
    }

    private void recomputeAndPublish() {
        io.execute(() -> {
            List<LocalMediaItem> localAll;
            Set<String> folderFilters;
            MediaType mt;
            boolean fav;
            boolean ss;
            boolean live;
            boolean missingFilter;
            Long from;
            Long to;
            SortOption sort;
            LayoutOption layout;
            int seed;
            boolean inSelection;
            Set<String> selection;
            Map<String, Integer> cloud;

            synchronized (lock) {
                localAll = new ArrayList<>(allItems);
                folderFilters = new LinkedHashSet<>(selectedFolders);
                mt = mediaType;
                fav = favoritesOnly;
                ss = filterScreenshots;
                live = filterLive;
                missingFilter = filterMissingCloud;
                from = dateFromSec;
                to = dateToSec;
                sort = sortOption;
                layout = layoutOption;
                seed = randomSeed;
                inSelection = selectionMode;
                selection = new LinkedHashSet<>(selectedIds);
                cloud = new HashMap<>(cloudStateByLocalId);
            }

            List<LocalMediaItem> noType = new ArrayList<>();
            for (LocalMediaItem item : localAll) {
                if (fav && !item.favorite) continue;
                if (!folderFilters.isEmpty() && !matchesAllFolders(item, folderFilters)) continue;
                if (ss && !item.screenshot) continue;
                if (live && !item.motionPhoto) continue;
                if (from != null && item.createdAtSec < from) continue;
                if (to != null && item.createdAtSec > to) continue;
                if (missingFilter) {
                    Integer st = cloud.get(item.localId);
                    if (st == null || st != 0) continue;
                }
                noType.add(item);
            }

            int allCount = noType.size();
            int photoCount = 0;
            int videoCount = 0;
            for (LocalMediaItem item : noType) {
                if (item.isVideo) videoCount++; else photoCount++;
            }

            List<LocalMediaItem> visible = new ArrayList<>();
            for (LocalMediaItem item : noType) {
                if (mt == MediaType.PHOTOS && item.isVideo) continue;
                if (mt == MediaType.VIDEOS && !item.isVideo) continue;
                visible.add(item);
            }

            sortItems(visible, sort, seed);
            if (layout == LayoutOption.TIMELINE && !(sort == SortOption.NEWEST || sort == SortOption.OLDEST)) {
                layout = LayoutOption.GRID;
                synchronized (lock) {
                    layoutOption = LayoutOption.GRID;
                    persistPrefsLocked();
                }
            }

            Set<String> visibleIds = new HashSet<>();
            for (LocalMediaItem item : visible) visibleIds.add(item.localId);
            if (inSelection) {
                selection.retainAll(visibleIds);
                synchronized (lock) {
                    selectedIds.clear();
                    selectedIds.addAll(selection);
                }
            }

            ArrayList<MediaGridAdapter.Cell> gridCells = new ArrayList<>();
            for (LocalMediaItem item : visible) {
                Integer st = cloud.get(item.localId);
                boolean cloudBacked = st != null && st == 1;
                gridCells.add(new MediaGridAdapter.Cell(
                        item.localId,
                        item.displayName,
                        false,
                        item.uri,
                        item.isVideo,
                        item.localId,
                        0,
                        item.durationMs,
                        cloudBacked
                ));
            }

            List<TimelineAdapter.Cell> timelineCells = layout == LayoutOption.TIMELINE
                    ? buildTimelineCells(visible, sort == SortOption.NEWEST, cloud)
                    : new ArrayList<>();

            ArrayList<String> folders = new ArrayList<>();
            Set<String> uniq = new LinkedHashSet<>();
            for (LocalMediaItem item : localAll) {
                String p = item.folderPathNormalized();
                if (!p.isEmpty()) uniq.add(p);
            }
            folders.addAll(uniq);
            Collections.sort(folders);

            synchronized (lock) {
                visibleItemsCache = new ArrayList<>(visible);
            }

            gridCellsLive.postValue(gridCells);
            timelineCellsLive.postValue(timelineCells);
            visibleItemsLive.postValue(visible);
            countsLive.postValue(new Counts(allCount, photoCount, videoCount));
            availableFoldersLive.postValue(folders);
            selectedFoldersLive.postValue(new LinkedHashSet<>(folderFilters));
            selectionModeLive.postValue(inSelection);
            selectedCountLive.postValue(selection.size());
            activeFiltersLive.postValue(hasActiveFilters(folderFilters, fav, ss, live, missingFilter, from, to, sort));
        });
    }

    private static boolean hasActiveFilters(
            @NonNull Set<String> folders,
            boolean favorites,
            boolean screenshots,
            boolean live,
            boolean missing,
            @Nullable Long from,
            @Nullable Long to,
            @NonNull SortOption sort
    ) {
        return !folders.isEmpty()
                || favorites
                || screenshots
                || live
                || missing
                || from != null
                || to != null
                || sort != SortOption.NEWEST;
    }

    private void hydrateCloudStatesLocked(@NonNull List<LocalMediaItem> items) {
        for (LocalMediaItem it : items) {
            LocalCloudCacheStore.Entry e = cloudCache.get(it.localId);
            if (e == null) continue;
            String fp = BackupIdUtil.fingerprint(it);
            if (!fp.equals(e.fingerprint)) continue;
            cloudStateByLocalId.put(it.localId, e.backedUp ? 1 : 0);
        }
    }

    private static void sortItems(@NonNull List<LocalMediaItem> items, @NonNull SortOption sort, int seed) {
        switch (sort) {
            case NEWEST:
                items.sort(Comparator.comparingLong((LocalMediaItem it) -> it.createdAtSec).reversed());
                break;
            case OLDEST:
                items.sort(Comparator.comparingLong(it -> it.createdAtSec));
                break;
            case LARGEST:
                items.sort(Comparator.comparingLong((LocalMediaItem it) -> it.sizeBytes).reversed());
                break;
            case RANDOM:
                Collections.shuffle(items, new Random(seed));
                break;
        }
    }

    private static boolean matchesAllFolders(@NonNull LocalMediaItem item, @NonNull Set<String> filters) {
        String path = item.folderPathNormalized();
        for (String filter : filters) {
            if (filter == null || filter.isEmpty()) continue;
            String f = filter.endsWith("/") ? filter : (filter + "/");
            String p = path.endsWith("/") ? path : (path + "/");
            if (!p.startsWith(f)) return false;
        }
        return true;
    }

    @NonNull
    private static List<TimelineAdapter.Cell> buildTimelineCells(
            @NonNull List<LocalMediaItem> items,
            boolean newestFirst,
            @NonNull Map<String, Integer> cloud
    ) {
        Map<String, List<LocalMediaItem>> monthMap = new HashMap<>();
        Map<String, List<LocalMediaItem>> dayMap = new HashMap<>();
        Map<Integer, Set<String>> yearToMonths = new HashMap<>();
        Map<String, Set<String>> monthToDays = new HashMap<>();

        Calendar cal = Calendar.getInstance();
        for (LocalMediaItem item : items) {
            long ts = item.createdAtSec > 0 ? item.createdAtSec : 0L;
            cal.setTimeInMillis(ts * 1000L);
            int y = cal.get(Calendar.YEAR);
            int m = cal.get(Calendar.MONTH) + 1;
            int d = cal.get(Calendar.DAY_OF_MONTH);
            String monthKey = String.format(Locale.US, "%04d-%02d", y, m);
            String dayKey = String.format(Locale.US, "%04d-%02d-%02d", y, m, d);

            yearToMonths.computeIfAbsent(y, k -> new LinkedHashSet<>()).add(monthKey);
            monthToDays.computeIfAbsent(monthKey, k -> new LinkedHashSet<>()).add(dayKey);
            monthMap.computeIfAbsent(monthKey, k -> new ArrayList<>()).add(item);
            dayMap.computeIfAbsent(dayKey, k -> new ArrayList<>()).add(item);
        }

        ArrayList<Integer> years = new ArrayList<>(yearToMonths.keySet());
        years.sort((a, b) -> newestFirst ? Integer.compare(b, a) : Integer.compare(a, b));

        ArrayList<TimelineAdapter.Cell> out = new ArrayList<>();
        for (Integer y : years) {
            out.add(TimelineAdapter.Cell.yearAnchor(y));
            ArrayList<String> months = new ArrayList<>(yearToMonths.get(y));
            months.sort((a, b) -> newestFirst ? b.compareTo(a) : a.compareTo(b));
            for (String monthKey : months) {
                long monthTs = parseMonthTs(monthKey);
                out.add(TimelineAdapter.Cell.monthHeader(TimelineAdapter.monthHeaderFor(monthTs), monthTs));

                ArrayList<String> days = new ArrayList<>(monthToDays.get(monthKey));
                days.sort((a, b) -> newestFirst ? b.compareTo(a) : a.compareTo(b));
                for (String dayKey : days) {
                    long dayTs = parseDayTs(dayKey);
                    out.add(TimelineAdapter.Cell.dayHeader(TimelineAdapter.dayHeaderFor(dayTs), dayTs));

                    ArrayList<LocalMediaItem> dayItems = new ArrayList<>(dayMap.get(dayKey));
                    dayItems.sort((a, b) -> newestFirst
                            ? Long.compare(b.createdAtSec, a.createdAtSec)
                            : Long.compare(a.createdAtSec, b.createdAtSec));
                    for (LocalMediaItem item : dayItems) {
                        Integer st = cloud.get(item.localId);
                        boolean cloudBacked = st != null && st == 1;
                        out.add(TimelineAdapter.Cell.photo(
                                item.localId,
                                item.isVideo,
                                false,
                                0,
                                item.uri,
                                item.createdAtSec,
                                item.durationMs,
                                cloudBacked
                        ));
                    }
                }
            }
        }
        return out;
    }

    private static long parseMonthTs(String monthKey) {
        try {
            Date d = new SimpleDateFormat("yyyy-MM", Locale.US).parse(monthKey);
            return d != null ? (d.getTime() / 1000L) : 0L;
        } catch (Exception ignored) {
            return 0L;
        }
    }

    private static long parseDayTs(String dayKey) {
        try {
            Date d = new SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(dayKey);
            return d != null ? (d.getTime() / 1000L) : 0L;
        } catch (Exception ignored) {
            return 0L;
        }
    }

    private void restorePrefs() {
        synchronized (lock) {
            sortOption = parseSort(prefs.getString(K_SORT, SortOption.NEWEST.name()));
            layoutOption = parseLayout(prefs.getString(K_LAYOUT, LayoutOption.GRID.name()));
            mediaType = parseMediaType(prefs.getString(K_MEDIA_TYPE, MediaType.ALL.name()));
            favoritesOnly = prefs.getBoolean(K_FAVORITES, false);
            filterScreenshots = prefs.getBoolean(K_FILTER_SS, false);
            filterLive = prefs.getBoolean(K_FILTER_LIVE, false);
            filterMissingCloud = prefs.getBoolean(K_FILTER_MISSING, false);
            long from = prefs.getLong(K_DATE_FROM, -1L);
            long to = prefs.getLong(K_DATE_TO, -1L);
            dateFromSec = from > 0 ? from : null;
            dateToSec = to > 0 ? to : null;
        }
    }

    private void persistPrefsLocked() {
        prefs.edit()
                .putString(K_SORT, sortOption.name())
                .putString(K_LAYOUT, layoutOption.name())
                .putString(K_MEDIA_TYPE, mediaType.name())
                .putBoolean(K_FAVORITES, favoritesOnly)
                .putBoolean(K_FILTER_SS, filterScreenshots)
                .putBoolean(K_FILTER_LIVE, filterLive)
                .putBoolean(K_FILTER_MISSING, filterMissingCloud)
                .putLong(K_DATE_FROM, dateFromSec != null ? dateFromSec : -1L)
                .putLong(K_DATE_TO, dateToSec != null ? dateToSec : -1L)
                .apply();
    }

    @NonNull
    private static SortOption parseSort(@Nullable String raw) {
        if (raw == null) return SortOption.NEWEST;
        try { return SortOption.valueOf(raw); } catch (Exception ignored) { return SortOption.NEWEST; }
    }

    @NonNull
    private static LayoutOption parseLayout(@Nullable String raw) {
        if (raw == null) return LayoutOption.GRID;
        try { return LayoutOption.valueOf(raw); } catch (Exception ignored) { return LayoutOption.GRID; }
    }

    @NonNull
    private static MediaType parseMediaType(@Nullable String raw) {
        if (raw == null) return MediaType.ALL;
        try { return MediaType.valueOf(raw); } catch (Exception ignored) { return MediaType.ALL; }
    }

    @NonNull
    public static String sortDisplay(@NonNull SortOption option) {
        switch (option) {
            case NEWEST: return "Newest First";
            case OLDEST: return "Oldest First";
            case LARGEST: return "Largest First";
            case RANDOM: return "Random";
            default: return "Sort";
        }
    }
}
