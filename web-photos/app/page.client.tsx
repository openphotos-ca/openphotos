'use client';
// Client-only home page implementation (moved from app/page.tsx)

import type React from 'react';
import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useRouter } from 'next/navigation';

import { Header } from '@/components/layout/Header';
import dynamic from 'next/dynamic';
const EEShareButton: any = dynamic(() => import('@ee/components/ShareButton'));
const EEInlineShareButton: any = dynamic(() => import('@ee/components/InlineShareButton'));
import { AlbumChips } from '@/components/AlbumChips';
import SafeBoundary from '@/components/utils/SafeBoundary';
import { MediaTypeSegment } from '@/components/MediaTypeSegment';
import { X, ArrowLeft, ArrowRight, Download as DownloadIcon, Play, Pause, Volume2, VolumeX, Copy as CopyIcon, Info as InfoIcon, Heart as HeartIcon, User as UserIcon, Lock as LockIcon, Folder as FolderIcon, Network as SitemapIcon, MoreVertical, TreePine } from 'lucide-react';
import AlbumBar from '@/components/albums/AlbumBar';
import AlbumPickerDialog from '@/components/albums/AlbumPickerDialog';
import { PhotoGrid } from '@/components/photos/PhotoGrid';
import TimelineView from '@/components/photos/TimelineView';
import { PinDialog } from '@/components/security/PinDialog';
import { SimilarGroups } from '@/components/similar/SimilarGroups';
import { SimilarVideoGroups } from '@/components/similar/SimilarVideoGroups';
// Replaced face-only filter with unified drawer and chips
import { FiltersDrawer } from '@/components/filters/FiltersDrawer';
import { ActiveFilterChips } from '@/components/ActiveFilterChips';
import ActiveFilterChipsFallback from '@/components/filters/ActiveFilterChipsFallback';
import { AuthenticatedImage } from '@/components/ui/AuthenticatedImage';
import { LivePhotoFullscreenOverlay } from '@/components/photos/LivePhotoFullscreenOverlay';
import { useAuthStore } from '@/lib/stores/auth';
import { photosApi } from '@/lib/api/photos';
import { apiClient } from '@/lib/api/client';
import { Photo, PhotoListQuery, SortOption, SortOrder, PhotoListResponse, Album } from '@/lib/types/photo';
import { useQueryState } from '@/hooks/useQueryState';
import UpdateFaceOverlay from '@/components/faces/UpdateFaceOverlay';
import { logger } from '@/lib/logger';
import { useToast } from '@/hooks/use-toast';

const PHOTOS_PER_PAGE_GRID = 100;
const PHOTOS_PER_PAGE_TIMELINE = 500;

// Small utility: Uint8Array -> hex string
function toHex(u8: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < u8.length; i++) hex += u8[i].toString(16).padStart(2, '0');
  return hex;
}

export default function HomePage() {
  const router = useRouter();
  const { toast } = useToast();
  const { isAuthenticated, token, hasHydrated, setHydrated } = useAuthStore();
  const queryClient = useQueryClient();
  const qs = useQueryState();

  // Guard: if layout=timeline but sort is not date-based, revert to grid
  useEffect(() => {
    const s = qs.state.sort;
    const isDate = s === 'newest' || s === 'oldest' || !s; // default is newest
    if (qs.state.layout === 'timeline' && !isDate) {
      try { qs.setLayout('grid'); } catch {}
    }
  }, [qs.state.layout, qs.state.sort]);
  
  // Fallback hydration mechanism - ensure hydration happens within 1 second
  useEffect(() => {
    if (!hasHydrated) {
      logger.debug('[HOMEPAGE] Hydration not complete after mount, setting fallback timer');
      const timer = setTimeout(() => {
        if (!useAuthStore.getState().hasHydrated) {
          logger.debug('[HOMEPAGE] Fallback hydration trigger after 1 second');
          setHydrated();
        }
      }, 1000);
      
      return () => clearTimeout(timer);
    }
  }, [hasHydrated, setHydrated]);
  
  // Wait for hydration and authenticated session before fetching data.
  // Do not require in-memory token here: same-origin cookie auth can be valid
  // on mobile while token hydration/refresh catches up.
  const isReadyForData = hasHydrated && isAuthenticated;
  logger.debug('[HOMEPAGE] Auth state:', {
    isAuthenticated,
    hasToken: !!token,
    tokenLength: token?.length || 0,
    hasHydrated,
    isReadyForData
  });

  // State
  const [selectedPhotos, setSelectedPhotos] = useState<string[]>([]);
  // Batch progress overlay state
  const [batchBusy, setBatchBusy] = useState(false);
  const [batchTitle, setBatchTitle] = useState<string>('');
  const [batchTotal, setBatchTotal] = useState<number>(0);
  const [batchDone, setBatchDone] = useState<number>(0);
  const [batchFailed, setBatchFailed] = useState<number>(0);
  const [batchCancel, setBatchCancel] = useState<boolean>(false);
  const [currentPage, setCurrentPage] = useState(1);
  const lastAppliedPageRef = useRef<number | null>(null);
  const [totalHint, setTotalHint] = useState<number | null>(null);
  const [allPhotos, setAllPhotos] = useState<Photo[]>([]);
  // Sort is now controlled solely by URL query state (qs.state.sort)
  const [showFilters, setShowFilters] = useState(false);
  // Locked-only is controlled via URL query state (qs.state.locked)
  const [pinStatus, setPinStatus] = useState<{ is_set: boolean; verified: boolean; verified_until?: number } | null>(null);
  // PIN modal state
  const [pinOpen, setPinOpen] = useState(false);
  const [pinMode, setPinMode] = useState<'verify' | 'set'>("verify");
  const pinResolverRef = useRef<((ok: boolean) => void) | null>(null);
  // Sidebar width for desktop split-pane (px)
  const [sidebarWidth, setSidebarWidth] = useState<number>(() => {
    if (typeof window !== 'undefined') {
      const saved = window.localStorage.getItem('filtersSidebarWidth');
      const n = saved ? parseInt(saved, 10) : NaN;
      if (!Number.isNaN(n)) return Math.min(520, Math.max(240, n));
    }
    return 320;
  });
  const [containerDimensions, setContainerDimensions] = useState({ width: 1200, height: 800 });
  const isDesktop = containerDimensions.width >= 768;
  const effectiveContainerWidth = Math.max(320, containerDimensions.width || 0);
  const effectiveContainerHeight = Math.max(320, containerDimensions.height || 0);
  const [viewerIndex, setViewerIndex] = useState<number | null>(null);
  // Zoom/Pan state for viewer
  const [zoom, setZoom] = useState(1);
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const [isPanning, setIsPanning] = useState(false);
  const panStart = useRef<{ x: number; y: number } | null>(null);
  const touchSwipeStart = useRef<{ x: number; time: number } | null>(null);
  const pinchStart = useRef<{ dist: number; center: { x: number; y: number }; zoom: number } | null>(null);
  const viewerContainerRef = useRef<HTMLDivElement | null>(null);
  const lastTapRef = useRef<{ x: number; y: number; time: number } | null>(null);
  const velocityRef = useRef<{ vx: number; vy: number }>({ vx: 0, vy: 0 });
  const momentumRaf = useRef<number | null>(null);
  // Scroll container ref for timeline layout
  const mainScrollRef = useRef<HTMLDivElement | null>(null);

  // Redirect to auth if not authenticated (but wait for hydration)
  useEffect(() => {
    if (hasHydrated && !isAuthenticated) {
      router.push('/auth');
    }
  }, [isAuthenticated, hasHydrated, router]);

  // Auth refresh logic is now centralized in AuthRefreshProvider

  // Load PIN status on mount
  useEffect(() => {
    (async () => { try { const st = await photosApi.getPinStatus(); setPinStatus(st as any); } catch {} })();
  }, []);

  

  // Locked-only changes are driven by URL state; no separate local toggle here.

  const ensurePinVerified = useCallback(async (): Promise<boolean> => {
    try {
      const st: any = await photosApi.getPinStatus();
      setPinStatus(st);
      if (!st?.is_set) {
        setPinMode('set');
      } else if (!st?.verified) {
        setPinMode('verify');
      } else {
        return true;
      }
      setPinOpen(true);
      const ok = await new Promise<boolean>((resolve) => { pinResolverRef.current = resolve; });
      if (!ok) return false;
      await new Promise((r) => setTimeout(r, 30));
      return true;
    } catch {
      return false;
    }
  }, []);

  // Query parameters
  const queryParams = useMemo<PhotoListQuery>(() => {
    const perPage = qs.state.layout === 'timeline' ? PHOTOS_PER_PAGE_TIMELINE : PHOTOS_PER_PAGE_GRID;
    const qp: PhotoListQuery = {
      page: currentPage,
      limit: perPage,
      // fallback defaults
      sort_by: 'created_at',
      sort_order: 'DESC',
    };
    if (currentPage > 1 && totalHint != null && totalHint > 0) {
      qp.total_hint = totalHint;
    }
    // Map URL query state into API filters
    const st = qs.state;
    if (st.q) qp.q = st.q;
    if (st.albums && st.albums.length) {
      (qp as any).album_ids = st.albums.join(',');
      (qp as any).album_subtree = st.albumSubtree === '1';
    } else if (st.album) {
      const n = Number(st.album);
      if (!Number.isNaN(n)) qp.album_id = n;
      // Always send explicit subtree boolean when an album is selected
      (qp as any).album_subtree = st.albumSubtree === '1';
    }
    if (st.favorite === '1') qp.filter_favorite = true;
    if (st.media === 'photo') qp.filter_is_video = false;
    if (st.media === 'video') qp.filter_is_video = true;
    if (st.faces?.length) {
      (qp as any).filter_faces = st.faces.join(',');
      if (st.facesMode === 'any') (qp as any).filter_faces_mode = 'any';
    }
    if (st.country) qp.filter_country = st.country;
    if (st.city) qp.filter_city = st.city;
    if (st.start) {
      // Start of range: epoch seconds at given date's midnight (browser parses YYYY-MM-DD as UTC)
      qp.filter_date_from = Math.floor(new Date(st.start).getTime() / 1000);
    }
    if (st.end) {
      // End of range: set to end-of-day (23:59:59) to make the UI inclusive
      const endBase = Math.floor(new Date(st.end).getTime() / 1000);
      qp.filter_date_to = endBase + 86_399; // include entire end day
    }
    if (st.type?.includes('screenshot')) {
      qp.filter_screenshot = true;
      qp.filter_is_video = false; // screenshots are photos
    }
    if (st.type?.includes('live')) {
      qp.filter_live_photo = true;
      qp.filter_is_video = false; // live photos are photos
    }
    if (st.rating) {
      const n = parseInt(st.rating, 10);
      if (!Number.isNaN(n) && n >= 1 && n <= 5) (qp as any).filter_rating_min = n;
    }
    if ((qs.state as any).locked === '1') {
      (qp as any).filter_locked_only = true;
      (qp as any).include_locked = true; // ensures backend PIN path
    }
    // Map sort from URL state
    switch (st.sort) {
      case 'newest':
        qp.sort_by = 'created_at';
        qp.sort_order = 'DESC';
        break;
      case 'oldest':
        qp.sort_by = 'created_at';
        qp.sort_order = 'ASC';
        break;
      case 'imported_newest':
        qp.sort_by = 'last_indexed' as any;
        qp.sort_order = 'DESC';
        break;
      case 'imported_oldest':
        qp.sort_by = 'last_indexed' as any;
        qp.sort_order = 'ASC';
        break;
      case 'largest':
        qp.sort_by = 'size';
        qp.sort_order = 'DESC';
        break;
      case 'random':
        // Backend will use seed for deterministic random ordering
        (qp as any).sort_by = 'random';
        (qp as any).sort_random_seed = st.seed ?? Math.floor(Math.random() * 1_000_000);
        break;
      default:
        break;
    }
    return qp;
  }, [currentPage, totalHint, qs.state]);

  // total_hint is a perf optimization only; exclude it from the query identity key.
  const queryKeyParams = useMemo(() => {
    const qp: any = { ...(queryParams as any) };
    delete qp.total_hint;
    return qp as PhotoListQuery;
  }, [queryParams]);

  // Fetch photos
  const {
    data: photoResponse,
    isLoading,
    error,
  } = useQuery<PhotoListResponse>({
    queryKey: ['photos', queryKeyParams],
    queryFn: () => {
      logger.debug('[HOMEPAGE] Executing photos query with params:', queryParams);
      return photosApi.getPhotos(queryParams);
    },
    // Only fetch when auth is fully ready to avoid caching empty results
    enabled: isReadyForData,
    staleTime: 1000, // Cache for only 1 second
  });

  logger.debug('[HOMEPAGE] Query state:', {
    isLoading,
    hasPhotoResponse: !!photoResponse,
    photoResponseKeys: photoResponse ? Object.keys(photoResponse) : [],
    photosLength: photoResponse?.photos?.length || 0,
    error: error?.message
  });

  // After auth + hydration, if we still have zero photos, poll backend count
  useEffect(() => {
    if (!isReadyForData) return;
    if (currentPage !== 1) return;
    const total = photoResponse?.total ?? 0;
    if (total > 0) return;

    let cancelled = false;
    let attempts = 0;
    const maxAttempts = 30;

    const pollCount = async () => {
      if (cancelled) return;
      try {
        try {
          const data = await apiClient.get<any>('/debug/photos-count');
          logger.debug('[HOMEPAGE] Debug photos-count:', { count: data.count, db: data.db_path, dbFile: data.db_file, sample0: data.sample_asset_ids?.[0] });
          if (typeof data.count === 'number' && data.count > 0) {
            // New data available: refetch photos and stop polling
            await queryClient.invalidateQueries({ queryKey: ['photos'] });
            await queryClient.refetchQueries({ queryKey: ['photos'] });
            return;
          }
        } catch (e: any) {
          const status = e?.status;
          if (status === 401) {
            logger.info('[HOMEPAGE] photos-count poll unauthorized; stopping');
            return;
          }
          throw e;
        }
      } catch (e) {
        logger.warn('[HOMEPAGE] photos-count poll error', e);
      }
      attempts += 1;
      if (attempts < maxAttempts) {
        setTimeout(pollCount, 1000);
      }
    };

    pollCount();
    return () => { cancelled = true; };
  }, [isReadyForData, currentPage, photoResponse?.total, queryClient]);

  // Search and face filtering are now handled via URL params and server-side filtering
  // New: Text search via Tantivy
  const isTextSearch = (qs.state.q || '').trim().length >= 2;
  const lockedOnly = (qs.state as any).locked === '1';
  const [searchAssetIds, setSearchAssetIds] = useState<string[] | null>(null);
  const [searchPhotos, setSearchPhotos] = useState<Photo[]>([]);
  const [searchMode, setSearchMode] = useState<'text'|'clip'|'all'|'none'>('none');
  const textResultsReady = searchAssetIds !== null; // completed at least one request
  const useTextResults = isTextSearch && textResultsReady && !lockedOnly;

  useEffect(() => {
    let cancelled = false;
    const run = async () => {
      if (!isTextSearch || lockedOnly) { setSearchAssetIds(null); setSearchPhotos([]); setSearchMode('none'); return; }
      const q = (qs.state.q || '').trim();
      try {
        const media = qs.state.media === 'photo' ? 'photos' : (qs.state.media === 'video' ? 'videos' : 'all');
        const locked = (qs.state as any).locked === '1' ? true : false;
        const mode = (qs.state as any).qmode || 'auto';
        if (mode === 'all') {
          const [textRes, semRes] = await Promise.all([
            photosApi.textSearch({ q, page: 1, limit: 200, media: media as any, locked, engine: 'text' }),
            photosApi.textSearch({ q, page: 1, limit: 200, media: media as any, locked, engine: 'semantic' }),
          ]);
          if (cancelled) return;
          const textIds = textRes.items.map(it => it.asset_id);
          const semIdsAll = semRes.items.map(it => it.asset_id);
          const semExtra = semIdsAll.filter(id => !textIds.includes(id));
          const ids = [...textIds, ...semExtra];
          setSearchMode('all');
          setSearchAssetIds(ids);
          if (ids.length) {
            const meta = await photosApi.getPhotosByAssetIds(ids);
            if (cancelled) return;
            const order = new Map(ids.map((id, i) => [id, i] as const));
            meta.sort((a, b) => (order.get(a.asset_id) ?? 1e9) - (order.get(b.asset_id) ?? 1e9));
            setSearchPhotos(meta);
          } else {
            setSearchPhotos([]);
          }
        } else if (mode === 'semantic') {
          const res = await photosApi.textSearch({ q, page: 1, limit: 200, media: media as any, locked, engine: 'semantic' });
          if (cancelled) return;
          setSearchMode('clip');
          const ids = res.items.map(it => it.asset_id);
          setSearchAssetIds(ids);
          const meta = ids.length ? await photosApi.getPhotosByAssetIds(ids) : [];
          if (cancelled) return;
          const order = new Map(ids.map((id, i) => [id, i] as const));
          meta.sort((a, b) => (order.get(a.asset_id) ?? 1e9) - (order.get(b.asset_id) ?? 1e9));
          setSearchPhotos(meta);
        } else if (mode === 'text') {
          const res = await photosApi.textSearch({ q, page: 1, limit: 200, media: media as any, locked, engine: 'text' });
          if (cancelled) return;
          setSearchMode('text');
          const ids = res.items.map(it => it.asset_id);
          setSearchAssetIds(ids);
          const meta = ids.length ? await photosApi.getPhotosByAssetIds(ids) : [];
          if (cancelled) return;
          const order = new Map(ids.map((id, i) => [id, i] as const));
          meta.sort((a, b) => (order.get(a.asset_id) ?? 1e9) - (order.get(b.asset_id) ?? 1e9));
          setSearchPhotos(meta);
        } else {
          // auto
          const res = await photosApi.textSearch({ q, page: 1, limit: 200, media: media as any, locked, engine: 'auto' });
          if (cancelled) return;
          setSearchMode(((res as any)?.mode === 'clip') ? 'clip' : 'text');
          const ids = res.items.map(it => it.asset_id);
          setSearchAssetIds(ids);
          const meta = ids.length ? await photosApi.getPhotosByAssetIds(ids) : [];
          if (cancelled) return;
          const order = new Map(ids.map((id, i) => [id, i] as const));
          meta.sort((a, b) => (order.get(a.asset_id) ?? 1e9) - (order.get(b.asset_id) ?? 1e9));
          setSearchPhotos(meta);
        }
      } catch (e) {
        logger.error('[SEARCH] text search failed', e);
        setSearchAssetIds(null);
        setSearchPhotos([]);
      }
    };
    run();
    return () => { cancelled = true; };
  }, [qs.state.q, qs.state.media, (qs.state as any).qmode, (qs.state as any).locked]);

  // Update photos when data changes
  useEffect(() => {
	  logger.debug('[HOMEPAGE] Photo response changed:', {
      hasPhotoResponse: !!photoResponse,
      currentPage,
      newPhotosCount: photoResponse?.photos?.length || 0,
      totalInResponse: photoResponse?.total || 0
  });
    if (useTextResults) {
      // Text search mode strictly shows ranked results, but only after results are ready
      setAllPhotos(searchPhotos);
      lastAppliedPageRef.current = null;
    } else if (photoResponse) {
      if (photoResponse.total != null && (totalHint == null || currentPage === 1)) {
        setTotalHint(photoResponse.total);
      }

      const lastApplied = lastAppliedPageRef.current;
      if (lastApplied === currentPage && currentPage !== 1) {
        // No-op: avoid clobbering already-appended pages on unrelated re-renders (e.g. totalHint updates).
        return;
      }

      const shouldAppend = lastApplied != null && currentPage === lastApplied + 1;
      if (!shouldAppend) {
        logger.debug('[HOMEPAGE] Setting all photos (page', currentPage, '):', photoResponse.photos.length);
        setAllPhotos(photoResponse.photos);
      } else {
        logger.debug('[HOMEPAGE] Appending photos (page', currentPage, '):', photoResponse.photos.length);
        setAllPhotos((prev) => [...prev, ...photoResponse.photos]);
      }
      lastAppliedPageRef.current = currentPage;
    }
  }, [photoResponse, currentPage, useTextResults, searchPhotos, totalHint]);

  // Handle container resize
  useEffect(() => {
    const updateDimensions = () => {
      const header = document.querySelector('header');
      const headerHeight = header ? (header as HTMLElement).offsetHeight : 64;
      const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
      const availableHeight = Math.max(320, Math.floor(viewportHeight - headerHeight));
      const availableWidth = Math.max(320, Math.floor(window.innerWidth));

      setContainerDimensions({
        width: availableWidth,
        height: availableHeight,
      });
    };

    updateDimensions();
    window.addEventListener('resize', updateDimensions);
    return () => window.removeEventListener('resize', updateDimensions);
  }, []);

  // Reset selection when photos change
  useEffect(() => {
    setSelectedPhotos([]);
  }, [allPhotos]);

  // Key representing the current "result set" (all filters/sort except pagination)
  // Used to reset pagination and virtualized scroll when filters change.
  const resultsKey = useMemo(() => {
    const st = qs.state;
    return [
      st.q || '',
      (st as any).qmode || '',
      st.favorite || '',
      st.album || '',
      (st.albums || []).join(','),
      st.albumSubtree || '',
      (st.faces || []).join(','),
      st.facesMode || '',
      st.media || '',
      (st.type || []).join(','),
      st.sort || '',
      String(st.seed ?? ''),
      st.layout || '',
      st.start || '',
      st.end || '',
      st.country || '',
      st.region || '',
      st.city || '',
      st.rating || '',
      (st as any).locked || '',
      (st as any).trash || '',
      st.view || '',
    ].join('|');
  }, [qs.state]);

  // Reset pagination when filters/sort change (keep current photos to avoid flicker)
  useEffect(() => {
    setCurrentPage(1);
    setSelectedPhotos([]);
    setTotalHint(null);
    lastAppliedPageRef.current = null;
    try { mainScrollRef.current?.scrollTo({ top: 0 }); } catch {}
  }, [resultsKey]);

  // Buckets should be keyed to the current filter set, not pagination.
  const bucketQueryParams = useMemo(() => {
    const qp: any = { ...(queryParams as any) };
    delete qp.page;
    delete qp.limit;
    return qp as Record<string, any>;
  }, [resultsKey]);

  // Event handlers
  const handleSearch = useCallback((query: string) => {
    qs.setQ(query);
    setCurrentPage(1);
    setSelectedPhotos([]);
  }, [qs]);

  const handleReindex = useCallback(() => {
    // Reset view
    setCurrentPage(1);
    setSelectedPhotos([]);
    // Clear all filters/search so we land back on the full photo grid
    qs.clearAllFilters();
    // Kick a single fresh fetch
    queryClient.invalidateQueries({ queryKey: ['photos'] });
    // Also refresh media counts so the segmented control updates
    try { queryClient.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); } catch {}
    setTimeout(() => queryClient.refetchQueries({ queryKey: ['photos'] }), 100);
  }, [queryClient, qs]);

  const handleRefreshPhotos = useCallback(async () => {
  logger.info('[HOMEPAGE] Refresh photos clicked');
    // Reset view state
    setCurrentPage(1);
    setSelectedPhotos([]);
    setTotalHint(null);
    lastAppliedPageRef.current = null;
    qs.setQ('');
    
    // Clear all cached data first
    await queryClient.invalidateQueries({ queryKey: ['photos'] });
    await queryClient.invalidateQueries({ queryKey: ['search'] });
    await queryClient.invalidateQueries({ queryKey: ['face-filter'] });
    await queryClient.invalidateQueries({ queryKey: ['albums'] });
    await queryClient.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' });
    
    // Wait a moment before refetching to avoid race conditions
    setTimeout(() => {
      queryClient.refetchQueries({ queryKey: ['photos'] });
      queryClient.refetchQueries({ queryKey: ['albums'] });
      queryClient.refetchQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' });
    }, 100);
  }, [queryClient]);

  // Sort changes are driven by query param; no local handler needed

  // Determine which photos to display
  const [viewerOverride, setViewerOverride] = useState<Photo[] | null>(null);
  const [viewerFromSimilar, setViewerFromSimilar] = useState<boolean>(false);
  const displayPhotos = useMemo(() => {
    const latestQueryPhotos = photoResponse?.photos ?? [];
    const base = viewerOverride ?? (allPhotos.length > 0 ? allPhotos : latestQueryPhotos);
    const lockedOnly = (qs.state as any).locked === '1';
    const isLocked = (p: Photo) => p.locked === true || (p as any).locked === 1 || (p as any).locked === '1';
    if (lockedOnly) return base.filter(isLocked);
    const unlocked = base.filter((p) => !isLocked(p));
    // Defensive fallback: if backend returns only locked entries while locked-only is off,
    // prefer showing the base result set rather than rendering an empty pane.
    if (unlocked.length === 0 && base.length > 0) return base;
    return unlocked;
  }, [viewerOverride, allPhotos, photoResponse?.photos, qs.state]);

  // Temporary runtime diagnostics for mobile blank-grid investigations.
  useEffect(() => {
    try {
      const snapshot = {
        isReadyForData,
        isLoading,
        currentPage,
        layout: qs.state.layout || 'grid',
        view: qs.state.view || 'library',
        media: qs.state.media || 'all',
        locked: (qs.state as any).locked || '0',
        responseTotal: photoResponse?.total ?? null,
        responsePhotosLen: photoResponse?.photos?.length ?? null,
        allPhotosLen: allPhotos.length,
        displayPhotosLen: displayPhotos.length,
        containerWidth: effectiveContainerWidth,
        containerHeight: effectiveContainerHeight,
      };
      console.log('[HOME_DEBUG] snapshot', snapshot);
      if ((photoResponse?.total ?? 0) > 0 && displayPhotos.length === 0) {
        console.warn('[HOME_DEBUG] non-zero total but empty displayPhotos', snapshot);
      }
    } catch {}
  }, [
    isReadyForData,
    isLoading,
    currentPage,
    qs.state.layout,
    qs.state.view,
    qs.state.media,
    (qs.state as any).locked,
    photoResponse?.total,
    photoResponse?.photos?.length,
    allPhotos.length,
    displayPhotos.length,
    effectiveContainerWidth,
    effectiveContainerHeight,
  ]);

  const handlePhotoClick = useCallback((photo: Photo) => {
    setViewerOverride(null); // ensure normal grid context
    setViewerFromSimilar(false);
    const idx = displayPhotos.findIndex(p => p.asset_id === photo.asset_id);
    setViewerIndex(idx >= 0 ? idx : 0);
    // Ensure panels are hidden on entry
    setShowInfo(false);
    setShowAlbumsOverlay(false);
    setShowAlbumPicker(false);
    if (typeof document !== 'undefined') {
      document.body.style.overflow = 'hidden';
    }
  }, [displayPhotos]);

  const closeViewer = useCallback(() => {
    setViewerIndex(null);
    setViewerOverride(null);
    setShowInfo(false);
    setShowAlbumsOverlay(false);
    setShowAlbumPicker(false);
    if (viewerFromSimilar) {
      try { qs.setView('similar'); } catch {}
      setViewerFromSimilar(false);
    }
    if (typeof document !== 'undefined') {
      document.body.style.overflow = '';
    }
  }, [viewerFromSimilar, qs]);

  // Launch viewer from Similar overlay
  const openViewerFromSimilar = useCallback((assetId: string, group: string[], index: number) => {
    // Build an override sequence from this group
    const seq: Photo[] = group.map(id => {
      const found = allPhotos.find(p => p.asset_id === id);
      if (found) return found;
      return {
        asset_id: id,
        id: undefined,
        path: '',
        filename: id,
        mime_type: 'image/jpeg',
        created_at: Math.floor(Date.now() / 1000),
        modified_at: Math.floor(Date.now() / 1000),
        size: 0,
        favorites: 0,
        is_video: false,
        is_live_photo: false,
        is_screenshot: 0,
      } as any;
    });
    setViewerOverride(seq);
    setViewerIndex(index >= 0 && index < seq.length ? index : 0);
    setViewerFromSimilar(true);
    qs.setView(undefined);
    setShowInfo(false);
    setShowAlbumsOverlay(false);
    setShowAlbumPicker(false);
    if (typeof document !== 'undefined') document.body.style.overflow = 'hidden';
  }, [allPhotos, qs]);

  // Close on Escape
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') closeViewer();
      if (e.key === 'ArrowLeft' && viewerIndex !== null) {
        setViewerIndex(i => (i !== null && i > 0 ? i - 1 : i));
      }
      if (e.key === 'ArrowRight' && viewerIndex !== null) {
        setViewerIndex(i => (i !== null && i < displayPhotos.length - 1 ? i + 1 : i));
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [closeViewer, viewerIndex, displayPhotos.length]);

  const viewerPhoto: Photo | null = useMemo(() => {
    if (viewerIndex === null) return null;
    return displayPhotos[viewerIndex] || null;
  }, [viewerIndex, displayPhotos]);

  const humanFileSize = (bytes?: number) => {
    const v = typeof bytes === 'number' ? bytes : 0;
    if (v < 1024) return `${v} B`;
    const units = ['KB', 'MB', 'GB', 'TB'];
    let p = v;
    let i = -1;
    do { p /= 1024; i++; } while (p >= 1024 && i < units.length - 1);
    const dp = p >= 100 ? 0 : 2;
    return `${p.toFixed(dp)} ${units[i]}`;
  };
  const currentIndexRef = useRef<number | null>(null);
  useEffect(() => { currentIndexRef.current = viewerIndex; }, [viewerIndex]);
  const videoViewerRef = useRef<HTMLVideoElement | null>(null);
  const [videoPaused, setVideoPaused] = useState(false);
  const [videoMuted, setVideoMuted] = useState(false);
  const [videoDuration, setVideoDuration] = useState(0);
  const [videoTime, setVideoTime] = useState(0);
  const [scrubbing, setScrubbing] = useState(false);
  const desiredSeekRef = useRef<number | null>(null);
  const [forcedIsVideo, setForcedIsVideo] = useState<boolean | null>(null);
  const [showInfo, setShowInfo] = useState(false);
  const [assetPersons, setAssetPersons] = useState<Array<{ person_id: string; display_name?: string; birth_date?: string }>>([]);
  const [viewerFavorite, setViewerFavorite] = useState<boolean>(false);
  const [showFaceUpdate, setShowFaceUpdate] = useState<boolean>(false);
  const [viewerAlbums, setViewerAlbums] = useState<Album[] | null>(null);
  // Use unified Album Picker dialog (same as homepage)
  const [showAlbumPicker, setShowAlbumPicker] = useState<boolean>(false);
  const [mobileActionsOpen, setMobileActionsOpen] = useState<boolean>(false);
  const [showAlbumsOverlay, setShowAlbumsOverlay] = useState<boolean>(false);
  const albumsBtnRef = useRef<HTMLButtonElement | null>(null);
  const [albumsOverlayPos, setAlbumsOverlayPos] = useState<{ top: number; left: number } | null>(null);
  // Client-measured dimensions for items where DB width/height are missing
  const [measuredDims, setMeasuredDims] = useState<Record<string, { w: number; h: number }>>({});
  // Albums list (for AlbumPickerDialog)
  const { data: allAlbums = [] } = useQuery({ queryKey: ['albums'], queryFn: () => photosApi.getAlbums(), staleTime: 60_000 });

  // Close Albums chips overlay when other dialogs/panels open
  useEffect(() => {
    if (showAlbumPicker || showInfo) setShowAlbumsOverlay(false);
  }, [showAlbumPicker, showInfo]);

  const fmtDate = useCallback((epoch?: number) => {
    if (!epoch || epoch <= 0) return '';
    try {
      const d = new Date(epoch * 1000);
      // Build EXIF-style date with timezone, e.g., 2025:09:13 16:16:59 +08:00
      const pad = (n: number, w = 2) => String(n).padStart(w, '0');
      const yyyy = d.getFullYear();
      const MM = pad(d.getMonth() + 1);
      const DD = pad(d.getDate());
      const hh = pad(d.getHours());
      const mm = pad(d.getMinutes());
      const ss = pad(d.getSeconds());
      // getTimezoneOffset returns minutes behind UTC (e.g., -480 for +08:00)
      const offMin = -d.getTimezoneOffset();
      const sign = offMin >= 0 ? '+' : '-';
      const absMin = Math.abs(offMin);
      const offH = pad(Math.floor(absMin / 60));
      const offM = pad(absMin % 60);
      return `${yyyy}:${MM}:${DD} ${hh}:${mm}:${ss} ${sign}${offH}:${offM}`;
    } catch { return String(epoch); }
  }, []);

  const copyToClipboard = useCallback(async (text?: string) => {
    if (!text) return;
    try { await navigator.clipboard.writeText(text); } catch {}
  }, []);

  // Decide media type on the fly for search results stubs by probing Content-Type
  useEffect(() => {
    let cancelled = false;
    setForcedIsVideo(null);
    const token = useAuthStore.getState().token;
    if (!viewerPhoto || !token) return;
    // If we already know it's a video, no need to probe
    if (viewerPhoto.is_video) { setForcedIsVideo(true); return; }
    (async () => {
      try {
        const res = await fetch(`/api/images/${encodeURIComponent(viewerPhoto.asset_id)}`, {
          method: 'HEAD',
          headers: { Authorization: `Bearer ${token}` },
        });
        const ct = res.headers.get('content-type') || '';
        if (!cancelled) setForcedIsVideo(ct.startsWith('video/'));
      } catch {
        if (!cancelled) setForcedIsVideo(viewerPhoto.is_video);
      }
    })();
    return () => { cancelled = true; };
  }, [viewerPhoto]);

  // When Info opens, load people and ensure EXIF metadata is populated.
  const metaRefreshed = useRef<Set<string>>(new Set());
  useEffect(() => {
    if (!showInfo || !viewerPhoto) return;
    (async () => {
      try {
        const people = await photosApi.getPersonsForAsset(viewerPhoto.asset_id);
        setAssetPersons(people as any);
      } catch { setAssetPersons([]); }

      // Auto-refresh metadata once per asset if key EXIF fields are missing
      try {
        const id = viewerPhoto.asset_id;
        if (!metaRefreshed.current.has(id)) {
          const missing = !(
            viewerPhoto.iso || viewerPhoto.aperture || viewerPhoto.shutter_speed || viewerPhoto.focal_length || viewerPhoto.camera_make || viewerPhoto.camera_model
          );
          if (missing) {
            const resp = await photosApi.refreshPhotoMetadata(id);
            // Merge refreshed fields back into grid data
            setAllPhotos(prev => prev.map(p => p.asset_id === id ? {
              ...p,
              camera_make: resp.camera_make ?? p.camera_make,
              camera_model: resp.camera_model ?? p.camera_model,
              iso: (resp.iso as any) ?? p.iso,
              aperture: (resp.aperture as any) ?? p.aperture,
              shutter_speed: (resp.shutter_speed as any) ?? p.shutter_speed,
              focal_length: (resp.focal_length as any) ?? p.focal_length,
              created_at: typeof resp.created_at === 'number' && resp.created_at > 0 ? resp.created_at : p.created_at,
              latitude: (resp.latitude as any) ?? p.latitude,
              longitude: (resp.longitude as any) ?? p.longitude,
              altitude: (resp.altitude as any) ?? p.altitude,
            } : p));
          }
        }
        metaRefreshed.current.add(viewerPhoto.asset_id);
      } catch {}

      // If width/height are 0 or missing, try to measure from the served image once
      try {
        const id = viewerPhoto.asset_id;
        const has = measuredDims[id];
        const needs = !(viewerPhoto.width && viewerPhoto.width > 0 && viewerPhoto.height && viewerPhoto.height > 0);
        if (!has && needs) {
          const url = photosApi.getImageUrl(id);
          const img = new Image();
          img.onload = () => {
            if (img.naturalWidth > 0 && img.naturalHeight > 0) {
              setMeasuredDims(prev => ({ ...prev, [id]: { w: img.naturalWidth, h: img.naturalHeight } }));
            }
          };
          img.onerror = () => {};
          img.src = url;
        }
      } catch {}
    })();
  }, [showInfo, viewerPhoto, measuredDims]);

  // Keep local favorite state in sync with current photo
  useEffect(() => {
    setViewerFavorite((viewerPhoto?.favorites || 0) > 0);
  }, [viewerPhoto]);

  // Caption/Description edit state
  const [captionInput, setCaptionInput] = useState<string>('');
  const [descriptionInput, setDescriptionInput] = useState<string>('');
  useEffect(() => {
    setCaptionInput(viewerPhoto?.caption || '');
    setDescriptionInput(viewerPhoto?.description || '');
  }, [viewerPhoto]);

  const saveCaption = useCallback(async () => {
    if (!viewerPhoto) return;
    const newVal = captionInput.trim();
    if ((viewerPhoto.caption || '') === newVal) return;
    try {
      await photosApi.updatePhotoMetadata(viewerPhoto.asset_id, { caption: newVal });
      setAllPhotos(prev => prev.map(p => p.asset_id === viewerPhoto.asset_id ? { ...p, caption: newVal } : p));
      toast({ title: 'Saved', description: 'Caption updated', variant: 'success' });
    } catch (e: any) {
      toast({ title: 'Save failed', description: e?.message || String(e), variant: 'destructive' });
    }
  }, [viewerPhoto, captionInput]);

  const saveDescription = useCallback(async () => {
    if (!viewerPhoto) return;
    const newVal = descriptionInput.trim();
    if ((viewerPhoto.description || '') === newVal) return;
    try {
      await photosApi.updatePhotoMetadata(viewerPhoto.asset_id, { description: newVal });
      setAllPhotos(prev => prev.map(p => p.asset_id === viewerPhoto.asset_id ? { ...p, description: newVal } : p));
      toast({ title: 'Saved', description: 'Description updated', variant: 'success' });
    } catch (e: any) {
      toast({ title: 'Save failed', description: e?.message || String(e), variant: 'destructive' });
    }
  }, [viewerPhoto, descriptionInput]);

  const toggleFavorite = useCallback(async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (!viewerPhoto) return;
    const next = !viewerFavorite;
    // optimistic UI
    setViewerFavorite(next);
    try {
      const resp = await photosApi.setFavorite(viewerPhoto.asset_id, next);
      const fv = (resp as any).favorites > 0;
      setViewerFavorite(fv);
      // Update in grid data
      setAllPhotos(prev => prev.map(p => p.asset_id === viewerPhoto.asset_id ? { ...p, favorites: fv ? 1 : 0 } : p));
      // Invalidate caches so segmented control and grid update
      try {
        await queryClient.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' });
        await queryClient.invalidateQueries({ queryKey: ['photos'] });
      } catch {}
    } catch (err) {
      // rollback
      setViewerFavorite(!next);
      logger.error('Failed to toggle favorite', err);
    }
  }, [viewerPhoto, viewerFavorite]);

  // Albums overlay helpers
  const openAlbumsOverlay = useCallback(async (e?: React.MouseEvent) => {
    if (e) { e.stopPropagation(); e.preventDefault(); }
    // Show overlay immediately; hydrate chips once loaded
    setShowAlbumsOverlay(true);
    // Position next to the Albums button
    try {
      const rect = albumsBtnRef.current?.getBoundingClientRect();
      if (rect) {
        setAlbumsOverlayPos({ top: Math.round(rect.top + rect.height / 2 - 20), left: Math.round(rect.right + 12) });
      } else {
        setAlbumsOverlayPos({ top: 140, left: 128 });
      }
    } catch { setAlbumsOverlayPos({ top: 140, left: 128 }); }
    if (!viewerPhoto?.id) { setViewerAlbums([]); return; }
    try {
      const albums = await photosApi.getPhotoAlbums(viewerPhoto.id);
      setViewerAlbums(albums as any);
    } catch {
      setViewerAlbums([]);
    }
  }, [viewerPhoto]);
  const closeAlbumsOverlay = useCallback((e?: React.MouseEvent) => { if (e) { e.stopPropagation(); e.preventDefault(); } setShowAlbumsOverlay(false); }, []);
  const removeAlbumChip = useCallback(async (albumId: number) => {
    if (!viewerPhoto?.id) return;
    try {
      await photosApi.removePhotosFromAlbum(albumId, [viewerPhoto.id]);
      setViewerAlbums(prev => (prev || []).filter(a => a.id !== albumId));
      try {
        await queryClient.invalidateQueries({ queryKey: ['albums'] });
        await queryClient.refetchQueries({ queryKey: ['albums'] });
        await queryClient.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' });
      } catch {}
    } catch (err) {
      logger.error('Failed to remove from album', err);
      toast({ title: 'Remove failed', description: err instanceof Error ? err.message : String(err), variant: 'destructive' });
    }
  }, [viewerPhoto]);

  const lockCurrentPhoto = useCallback(async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (!viewerPhoto) return;
    // Ensure UMK available
    const st = require('@/lib/stores/e2ee').useE2EEStore.getState();
    if (!st.umk) {
      alert('Unlock E2EE first (Header → Unlock or Settings → Security)');
      return;
    }
    try {
      const isVideo = viewerPhoto.is_video;
      // Fetch plaintext original
      const resp = await fetch(`/api/images/${encodeURIComponent(viewerPhoto.asset_id)}`);
      if (!resp.ok) throw new Error(`Fetch original failed: ${resp.status}`);
      let blob = await resp.blob();
      const { encryptV3WithWorker, fileToArrayBuffer, generateImageThumb, generateVideoThumb, umkToHex } = await import('@/lib/e2eeClient');
      const { maybeConvertHeicToJpeg } = await import('@/lib/heic');
      const umkHex = umkToHex();
      if (!umkHex) throw new Error('UMK not available');
      const user = require('@/lib/stores/auth').useAuthStore.getState().user;
      const userIdUtf8 = user?.user_id || '';
      // Convert HEIC → JPEG before encrypting, so the encrypted media is broadly viewable
      if (!isVideo && ((blob.type || '').toLowerCase().includes('heic') || (viewerPhoto?.filename||'').toLowerCase().endsWith('.heic') || (viewerPhoto?.mime_type||'').toLowerCase().includes('heic'))) {
        try {
          const conv = await maybeConvertHeicToJpeg(blob);
          if (conv.converted) blob = conv.blob;
        } catch {}
      }
      const bytes = await fileToArrayBuffer(blob);
      const lm = new Date(viewerPhoto.created_at * 1000);
      const y = lm.getUTCFullYear(); const m = String(lm.getUTCMonth()+1).padStart(2,'0'); const d = String(lm.getUTCDate()).padStart(2,'0');
      const metadata: any = {
        capture_ymd: `${y}-${m}-${d}`,
        size_kb: Math.max(1, Math.round(blob.size/1024)),
        width: viewerPhoto.width||0, height: viewerPhoto.height||0, orientation: viewerPhoto.orientation||1,
        is_video: isVideo ? 1 : 0, duration_s: Math.round((viewerPhoto.duration_ms||0)/1000), mime_hint: isVideo ? (viewerPhoto.mime_type || 'video/mp4') : 'image/jpeg',
        kind: 'orig',
      };
      if (viewerPhoto.created_at) { metadata.created_at = String(viewerPhoto.created_at); }
      // Apply optional locked metadata based on saved Security settings
      try {
        const allowLoc = (localStorage.getItem('lockedMeta.include_location')||'0') === '1';
        const allowCap = (localStorage.getItem('lockedMeta.include_caption')||'0') === '1';
        const allowDesc = (localStorage.getItem('lockedMeta.include_description')||'0') === '1';
        if (allowLoc) {
          if (viewerPhoto.latitude != null) metadata.latitude = String(viewerPhoto.latitude);
          if (viewerPhoto.longitude != null) metadata.longitude = String(viewerPhoto.longitude);
          if (viewerPhoto.altitude != null) metadata.altitude = String(viewerPhoto.altitude);
          if (viewerPhoto.location_name) metadata.location_name = viewerPhoto.location_name;
          if (viewerPhoto.city) metadata.city = viewerPhoto.city;
          if (viewerPhoto.province) metadata.province = viewerPhoto.province;
          if (viewerPhoto.country) metadata.country = viewerPhoto.country;
        }
        if (allowCap && viewerPhoto.caption) metadata.caption = viewerPhoto.caption;
        if (allowDesc && viewerPhoto.description) metadata.description = viewerPhoto.description;
      } catch {}
      const enc = await encryptV3WithWorker(umkHex, userIdUtf8, bytes, metadata, 1024*1024);
      // Generate encrypted thumbnail
      let tBlob: Blob | null = null;
      if (!isVideo) tBlob = await generateImageThumb(new File([blob], (viewerPhoto.filename || 'image.jpg')));
      else { try { tBlob = await generateVideoThumb(new File([blob], viewerPhoto.filename || 'v.mp4')); } catch {} }
      const tus = await import('tus-js-client');
      const headers = require('@/lib/stores/auth').useAuthStore.getState().token ? { Authorization: `Bearer ${require('@/lib/stores/auth').useAuthStore.getState().token}` } : undefined;
      if (tBlob) {
        const tBytes = await fileToArrayBuffer(tBlob);
        const tEnc = await encryptV3WithWorker(umkHex, userIdUtf8, tBytes, { ...metadata, kind: 'thumb' }, 256*1024);
        const upT = new tus.Upload(new Blob([tEnc.container]) as any, {
          endpoint: '/files/', chunkSize: 5*1024*1024, retryDelays: [0,1000,3000], headers,
          // Important: override to existing asset_id to avoid creating a duplicate row
          metadata: { locked: '1', crypto_version: '3', kind: 'thumb', asset_id_b58: viewerPhoto.asset_id, capture_ymd: metadata.capture_ymd, created_at: String(viewerPhoto.created_at||''), size_kb: String(Math.max(1, Math.round(tBlob.size/1024))), width: String(metadata.width), height: String(metadata.height), orientation: String(metadata.orientation), is_video: isVideo?'1':'0', duration_s: String(metadata.duration_s), mime_hint: 'image/jpeg' },
          onError: () => {}, onSuccess: () => {},
        }); upT.start();
      }
      const up = new tus.Upload(new Blob([enc.container]) as any, {
        endpoint: '/files/', chunkSize: 10*1024*1024, retryDelays: [0,1000,3000,5000], headers,
        // Important: override to existing asset_id to avoid creating a duplicate row
        metadata: (()=>{ const m:any = { locked: '1', crypto_version: '3', kind: 'orig', asset_id_b58: viewerPhoto.asset_id, capture_ymd: metadata.capture_ymd, created_at: String(viewerPhoto.created_at||''), size_kb: String(metadata.size_kb), width: String(metadata.width), height: String(metadata.height), orientation: String(metadata.orientation), is_video: isVideo?'1':'0', duration_s: String(metadata.duration_s), mime_hint: metadata.mime_hint };
          // Propagate optional metadata if present
          if (metadata.latitude) m.latitude = String(metadata.latitude);
          if (metadata.longitude) m.longitude = String(metadata.longitude);
          if (metadata.altitude) m.altitude = String(metadata.altitude);
          if (metadata.location_name) m.location_name = String(metadata.location_name);
          if (metadata.city) m.city = String(metadata.city);
          if (metadata.province) m.province = String(metadata.province);
          if (metadata.country) m.country = String(metadata.country);
          if (metadata.caption) m.caption = String(metadata.caption);
          if (metadata.description) m.description = String(metadata.description);
          return m; })(),
        onError: (err: Error) => { throw err; }, onSuccess: () => {},
      }); up.start();
      // Update local state
      setAllPhotos(prev => prev.map(p => p.asset_id === viewerPhoto.asset_id ? { ...p, locked: true } : p));
      try { await queryClient.invalidateQueries({ queryKey: ['photos'] }); await queryClient.invalidateQueries({ predicate: (q:any) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); } catch {}
    } catch (err) { logger.error('Failed to lock (encrypt/replace) photo', err); }
  }, [viewerPhoto, queryClient]);

  const unlockCurrentPhoto = useCallback(async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (!viewerPhoto) return;
    try {
      // Fetch encrypted original
      const resp = await fetch(`/api/images/${encodeURIComponent(viewerPhoto.asset_id)}`);
      if (!resp.ok) throw new Error(`Fetch encrypted failed: ${resp.status}`);
      const ab = await resp.arrayBuffer();
      // Ensure UMK
      const st = require('@/lib/stores/e2ee').useE2EEStore.getState();
      if (!st.umk) { alert('Unlock E2EE first'); return; }
      let hex = ''; for (let i=0;i<st.umk.length;i++) hex += st.umk[i].toString(16).padStart(2,'0');
      // @ts-ignore
      const worker = new Worker(new URL('../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
      const plain: ArrayBuffer = await new Promise((resolve, reject) => {
        worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind === 'v3-decrypted') { try{worker.terminate();}catch{}; resolve(d.container); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'decrypt failed')); } };
        worker.onerror = (er) => { try{worker.terminate();}catch{}; reject(er.error||new Error(String(er.message||er))); };
        worker.postMessage({ type: 'decrypt-v3', umkHex: hex, userIdUtf8: require('@/lib/stores/auth').useAuthStore.getState().user?.user_id || '', container: ab }, [ab]);
      });
      const blob = new Blob([plain]);
      const tus = await import('tus-js-client');
      const headers = require('@/lib/stores/auth').useAuthStore.getState().token ? { Authorization: `Bearer ${require('@/lib/stores/auth').useAuthStore.getState().token}` } : undefined;
      const up = new tus.Upload(blob as any, {
        endpoint: '/files/', chunkSize: 10*1024*1024, retryDelays: [0,1000,3000,5000], headers,
        metadata: { filename: viewerPhoto.filename || `${viewerPhoto.asset_id}`, replace: '1' },
        onError: (err: Error) => { throw err; }, onSuccess: () => {},
      }); up.start();
      setAllPhotos(prev => prev.map(p => p.asset_id === viewerPhoto.asset_id ? { ...p, locked: false } : p));
      try { await queryClient.invalidateQueries({ queryKey: ['photos'] }); await queryClient.invalidateQueries({ predicate: (q:any) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); } catch {}
    } catch (err) { logger.error('Failed to unlock (decrypt/replace) photo', err); }
  }, [viewerPhoto, queryClient]);

  // Try to start playback for videos when viewer opens
  useEffect(() => {
    if (!viewerPhoto) return;
    const isVid = (forcedIsVideo ?? viewerPhoto.is_video);
    if (!isVid) return;
    if (videoViewerRef.current) {
      videoViewerRef.current.play().then(() => setVideoPaused(false)).catch(() => setVideoPaused(true));
    }
  }, [viewerPhoto, forcedIsVideo]);

  const handlePrev = useCallback((e?: React.MouseEvent) => {
    if (e) { e.stopPropagation(); e.preventDefault(); }
    const i = currentIndexRef.current;
    if (i == null) return;
    const next = i > 0 ? i - 1 : i;
    if (next !== i) { setZoom(1); setOffset({ x: 0, y: 0 }); setViewerIndex(next); }
  }, []);

  const handleNext = useCallback((e?: React.MouseEvent) => {
    if (e) { e.stopPropagation(); e.preventDefault(); }
    const i = currentIndexRef.current;
    if (i == null) return;
    const next = i < displayPhotos.length - 1 ? i + 1 : i;
    if (next !== i) { setZoom(1); setOffset({ x: 0, y: 0 }); setViewerIndex(next); }
  }, [displayPhotos.length]);

  const handleDownload = useCallback(async (e?: React.MouseEvent) => {
    if (e) { e.stopPropagation(); e.preventDefault(); }
    if (!viewerPhoto || !token) return;
    try {
      const res = await fetch(`/api/images/${encodeURIComponent(viewerPhoto.asset_id)}`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) throw new Error(`Download failed: ${res.status}`);
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = viewerPhoto.filename || `${viewerPhoto.asset_id}.jpg`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      logger.error('Download error:', err);
    }
  }, [viewerPhoto, token]);

  // Reset zoom when closing viewer
  useEffect(() => {
    if (viewerIndex === null) {
      setZoom(1); setOffset({ x: 0, y: 0 });
    }
  }, [viewerIndex]);

  // Helpers
  const clamp = (v: number, min: number, max: number) => Math.max(min, Math.min(max, v));

  // Wheel zoom (desktop/trackpad)
  const onWheelZoom = useCallback((e: React.WheelEvent) => {
    if (!viewerPhoto) return;
    // Avoid preventDefault on wheel to not conflict with passive listeners.
    const factor = e.deltaY > 0 ? 0.9 : 1.1;
    setZoom((z) => clamp(z * factor, 1, 5));
  }, [viewerPhoto]);

  // Mouse pan (when zoom > 1)
  const onMouseDown = useCallback((e: React.MouseEvent) => {
    if (zoom <= 1) return;
    e.preventDefault();
    setIsPanning(true);
    panStart.current = { x: e.clientX - offset.x, y: e.clientY - offset.y };
  }, [zoom, offset.x, offset.y]);

  const onMouseMove = useCallback((e: React.MouseEvent) => {
    if (!isPanning || !panStart.current) return;
    e.preventDefault();
    const nx = e.clientX - panStart.current.x;
    const ny = e.clientY - panStart.current.y;
    setOffset(prev => {
      velocityRef.current.vx = nx - prev.x;
      velocityRef.current.vy = ny - prev.y;
      return { x: nx, y: ny };
    });
  }, [isPanning]);

  const onMouseUp = useCallback(() => {
    setIsPanning(false);
    panStart.current = null;
    // Momentum/inertia after pan
    if (zoom > 1) {
      const decay = 0.95;
      const step = () => {
        const { vx, vy } = velocityRef.current;
        if (Math.hypot(vx, vy) < 0.2 || viewerIndex === null) {
          if (momentumRaf.current) cancelAnimationFrame(momentumRaf.current);
          momentumRaf.current = null;
          return;
        }
        setOffset(prev => ({ x: prev.x + vx, y: prev.y + vy }));
        velocityRef.current.vx *= decay;
        velocityRef.current.vy *= decay;
        momentumRaf.current = requestAnimationFrame(step);
      };
      if (momentumRaf.current) cancelAnimationFrame(momentumRaf.current);
      momentumRaf.current = requestAnimationFrame(step);
    }
  }, [zoom, viewerIndex]);

  // Prefetch full-size images for current and upcoming items to speed navigation
  const prefetchFullMapRef = useRef<Map<string, string>>(new Map());
  const prefetchingRef = useRef<Set<string>>(new Set());
  const MAX_PREFETCH = 12;

  const prefetchFull = useCallback(async (assetId: string) => {
    if (!assetId) return;
    if (!token) return;
    if (prefetchFullMapRef.current.has(assetId) || prefetchingRef.current.has(assetId)) return;
    prefetchingRef.current.add(assetId);
    try {
      const res = await fetch(`/api/images/${encodeURIComponent(assetId)}`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) return;
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const map = prefetchFullMapRef.current;
      if (!map.has(assetId)) {
        if (map.size >= MAX_PREFETCH) {
          const firstKey = map.keys().next().value as string | undefined;
          if (firstKey) { const old = map.get(firstKey)!; try { URL.revokeObjectURL(old); } catch {} map.delete(firstKey); }
        }
        map.set(assetId, url);
      }
    } catch {}
    finally { prefetchingRef.current.delete(assetId); }
  }, [token]);

  useEffect(() => {
    const vp = viewerPhoto;
    if (!vp || !token) return;
    const idx = currentIndexRef.current ?? viewerIndex ?? 0;
    const ids: string[] = [];
    ids.push(vp.asset_id);
    if (idx + 1 < displayPhotos.length) ids.push(displayPhotos[idx + 1].asset_id);
    if (idx + 2 < displayPhotos.length) ids.push(displayPhotos[idx + 2].asset_id);
    ids.forEach((id) => prefetchFull(id));
  }, [viewerPhoto, viewerIndex, displayPhotos.length, token, prefetchFull]);

  // Touch handlers: swipe navigation when zoom==1; pan/pinch when zoom>1 or two fingers
  const getTouchDist = (t: React.TouchList) => {
    const dx = t[0].clientX - t[1].clientX;
    const dy = t[0].clientY - t[1].clientY;
    return Math.hypot(dx, dy);
  };
  const getTouchCenter = (t: React.TouchList) => ({ x: (t[0].clientX + t[1].clientX) / 2, y: (t[0].clientY + t[1].clientY) / 2 });

  const onTouchStart = useCallback((e: React.TouchEvent) => {
    if (e.touches.length === 2) {
      pinchStart.current = { dist: getTouchDist(e.touches), center: getTouchCenter(e.touches), zoom };
    } else if (e.touches.length === 1) {
      if (zoom > 1) {
        panStart.current = { x: e.touches[0].clientX - offset.x, y: e.touches[0].clientY - offset.y };
        setIsPanning(true);
      } else {
        const now = Date.now();
        const x = e.touches[0].clientX;
        const y = e.touches[0].clientY;
        // Double-tap toggle zoom
        if (lastTapRef.current && (now - lastTapRef.current.time) < 300 && Math.hypot(x - lastTapRef.current.x, y - lastTapRef.current.y) < 25) {
            const targetZoom = zoom > 1 ? 1 : 2;
            const rect = viewerContainerRef.current?.getBoundingClientRect();
            if (rect) {
              const px = x - rect.left;
              const py = y - rect.top;
              setOffset(prev => {
                const s = targetZoom / zoom;
                return { x: (1 - s) * px + s * prev.x, y: (1 - s) * py + s * prev.y };
              });
            }
            setZoom(targetZoom);
            lastTapRef.current = null;
        } else {
            lastTapRef.current = { x, y, time: now };
            touchSwipeStart.current = { x, time: now };
        }
      }
    }
  }, [zoom, offset.x, offset.y]);

  const onTouchMove = useCallback((e: React.TouchEvent) => {
    if (e.touches.length === 2 && pinchStart.current) {
      // Do not call preventDefault on touchmove; instead rely on CSS touch-action.
      const ratio = getTouchDist(e.touches) / pinchStart.current.dist;
      setZoom((z) => clamp(pinchStart.current!.zoom * ratio, 1, 5));
    } else if (e.touches.length === 1 && isPanning && panStart.current) {
      // Do not call preventDefault on touchmove; instead rely on CSS touch-action.
      setOffset({ x: e.touches[0].clientX - panStart.current.x, y: e.touches[0].clientY - panStart.current.y });
    }
  }, [isPanning]);

  const onTouchEnd = useCallback((e: React.TouchEvent) => {
    if (pinchStart.current && e.touches.length < 2) {
      pinchStart.current = null;
    }
    if (isPanning && e.touches.length === 0) {
      setIsPanning(false);
      panStart.current = null;
    }
    if (zoom === 1 && touchSwipeStart.current) {
      const dx = (touchSwipeStart.current.x - (e.changedTouches[0]?.clientX ?? touchSwipeStart.current.x));
      const dt = Date.now() - touchSwipeStart.current.time;
      touchSwipeStart.current = null;
      if (Math.abs(dx) > 50 && dt < 600) {
        if (dx > 0) {
          // swipe left -> next
          setViewerIndex(i => (i !== null && i < displayPhotos.length - 1 ? (setZoom(1), setOffset({ x:0,y:0 }), (i + 1)) : i));
        } else {
          // swipe right -> prev
          setViewerIndex(i => (i !== null && i > 0 ? (setZoom(1), setOffset({ x:0,y:0 }), (i - 1)) : i));
        }
      }
    }
  }, [zoom, displayPhotos.length]);

  const handlePhotoSelect = useCallback((assetId: string, selected: boolean) => {
    setSelectedPhotos(prev => 
      selected 
        ? [...prev, assetId]
        : prev.filter(id => id !== assetId)
    );
  }, []);

  const handleSelectAll = useCallback(() => {
    // Select all currently loaded photos (server applies any search/filter)
    setSelectedPhotos(allPhotos.map(p => p.asset_id));
  }, [allPhotos]);

  const handleSelectNone = useCallback(() => {
    setSelectedPhotos([]);
  }, []);

  const handleLoadMore = useCallback(() => {
    if (!isLoading && photoResponse?.has_more) {
      setCurrentPage(prev => prev + 1);
    }
  }, [isLoading, photoResponse?.has_more]);

  const handleJumpToPage = useCallback(async (page: number) => {
    if (useTextResults) return;
    const p = Math.max(1, Math.floor(page));
    logger.warn('[TimelineJump] jumpToPage requested', {
      page: p,
      perPage: PHOTOS_PER_PAGE_TIMELINE,
      resultsKey,
    });
    lastAppliedPageRef.current = null;
    setSelectedPhotos([]);
    setCurrentPage(p);
    try { mainScrollRef.current?.scrollTo({ top: 0, behavior: 'auto' }); } catch {}
  }, [useTextResults, resultsKey]);

  // Show loading while waiting for hydration or if not authenticated
  if (!hasHydrated || !isAuthenticated) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
        <span className="ml-2 text-muted-foreground">
          {!hasHydrated ? 'Loading...' : 'Authenticating...'}
        </span>
      </div>
    );
}

// Right-side drawer for Album Tree with attach/detach and create/rename
function AlbumTreePanel({ onClose, photoId }: { onClose: ()=>void; photoId?: number }) {
  const [albums, setAlbums] = useState<Album[]>([]);
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);
  const { toast } = useToast();
  useEffect(() => {
    (async () => {
      try { setLoading(true); const res = await photosApi.getAlbums(); setAlbums(res as any); setError(null); }
      catch (e:any) { setError(e?.message || String(e)); }
      finally { setLoading(false); }
    })();
  }, []);

  const tree = useMemo(() => buildAlbumTree(albums), [albums]);
  const refreshAlbums = useCallback(async () => {
    try { const res = await photosApi.getAlbums(); setAlbums(res as any); } catch {}
  }, []);

  return (
    <div className="absolute right-0 top-0 bottom-0 w-[340px] bg-card/95 border-l border-border z-[75] shadow-lg pointer-events-auto" onClick={(e)=>e.stopPropagation()}>
      <div className="flex items-center justify-between p-3 border-b border-border">
        <div className="font-medium">Album Tree</div>
        <button className="p-1 hover:bg-muted rounded" onClick={onClose} aria-label="Close" title="Close"><X className="w-4 h-4"/></button>
      </div>
      <div className="p-3 space-y-2 overflow-auto h-full">
        {loading ? <div className="text-sm text-muted-foreground">Loading...</div> : error ? <div className="text-sm text-destructive">{error}</div> : (
          <AlbumTreeNodes nodes={tree} photoId={photoId} refreshAlbums={refreshAlbums} toast={toast} />
        )}
      </div>
    </div>
  );
}

type TreeNode = Album & { children: TreeNode[] };
function buildAlbumTree(albums: Album[]): TreeNode[] {
  const idMap = new Map<number, TreeNode>();
  albums.forEach(a => idMap.set(a.id, { ...a, children: [] }));
  const roots: TreeNode[] = [];
  for (const a of albums) {
    const node = idMap.get(a.id)!;
    if (a.parent_id == null) roots.push(node); else {
      const p = idMap.get(a.parent_id); if (p) p.children.push(node); else roots.push(node);
    }
  }
  const sort = (nodes: TreeNode[]) => { nodes.sort((a,b)=>(a.position??0)-(b.position??0) || (b.updated_at-a.updated_at)); nodes.forEach(n=>sort(n.children)); };
  sort(roots);
  return roots;
}

function AlbumTreeNodes({ nodes, photoId, refreshAlbums, toast }: { nodes: TreeNode[]; photoId?: number; refreshAlbums: ()=>Promise<void>|void; toast: (arg: any)=>void }) {
  const [creatingUnder, setCreatingUnder] = useState<number | null>(null);
  const [creatingName, setCreatingName] = useState<string>('');
  const [renamingId, setRenamingId] = useState<number | null>(null);
  const [renamingName, setRenamingName] = useState<string>('');

  return (
    <ul className="space-y-1">
      {nodes.map(n => (
        <li key={n.id}>
          <div className="flex items-center gap-2">
            <FolderIcon className="w-4 h-4"/>
            {renamingId === n.id ? (
              <input className="px-1 py-0.5 border border-border rounded bg-background text-sm" value={renamingName} onChange={e=>setRenamingName(e.target.value)} onKeyDown={async (e)=>{ if (e.key==='Enter') { try { await photosApi.updateAlbum(n.id, { name: renamingName.trim() }); setRenamingId(null); await refreshAlbums(); } catch(err:any){ toast({ title: 'Rename failed', description: err?.message||String(err), variant: 'destructive' }); } }} } />
            ) : (
              <span title={n.name} className="truncate max-w-[18ch]">{n.name}</span>
            )}
            <div className="ml-auto flex items-center gap-1">
              {photoId && (
                <>
                  <button className="px-2 py-1 text-xs border border-border rounded hover:bg-muted" title="Attach photo" onClick={async()=>{ try { await photosApi.addPhotosToAlbum(n.id, [photoId]); try { await queryClient.invalidateQueries({ queryKey: ['albums'] }); await queryClient.refetchQueries({ queryKey: ['albums'] }); await queryClient.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); } catch {} toast({ title: 'Attached', description: `Added to ${n.name}`, variant: 'success' }); } catch(e:any){ toast({ title: 'Attach failed', description: e?.message||String(e), variant: 'destructive' }); } }}>
                    +
                  </button>
                  <button className="px-2 py-1 text-xs border border-border rounded hover:bg-muted" title="Detach photo" onClick={async()=>{ try { await photosApi.removePhotosFromAlbum(n.id, [photoId]); try { await queryClient.invalidateQueries({ queryKey: ['albums'] }); await queryClient.refetchQueries({ queryKey: ['albums'] }); await queryClient.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' }); } catch {} toast({ title: 'Removed', description: `Removed from ${n.name}`, variant: 'success' }); } catch(e:any){ toast({ title: 'Remove failed', description: e?.message||String(e), variant: 'destructive' }); } }}>
                    ×
                  </button>
                </>
              )}
              <button className="px-2 py-1 text-xs border border-border rounded hover:bg-muted" title="Rename" onClick={()=>{ setRenamingId(n.id); setRenamingName(n.name); }}>
                Ren
              </button>
              <button className="px-2 py-1 text-xs border border-border rounded hover:bg-muted" title="New album under this" onClick={()=>{ setCreatingUnder(n.id); }}>
                New
              </button>
            </div>
          </div>
          {creatingUnder === n.id && (
            <div className="pl-6 flex items-center gap-2 mt-1">
              <input className="px-1 py-0.5 border border-border rounded bg-background text-sm" placeholder="Album name" value={creatingName} onChange={e=>setCreatingName(e.target.value)} />
              <button className="px-2 py-1 text-xs border border-border rounded hover:bg-muted" onClick={async()=>{ try { await photosApi.createAlbum({ name: creatingName.trim(), parent_id: n.id }); setCreatingUnder(null); setCreatingName(''); await refreshAlbums(); } catch(e:any){ toast({ title: 'Create failed', description: e?.message||String(e), variant: 'destructive' }); } }}>Create</button>
              <button className="px-2 py-1 text-xs border border-border rounded hover:bg-muted" onClick={()=>{ setCreatingUnder(null); setCreatingName(''); }}>Cancel</button>
            </div>
          )}
          {n.children.length > 0 && (
            <div className="pl-5 mt-1"><AlbumTreeNodes nodes={n.children} photoId={photoId} refreshAlbums={refreshAlbums} toast={toast} /></div>
          )}
        </li>
      ))}
    </ul>
  );
}
  return (
    <div className="min-h-screen bg-background">
      <Header
        onSearch={handleSearch}
        onReindex={handleReindex}
        onRefreshPhotos={handleRefreshPhotos}
        
        onFilterToggle={() => setShowFilters(!showFilters)}
        selectedCount={selectedPhotos.length}
        onSelectAll={handleSelectAll}
        onSelectNone={handleSelectNone}
        onBulkLock={async () => {
          // Batch lock selected (encrypt) — skips already-locked
          const { encryptV3WithWorker, fileToArrayBuffer, generateImageThumb, generateVideoThumb, umkToHex } = await import('@/lib/e2eeClient');
          const st = require('@/lib/stores/e2ee').useE2EEStore.getState();
          const token = require('@/lib/stores/auth').useAuthStore.getState().token;
          const userIdUtf8 = require('@/lib/stores/auth').useAuthStore.getState().user?.user_id || '';
          const umkHex = st.umk ? toHex(st.umk) : null;
          const tus = await import('tus-js-client');
          const hdrs = token ? { Authorization: `Bearer ${token}` } : undefined;
          if (!umkHex) { alert('Unlock E2EE first to lock selected items'); return; }
          const toLock = selectedPhotos.filter(aid => {
            const p = allPhotos.find(x => x.asset_id === aid) || displayPhotos.find(x => x.asset_id === aid);
            return p && !p.locked;
          });
          const tasks = toLock.map(aid => async () => {
            const p = allPhotos.find(x => x.asset_id === aid) || displayPhotos.find(x => x.asset_id === aid);
            if (!p) return;
            const resp = await fetch(`/api/images/${encodeURIComponent(aid)}`);
            if (!resp.ok) throw new Error(`Fetch failed ${resp.status}`);
            const blob = await resp.blob();
            const bytes = await fileToArrayBuffer(blob);
            const lm = new Date((p.created_at||p.modified_at)*1000);
            const y = lm.getUTCFullYear(); const m = String(lm.getUTCMonth()+1).padStart(2,'0'); const d = String(lm.getUTCDate()).padStart(2,'0');
            const meta: any = { capture_ymd: `${y}-${m}-${d}`, size_kb: Math.max(1, Math.round(blob.size/1024)), width: p.width||0, height: p.height||0, orientation: p.orientation||1, is_video: p.is_video?1:0, duration_s: Math.round((p.duration_ms||0)/1000), mime_hint: p.mime_type || (p.is_video?'video/mp4':'image/jpeg'), kind: 'orig' };
            const enc = await encryptV3WithWorker(umkHex!, userIdUtf8, bytes, meta, 1024*1024);
            let tBlob: Blob|null = null;
            if (!p.is_video) tBlob = await generateImageThumb(new File([blob], p.filename || 'f'));
            else { try { tBlob = await generateVideoThumb(new File([blob], p.filename || 'v.mp4')); } catch {} }
            if (tBlob) {
              const tEnc = await encryptV3WithWorker(umkHex!, userIdUtf8, await fileToArrayBuffer(tBlob), { ...meta, kind: 'thumb' }, 256*1024);
              await new Promise<void>(res=>{ const upT = new tus.Upload(new Blob([tEnc.container]) as any, { endpoint: '/files/', chunkSize: 5*1024*1024, retryDelays:[0,1000,3000], headers: hdrs, metadata: { locked:'1', crypto_version:'3', kind:'thumb', asset_id_b58: p.asset_id, capture_ymd: meta.capture_ymd, size_kb: String(Math.max(1, Math.round((tBlob as Blob).size/1024))), width:String(meta.width), height:String(meta.height), orientation:String(meta.orientation), is_video: p.is_video?'1':'0', duration_s:String(meta.duration_s), mime_hint: 'image/jpeg' }, onError:()=>res(), onSuccess:()=>res() }); upT.start(); });
            }
            await new Promise<void>((res, rej)=>{ const up = new tus.Upload(new Blob([enc.container]) as any, { endpoint:'/files/', chunkSize:10*1024*1024, retryDelays:[0,1000,3000,5000], headers: hdrs, metadata: { locked:'1', crypto_version:'3', kind:'orig', asset_id_b58: p.asset_id, capture_ymd: meta.capture_ymd, size_kb:String(meta.size_kb), width:String(meta.width), height:String(meta.height), orientation:String(meta.orientation), is_video:p.is_video?'1':'0', duration_s:String(meta.duration_s), mime_hint: meta.mime_hint }, onError:(e:Error)=>rej(e), onSuccess:()=>res() }); up.start(); });
            setAllPhotos(prev => prev.map(q => q.asset_id === aid ? { ...q, locked: true } : q));
          });
          let ok = 0, fail = 0;
          const limit = 2;
          const queue = tasks.slice();
          const runNext = async (): Promise<void> => {
            const fn = queue.shift();
            if (!fn) return;
            try { await fn(); ok++; } catch { fail++; }
            await runNext();
          };
          await Promise.all(Array.from({ length: Math.min(limit, tasks.length) }, () => runNext()));
          try { await queryClient.invalidateQueries({ queryKey: ['photos'] }); await queryClient.invalidateQueries({ predicate: (q:any)=>Array.isArray(q.queryKey)&&q.queryKey[0]==='media-counts' }); } catch {}
          toast({ title: 'Batch Lock', description: `${ok} locked, ${fail} failed`, variant: fail ? 'destructive' : 'success' });
        }}
        onBulkUnlock={async () => {
          // Batch unlock selected (decrypt) — skips already-unlocked
          const st = require('@/lib/stores/e2ee').useE2EEStore.getState();
          const token = require('@/lib/stores/auth').useAuthStore.getState().token;
          const userIdUtf8 = require('@/lib/stores/auth').useAuthStore.getState().user?.user_id || '';
          const umkHex = st.umk ? toHex(st.umk) : null;
          if (!umkHex) { alert('Unlock E2EE first to unlock selected items'); return; }
          const tus = await import('tus-js-client');
          const hdrs = token ? { Authorization: `Bearer ${token}` } : undefined;
          const toUnlock = selectedPhotos.filter(aid => {
            const p = allPhotos.find(x => x.asset_id === aid) || displayPhotos.find(x => x.asset_id === aid);
            return p && p.locked;
          });
          let ok = 0, fail = 0;
          const tasks = toUnlock.map(aid => async () => {
            const p = allPhotos.find(x => x.asset_id === aid) || displayPhotos.find(x => x.asset_id === aid);
            if (!p) return;
            const resp = await fetch(`/api/images/${encodeURIComponent(aid)}`);
            if (!resp.ok) throw new Error(`Fetch encrypted failed ${resp.status}`);
            const ab = await resp.arrayBuffer();
            // @ts-ignore
            const worker = new Worker(new URL('../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
            const plain: ArrayBuffer = await new Promise((resolve, reject) => {
              worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind === 'v3-decrypted') { try{worker.terminate();}catch{}; resolve(d.container); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'decrypt failed')); } };
              worker.onerror = (er) => { try{worker.terminate();}catch{}; reject(er.error||new Error(String(er.message||er))); };
              worker.postMessage({ type: 'decrypt-v3', umkHex, userIdUtf8, container: ab }, [ab]);
            });
            await new Promise<void>((res, rej)=>{ const up = new tus.Upload(new Blob([plain]) as any, { endpoint:'/files/', chunkSize:10*1024*1024, retryDelays:[0,1000,3000,5000], headers: hdrs, metadata: { filename: p.filename || aid, replace:'1' }, onError:(e:Error)=>rej(e), onSuccess:()=>res() }); up.start(); });
            setAllPhotos(prev => prev.map(q => q.asset_id === aid ? { ...q, locked: false } : q));
          });
          const limit = 2;
          const queue = tasks.slice();
          const runNext = async (): Promise<void> => {
            const fn = queue.shift();
            if (!fn) return;
            try { await fn(); ok++; } catch { fail++; }
            await runNext();
          };
          await Promise.all(Array.from({ length: Math.min(limit, tasks.length) }, () => runNext()));
          try { await queryClient.invalidateQueries({ queryKey: ['photos'] }); await queryClient.invalidateQueries({ predicate: (q:any)=>Array.isArray(q.queryKey)&&q.queryKey[0]==='media-counts' }); } catch {}
          toast({ title: 'Batch Unlock', description: `${ok} unlocked, ${fail} failed`, variant: fail ? 'destructive' : 'success' });
        }}
        isLoading={isLoading}
      />
      {/* Album chips row (isolated to avoid whole-page crash if something fails) */}
      <SafeBoundary name="AlbumChips" fallback={null}>
        <AlbumChips onOpenFilters={() => setShowFilters(!showFilters)} />
      </SafeBoundary>
      {/* Media segmented control */}
      <MediaTypeSegment />
      {/* Locked-only + text search note */}
      {(lockedOnly && isTextSearch) ? (
        <div className="px-4 sm:px-6 lg:px-8 py-2 text-sm text-muted-foreground">
          Text search is disabled for locked items.
        </div>
      ) : null}

      {/* Mobile drawer only */}
      <div className="md:hidden">
        <FiltersDrawer open={showFilters} onClose={() => setShowFilters(false)} />
      </div>

      {/* Split pane on desktop */}
      <div className="flex" style={{ height: effectiveContainerHeight }}>
        {isDesktop && showFilters && (
          <>
            <FiltersDrawer open={true} onClose={() => setShowFilters(false)} inline inlineWidth={sidebarWidth} />
            {/* Drag handle */}
            <div
              role="separator"
              aria-orientation="vertical"
              title="Resize filters panel"
              onMouseDown={(e) => {
                e.preventDefault();
                const startX = e.clientX;
                const startW = sidebarWidth;
                let latest = startW;
                const onMove = (ev: MouseEvent) => {
                  const dx = ev.clientX - startX;
                  latest = Math.min(520, Math.max(240, startW + dx));
                  setSidebarWidth(latest);
                };
                const onUp = () => {
                  document.removeEventListener('mousemove', onMove);
                  document.removeEventListener('mouseup', onUp);
                  try { window.localStorage.setItem('filtersSidebarWidth', String(latest)); } catch {}
                };
                document.addEventListener('mousemove', onMove);
                document.addEventListener('mouseup', onUp);
              }}
              className="w-1.5 cursor-col-resize bg-border hover:bg-primary/40"
              style={{ userSelect: 'none' }}
            />
          </>
        )}
        {/* Right pane */}
        <main ref={mainScrollRef} className="flex-1 overflow-y-auto">
          {/* Active filters & album chips row; guard with a fallback that keeps controls visible */}
          <SafeBoundary name="ActiveFilterChips" fallback={<ActiveFilterChipsFallback /> }>
            <ActiveFilterChips />
          </SafeBoundary>
          {/* Results mode banner */}
          <div className="px-2 pb-2 flex items-center gap-2 flex-wrap">
            {useTextResults ? (
              <div className="text-xs text-muted-foreground bg-muted/40 border border-border rounded px-2 py-1 inline-flex items-center gap-2">
                <span>{(qs.state as any).qmode === 'all' ? 'Showing all results for' : (searchMode === 'clip' ? 'Showing semantic results for' : 'Showing text results for')}</span>
                <span className="px-1.5 py-0.5 rounded bg-card border border-border text-foreground">{(qs.state.q || '').trim()}</span>
              </div>
            ) : (
              <div className="text-xs text-muted-foreground bg-muted/40 border border-border rounded px-2 py-1 inline-flex items-center">
                Showing library results
              </div>
            )}

            {/* Search mode tabs */}
            {isTextSearch && (
              <div className="ml-2 inline-flex border border-border rounded overflow-hidden text-xs">
                {[
                  {k:'auto', label:'Auto'},
                  {k:'all', label:'All'},
                  {k:'semantic', label:'Semantic'},
                  {k:'text', label:'Text'},
                ].map((opt) => (
                  <button
                    key={opt.k}
                    type="button"
                    className={`px-2 py-1 ${((qs.state as any).qmode||'auto')===opt.k ? 'bg-primary text-primary-foreground' : 'bg-card text-foreground hover:bg-muted'} border-r border-border last:border-r-0`}
                    onClick={() => {
                      try { (qs as any).setQMode(opt.k as any); } catch {}
                    }}
                    aria-pressed={((qs.state as any).qmode||'auto')===opt.k}
                  >{opt.label}</button>
                ))}
              </div>
            )}
          </div>
        {qs.state.view === 'similar' ? (
          <div className="max-w-6xl mx-auto">
            <SimilarGroups />
            <SimilarVideoGroups />
          </div>
        ) : error ? (
          <div className="flex items-center justify-center h-64">
            <div className="text-center">
              <div className="text-red-500 text-6xl mb-4">⚠️</div>
              <h3 className="text-lg font-medium text-foreground mb-2">Error loading photos</h3>
              <p className="text-sm text-muted-foreground mb-4">
                {error instanceof Error ? error.message : 'Something went wrong'}
              </p>
              <button
                onClick={() => queryClient.invalidateQueries({ queryKey: ['photos'] })}
                className="px-4 py-2 bg-primary text-primary-foreground rounded-md hover:bg-primary/90"
              >
                Try again
              </button>
            </div>
          </div>
        ) : (
          <>
            {qs.state.layout === 'timeline' ? (
              <div className="px-2">
                <TimelineView
                  photos={displayPhotos}
                  selectedPhotos={selectedPhotos}
                  onPhotoClick={handlePhotoClick}
                  onPhotoSelect={handlePhotoSelect}
                  onLoadMore={handleLoadMore}
                  onJumpToPage={handleJumpToPage}
                  perPage={PHOTOS_PER_PAGE_TIMELINE}
                  hasMore={useTextResults ? false : (photoResponse?.has_more)}
                  isLoading={isLoading}
                  scrollContainerRef={mainScrollRef as any}
                  bucketQuery={bucketQueryParams}
                  bucketKey={resultsKey}
                />
              </div>
            ) : (
              <PhotoGrid
                key={resultsKey}
                photos={displayPhotos}
                selectedPhotos={selectedPhotos}
                onPhotoClick={handlePhotoClick}
                onPhotoSelect={handlePhotoSelect}
                onLoadMore={handleLoadMore}
                hasMore={useTextResults ? false : (photoResponse?.has_more)}
                isLoading={isLoading}
                containerWidth={effectiveContainerWidth - (isDesktop && showFilters ? sidebarWidth : 0)}
                containerHeight={effectiveContainerHeight}
              />
            )}
          </>
        )}

        {/* Fullscreen viewer */}
        {viewerPhoto && (
          <>
          <div className="fullscreen-viewer" onClick={closeViewer}
               onTouchStart={onTouchStart} onTouchMove={onTouchMove} onTouchEnd={onTouchEnd}>
            {/* Left arrow */}
            {viewerIndex !== null && viewerIndex > 0 && (
              <button
                className="absolute left-[76px] top-1/2 -translate-y-1/2 bg-card/80 text-foreground p-3 rounded-full hover:bg-card z-[70] pointer-events-auto outline-none focus:outline-none focus:ring-0"
                onClick={handlePrev}
                aria-label="Previous"
              >
                <ArrowLeft className="w-5 h-5" />
              </button>
            )}

            {/* Right arrow */}
            {viewerIndex !== null && viewerIndex < displayPhotos.length - 1 && (
              <button
                className="absolute right-5 top-1/2 -translate-y-1/2 bg-card/80 text-foreground p-3 rounded-full hover:bg-card z-[70] pointer-events-auto outline-none focus:outline-none focus:ring-0"
                onClick={handleNext}
                aria-label="Next"
              >
                <ArrowRight className="w-5 h-5" />
              </button>
            )}

            {/* Back (icon-only) and Mobile More toggle */}
            <div className="absolute top-4 left-[10px] z-50 flex items-center gap-2">
              <button
                className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card"
                onClick={(e) => { e.stopPropagation(); closeViewer(); }}
                aria-label="Close"
                title="Close"
              >
                <X className="w-5 h-5" />
              </button>
              <button
                className="md:hidden bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card"
                onClick={(e) => { e.stopPropagation(); setMobileActionsOpen(v => !v); }}
                aria-label="More"
                title="More"
              >
                <MoreVertical className="w-5 h-5" />
              </button>
            </div>

            {/* Left vertical toolbar (desktop) */}
            <div className="hidden md:flex fixed left-0 top-0 bottom-0 z-[200] w-14 flex-col items-center gap-3 pt-16 pb-6 bg-transparent pointer-events-auto">
              <div className="flex flex-col gap-3 pointer-events-auto">
                <button className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card" onClick={(e)=>{ e.stopPropagation(); setShowInfo(v=>!v); }} title="Info" aria-label="Info"><InfoIcon className="w-5 h-5"/></button>
                <button className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card" onClick={(e)=>{ e.stopPropagation(); toggleFavorite(e); }} title="Favorite" aria-label="Favorite"><HeartIcon className={`w-5 h-5 ${viewerFavorite ? 'text-red-600 [&>path]:fill-red-600 [&>path]:stroke-red-600' : ''}`} /></button>
                <button className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card" onClick={(e)=>{ e.stopPropagation(); setShowFaceUpdate(true); }} title="Update Person" aria-label="Update Person"><UserIcon className="w-5 h-5"/></button>
                <button className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card" onClick={(e)=>{ e.stopPropagation(); viewerPhoto.locked ? unlockCurrentPhoto(e) : lockCurrentPhoto(e); }} title={viewerPhoto.locked ? 'Unlock' : 'Lock'} aria-label={viewerPhoto.locked ? 'Unlock' : 'Lock'}>
                  <LockIcon className={`w-5 h-5 ${viewerPhoto.locked ? 'text-yellow-500' : ''}`} />
                </button>
                <button className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card" onClick={(e)=>{ e.stopPropagation(); handleDownload(e); }} title="Download" aria-label="Download"><DownloadIcon className="w-5 h-5"/></button>
                {/* Reinstate Albums button to open chips list */}
                <button ref={albumsBtnRef} className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card" onClick={(e)=>{ e.stopPropagation(); if (showAlbumsOverlay) { setShowAlbumsOverlay(false); } else { openAlbumsOverlay(e); } }} title="Albums" aria-label="Albums"><FolderIcon className="w-5 h-5"/></button>
                {/* Album Tree (same dialog as homepage) */}
                <button className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card" onClick={(e)=>{ e.stopPropagation(); setShowAlbumPicker(true); }} title="Album Tree" aria-label="Album Tree"><TreePine className="w-5 h-5"/></button>
                {/* EE Share button (item-level) */}
                <div className="pointer-events-auto">
                  <EEInlineShareButton assetId={viewerPhoto.asset_id} filename={viewerPhoto.filename} className="bg-card/80 text-foreground border border-border p-2 rounded-full hover:bg-card" />
                </div>
              </div>
            </div>

            {/* Mobile actions popover */}
            {mobileActionsOpen && (
              <div className="md:hidden absolute top-14 left-4 z-[65] bg-card/95 border border-border rounded shadow-lg p-2 flex flex-col gap-2 pointer-events-auto" onClick={(e)=>e.stopPropagation()}>
                <button className="flex items-center px-2 py-1 rounded hover:bg-muted text-sm" onClick={() => { setShowInfo(v=>!v); setMobileActionsOpen(false); }} title="Info" aria-label="Info"><InfoIcon className="w-4 h-4 mr-2"/>Info</button>
                <button className="flex items-center px-2 py-1 rounded hover:bg-muted text-sm" onClick={(e:any) => { toggleFavorite(e); setMobileActionsOpen(false); }} title="Favorite" aria-label="Favorite"><HeartIcon className="w-4 h-4 mr-2"/>Favorite</button>
                <button className="flex items-center px-2 py-1 rounded hover:bg-muted text-sm" onClick={() => { setShowFaceUpdate(true); setMobileActionsOpen(false); }} title="Update Person" aria-label="Update Person"><UserIcon className="w-4 h-4 mr-2"/>Update Person</button>
                <button className="flex items-center px-2 py-1 rounded hover:bg-muted text-sm" onClick={(e:any) => { viewerPhoto.locked ? unlockCurrentPhoto(e) : lockCurrentPhoto(e); setMobileActionsOpen(false); }} title={viewerPhoto.locked ? 'Unlock' : 'Lock'} aria-label={viewerPhoto.locked ? 'Unlock' : 'Lock'}><LockIcon className="w-4 h-4 mr-2"/>{viewerPhoto.locked ? 'Unlock' : 'Lock'}</button>
                <button className="flex items-center px-2 py-1 rounded hover:bg-muted text-sm" onClick={(e:any) => { handleDownload(e); setMobileActionsOpen(false); }} title="Download" aria-label="Download"><DownloadIcon className="w-4 h-4 mr-2"/>Download</button>
                <button className="flex items-center px-2 py-1 rounded hover:bg-muted text-sm" onClick={() => { openAlbumsOverlay(); setMobileActionsOpen(false); }} title="Albums" aria-label="Albums"><FolderIcon className="w-4 h-4 mr-2"/>Albums</button>
                <button className="flex items-center px-2 py-1 rounded hover:bg-muted text-sm" onClick={() => { setShowAlbumPicker(true); setMobileActionsOpen(false); }} title="Album Tree" aria-label="Album Tree"><SitemapIcon className="w-4 h-4 mr-2"/>Album Tree</button>
              </div>
            )}

            {/* Download handled in top toolbar */}

            {/* Media container */}
            <div ref={viewerContainerRef} onClick={(e) => e.stopPropagation()}
                 onWheel={onWheelZoom}
                 onMouseDown={onMouseDown}
                 onMouseMove={onMouseMove}
                 onMouseUp={onMouseUp}
                 onMouseLeave={onMouseUp}
                 onDoubleClick={(e) => {
                   e.stopPropagation();
                   const rect = (e.currentTarget as HTMLDivElement).getBoundingClientRect();
                   const px = e.clientX - rect.left;
                   const py = e.clientY - rect.top;
                   const targetZoom = zoom > 1 ? 1 : 2;
                   setOffset(prev => {
                     const s = targetZoom / zoom;
                     return { x: (1 - s) * px + s * prev.x, y: (1 - s) * py + s * prev.y };
                   });
                   setZoom(targetZoom);
                 }}
                 style={{
                   cursor: zoom > 1 ? (isPanning ? 'grabbing' : 'grab') : 'default',
                   position: 'absolute',
                   top: 0,
                   left: 0,
                   right: 0,
                   bottom: 0,
                   display: 'flex',
                   alignItems: 'center',
                   justifyContent: 'center',
                   // Fullscreen content with no reserved bottom space
                   // Prevent browser-native touch panning/zooming so we can manage it ourselves
                   touchAction: 'none',
                   // Prevent scroll chaining to any parents while interacting
                   overscrollBehavior: 'contain',
                 }}>
              {(forcedIsVideo ?? viewerPhoto.is_video) ? (
                <video
                  ref={videoViewerRef}
                  className="block"
                  src={`/api/images/${encodeURIComponent(viewerPhoto.asset_id)}`}
                  poster={`/api/thumbnails/${encodeURIComponent(viewerPhoto.asset_id)}`}
                  playsInline
                  preload="metadata"
                  controls={false}
                  style={{ maxHeight: '100vh', maxWidth: '90vw', objectFit: 'contain' }}
                  onClick={(e) => e.stopPropagation()}
                  onPlay={() => setVideoPaused(false)}
                  onPause={() => setVideoPaused(true)}
                  onLoadedMetadata={(e) => { try { setVideoDuration(e.currentTarget.duration || 0); } catch {} }}
                  onTimeUpdate={(e) => {
                    try {
                      const t = e.currentTarget.currentTime || 0;
                      if (desiredSeekRef.current != null) {
                        const d = Math.abs(t - desiredSeekRef.current);
                        if (d < 0.2) { desiredSeekRef.current = null; }
                      }
                      if (!scrubbing) setVideoTime(t);
                    } catch {}
                  }}
                  onPlaying={(e) => {
                    try {
                      const want = desiredSeekRef.current;
                      if (want != null) {
                        e.currentTarget.currentTime = want;
                        desiredSeekRef.current = null;
                      }
                    } catch {}
                  }}
                />
              ) : (
                <AuthenticatedImage
                  key={viewerPhoto.asset_id}
                  assetId={viewerPhoto.asset_id}
                  alt={viewerPhoto.filename}
                  variant="original"
                  progressive={!(((viewerPhoto?.mime_type || '').toLowerCase().includes('image/avif')) || ((viewerPhoto?.filename || '').toLowerCase().endsWith('.avif')))}
                  prefetchFullUrl={prefetchFullMapRef.current.get(viewerPhoto.asset_id) || undefined}
                  className="fullscreen-image"
                  style={{ transform: `translate3d(${offset.x}px, ${offset.y}px, 0) scale(${zoom})`, transition: isPanning ? 'none' : 'transform 0.05s linear' }}
                />
              )}
              {viewerPhoto.is_live_photo && !(forcedIsVideo ?? viewerPhoto.is_video) && (
                <LivePhotoFullscreenOverlay assetId={viewerPhoto.asset_id} />
              )}
              {(forcedIsVideo ?? viewerPhoto.is_video) && (
                <div className="absolute left-1/2 -translate-x-1/2 flex items-center gap-3 z-[80] pointer-events-auto" style={{ bottom: '50px' }}>
                  <button
                    className="bg-card/80 text-foreground border border-border p-2 rounded-full flex items-center justify-center hover:bg-card"
                    onClick={(e) => {
                      e.stopPropagation();
                      const vid = videoViewerRef.current;
                      if (!vid) return;
                      if (videoPaused) {
                        try { vid.currentTime = Math.min(Math.max(0, videoTime), videoDuration || Infinity); } catch {}
                        vid.play().catch(() => {});
                      } else {
                        vid.pause();
                      }
                    }}
                    aria-label={videoPaused ? 'Play' : 'Pause'}
                    title={videoPaused ? 'Play' : 'Pause'}
                  >
                    {videoPaused ? <Play className="w-5 h-5" /> : <Pause className="w-5 h-5" />}
                  </button>
                  <button
                    className="bg-card/80 text-foreground border border-border p-2 rounded-full flex items-center justify-center hover:bg-card"
                    onClick={(e) => { e.stopPropagation(); if (!videoViewerRef.current) return; videoViewerRef.current.muted = !videoViewerRef.current.muted; setVideoMuted(videoViewerRef.current.muted); }}
                    aria-label={videoMuted ? 'Unmute' : 'Mute'}
                    title={videoMuted ? 'Unmute' : 'Mute'}
                  >
                    {videoMuted ? <VolumeX className="w-5 h-5" /> : <Volume2 className="w-5 h-5" />}
                  </button>
                </div>
              )}

              {(forcedIsVideo ?? viewerPhoto.is_video) && (
                <div
                  className="absolute left-1/2 -translate-x-1/2 z-[90] w-[60vw] max-w-[900px] pointer-events-auto"
                  style={{ bottom: '20px' }}
                  onClick={(e) => e.stopPropagation()}
                  onMouseDown={(e) => { e.stopPropagation(); setScrubbing(true); if (videoViewerRef.current) { try { videoViewerRef.current.pause(); } catch {} } }}
                  onMouseUp={(e) => { e.stopPropagation(); setScrubbing(false); if (videoViewerRef.current) { try { videoViewerRef.current.currentTime = videoTime; } catch {} } }}
                  onTouchStart={(e) => { e.stopPropagation(); setScrubbing(true); }}
                  onTouchEnd={(e) => { e.stopPropagation(); setScrubbing(false); if (videoViewerRef.current) { try { videoViewerRef.current.currentTime = videoTime; } catch {} } }}
                  onPointerDown={(e) => { e.stopPropagation(); setScrubbing(true); }}
                  onPointerUp={(e) => { e.stopPropagation(); setScrubbing(false); if (videoViewerRef.current) { try { videoViewerRef.current.currentTime = videoTime; } catch {} } }}
                >
                  {(() => { const sliderMax = videoDuration > 0 ? videoDuration : Math.max(videoTime, 0.01); return (
                  <input
                    type="range"
                    min={0}
                    max={sliderMax}
                    step={0.01}
                    value={Math.min(sliderMax, Math.max(0, videoTime))}
                    style={{ touchAction: 'manipulation' }}
                    onChange={(e) => {
                      const t = Number(e.target.value);
                      setVideoTime(t);
                      if (videoViewerRef.current) {
                        try { videoViewerRef.current.currentTime = t; } catch {}
                      }
                    }}
                    onInput={(e) => {
                      const t = Number((e.target as HTMLInputElement).value);
                      setVideoTime(t);
                      if (videoViewerRef.current) {
                        try { videoViewerRef.current.currentTime = t; } catch {}
                      }
                    }}
                    onMouseDown={() => setScrubbing(true)}
                    onMouseUp={() => setScrubbing(false)}
                    onTouchStart={() => setScrubbing(true)}
                    onTouchEnd={() => setScrubbing(false)}
                    onPointerDown={() => setScrubbing(true)}
                    onPointerUp={() => setScrubbing(false)}
                    className="w-full accent-primary"
                    aria-label="Seek video"
                  /> ); })()}
                </div>
              )}
            </div>
          </div>
          {/* Album bar removed to allow full-height media */}
          {/* Albums chips overlay (list of chips with close button) */}
          {showAlbumsOverlay && (
            <div
              className="fixed z-[85] bg-card border border-border rounded shadow-lg p-2 flex flex-wrap gap-2 max-w-[90vw] pointer-events-auto"
              style={{ top: (albumsOverlayPos?.top ?? 140) + 'px', left: (albumsOverlayPos?.left ?? 128) + 'px' }}
              onClick={(e) => e.stopPropagation()}
            >
              {(viewerAlbums || []).length === 0 ? (
                <div className="text-sm text-muted-foreground px-2 py-1">No albums</div>
              ) : (
                (viewerAlbums || []).map((a) => (
                  <span key={a.id} className="relative inline-flex items-center gap-2 rounded-full px-3 py-1 pr-7 text-sm shadow-sm bg-green-600 text-white">
                    <span className="max-w-[16rem] truncate" title={a.name}>{a.name || `Album #${a.id}`}</span>
                    <button
                      className="absolute -top-1 -right-1 w-5 h-5 rounded-full bg-white text-black hover:opacity-90 flex items-center justify-center shadow"
                      onClick={(e) => { e.stopPropagation(); removeAlbumChip(a.id); }}
                      aria-label="Remove from album"
                      title="Remove from album"
                    >
                      <X className="w-3 h-3" />
                    </button>
                  </span>
                ))
              )}
            </div>
          )}
          {/* Panel backdrop scrim (captures click to close panel) */}
          <div
            className={`fixed inset-0 z-[55] bg-background/60 transition-opacity duration-300 ${showInfo ? 'opacity-100' : 'opacity-0 pointer-events-none'}`}
            onClick={(e) => { e.stopPropagation(); setShowInfo(false); }}
          />
          {/* Slide-in Info panel (animated, aligned to left toolbar) */}
          <div
            className={`absolute top-0 left-14 w-80 h-full bg-card/95 backdrop-blur border-r border-border shadow-2xl z-[61] overflow-y-auto transform transition-transform duration-300 will-change-transform ${showInfo ? 'translate-x-0' : '-translate-x-[calc(100%+56px)] pointer-events-none'}`}
            onClick={(e) => e.stopPropagation()}
          >
              <div className="p-4 border-b font-semibold">
                <span>Info</span>
              </div>
              <div className="p-4 space-y-4 text-sm">
                <div>
                  <div className="text-muted-foreground">File Name</div>
                  <div className="flex items-center gap-2">
                    <span className="truncate" title={viewerPhoto.filename}>{viewerPhoto.filename}</span>
                    <button className="text-muted-foreground hover:text-foreground" title="Copy filename" onClick={(e)=>{e.stopPropagation(); copyToClipboard(viewerPhoto.filename);}}>
                      <CopyIcon className="w-4 h-4" />
                    </button>
                  </div>
                  <div className="text-muted-foreground">Size</div>
                  <div>{humanFileSize(viewerPhoto.size)}</div>
                  <div className="text-muted-foreground mt-2">Asset ID</div>
                  <div className="flex items-center gap-2">
                    <span className="truncate" title={viewerPhoto.asset_id}>{viewerPhoto.asset_id}</span>
                    <button className="text-muted-foreground hover:text-foreground" title="Copy asset id" onClick={(e)=>{e.stopPropagation(); copyToClipboard(viewerPhoto.asset_id);}}>
                      <CopyIcon className="w-4 h-4" />
                    </button>
                  </div>
                </div>
                <div>
                  <div className="text-muted-foreground">Dimensions</div>
                  <div>
                    {(() => {
                      const dim = measuredDims[viewerPhoto.asset_id];
                      const w = (viewerPhoto.width && viewerPhoto.width > 0) ? viewerPhoto.width : dim?.w;
                      const h = (viewerPhoto.height && viewerPhoto.height > 0) ? viewerPhoto.height : dim?.h;
                      return w && h ? `${w} × ${h}` : '—';
                    })()}
                  </div>
                </div>
                <div>
                  <div className="text-muted-foreground">Camera</div>
                  <div>{(viewerPhoto.camera_make || viewerPhoto.camera_model) ? `${viewerPhoto.camera_make ?? ''} ${viewerPhoto.camera_model ?? ''}`.trim() : '—'}</div>
                  <div>{viewerPhoto.iso ? `ISO ${viewerPhoto.iso}` : 'ISO —'}</div>
                  <div>
                    {viewerPhoto.aperture ? `Aperture f/${viewerPhoto.aperture}` : 'Aperture —'}{' '}
                    {viewerPhoto.shutter_speed ? `Shutter ${viewerPhoto.shutter_speed}` : 'Shutter —'}{' '}
                    {viewerPhoto.focal_length ? `Focal ${viewerPhoto.focal_length}mm` : 'Focal —'}
                  </div>
                </div>
                <div>
                  <div className="text-muted-foreground">Dates</div>
                  <div>Taken {fmtDate(viewerPhoto.created_at || viewerPhoto.modified_at)}</div>
                  <div>Modified {fmtDate(viewerPhoto.modified_at)}</div>
                </div>
                <div>
                  <div className="text-muted-foreground">Location</div>
                  <div>
                    {viewerPhoto.location_name || [viewerPhoto.city, viewerPhoto.province, viewerPhoto.country].filter(Boolean).join(', ') || '—'}
                  </div>
                </div>
                <div>
                  <div className="text-muted-foreground">Caption</div>
                  <input
                    type="text"
                    className="w-full px-2 py-1 rounded border border-border bg-background/60 focus:outline-none focus:ring-1 focus:ring-primary"
                    placeholder="Add a caption"
                    value={captionInput}
                    onChange={(e) => setCaptionInput(e.target.value)}
                    onBlur={(e) => { e.stopPropagation(); saveCaption(); }}
                    onKeyDown={(e) => { if (e.key === 'Enter') { (e.target as HTMLInputElement).blur(); } }}
                  />
                </div>
                <div>
                  <div className="text-muted-foreground">Description</div>
                  <textarea
                    className="w-full px-2 py-1 rounded border border-border bg-background/60 focus:outline-none focus:ring-1 focus:ring-primary min-h-[64px] resize-vertical"
                    placeholder="Add a description"
                    value={descriptionInput}
                    onChange={(e) => setDescriptionInput(e.target.value)}
                    onBlur={(e) => { e.stopPropagation(); saveDescription(); }}
                  />
                </div>
                <div>
                  <div className="text-muted-foreground">People</div>
                  {assetPersons.length === 0 ? (
                    <div className="text-muted-foreground">No people detected</div>
                  ) : (
                    <ul className="space-y-1">
                      {assetPersons.map(p => (
                        <li key={p.person_id} className="flex items-center justify-between">
                          <span>{p.display_name || p.person_id}</span>
                          {p.birth_date && <span className="text-muted-foreground">{p.birth_date}</span>}
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              </div>
          </div>
          {/* Album Picker dialog (same as homepage) */}
          <AlbumPickerDialog
            open={showAlbumPicker}
            albums={allAlbums}
            showIncludeSubtree={false}
            onClose={() => setShowAlbumPicker(false)}
            onConfirm={(albumId) => {
              setShowAlbumPicker(false);
              if (!viewerPhoto?.id) return;
              (async () => {
                try {
                  await photosApi.addPhotoToAlbum(albumId, viewerPhoto.id!);
                  try {
                    await queryClient.invalidateQueries({ queryKey: ['albums'] });
                    await queryClient.refetchQueries({ queryKey: ['albums'] });
                    await queryClient.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' });
                  } catch {}
                  const album = (allAlbums || []).find(a => a.id === albumId) || null;
                  if (album) {
                    setViewerAlbums(prev => {
                      const existing = prev || [];
                      if (existing.find(a => a.id === albumId)) return existing;
                      return [album, ...existing];
                    });
                  }
                  toast({ title: 'Added to album', description: album ? album.name : String(albumId), variant: 'success' });
                } catch (e: any) {
                  toast({ title: 'Add to album failed', description: e?.message || String(e), variant: 'destructive' });
                }
              })();
            }}
          />
          </>
        )}

        {/* Loading indicator for initial load */}
        {isLoading && currentPage === 1 && (
          <div className="flex items-center justify-center h-64">
            <div className="text-center">
              <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-primary mb-4"></div>
              <p className="text-muted-foreground">Loading your photos...</p>
            </div>
          </div>
        )}

        {/* No separate search indicator; results and counts reflect `q` */}
      </main>

      {/* Batch progress overlay */}
      {batchBusy && (
        <div className="fixed inset-0 z-[90]">
          <div className="absolute inset-0 bg-black/50" />
          <div className="absolute inset-0 grid place-items-center p-4">
            <div className="w-full max-w-sm bg-background text-foreground border border-border rounded-lg shadow-2xl">
              <div className="px-4 py-3 border-b border-border font-medium flex items-center justify-between gap-3">
                <div>{batchTitle}</div>
                <button className="px-2 py-1 text-xs border border-border rounded hover:bg-muted" onClick={()=>setBatchCancel(true)}>Cancel</button>
              </div>
              <div className="p-4 space-y-3">
                <div className="text-sm">{batchDone + batchFailed} / {batchTotal}</div>
                <div className="w-full bg-muted border border-border rounded h-2 overflow-hidden">
                  <div className="bg-primary h-2" style={{ width: `${batchTotal>0 ? Math.round(((batchDone+batchFailed)/batchTotal)*100) : 0}%` }} />
                </div>
                {batchFailed>0 && <div className="text-xs text-red-500">Failed: {batchFailed}</div>}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Fullscreen Similar Photos/Videos overlay */}
      {qs.state.view === 'similar' && (
        <div className="fixed inset-0 z-50 bg-background">
          {/* Back button (left) */}
          <div className="absolute top-3 left-3 z-20">
            <button
              className="h-10 w-10 grid place-items-center rounded-full border border-border hover:bg-muted text-foreground"
              onClick={() => qs.setView(undefined)}
              aria-label="Back"
              title="Back"
            >
              <ArrowLeft className="w-5 h-5" />
            </button>
          </div>
          {/* Centered title */}
          <div className="absolute top-2 left-0 right-0 z-10 pointer-events-none">
            <h2 className="text-center text-xl md:text-2xl font-semibold tracking-wide text-foreground">
              Similar Photos/Videos
            </h2>
          </div>
          <div className="absolute inset-0 pt-14 md:pt-16 overflow-y-auto">
            <div className="max-w-6xl mx-auto px-3 md:px-4">
              <SimilarGroups onOpenPhoto={openViewerFromSimilar} />
              <SimilarVideoGroups onOpenAsset={openViewerFromSimilar} />
            </div>
          </div>
        </div>
      )}

      {/* Backdrop handled inside FiltersDrawer */}
    </div>
    {/* Close top-level container */}
    {showFaceUpdate && viewerPhoto && (
      <UpdateFaceOverlay
        assetId={viewerPhoto.asset_id}
        onClose={() => setShowFaceUpdate(false)}
        onAssigned={async () => {
          try {
            const people = await photosApi.getPersonsForAsset(viewerPhoto.asset_id);
            setAssetPersons(people as any);
          } catch {}
        }}
      />
    )}
    <PinDialog
      open={pinOpen}
      mode={pinMode}
      onClose={() => { setPinOpen(false); pinResolverRef.current?.(false); pinResolverRef.current = null; }}
      onVerified={async () => {
        try { setPinStatus(await photosApi.getPinStatus() as any); } catch {}
        setPinOpen(false);
        pinResolverRef.current?.(true);
        pinResolverRef.current = null;
      }}
      description={pinMode === 'verify' ? 'Enter your 8‑character PIN to access locked items.' : undefined}
    />
    </div>
  );
}
