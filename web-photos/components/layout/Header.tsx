'use client';

import React, { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useRouter } from 'next/navigation';
import { 
  Search, 
  Settings, 
  RefreshCw, 
  RotateCcw,
  LogOut,
  User,
  Users,
  ChevronDown,
  SortAsc,
  List,
  Filter,
  Check,
  TreePine,
  X,
  MoreHorizontal,
  Menu,
  ArrowLeft,
  Image as ImageIcon
} from 'lucide-react';
import dynamic from 'next/dynamic';
const EEShareButton: any = dynamic(() => import('@ee/components/ShareButton'));

import { useAuthStore } from '@/lib/stores/auth';
import { photosApi } from '@/lib/api/photos';
import { useQueryState } from '@/hooks/useQueryState';
import { SearchTypeahead, Suggestion } from '@/components/SearchTypeahead';
import { logger } from '@/lib/logger';
import { UploadDashboardModal } from '@/components/upload/UploadDashboard';
import { useE2EEStore } from '@/lib/stores/e2ee';
import { UploadDebugModal } from '@/components/upload/UploadDebugModal';
import { useUploadDebugStore } from '@/lib/stores/uploadDebug';
import { UnlockModal } from '@/components/security/UnlockModal';
import { useToast } from '@/hooks/use-toast';
import { isDemoEmail } from '@/lib/demo';

interface HeaderProps {
  onSearch: (query: string) => void;
  onReindex: () => void;
  onRefreshPhotos: () => void;
  onFilterToggle: () => void;
  selectedCount: number;
  selectedFirstAssetId?: string;
  selectedAssetIds?: string[];
  onSelectAll: () => void;
  onSelectNone: () => void;
  selectionMeta?: { anyLocked: boolean; allLocked: boolean; anyFav: boolean; allFav: boolean; allSelected: boolean; inTrash?: boolean };
  onBulkSelectAll?: () => void;
  onBulkAddToAlbum?: () => void;
  onBulkLock?: () => void;
  onBulkUnlock?: () => void;
  onBulkToggleFavorite?: () => void;
  onBulkDelete?: () => void;
  onBulkRestore?: () => void;
  onBulkPurge?: () => void;
  isLoading?: boolean;
}

export function Header({ 
  onSearch, 
  onReindex,
  onRefreshPhotos, 
  onFilterToggle,
  selectedCount,
  selectedFirstAssetId,
  selectedAssetIds,
  onSelectAll,
  onSelectNone,
  selectionMeta,
  onBulkSelectAll,
  onBulkAddToAlbum,
  onBulkLock,
  onBulkUnlock,
  onBulkToggleFavorite,
  onBulkDelete,
  onBulkRestore,
  onBulkPurge,
  isLoading = false 
}: HeaderProps) {
  const queryClient = useQueryClient();
  const qs = useQueryState();
  const [searchQuery, setSearchQuery] = useState('');
  const [showUserMenu, setShowUserMenu] = useState(false);
  const [showSortMenu, setShowSortMenu] = useState(false);
  const [showActionsMenu, setShowActionsMenu] = useState(false);
  const [isReindexing, setIsReindexing] = useState(false);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const [searchFocused, setSearchFocused] = useState(false);
  const [activeIdx, setActiveIdx] = useState<number>(-1);
  const [suggestions, setSuggestions] = useState<Suggestion[]>([]);
  const [isDark, setIsDark] = useState<boolean>(typeof window !== 'undefined' ? document.documentElement.classList.contains('dark') : false);
  const [isEE, setIsEE] = useState<boolean>(false);
  const fileInputRef = React.useRef<HTMLInputElement | null>(null);
  const legacyFileInputRef = React.useRef<HTMLInputElement | null>(null);
  const selectedAlbumRef = React.useRef<number | undefined>(undefined);
  const [showUploadAlbum, setShowUploadAlbum] = useState(false);
  const [albums, setAlbums] = useState<Array<{ id: number; name: string }>>([]);
  const [albumLoading, setAlbumLoading] = useState(false);
  const [albumError, setAlbumError] = useState<string | null>(null);
  const [uploadTasks, setUploadTasks] = useState<Array<{ id: string; name: string; progress: number; status: 'uploading'|'done'|'error' }>>([]);
  const [showBulkUpload, setShowBulkUpload] = useState(false);
  const [showUploadDebug, setShowUploadDebug] = useState(false);
  const [showUnlockModal, setShowUnlockModal] = useState(false);
  const { toast } = useToast();
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);

  const collapseSearchField = React.useCallback(() => {
    setSearchFocused(false);
    try { searchInputRef.current?.blur(); } catch {}
  }, []);

  const refreshCapabilities = React.useCallback(async () => {
    const url = `/api/capabilities?_=${Date.now()}`;
    try {
      const res = await fetch(url, { cache: 'no-store' });
      if (!res.ok) { setIsEE(false); return; }
      const j = await res.json();
      setIsEE(!!j?.ee);
    } catch {
      setIsEE(false);
    }
  }, []);

  // When picking an album from search suggestions, auto-enable locked mode if that album contains locked items
  const maybeEnableLockedForAlbum = React.useCallback(async (albumId: number) => {
    try {
      const counts = await photosApi.getMediaCounts({ album_id: albumId, album_subtree: qs.state.albumSubtree === '1' });
      const lockedCount = (counts as any)?.locked ?? 0;
      if (lockedCount > 0) {
        // Reuse the PIN flow used elsewhere via UnlockModal button in header when needed
        // Here we check local state and open the modal if not unlocked
        if (!useE2EEStore.getState().umk) {
          setShowUnlockModal(true);
          // After user unlocks, they remain on the same page; enabling locked mode now is fine
        }
        try { qs.setLocked(true); } catch {}
      }
    } catch {}
  }, [qs]);

  function openFileDialog() {
    try { fileInputRef.current?.click(); } catch {}
  }

  function openLegacyFileDialog() {
    try { legacyFileInputRef.current?.click(); } catch {}
  }

  function openFileDialogForAlbum(albumId?: number) {
    selectedAlbumRef.current = albumId;
    openFileDialog();
  }

  async function onFilesSelected(e: React.ChangeEvent<HTMLInputElement>) {
    const files = e.target.files ? Array.from(e.target.files) : [];
    if (files.length === 0) return;
    setShowUserMenu(false);
    setShowUploadAlbum(false);
    // Retrieve token if stored; otherwise rely on auth-token cookie set by auth store
    // Prefer in-memory store token; fallback to cookie-based auth
    let token: string | undefined = undefined;
    try { token = useAuthStore.getState().token || undefined; } catch {}
    await uploadFilesTus(files, token, selectedAlbumRef.current);
    // Reset input value so selecting the same file again triggers change
    try { e.currentTarget.value = ''; } catch {}
  }

  async function onLegacyFilesSelected(e: React.ChangeEvent<HTMLInputElement>) {
    const files = e.target.files ? Array.from(e.target.files) : [];
    if (files.length === 0) return;
    setShowUserMenu(false);
    // Retrieve token (or rely on cookie auth)
    let token: string | undefined = undefined;
    try { token = useAuthStore.getState().token || undefined; } catch {}
    await uploadFilesMultipart(files, token, undefined);
    try { e.currentTarget.value = ''; } catch {}
  }

  async function uploadFilesMultipart(files: File[], token?: string, albumId?: number) {
    // Precompute task IDs so error handler can reference them
    const ids = files.map(() => `${Date.now()}-${Math.random().toString(36).slice(2,8)}`);
    try {
      // Create UI tasks (no per-file progress in multipart fetch; mark done on completion)
      setUploadTasks((prev) => prev.concat(files.map((f, ix) => ({ id: ids[ix], name: f.name, progress: 0, status: 'uploading' }))));

      const fd = new FormData();
      if (albumId != null) fd.append('albumId', String(albumId));
      for (const file of files) fd.append('file', file);

      const res = await fetch('/api/upload', {
        method: 'POST',
        headers: token ? { Authorization: `Bearer ${token}` } : undefined,
        body: fd,
      });
      if (!res.ok) {
        throw new Error(`Multipart upload failed: ${res.status}`);
      }
      // Mark all added tasks as done
      setUploadTasks((prev) => prev.map((t) => ids.includes(t.id) ? { ...t, progress: 100, status: 'done' } : t));
    } catch (err) {
      console.error('Multipart upload error:', err);
      setUploadTasks((prev) => prev.map((t) => ids.includes(t.id) ? { ...t, status: 'error' } : t));
    }
  }

  async function uploadFilesTus(files: File[], token?: string, albumId?: number) {
    const tus = await import('tus-js-client');
    // Check bulk-upload locked preference (shared with dashboard)
    let lockedPref = false;
    try { lockedPref = localStorage.getItem('bulkUpload.locked') === '1'; } catch {}
    const st = useE2EEStore.getState();
    let canEncrypt = st.isUnlocked && st.canEncrypt;
    for (const file of files) {
      const taskId = `${Date.now()}-${Math.random().toString(36).slice(2,8)}`;
      setUploadTasks((prev) => prev.concat([{ id: taskId, name: file.name, progress: 0, status: 'uploading' }]));
      await new Promise<void>(async (resolve, reject) => {
        let uploadBlob: Blob = file;
        let meta: any = albumId ? { filename: file.name, albumId: String(albumId) } : { filename: file.name };
        let name = file.name;
        const isVideo = /^video\//i.test(file.type);
        try {
          if (lockedPref && canEncrypt) {
            const { encryptV3WithWorker, fileToArrayBuffer, generateImageThumb, generateVideoThumb, umkToHex } = await import('@/lib/e2eeClient');
            const umkHex = umkToHex();
            if (!umkHex) throw new Error('UMK not available');
            const user = useAuthStore.getState().user;
            const userIdUtf8 = user?.user_id || '';
            const bytes = await fileToArrayBuffer(file);
            // Compute minimal metadata
            const lm = file.lastModified ? new Date(file.lastModified) : new Date();
            const y = lm.getUTCFullYear(); const m = String(lm.getUTCMonth()+1).padStart(2,'0'); const d = String(lm.getUTCDate()).padStart(2,'0');
            let width = 0, height = 0, duration_s = 0;
            let thumbBlob: Blob | null = null;
            if (!isVideo) {
              try {
                const bmp = await createImageBitmap(file);
                width = bmp.width; height = bmp.height; try { bmp.close(); } catch {}
              } catch {}
              thumbBlob = await generateImageThumb(file);
            } else {
              try {
                const vthumb = await generateVideoThumb(file, 0.5);
                // We cannot easily read duration/wh here without video element; generateVideoThumb already created one; skip dims
                thumbBlob = vthumb;
              } catch {}
            }
            const metadata = {
              capture_ymd: `${y}-${m}-${d}`,
              size_kb: Math.max(1, Math.round(file.size / 1024)),
              width, height,
              orientation: 1,
              is_video: isVideo ? 1 : 0,
              duration_s: duration_s,
              mime_hint: file.type || (isVideo ? 'video/mp4' : 'image/jpeg'),
              kind: 'orig',
            };
            const enc = await encryptV3WithWorker(umkHex, userIdUtf8, bytes, metadata, 1024*1024);
            uploadBlob = new Blob([enc.container], { type: 'application/octet-stream' });
            name = `${enc.asset_id_b58}.pae3`;
            meta = {
              ...meta,
              locked: '1', crypto_version: '3', kind: 'orig', asset_id_b58: enc.asset_id_b58,
              capture_ymd: metadata.capture_ymd,
              size_kb: String(metadata.size_kb),
              width: String(width||0), height: String(height||0), orientation: '1', is_video: isVideo ? '1' : '0', duration_s: String(duration_s||0), mime_hint: metadata.mime_hint,
            };

            // Upload thumbnail first (best-effort), if we generated one
            if (thumbBlob) {
              try {
                const tBytes = await fileToArrayBuffer(thumbBlob);
                const tMeta = { ...metadata, kind: 'thumb' };
                const tEnc = await encryptV3WithWorker(umkHex, userIdUtf8, tBytes, tMeta, 256*1024);
                const tBlob = new Blob([tEnc.container], { type: 'application/octet-stream' });
                const tMetaTus: any = {
                  locked: '1', crypto_version: '3', kind: 'thumb', asset_id_b58: enc.asset_id_b58,
                  capture_ymd: metadata.capture_ymd,
                  size_kb: String(Math.max(1, Math.round(thumbBlob.size/1024))),
                  width: String(width||0), height: String(height||0), orientation: '1', is_video: isVideo ? '1' : '0', duration_s: String(duration_s||0), mime_hint: 'image/jpeg',
                };
                await new Promise<void>((res2, rej2) => {
                  const up2 = new tus.Upload(tBlob as any, {
                    endpoint: '/files/', chunkSize: 5*1024*1024, retryDelays: [0,1000,3000], metadata: tMetaTus, headers: token ? { Authorization: `Bearer ${token}` } : undefined,
                    onError: (err: Error) => { console.error('TUS thumbnail upload failed:', err); res2(); },
                    onSuccess: () => { res2(); },
                  });
                  up2.start();
                });
              } catch (e) { console.warn('Thumb encrypt/upload failed', e); }
            }
          }
        } catch (e) { console.warn('Locked encrypt flow failed, falling back to plaintext upload:', e); try{ toast({ title: 'Encryption unavailable', description: `Uploading ${file.name} without encryption`, variant: 'destructive' }); } catch {} }

        const upload = new tus.Upload(uploadBlob as any, {
          endpoint: '/files/', // trailing slash matters
          chunkSize: 10 * 1024 * 1024, // 10MB chunks (streamed by proxy)
          retryDelays: [0, 1000, 3000, 5000],
          metadata: meta,
          headers: token ? { Authorization: `Bearer ${token}` } : undefined,
          // Ensure cookies are sent for same-origin when not using Authorization header
          onBeforeRequest: (req: any) => {
            if (!token) {
              try {
                const xhr = req?.getUnderlyingObject?.();
                if (xhr && 'withCredentials' in xhr) {
                  xhr.withCredentials = true;
                }
              } catch {}
            }
            try {
              const add = useUploadDebugStore.getState().add;
              const method = req?.getMethod?.();
              const url = req?.getURL?.();
              add({
                id: `${Date.now()}-${Math.random().toString(36).slice(2,8)}`,
                ts: Date.now(),
                source: 'tus-js',
                method: method || 'UNKNOWN',
                url: url || '',
                reqHeaders: {
                  Authorization: token ? 'Bearer …' : undefined,
                },
              });
            } catch {}
          },
          onAfterResponse: (req: any, res: any) => {
            try {
              const add = useUploadDebugStore.getState().add;
              const method = req?.getMethod?.();
              const url = req?.getURL?.();
              const status = res?.getStatus?.();
              const rh = (name: string) => {
                try { return res?.getHeader?.(name) || undefined; } catch { return undefined; }
              };
              add({
                id: `${Date.now()}-${Math.random().toString(36).slice(2,8)}`,
                ts: Date.now(),
                source: 'tus-js',
                method: method || 'UNKNOWN',
                url: url || '',
                status: typeof status === 'number' ? status : undefined,
                resHeaders: {
                  'Tus-Resumable': rh('Tus-Resumable'),
                  'Tus-Version': rh('Tus-Version'),
                  'Tus-Extension': rh('Tus-Extension'),
                  'Tus-Max-Size': rh('Tus-Max-Size'),
                  'Upload-Offset': rh('Upload-Offset'),
                  'Upload-Length': rh('Upload-Length'),
                  'Location': rh('Location'),
                },
              });
            } catch {}
          },
          removeFingerprintOnSuccess: true,
          onError: (err: Error) => {
            console.error('TUS upload failed:', err);
            setUploadTasks((prev) => prev.map((t) => t.id === taskId ? { ...t, status: 'error' } : t));
            reject(err);
          },
          onProgress: (bytesSent: number, bytesTotal: number) => {
            const pct = Math.floor((bytesSent / bytesTotal) * 100);
            setUploadTasks((prev) => prev.map((t) => t.id === taskId ? { ...t, progress: pct } : t));
          },
          onSuccess: () => {
            // Post-finish hook will ingest and SSE will notify
            setUploadTasks((prev) => prev.map((t) => t.id === taskId ? { ...t, progress: 100, status: 'done' } : t));
            resolve();
          },
        });
        upload.start();
      });
    }
  }

  const toggleThemeQuick = () => {
    try {
      const d = document.documentElement;
      const nextDark = !d.classList.contains('dark');
      if (nextDark) {
        d.classList.add('dark');
        localStorage.setItem('theme', 'dark');
      } else {
        d.classList.remove('dark');
        localStorage.setItem('theme', 'light');
      }
      setIsDark(nextDark);
    } catch {}
  };

  // Debounce search apply
  React.useEffect(() => {
    if (!searchFocused) return;
    const q = searchQuery.trim();
    const t = setTimeout(() => {
      if (q.length >= 2 || q.length === 0) onSearch(q);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery, searchFocused]);
  React.useEffect(() => {
    if (selectedCount === 0 && showActionsMenu) {
      setShowActionsMenu(false);
    }
  }, [selectedCount, showActionsMenu]);
  const router = useRouter();
  const { user, logout } = useAuthStore();
  const isAdmin = !!user && (user.role === 'owner' || user.role === 'admin');
  const isDemoUser = isDemoEmail(user?.email);
  const e2ee = useE2EEStore();
  const layout = qs.state.layout || 'grid';
  const sortFacet = qs.state.sort || 'newest';
  const isDateSort = sortFacet === 'newest' || sortFacet === 'oldest';
  const currentSort = sortFacet;
  const inTrash = !!selectionMeta?.inTrash;

  // Determine a single selected album (from either album or albums[] state)
  const selectedAlbumId = React.useMemo(() => {
    const st: any = qs.state as any;
    if (Array.isArray(st.albums) && st.albums.length === 1) {
      const n = Number(st.albums[0]);
      return Number.isNaN(n) ? undefined : n;
    }
    if (st.album != null) {
      const n = Number(st.album);
      return Number.isNaN(n) ? undefined : n;
    }
    return undefined;
  }, [qs.state]);

  // If current sort is not date-based, enforce grid layout
  React.useEffect(() => {
    if (!isDateSort && layout === 'timeline') {
      try { qs.setLayout('grid'); } catch {}
    }
  }, [isDateSort, layout]);

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    onSearch(searchQuery);
    collapseSearchField();
  };

  const handleClearSearch = () => {
    setSearchQuery('');
    onSearch(''); // This will show all photos
  };

  const handleReindex = async () => {
    if (isDemoUser) {
      toast({
        title: 'ReIndex unavailable',
        description: 'Reindexing is not enabled for this account.',
        variant: 'destructive',
      });
      return;
    }
    if (typeof window !== 'undefined') {
      const ok = window.confirm('Start reindex now? This may take a while.');
      if (!ok) return;
    }
    setIsReindexing(true);
    // Close settings modal when starting reindex
    setShowSettings(false);
    try {
      const res: any = await photosApi.reindexPhotos();
      const jobId: string | undefined = res?.job_id;
      if (jobId) {
        // Notify global reindex provider to attach SSE and manage refresh
        try { window.postMessage({ type: 'reindex-started', jobId }, window.location.origin); } catch {}
        // Reset view and ensure we're on the grid
        try { onReindex(); } catch {}
        try { router.push('/'); } catch {}
        try { if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' }); } catch {}
      }
    } catch (error) {
      logger.error('Reindex failed:', error);
    } finally {
      // let global provider handle progress UI; stop button spinner soon
      setTimeout(() => setIsReindexing(false), 800);
    }
  };

  const handleRefreshPhotos = async () => {
    setIsRefreshing(true);
    try {
      await onRefreshPhotos();
    } catch (error) {
      logger.error('Refresh photos failed:', error);
    } finally {
      setIsRefreshing(false);
    }
  };

  // Fetch backend capabilities to gate EE-only UI items
  React.useEffect(() => {
    let mounted = true;
    (async () => {
      const url = `/api/capabilities?_=${Date.now()}`;
      try {
        const res = await fetch(url, { cache: 'no-store' });
        if (!res.ok) { if (mounted) setIsEE(false); return; }
        const j = await res.json();
        if (mounted) setIsEE(!!j?.ee);
      } catch {
        if (mounted) setIsEE(false);
      }
    })();
    return () => { mounted = false; };
  }, []);

  // Refresh capabilities each time the menu opens to avoid stale EE UI after server switches/build flips.
  React.useEffect(() => {
    if (!showUserMenu) return;
    refreshCapabilities();
  }, [showUserMenu, refreshCapabilities]);

  const handleLogout = async () => {
    try {
      await logout();
      router.push('/auth');
    } catch (error) {
      logger.error('Logout failed:', error);
      // Still logout locally even if server call fails
      logout();
      router.push('/auth');
    }
  };

  const applyUiSort = (kind: 'newest'|'oldest'|'largest'|'random'|'imported_newest'|'imported_oldest') => {
    // Source of truth: URL query params
    if (kind === 'random') {
      const seed = Math.floor(Math.random()*1_000_000);
      qs.setSort('random', seed);
    } else {
      qs.setSort(kind as any);
    }
    // Ensure layout compatibility
    if (!(kind === 'newest' || kind === 'oldest')) {
      try { qs.setLayout('grid'); } catch {}
    }
    setShowSortMenu(false);
  };

  // Listen for close-modals messages, reindex events, and clear-all-filters
  React.useEffect(() => {
    const onMsg = async (e: MessageEvent) => {
      try {
        if (e.origin !== window.location.origin) return;
        const data = e.data;
        if (data && (data.type === 'close-modals' || data.type === 'reindex-started')) {
          setShowSettings(false);
          setShowUserMenu(false);
          setShowSortMenu(false);
          setShowActionsMenu(false);
        }
        if (data && data.type === 'close-all-menus') {
          setShowSettings(false);
          setShowUserMenu(false);
          setShowSortMenu(false);
          setShowActionsMenu(false);
        }
        if (data && data.type === 'clear-all-filters') {
          setSearchQuery('');
        }
        if (data && data.type === 'albums-updated') {
          try { await queryClient.invalidateQueries({ queryKey: ['albums'] }); } catch {}
        }
      } catch {}
    };
    window.addEventListener('message', onMsg);
    return () => window.removeEventListener('message', onMsg);
  }, []);

  // Note: do not auto-close Settings while indexing is active; rely on
  // explicit 'reindex-started'/'close-modals' messages to close once.

  return (
    <>
    <header className="bg-background border-b border-border sticky top-0 z-40">
      <div className="px-4 sm:px-6 lg:px-8">
          <div className="flex items-center justify-between h-16">
          {/* Left side - Logo and Search */}
          <div className="flex items-center space-x-4 flex-1">
            <div className="flex items-center space-x-2">
              <img
                src="/app-icon.png"
                alt="OpenPhotos"
                className="hidden md:block w-8 h-8 rounded-lg"
                draggable={false}
              />
	              <h1 className="text-xl font-semibold text-foreground hidden sm:block">OpenPhotos</h1>
            </div>

            {/* Search Form */}
            <form
              onSubmit={handleSearch}
              className={`flex-1 relative transition-all duration-150 ease-out ${searchFocused ? 'w-full max-w-none md:max-w-lg' : 'max-w-lg'}`}
            >
              <div className="relative z-50">
                <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                  <Search className="h-5 w-5 text-muted-foreground" />
                </div>
                <input
                  ref={searchInputRef}
                  type="text"
                  placeholder="Search photos... (e.g., cats, beach, mountains)"
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  onFocus={() => setSearchFocused(true)}
                  onBlur={() => setTimeout(()=>setSearchFocused(false), 100)}
                  onKeyDown={(e) => {
                    if (e.key === 'ArrowDown') { e.preventDefault(); setActiveIdx((i) => (i + 1) % Math.max(1, suggestions.length)); }
                    if (e.key === 'ArrowUp') { e.preventDefault(); setActiveIdx((i) => (i <= 0 ? Math.max(0, suggestions.length - 1) : i - 1)); }
                    if (e.key === 'Enter') {
                      e.preventDefault();
                      const s = suggestions[activeIdx];
                      if (s) {
                        if (s.kind === 'submit') onSearch(searchQuery); else {
                          if (s.kind === 'face') qs.setFaces([s.personId]);
                          if (s.kind === 'album') { qs.setAlbum(String(s.albumId)); maybeEnableLockedForAlbum(s.albumId); }
                          if (s.kind === 'city') qs.setLocation({ country: qs.state.country, region: qs.state.region, city: s.city });
                          if (s.kind === 'country') qs.setLocation({ country: s.country, region: undefined, city: undefined });
                        }
                        collapseSearchField();
                        return;
                      }
                      onSearch(searchQuery);
                      collapseSearchField();
                    }
                    if (e.key === 'Escape') { collapseSearchField(); }
                  }}
                  className={`block w-full pl-10 ${searchQuery ? 'pr-10' : 'pr-3'} py-2 border border-border rounded-md leading-5 bg-background text-foreground placeholder:text-muted-foreground focus:outline-none focus:placeholder:text-muted-foreground focus:ring-1 focus:ring-primary focus:border-primary sm:text-sm`}
                />
                {/* Clear button - only show when there's text */}
                {searchQuery && (
                  <div className="absolute inset-y-0 right-0 pr-3 flex items-center">
                    <button
                      type="button"
                      onClick={handleClearSearch}
                      className="text-muted-foreground hover:text-foreground focus:outline-none"
                      title="Clear search"
                    >
                      <X className="h-4 w-4" />
                    </button>
                  </div>
                )}
              </div>
              {searchFocused && searchQuery.length >= 2 && (
                <SearchTypeahead
                  value={searchQuery}
                  onSubmit={(q) => { setShowSortMenu(false); onSearch(q); collapseSearchField(); }}
                  onPick={(s: Suggestion) => {
                    if (s.kind === 'submit') { onSearch(searchQuery); collapseSearchField(); return; }
                    if (s.kind === 'face') { qs.setFaces([s.personId]); }
                    if (s.kind === 'album') {
                      qs.setAlbum(String(s.albumId));
                      // Best-effort: enable locked mode if album contains locked items
                      maybeEnableLockedForAlbum(s.albumId);
                    }
                    if (s.kind === 'city') { qs.setLocation({ country: qs.state.country, region: qs.state.region, city: s.city }); }
                    if (s.kind === 'country') { qs.setLocation({ country: s.country, region: undefined, city: undefined }); }
                    collapseSearchField();
                  }}
                  activeIndex={activeIdx}
                  onActiveIndexChange={setActiveIdx}
                  onSuggestionsChange={setSuggestions}
                />
              )}
            </form>
          </div>

          {/* Right side - Actions */}
          <div className={`flex items-center space-x-2 ${searchFocused ? 'hidden md:flex' : ''}`}>
            {/* Selection summary and Actions (desktop) */}
            {selectedCount > 0 && (
              <div className="relative">
                <button
                  onClick={() => setShowActionsMenu(!showActionsMenu)}
                  className="hidden md:inline-flex items-center space-x-1 px-3 py-2 text-sm font-medium text-foreground bg-card border border-border rounded-md hover:bg-muted focus:outline-none focus:ring-2 focus:ring-primary"
                  type="button"
                >
                  <span>Actions</span>
                  <ChevronDown className="w-4 h-4" />
                </button>
                {showActionsMenu && (
                  <div className="absolute right-0 mt-2 w-56 bg-background text-foreground rounded-md shadow-xl border border-border z-50">
                    <div className="py-1">
                      <button onClick={() => { setShowActionsMenu(false); onBulkSelectAll?.(); }} className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted" type="button">
                        <span>{selectionMeta?.allSelected ? 'Unselect All' : 'Select All'}</span>
                      </button>
                      {inTrash ? (
                        <>
                          <button onClick={() => { setShowActionsMenu(false); onBulkRestore?.(); }} className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted" type="button">
                            <span>Restore</span>
                          </button>
                          <div className="h-px bg-border my-1" />
                          <button onClick={() => { setShowActionsMenu(false); onBulkPurge?.(); }} className="flex items-center justify-between w-full px-4 py-2 text-sm text-red-600 hover:bg-muted" type="button">
                            <span>Delete Permanently…</span>
                          </button>
                        </>
                      ) : (
                        <>
                          <button onClick={() => { setShowActionsMenu(false); onBulkAddToAlbum?.(); }} className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted" type="button">
                            <span>Add to Album…</span>
                          </button>
                          {/* EE: Share selected (single item) */}
                          {isEE && selectedCount > 0 && !inTrash && (
                            selectedFirstAssetId ? (
                              <EEShareButton
                                assetId={selectedFirstAssetId}
                                assetIds={selectedAssetIds}
                                defaultMode="asset"
                                className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted"
                              />
                            ) : (
                              <button
                                className="flex items-center justify-between w-full px-4 py-2 text-sm text-muted-foreground cursor-not-allowed opacity-60"
                                type="button"
                                disabled
                                title="Select an item to share"
                              >
                                <span>Share</span>
                              </button>
                            )
                          )}
                          <button
                            onClick={() => { setShowActionsMenu(false); if (!selectionMeta?.allLocked) onBulkLock?.(); }}
                            disabled={!!selectionMeta?.allLocked}
                            className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted disabled:opacity-50"
                            type="button"
                          >
                            <span>{selectionMeta?.allLocked ? 'All Locked' : (selectionMeta?.anyLocked ? 'Lock Unlocked' : 'Lock')}</span>
                          </button>
                          <button
                            onClick={() => { setShowActionsMenu(false); onBulkUnlock?.(); }}
                            disabled={!selectionMeta?.anyLocked}
                            className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted disabled:opacity-50"
                            type="button"
                          >
                            <span>Unlock Locked</span>
                          </button>
                          <button onClick={() => { setShowActionsMenu(false); onBulkToggleFavorite?.(); }} className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted" type="button">
                            <span>{selectionMeta?.allFav ? 'Remove from Favorites' : 'Add to Favorites'}</span>
                          </button>
                          <div className="h-px bg-border my-1" />
                          <button onClick={() => { setShowActionsMenu(false); onBulkDelete?.(); }} className="flex items-center justify-between w-full px-4 py-2 text-sm text-red-600 hover:bg-muted" type="button">
                            <span>Delete…</span>
                          </button>
                        </>
                      )}
                    </div>
                  </div>
                )}
              </div>
            )}

            {/* Sort dropdown */}
            <div className="relative">
              <button
                onClick={() => setShowSortMenu(!showSortMenu)}
                className="flex items-center space-x-1 px-3 py-2 text-sm font-medium text-foreground bg-card border border-border rounded-md hover:bg-muted focus:outline-none focus:ring-2 focus:ring-primary"
                type="button"
              >
                <SortAsc className="w-4 h-4" />
                <span className="hidden sm:inline">Sort</span>
                <ChevronDown className="w-4 h-4" />
              </button>
              
              {showSortMenu && (
                <div className="absolute right-0 mt-2 w-56 bg-background text-foreground rounded-md shadow-xl border border-border z-50">
                  <div className="py-1">
                    <button
                      onClick={() => applyUiSort('newest')}
                      className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted"
                      type="button"
                    >
                      <span>Date (Newest First)</span>
                      {currentSort === 'newest' && <Check className="w-4 h-4 text-primary" />}
                    </button>
                    <button
                      onClick={() => applyUiSort('oldest')}
                      className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted"
                      type="button"
                    >
                      <span>Date (Oldest First)</span>
                      {currentSort === 'oldest' && <Check className="w-4 h-4 text-primary" />}
                    </button>
                    <div className="h-px bg-border my-1" />
                    <button
                      onClick={() => applyUiSort('imported_newest')}
                      className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted"
                      type="button"
                    >
                      <span>Imported (Newest)</span>
                      {currentSort === 'imported_newest' && <Check className="w-4 h-4 text-primary" />}
                    </button>
                    <button
                      onClick={() => applyUiSort('imported_oldest')}
                      className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted"
                      type="button"
                    >
                      <span>Imported (Oldest)</span>
                      {currentSort === 'imported_oldest' && <Check className="w-4 h-4 text-primary" />}
                    </button>
                    <div className="h-px bg-border my-1" />
                    <button
                      onClick={() => applyUiSort('largest')}
                      className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted"
                      type="button"
                    >
                      <span>Size (Largest First)</span>
                      {currentSort === 'largest' && <Check className="w-4 h-4 text-primary" />}
                    </button>
                    <button
                      onClick={() => applyUiSort('random')}
                      className="flex items-center justify-between w-full px-4 py-2 text-sm text-foreground hover:bg-muted"
                      type="button"
                    >
                      <span>Random (Seeded)</span>
                      {currentSort === 'random' && <Check className="w-4 h-4 text-primary" />}
                    </button>
                  </div>
                </div>
              )}
            </div>

            {/* Layout toggle: only visible when using a date-based sort */}
            {isDateSort && (
              <div className="flex items-center rounded-md border border-border overflow-hidden">
                <button
                  onClick={() => { qs.setLayout('grid'); }}
                  className={`px-2.5 py-2 text-sm flex items-center gap-1 ${layout==='grid' ? 'bg-primary text-primary-foreground' : 'bg-card text-foreground hover:bg-muted'}`}
                  title="Grid layout"
                  aria-pressed={layout==='grid'}
                  type="button"
                >
                  <ImageIcon className="w-4 h-4" />
                  <span className="hidden sm:inline">Grid</span>
                </button>
                <button
                  onClick={() => { qs.setLayout('timeline'); }}
                  className={`px-2.5 py-2 text-sm flex items-center gap-1 border-l border-border ${layout==='timeline' ? 'bg-primary text-primary-foreground' : 'bg-card text-foreground hover:bg-muted'}`}
                  title="Timeline layout"
                  aria-pressed={layout==='timeline'}
                  type="button"
                >
                  <List className="w-4 h-4" />
                  <span className="hidden sm:inline">Timeline</span>
                </button>
              </div>
            )}

            {/* Filter button removed (duplicate with filters access elsewhere) */}

            {/* Reindex button */}
            <button
              onClick={handleReindex}
              disabled={isReindexing}
              className="flex items-center space-x-1 px-3 py-2 text-sm font-medium text-foreground bg-card border border-border rounded-md hover:bg-muted focus:outline-none focus:ring-2 focus:ring-primary disabled:opacity-50"
            >
              {/* Use Scan icon to represent indexing/scanning */}
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16" className={`${isReindexing ? 'animate-spin' : ''}`} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/><rect x="7" y="7" width="10" height="10" rx="2"/></svg>
              <span className="hidden sm:inline">
                {isReindexing ? 'Indexing...' : 'ReIndex'}
              </span>
            </button>

            {/* Refresh Photos button */}
            <button
              onClick={handleRefreshPhotos}
              disabled={isRefreshing}
              className="flex items-center space-x-1 px-3 py-2 text-sm font-medium text-foreground bg-card border border-border rounded-md hover:bg-muted focus:outline-none focus:ring-2 focus:ring-primary disabled:opacity-50"
            >
              <RotateCcw className={`w-4 h-4 ${isRefreshing ? 'animate-spin' : ''}`} />
              <span className="hidden sm:inline">
                {isRefreshing ? 'Refreshing...' : 'Refresh'}
              </span>
            </button>

            {/* EE: Share button moved to ActiveFilterChips right actions (fourth row). */}

            {/* Settings button removed (accessible via More menu) */}

            {/* User menu (more actions) */}
            <div className="relative">
              <button
                onClick={() => setShowUserMenu(!showUserMenu)}
                className="p-2 text-foreground rounded-md hover:bg-muted"
                title="Menu"
              >
                <Menu className="w-5 h-5" />
              </button>

              {showUserMenu && (
                <div className="absolute right-0 mt-2 w-48 bg-background text-foreground rounded-md shadow-xl border border-border z-50">
                  <div className="py-1" role="menu">
                    <div className="px-4 py-2 border-b border-border">
                      <p className="text-sm font-medium text-foreground">{user?.name}</p>
                      <p className="text-sm text-muted-foreground">{user?.email}</p>
                    </div>
                    {/* EE: Sharing */}
                    {isEE && (
                      <button
                        onClick={() => { setShowUserMenu(false); try { router.push('/sharing'); } catch {} }}
                        className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                        role="menuitem"
                      >
                        <List className="w-4 h-4" />
                        <span>Sharing</span>
                      </button>
                    )}
                    {/* Manage Groups & Users (EE only) */}
                    {isEE && isAdmin && !isDemoUser && (
                      <button
                        onClick={() => { setShowUserMenu(false); try { router.push('/settings/team'); } catch {} }}
                        className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                        role="menuitem"
                      >
                        <Users className="w-4 h-4" />
                          <span> Users &amp; Groups</span>
                      </button>
                    )}
                    {/* E2EE Unlock/Reset moved from header */}
                    <button
                      onClick={() => {
                        // Close menu then perform action
                        setShowUserMenu(false);
                        if (e2ee.umk) {
                          // Reset the in-memory unlock so PIN is required next time
                          e2ee.setUMK(null);
                          try { qs.setLocked(false); } catch {}
                          return;
                        }
                        if (!e2ee.envelope) { alert('No PIN set. Open Settings → Security to create your PIN.'); return; }
                        setShowUnlockModal(true);
                      }}
                      className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                      role="menuitem"
                    >
                      <span>{e2ee.umk ? 'Reset Lock' : 'Unlock'}</span>
                    </button>
                    {/* Separator */}
                    <div className="my-1 border-t border-border" role="separator" />
                    <button
                      onClick={() => { toggleThemeQuick(); setShowUserMenu(false); }}
                      className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                      role="menuitem"
                    >
                      <span>{isDark ? 'Switch to Light' : 'Switch to Dark'}</span>
                    </button>
                    {/* Separator */}
                    <div className="my-1 border-t border-border" role="separator" />
                    <button
                      onClick={() => { setShowUserMenu(false); setShowBulkUpload(true); }}
                      className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                      role="menuitem"
                    >
                      <span>Bulk Upload…</span>
                    </button>
                    {/* Separator */}
                    <div className="my-1 border-t border-border" role="separator" />
                    {/* Manage Faces entry */}
                    <button
                      onClick={() => { setShowUserMenu(false); try { router.push('/faces/manage'); } catch {} }}
                      className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                      role="menuitem"
                    >
                      <User className="w-4 h-4" />
                      <span>Manage Faces</span>
                    </button>
                    {/* Similar Photos/Videos entry */}
                    <button
                      onClick={() => { qs.setView('similar'); setShowUserMenu(false); }}
                      className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                      role="menuitem"
                    >
                      <ImageIcon className="w-4 h-4" />
                      <span>Similar Media</span>
                    </button>
                    {/* Separator */}
                    <div className="my-1 border-t border-border" role="separator" />
                    <button
                      onClick={() => { setShowUserMenu(false); setShowSettings(true); }}
                      className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                      role="menuitem"
                    >
                      <Settings className="w-4 h-4" />
                      <span>Settings</span>
                    </button>
                    <button
                      onClick={handleLogout}
                      className="flex items-center space-x-2 w-full text-left px-4 py-2 text-sm text-foreground hover:bg-muted"
                      role="menuitem"
                    >
                      <LogOut className="w-4 h-4" />
                      <span>Sign out</span>
                    </button>
                  </div>
                </div>
              )}
            </div>
          </div>
          <UnlockModal open={showUnlockModal} onClose={() => setShowUnlockModal(false)} />
        </div>
      </div>

      {/* Click outside to close menus */}
      {(showUserMenu || showSortMenu || showActionsMenu) && (
        <div
          className="fixed inset-0 z-40"
          onClick={() => {
            setShowUserMenu(false);
            setShowSortMenu(false);
            setShowActionsMenu(false);
          }}
        />
      )}
      {/* Global progress pill handled by ReindexProvider */}
    </header>
    {/* Hidden file input for TUS uploads */}
    <input
      ref={fileInputRef}
      type="file"
      multiple
      accept="image/*,video/*"
      className="hidden"
      onChange={onFilesSelected}
    />
    {/* Hidden file input for Legacy multipart uploads */}
    <input
      ref={legacyFileInputRef}
      type="file"
      multiple
      accept="image/*,video/*"
      className="hidden"
      onChange={onLegacyFilesSelected}
    />
    {/* Upload to Album modal */}
    {showUploadAlbum && (
      <div className="fixed inset-0 z-50">
        <div className="absolute inset-0 bg-black/40" onClick={() => setShowUploadAlbum(false)} />
        <div className="absolute inset-0 grid place-items-center p-4">
          <div className="w-full max-w-md bg-background border border-border rounded-lg shadow-xl">
            <div className="px-4 py-3 border-b border-border text-foreground font-medium">Upload to Album</div>
            <div className="p-4 space-y-3">
              {albumLoading && <div className="text-sm text-muted-foreground">Loading albums…</div>}
              {albumError && <div className="text-sm text-red-600">{albumError}</div>}
              {!albumLoading && !albumError && (
                <div className="space-y-2">
                  <label className="text-sm text-muted-foreground">Select album</label>
                  <select
                    className="w-full border border-border rounded-md bg-background text-foreground p-2"
                    onChange={(e) => { const v = e.target.value ? parseInt(e.target.value) : undefined; selectedAlbumRef.current = v; }}
                  >
                    <option value="">— None —</option>
                    {albums.map(a => (
                      <option key={a.id} value={a.id}>{a.name}</option>
                    ))}
                  </select>
                </div>
              )}
            </div>
            <div className="px-4 py-3 border-t border-border flex items-center justify-end gap-2">
              <button onClick={() => setShowUploadAlbum(false)} className="px-3 py-1.5 rounded border border-border text-foreground hover:bg-muted">Cancel</button>
              <button onClick={() => { openFileDialogForAlbum(selectedAlbumRef.current); }} className="px-3 py-1.5 rounded bg-primary text-primary-foreground hover:bg-primary/90">Choose Files…</button>
            </div>
          </div>
        </div>
      </div>
    )}

    {/* Upload progress panel */}
    {uploadTasks.length > 0 && (
      <div className="fixed bottom-4 right-4 z-40 w-64 bg-background border border-border rounded-lg shadow-xl">
        <div className="px-3 py-2 border-b border-border text-sm font-medium text-foreground">Uploads</div>
        <div className="max-h-60 overflow-auto p-2 space-y-2">
          {uploadTasks.map(t => (
            <div key={t.id} className="space-y-1">
              <div className="text-xs text-foreground truncate" title={t.name}>{t.name}</div>
              <div className="w-full h-1.5 bg-muted rounded">
                <div className={`h-1.5 rounded ${t.status==='error' ? 'bg-red-600' : 'bg-primary'}`} style={{ width: `${t.progress}%` }} />
              </div>
            </div>
          ))}
        </div>
        <div className="px-3 py-2 border-t border-border flex items-center justify-end">
          <button onClick={() => setUploadTasks([])} className="text-xs text-muted-foreground hover:text-foreground">Clear</button>
        </div>
      </div>
    )}
    {showSettings && (
      <div className="fixed inset-0 z-50">
        <div className="absolute inset-0 bg-black/50" onClick={() => setShowSettings(false)} />
        <div className="absolute inset-0 bg-background overflow-hidden">
          <div className="absolute top-3 left-3 z-10">
            <button
              onClick={() => setShowSettings(false)}
              className="h-10 w-10 grid place-items-center rounded-full border border-border hover:bg-muted text-foreground"
              aria-label="Back"
            >
              <ArrowLeft className="w-5 h-5" />
            </button>
          </div>
          {/* Fullscreen settings content */}
          <iframe src="/settings" className="w-full h-full border-0" />
        </div>
      </div>
    )}

    {/* Bulk Upload (Uppy) */}
    <UploadDashboardModal open={showBulkUpload} onClose={() => setShowBulkUpload(false)} />
    {/* Upload Debug Modal */}
    <UploadDebugModal open={showUploadDebug} onClose={() => setShowUploadDebug(false)} />

    </>
  );
}
