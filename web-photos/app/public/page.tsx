"use client";
import React from 'react';
import { ChevronLeft, ChevronRight, X as XIcon, Trash2 as TrashIcon, ListFilter as SortIcon, Check as CheckIcon, Play, Pause, Volume2, VolumeX } from 'lucide-react';
import dynamic from 'next/dynamic';
import { useAuthStore } from '@/lib/stores/auth';
import { getViewerKeyFromHash, unwrapSmkFromEnvelope, fetchJson, fetchArrayBuffer, decryptPae3WithSmk, bytesToBlobUrl, bytesToImageBlobUrl } from '@/lib/publicE2EE';

// 1x1 transparent GIF to stop retry loops when a thumbnail isn't available (e.g., locked without wraps)
const TRANSPARENT_PLACEHOLDER = 'data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=';
// EE runtime flag (inlined at build time by Next.js)
const EE_ENABLED = (process.env.NEXT_PUBLIC_ENABLE_EE === '1' || process.env.NEXT_PUBLIC_ENABLE_EE === 'true');
const PIN_TTL_MS = 3 * 24 * 60 * 60 * 1000; // 3 days

// Avoid SSR for Uppy dashboard (browser-only)
const UploadDashboardModal = dynamic(
  () => import('@/components/upload/UploadDashboard').then(m => m.UploadDashboardModal),
  { ssr: false }
);

function useQueryParam(name: string): string | null {
  const [val, setVal] = React.useState<string | null>(null);
  React.useEffect(() => {
    try {
      const u = new URL(window.location.href);
      setVal(u.searchParams.get(name));
    } catch {}
  }, []);
  return val;
}

export default function PublicLinkPage() {
  const linkId = useQueryParam('l');
  const key = useQueryParam('k');
  const pinParam = useQueryParam('pin');
  const [pin, setPin] = React.useState('');
  // Load a persisted PIN for this link if available and still valid
  React.useEffect(() => {
    if (!linkId) return;
    try {
      const raw = localStorage.getItem(`publicPin:${linkId}`);
      if (!raw) return;
      const data = JSON.parse(raw);
      if (data && typeof data.pin === 'string' && typeof data.ts === 'number') {
        if (Date.now() - data.ts < PIN_TTL_MS) {
          setPin((prev) => prev || data.pin);
        } else {
          localStorage.removeItem(`publicPin:${linkId}`);
        }
      }
    } catch {}
  }, [linkId]);
  const [needsPin, setNeedsPin] = React.useState(false);
  const [meta, setMeta] = React.useState<any>(null);
  const [error, setError] = React.useState<string>('');
  const [coverUrl, setCoverUrl] = React.useState<string>('');
  const [thumbs, setThumbs] = React.useState<Array<{ asset_id: string }>>([]);
  const [pendingThumbs, setPendingThumbs] = React.useState<Array<{ asset_id: string }>>([]);
  const [page, setPage] = React.useState(1);
  const [hasMore, setHasMore] = React.useState(true);
  const [loading, setLoading] = React.useState(false);
  const [showUpload, setShowUpload] = React.useState(false);
  const [viewerIndex, setViewerIndex] = React.useState<number | null>(null);
  const [latestByAsset, setLatestByAsset] = React.useState<Record<string, { id: string; author_display_name: string; body: string; created_at: number }|undefined>>({});
  const [likesByAsset, setLikesByAsset] = React.useState<Record<string, { asset_id: string; count: number; liked_by_me: boolean }>>({});
  const [showCommentsFor, setShowCommentsFor] = React.useState<string|null>(null);
  const [tab, setTab] = React.useState<'approved'|'pending'>('approved');
  const [selectMode, setSelectMode] = React.useState(false);
  const [selected, setSelected] = React.useState<Set<string>>(new Set());
  const [approvedCount, setApprovedCount] = React.useState<number|undefined>(undefined);
  const [pendingCount, setPendingCount] = React.useState<number|undefined>(undefined);
  const [showDeleteConfirm, setShowDeleteConfirm] = React.useState(false);
  const [deleteContext, setDeleteContext] = React.useState<'pending'|'approved'>('pending');
  const [sort, setSort] = React.useState<'newest'|'oldest'|'liked'>('newest');
  const [showSortMenu, setShowSortMenu] = React.useState(false);
  // Public E2EE viewing
  const [vkBytes, setVkBytes] = React.useState<Uint8Array | null>(null);
  const [smkHex, setSmkHex] = React.useState<string | null>(null);
  const [wrapCache, setWrapCache] = React.useState<Map<string, { orig?: any; thumb?: any }>>(new Map());
  const [wrapCacheVersion, setWrapCacheVersion] = React.useState<number>(0);
  const wrapsCheckedRef = React.useRef<Map<string, number>>(new Map());
  const CHECK_TTL_MS = 60_000; // avoid requerying wraps for 60s when missing
  // Video viewer state
  const videoViewerRef = React.useRef<HTMLVideoElement | null>(null);
  const [forcedIsVideo, setForcedIsVideo] = React.useState<boolean | null>(null);
  const [videoPaused, setVideoPaused] = React.useState(true);
  const [videoMuted, setVideoMuted] = React.useState(false);
  const [videoDuration, setVideoDuration] = React.useState(0);
  const [videoTime, setVideoTime] = React.useState(0);
  const [scrubbing, setScrubbing] = React.useState(false);
  // Slideshow state and highlighted tile index
  const [slideshowActive, setSlideshowActive] = React.useState(false);
  const SLIDESHOW_DELAY_MS = 5000; // 5 seconds between photos
  const [highlightIndex, setHighlightIndex] = React.useState(0);

  const [vkPresent, setVkPresent] = React.useState(false);
  React.useEffect(() => { try { setVkPresent(!!getViewerKeyFromHash()); } catch { setVkPresent(false); } }, []);
  const qp = React.useMemo(() => {
    const p = new URLSearchParams();
    if (key) p.set('k', key);
    if (pin) p.set('pin', pin);
    if (vkPresent) p.set('vk', '1');
    return p.toString();
  }, [key, pin, vkPresent]);

  // If a pin parameter is present in the URL on first load, adopt it and persist it.
  React.useEffect(() => {
    try {
      if (!linkId) return;
      if (!pin && pinParam && pinParam.length === 8) {
        setPin(pinParam);
        try { localStorage.setItem(`publicPin:${linkId}`, JSON.stringify({ pin: pinParam, ts: Date.now() })); } catch {}
      }
    } catch {}
  }, [pinParam, linkId, pin]);

  // Keep URL's pin= in sync with current pin (no reload). This ensures refresh works.
  React.useEffect(() => {
    try {
      if (!linkId) return;
      if (typeof window === 'undefined') return;
      const u = new URL(window.location.href);
      const cur = u.searchParams.get('pin') || '';
      if (pin && pin.length === 8 && cur !== pin) {
        u.searchParams.set('pin', pin);
        window.history.replaceState({}, '', u.toString());
      }
    } catch {}
  }, [pin, linkId]);

  // Load meta (and detect if PIN required)
  React.useEffect(() => {
    (async () => {
      if (!linkId || !key) return;
      setError(''); setMeta(null);
      try {
        // Ensure we try a saved PIN first before the initial meta fetch
        if (!pin || pin.length !== 8) {
          try {
            const raw = localStorage.getItem(`publicPin:${linkId}`);
            if (raw) {
              const data = JSON.parse(raw);
              if (data && typeof data.pin === 'string' && typeof data.ts === 'number' && (Date.now() - data.ts) < PIN_TTL_MS) {
                if (pin !== data.pin) { setPin(data.pin); return; }
              }
            }
          } catch {}
        }
        const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/meta?${qp}`);
        const j = await res.json().catch(()=>null);
        if (!res.ok) {
          // Server intentionally returns 404 to avoid leaking link existence when PIN is missing/incorrect.
          // Treat 404 as "PIN required" UX instead of surfacing the error.
          if (res.status === 404) {
            // If we attempted with a PIN, clear it; otherwise keep storage intact.
            try {
              if (pin && pin.length === 8) {
                const raw = localStorage.getItem(`publicPin:${linkId}`);
                if (raw) {
                  const data = JSON.parse(raw);
                  if (data && data.pin === pin) localStorage.removeItem(`publicPin:${linkId}`);
                }
              }
            } catch {}
            setNeedsPin(true);
            setError('');
            return;
          }
          throw new Error((j && j.message) || `Failed: ${res.status}`);
        }
        setMeta(j);
        setNeedsPin(!!j?.has_pin && (!pin || pin.length!==8));
        setApprovedCount(undefined);
        if (typeof j?.pending_count === 'number') setPendingCount(j.pending_count);
      } catch (e:any) {
        setError(e?.message || 'Failed to load');
      }
    })();
  }, [linkId, key, qp]);

  // Save VK to localStorage when it's present in the URL
  React.useEffect(() => {
    try {
      if (!linkId) return;
      const vk = getViewerKeyFromHash();
      if (vk) {
        // Save VK to localStorage for persistence
        const vkBase64 = btoa(String.fromCharCode.apply(null, Array.from(vk)));
        localStorage.setItem(`publicLink_vk_${linkId}`, vkBase64);
        // Also save timestamp for potential cleanup
        localStorage.setItem(`publicLink_vk_${linkId}_ts`, Date.now().toString());
        console.log('[VK] Saved viewing key to localStorage for link:', linkId);
      }
    } catch (e) {
      console.error('[VK] Failed to save viewing key:', e);
    }
  }, [linkId]);

  // Cleanup old VK entries from localStorage (older than 7 days)
  React.useEffect(() => {
    try {
      const VK_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
      const now = Date.now();
      const keysToRemove: string[] = [];

      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && key.startsWith('publicLink_vk_') && key.endsWith('_ts')) {
          const timestamp = parseInt(localStorage.getItem(key) || '0');
          if (timestamp && (now - timestamp) > VK_TTL_MS) {
            const vkKey = key.replace('_ts', '');
            keysToRemove.push(key, vkKey);
          }
        }
      }

      keysToRemove.forEach(key => localStorage.removeItem(key));
      if (keysToRemove.length > 0) {
        console.log('[VK] Cleaned up', keysToRemove.length / 2, 'old VK entries');
      }
    } catch (e) {
      console.error('[VK] Cleanup failed:', e);
    }
  }, []);

  // Derive SMK from #vk fragment and fetch envelope (with localStorage fallback)
  React.useEffect(() => {
    (async () => {
      try {
        if (!linkId || !key) { setVkBytes(null); setSmkHex(null); return; }

        // First try to get VK from URL hash
        let vk = getViewerKeyFromHash();

        // If not in URL, try localStorage fallback
        if (!vk) {
          try {
            const stored = localStorage.getItem(`publicLink_vk_${linkId}`);
            if (stored) {
              const bytes = atob(stored);
              vk = new Uint8Array(bytes.length);
              for (let i = 0; i < bytes.length; i++) {
                vk[i] = bytes.charCodeAt(i);
              }
              console.log('[VK] Recovered viewing key from localStorage for link:', linkId);

              // Optionally restore it to URL for consistency
              const vkBase64Url = btoa(String.fromCharCode.apply(null, Array.from(vk)))
                .replace(/\+/g, '-')
                .replace(/\//g, '_')
                .replace(/=/g, '');
              const url = new URL(window.location.href);
              url.hash = `vk=${vkBase64Url}`;
              window.history.replaceState({}, '', url.toString());
              console.log('[VK] Restored viewing key to URL');
            }
          } catch (e) {
            console.error('[VK] Failed to recover viewing key from localStorage:', e);
          }
        }

        setVkBytes(vk);
        if (!vk) { setSmkHex(null); return; }
        const env = await fetchJson<{ env: any }>(`/api/ee/public/${encodeURIComponent(linkId)}/e2ee/smk-envelope?k=${encodeURIComponent(key)}${pin?`&pin=${encodeURIComponent(pin)}`:''}`);
        if (!env?.env) { setSmkHex(null); return; }
        const smk = await unwrapSmkFromEnvelope(env.env, vk);
        const hex = Array.from(smk).map(b=>b.toString(16).padStart(2,'0')).join('');
        setSmkHex(hex);
      } catch { setSmkHex(null); }
    })();
  }, [linkId, key, pin]);

  // Load cover
  React.useEffect(() => {
    if (!linkId || !key || !meta || needsPin) return;
    if (meta?.has_cover) {
      try {
        const params = new URLSearchParams(qp);
        if (meta?.cover_asset_id) {
          params.set('v', String(meta.cover_asset_id));
        }
        const url = `/api/ee/public/${encodeURIComponent(linkId)}/cover?${params.toString()}`;
        setCoverUrl(url);
      } catch {
        const url = `/api/ee/public/${encodeURIComponent(linkId)}/cover?${qp}`;
        setCoverUrl(url);
      }
    } else {
      setCoverUrl('');
    }
  }, [meta, linkId, key, qp, needsPin]);

  // Load first page of assets (Approved)
  React.useEffect(() => {
    (async () => {
      if (!linkId || !key || !meta || needsPin || !hasMore || loading || tab !== 'approved') return;
      setLoading(true);
      try {
        const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/assets?${qp}&page=${page}&limit=60&sort=${encodeURIComponent(sort)}&_=${Date.now()}`);
        const j = await res.json().catch(()=>null);
        if (!res.ok || !j) throw new Error((j && j.message) || `Failed: ${res.status}`);
        const ids = Array.isArray(j.asset_ids) ? j.asset_ids : [];
        setThumbs(prev => prev.concat(ids.map((id:string)=>({ asset_id: id }))));
        setHasMore(!!j.has_more);
        if (page === 1) { try { setApprovedCount((j.asset_ids||[]).length); } catch {} }
        // Fetch comment previews and likes (EE only, and only if permissions allow)
        if (EE_ENABLED && ids.length > 0 && meta?.permissions !== undefined) {
          // Fetch comments if allowed (bit 2)
          if ((meta.permissions & 2) === 2) {
            try {
              const resC = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/comments/latest-by-assets`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ k: key, pin, asset_ids: ids }) });
              const listC = await resC.json().catch(()=>null);
              if (resC.ok && Array.isArray(listC)) {
                const map: any = {};
                listC.forEach((it:any)=>{ if (it && it.asset_id) map[it.asset_id] = it.latest || undefined; });
                setLatestByAsset(prev => ({ ...prev, ...map }));
              }
            } catch {}
          }
          // Fetch likes if allowed (bit 4)
          if ((meta.permissions & 4) === 4) {
            try {
              const sid = getViewerSessionId();
              const resL = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/likes/counts-by-assets`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ k: key, pin, asset_ids: ids, viewer_session_id: sid }) });
              const listL = await resL.json().catch(()=>null);
              if (resL.ok && Array.isArray(listL)) {
                const map: any = {};
                listL.forEach((it:any)=>{ if (it && it.asset_id) map[it.asset_id] = it; });
                setLikesByAsset(prev => ({ ...prev, ...map }));
              }
            } catch {}
          }
        }
      } catch (e:any) {
        setError(e?.message || 'Failed to load');
        setHasMore(false);
      } finally { setLoading(false); }
    })();
  }, [meta, linkId, key, qp, page, hasMore, loading, needsPin, tab, sort]);

  // When sort changes, reset paging state (approved tab)
  React.useEffect(() => {
    setThumbs([]);
    setPage(1);
    setHasMore(true);
  }, [sort]);

  // Prefetch wraps for visible thumbnails to reduce latency on decrypt.
  React.useEffect(() => {
    (async () => {
      try {
        if (!linkId || !key || !smkHex) return;
        // Collect a batch of asset_ids that are on-screen or in current page and missing thumb wraps
        const batch: string[] = [];
        for (const t of thumbs) {
          const id = t.asset_id;
          if (!id) continue;
          const w = wrapCache.get(id);
          if (w && w.thumb) continue;
          const k = `thumb:${id}`;
          const last = wrapsCheckedRef.current.get(k) || 0;
          if (Date.now() - last < CHECK_TTL_MS) continue;
          batch.push(id);
          if (batch.length >= 60) break;
        }
        if (batch.length === 0) return;
        const qp = new URLSearchParams(); qp.set('k', key); if (pin) qp.set('pin', pin); qp.set('asset_ids', batch.join(',')); qp.set('variant', 'thumb');
        const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/e2ee/wraps?${qp.toString()}`);
        const j = await res.json().catch(()=>null);
        // Mark checked regardless of result to avoid hammering
        for (const id of batch) wrapsCheckedRef.current.set(`thumb:${id}`, Date.now());
        if (!res.ok || !j || !Array.isArray(j.items) || j.items.length === 0) return;
        let added = 0;
        setWrapCache(prev => {
          const n = new Map(prev);
          for (const it of j.items as Array<{ asset_id: string; variant: 'orig' | 'thumb'; [k: string]: any }>) {
            const id = it.asset_id; if (!id) continue;
            const v: 'orig' | 'thumb' = it.variant as any;
            const cur = (n.get(id) || {}) as Partial<Record<'orig' | 'thumb', any>>;
            if (!cur[v]) { added++; }
            cur[v] = it;
            n.set(id, cur as { orig?: any; thumb?: any });
          }
          return n;
        });
        if (added > 0) setWrapCacheVersion(v => v + 1);
      } catch {}
    })();
  }, [linkId, key, pin, smkHex, thumbs, wrapCacheVersion]);

  const refreshStats = React.useCallback(async () => {
    try {
      if (!linkId || !meta?.moderation_enabled || !meta?.is_owner) return;
      const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/stats?${qp}`);
      const j = await res.json().catch(()=>null);
      if (res.ok && j) { setApprovedCount(j.approved_count); setPendingCount(j.pending_count); }
    } catch {}
  }, [linkId, meta?.moderation_enabled, meta?.is_owner, qp]);

  React.useEffect(() => { refreshStats(); }, [refreshStats]);

  // Load pending list for owner when moderation is enabled
  React.useEffect(() => {
    (async () => {
      if (!meta?.moderation_enabled || !meta?.is_owner || tab !== 'pending') return;
      try {
        const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId!)}/assets/pending?page=1&limit=200&_=${Date.now()}`);
        const j = await res.json().catch(()=>null);
        if (res.ok && j && Array.isArray(j.asset_ids)) {
          setPendingThumbs(j.asset_ids.map((id:string)=>({ asset_id: id })));
        } else { setPendingThumbs([]); }
      } catch { setPendingThumbs([]); }
    })();
  }, [meta?.moderation_enabled, meta?.is_owner, tab, linkId]);

  // Refresh assets after uploads complete
  const handleUploadsComplete = React.useCallback(() => {
    // Reset and refetch from first page so new uploads appear
    setThumbs([]);
    setPage(1);
    setHasMore(true);
    setError('');
    // A subsequent effect will refetch page 1 because hasMore=true and page=1
  }, []);

  const openViewerAt = React.useCallback((idx: number) => {
    setViewerIndex(idx);
    setHighlightIndex(idx);
  }, []);

  const closeViewer = React.useCallback(() => setViewerIndex(null), []);

  const goPrev = React.useCallback((e?: React.MouseEvent) => {
    if (e) { e.preventDefault(); e.stopPropagation(); }
    setViewerIndex((i) => (i==null?i: Math.max(0, i-1)));
  }, []);

  const goNext = React.useCallback((e?: React.MouseEvent) => {
    if (e) { e.preventDefault(); e.stopPropagation(); }
    setViewerIndex((i) => (i==null?i: Math.min(thumbs.length-1, i+1)));
  }, [thumbs.length]);

  // Slideshow: wrap-around next
  const goNextWrap = React.useCallback(() => {
    setViewerIndex((i) => {
      if (i == null) return i;
      const n = thumbs.length;
      if (n <= 0) return i;
      return (i + 1) % n;
    });
  }, [thumbs.length]);

  // Prefetch original wraps for current and neighbor items when the lightbox opens/moves.
  React.useEffect(() => {
    (async () => {
      try {
        if (viewerIndex == null) return;
        if (!linkId || !key || !smkHex) return;
        const ids: string[] = [];
        const cur = thumbs[viewerIndex]?.asset_id; if (cur) ids.push(cur);
        const prev = viewerIndex > 0 ? thumbs[viewerIndex-1]?.asset_id : undefined; if (prev) ids.push(prev);
        const next = viewerIndex < thumbs.length-1 ? thumbs[viewerIndex+1]?.asset_id : undefined; if (next) ids.push(next);
        const missing = ids.filter((id) => {
          const w = wrapCache.get(id);
          return !(w && w.orig);
        });
        if (missing.length === 0) return;
        const qp = new URLSearchParams(); qp.set('k', key); if (pin) qp.set('pin', pin); qp.set('asset_ids', missing.join(',')); qp.set('variant', 'orig');
        const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/e2ee/wraps?${qp.toString()}`);
        const j = await res.json().catch(()=>null);
        if (!res.ok || !j || !Array.isArray(j.items)) return;
        setWrapCache((prev) => {
          const n = new Map(prev);
          for (const it of j.items as Array<{ asset_id: string; variant: 'orig'|'thumb'; [k: string]: any }>) {
            const id = it.asset_id; if (!id) continue;
            const cur = (n.get(id) || {}) as Partial<Record<'orig'|'thumb', any>>;
            cur[it.variant] = it;
            n.set(id, cur as { orig?: any; thumb?: any });
          }
          return n;
        });
      } catch {}
    })();
  }, [viewerIndex, thumbs, linkId, key, pin, smkHex, wrapCache, setWrapCache]);

  // Probe Content-Type and meta to decide if it's a video
  React.useEffect(() => {
    let cancelled = false;
    setForcedIsVideo(null);
    setVideoDuration(0); setVideoTime(0); setVideoPaused(true);
    if (viewerIndex == null) return;
    const id = thumbs[viewerIndex]?.asset_id;
    if (!id) return;
    (async () => {
      try {
        const u = new URL(`/api/ee/public/${encodeURIComponent(linkId!)}/assets/${encodeURIComponent(id)}/image`, window.location.origin);
        if (key) u.searchParams.set('k', key);
        if (pin) u.searchParams.set('pin', pin);
        const res = await fetch(u.toString(), { method: 'HEAD' });
        const ct = res.headers.get('content-type') || '';
        if (ct.startsWith('video/')) { if (!cancelled) setForcedIsVideo(true); return; }
        if (ct.includes('octet-stream')) {
          // Locked: consult meta
          try {
            const mu = new URL(`/api/ee/public/${encodeURIComponent(linkId!)}/assets/${encodeURIComponent(id)}/meta`, window.location.origin);
            if (key) mu.searchParams.set('k', key);
            if (pin) mu.searchParams.set('pin', pin);
            const mres = await fetch(mu.toString());
            const mj = await mres.json().catch(()=>null);
            if (mres.ok && mj && typeof mj.is_video === 'boolean') {
              if (!cancelled) setForcedIsVideo(!!mj.is_video);
              return;
            }
          } catch {}
        }
        if (!cancelled) setForcedIsVideo(false);
      } catch {
        if (!cancelled) setForcedIsVideo(false);
      }
    })();
    return () => { cancelled = true; };
  }, [viewerIndex, thumbs, linkId, key, pin]);

  // Try to autoplay when video is opened
  React.useEffect(() => {
    if (viewerIndex == null) return;
    if (!forcedIsVideo) return;
    if (videoViewerRef.current) {
      videoViewerRef.current.play().then(() => setVideoPaused(false)).catch(() => setVideoPaused(true));
    }
  }, [viewerIndex, forcedIsVideo]);

  // Keep highlight index in sync with the current viewer slide
  React.useEffect(() => {
    if (viewerIndex != null) setHighlightIndex(viewerIndex);
  }, [viewerIndex]);

  // Slideshow auto-advance: images advance by timer; videos advance on ended
  React.useEffect(() => {
    if (!slideshowActive) return;
    if (viewerIndex == null) return;
    if (forcedIsVideo === false) {
      const id = window.setTimeout(() => { goNextWrap(); }, SLIDESHOW_DELAY_MS);
      return () => window.clearTimeout(id);
    }
  }, [slideshowActive, viewerIndex, forcedIsVideo, goNextWrap]);

  if (!linkId || !key) {
    return (
      <div className="p-6 max-w-3xl mx-auto">
        <h1 className="text-xl font-semibold mb-2">Public link</h1>
        <div className="text-sm text-muted-foreground">Missing required parameters.</div>
      </div>
    );
  }

  if (needsPin) {
    return (
      <div className="p-6 max-w-md mx-auto">
        <h1 className="text-xl font-semibold mb-2">Enter PIN</h1>
        <p className="text-sm text-muted-foreground mb-3">This link requires an 8‑character PIN.</p>
        <div className="flex items-center gap-2">
          <input type="password" maxLength={8} className="border border-border rounded p-2 bg-background flex-1" value={pin} onChange={(e)=> setPin(e.target.value.slice(0,8))} placeholder="••••••••" />
          <button
            className="px-3 py-2 rounded bg-primary text-primary-foreground disabled:opacity-50"
            disabled={pin.length!==8}
            onClick={() => {
              try { if (linkId && pin.length === 8) localStorage.setItem(`publicPin:${linkId}`, JSON.stringify({ pin, ts: Date.now() })); } catch {}
              // Reflect PIN in URL (without reload) so refresh keeps access for 3 days
              try {
                if (typeof window !== 'undefined' && linkId && pin.length === 8) {
                  const u = new URL(window.location.href);
                  u.searchParams.set('pin', pin);
                  window.history.replaceState({}, '', u.toString());
                }
              } catch {}
              setNeedsPin(false);
            }}
          >
            Continue
          </button>
        </div>
        {error && <div className="text-sm text-red-600 mt-2">{error}</div>}
      </div>
    );
  }

  return (
    <div className="p-4 max-w-6xl mx-auto">
      <div className="flex items-center justify-between mb-3 relative">
        <div className="flex items-center gap-4">
          <h1 className="text-xl font-semibold">{meta?.name || 'Shared'}</h1>
          {meta?.moderation_enabled && meta?.is_owner ? (
            <div className="inline-flex items-center gap-1 border border-border rounded overflow-hidden">
              <button className={`px-2 py-1 text-sm ${tab==='approved'?'bg-primary text-primary-foreground':''}`} onClick={()=>{ setTab('approved'); setSelectMode(false); setSelected(new Set()); }}>{`Approved${typeof approvedCount==='number' ? ` (${approvedCount})` : ''}`}</button>
              <button className={`px-2 py-1 text-sm ${tab==='pending'?'bg-primary text-primary-foreground':''}`} onClick={()=>{ setTab('pending'); setSelectMode(false); setSelected(new Set()); }}>{`Pending${typeof pendingCount==='number' ? ` (${pendingCount})` : ''}`}</button>
            </div>
          ) : null}
        </div>
        <div className="flex items-center gap-2">
          {(meta?.permissions & 8) === 8 ? (
            <button className="px-3 py-1.5 rounded border border-border bg-background hover:bg-muted text-sm" onClick={()=> setShowUpload(true)}>
              Bulk Upload
            </button>
          ) : null}
          {tab === 'approved' && (
            <button
              className="px-2 py-1.5 rounded border border-border bg-background hover:bg-muted"
              onClick={() => {
                if (thumbs.length === 0) return;
                const startIdx = Math.min(Math.max(0, highlightIndex), Math.max(0, thumbs.length - 1));
                if (viewerIndex == null) setViewerIndex(startIdx);
                setSlideshowActive(true);
              }}
              title="Slideshow"
              aria-label="Slideshow"
              disabled={thumbs.length === 0}
            >
              <Play className="w-4 h-4" />
            </button>
          )}
          <div className="relative">
            <button className="px-2 py-1.5 rounded border border-border bg-background hover:bg-muted" onClick={()=> setShowSortMenu(v=>!v)} title="Sort" aria-label="Sort">
              <SortIcon className="w-4 h-4" />
            </button>
            {showSortMenu && (
              <div className="absolute right-0 mt-1 w-64 bg-background text-foreground border border-border rounded shadow-md z-50">
                {[
                  { key: 'newest', label: 'By upload time (newest first)' },
                  { key: 'oldest', label: 'By upload time (oldest first)' },
                  { key: 'liked',  label: 'Most Liked' },
                ].map((opt:any) => (
                  <button
                    key={opt.key}
                    className={`w-full text-left px-3 py-2 hover:bg-muted flex items-center justify-between ${sort===opt.key ? 'font-medium' : ''}`}
                    onClick={()=> { setSort(opt.key); setShowSortMenu(false); }}
                  >
                    <span>{opt.label}</span>
                    {sort===opt.key && <CheckIcon className="w-4 h-4" />}
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
      {coverUrl && (
        <div className="mb-4">
          <img
            src={coverUrl}
            alt=""
            className="w-full max-h-[360px] object-cover rounded border border-border"
            onError={() => setCoverUrl('')}
          />
        </div>
      )}
      {tab==='approved' && (
        <div>
          {meta?.is_owner && (
            <div className="flex items-center justify-between mb-2">
              <button className="px-2 py-1 border rounded" onClick={()=> { setSelectMode(m => !m); if (!selectMode) setSelected(new Set()); }}>{selectMode ? 'Cancel' : 'Select'}</button>
              {selectMode && (
                <div className="flex items-center gap-2">
                  <button className="px-2 py-1 border rounded" onClick={()=> setSelected(new Set(thumbs.map(t=>t.asset_id)))}>Select all</button>
                  {selected.size > 0 && (
                    <button className="text-xs text-muted-foreground hover:underline" onClick={()=> setSelected(new Set())} aria-label="Select none" title="Select none">None</button>
                  )}
                  <button className="px-2 py-1 border rounded bg-red-600 text-white disabled:opacity-50" disabled={selected.size===0} onClick={()=> { setDeleteContext('approved'); setShowDeleteConfirm(true); }}>Delete</button>
                </div>
              )}
            </div>
          )}
          <div className="grid grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-2">
            {thumbs.map((t, idx) => (
              <div key={t.asset_id}>
                <button
                  onClick={() => { if (selectMode) { setSelected(prev => { const n = new Set(prev); if (n.has(t.asset_id)) n.delete(t.asset_id); else n.add(t.asset_id); return n; }); } else { openViewerAt(idx); } }}
                  onMouseEnter={() => setHighlightIndex(idx)}
                  onFocus={() => setHighlightIndex(idx)}
                  className={`relative block aspect-square rounded border ${selected.has(t.asset_id) ? 'ring-2 ring-primary border-primary' : 'border-border'} overflow-hidden bg-muted focus:outline-none w-full`}
                >
                  <PublicThumbImage linkId={linkId!} k={key!} pin={pin} assetId={t.asset_id} smkHex={smkHex} wrapCache={wrapCache} setWrapCache={setWrapCache} />
                  {selectMode && (
                    <span className={`absolute top-1 left-1 w-5 h-5 rounded-full ${selected.has(t.asset_id) ? 'bg-primary text-primary-foreground' : 'bg-background text-foreground'} border border-border grid place-items-center text-[11px]`}>✓</span>
                  )}
                </button>
                {EE_ENABLED && (meta?.permissions !== undefined && ((meta.permissions & 2) === 2 || (meta.permissions & 4) === 4)) && (
                  <div className="mt-1 flex items-center gap-2 text-xs">
                    {(meta.permissions & 2) === 2 && (
                      <button className="flex-1 text-left truncate px-1 py-0.5 rounded border border-border hover:bg-muted" onClick={()=> setShowCommentsFor(t.asset_id)} disabled={selectMode} aria-disabled={selectMode}>
                        {latestByAsset[t.asset_id] ? (<span><span className="font-medium">{latestByAsset[t.asset_id]?.author_display_name}:</span> {latestByAsset[t.asset_id]?.body}</span>) : (<span className="text-muted-foreground">Add a comment…</span>)}
                      </button>
                    )}
                    {(meta.permissions & 4) === 4 && (
                      <button className={`inline-flex items-center gap-1 px-1 py-0.5 rounded border border-border ${likesByAsset[t.asset_id]?.liked_by_me ? 'bg-red-600/10 text-red-600' : ''} ${selectMode ? 'opacity-50 cursor-not-allowed' : ''}`} disabled={selectMode} onClick={async()=>{
                        try {
                          const sid = getViewerSessionId();
                          const like = !likesByAsset[t.asset_id]?.liked_by_me;
                          const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/likes/toggle`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ k: key, pin, asset_id: t.asset_id, like, viewer_session_id: sid }) });
                          const j = await res.json().catch(()=>null);
                          if (res.ok && j) { setLikesByAsset(prev => ({ ...prev, [t.asset_id]: j })); }
                        } catch {}
                      }} title="Like" aria-label="Like">
                        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-4 h-4" fill={likesByAsset[t.asset_id]?.liked_by_me ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78L12 21.23l8.84-8.84a5.5 5.5 0 0 0 0-7.78z"/></svg>
                        <span>{likesByAsset[t.asset_id]?.count ?? 0}</span>
                      </button>
                    )}
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}
      {tab==='pending' && meta?.moderation_enabled && meta?.is_owner && (
        <div>
          <div className="flex items-center justify-between mb-2">
            <button className="px-2 py-1 border rounded" onClick={()=> { setSelectMode(m => !m); if (!selectMode) setSelected(new Set()); }}>{selectMode ? 'Cancel' : 'Select'}</button>
            {selectMode && (
              <div className="flex items-center gap-2">
                <button className="px-2 py-1 border rounded" onClick={()=> setSelected(new Set(pendingThumbs.map(t=>t.asset_id)))}>Select all</button>
                <button className="px-2 py-1 border rounded bg-green-600 text-white disabled:opacity-50" disabled={selected.size===0} onClick={async()=>{
                  const ids = Array.from(selected);
                  await fetch(`/api/ee/public/${encodeURIComponent(linkId!)}/moderate`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'approve', asset_ids: ids }) });
                  setSelected(new Set()); setSelectMode(false);
                  // Refresh approved list and stats
                  setTab('approved'); setThumbs([]); setPage(1); setHasMore(true);
                  try { await refreshStats(); } catch {}
                }}>Approve</button>
                <button className="px-2 py-1 border rounded bg-red-600 text-white disabled:opacity-50" disabled={selected.size===0} onClick={()=> { setDeleteContext('pending'); setShowDeleteConfirm(true); }}>Delete</button>
              </div>
            )}
          </div>
          <div className="grid grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-2">
            {pendingThumbs.map((t) => (
              <button key={t.asset_id} className={`relative block aspect-square rounded border ${selected.has(t.asset_id)?'ring-2 ring-primary':''}`} onClick={()=>{ if (!selectMode) return; setSelected(prev => { const n = new Set(prev); if (n.has(t.asset_id)) n.delete(t.asset_id); else n.add(t.asset_id); return n; }); }}>
                <img src={`/api/thumbnails/${encodeURIComponent(t.asset_id)}`} alt={t.asset_id} className="w-full h-full object-cover rounded" />
                {selectMode && (<span className="absolute top-1 right-1 w-5 h-5 rounded-full bg-background border border-border grid place-items-center text-xs">{selected.has(t.asset_id)?'✓':''}</span>)}
              </button>
            ))}
            {pendingThumbs.length===0 && (<div className="text-sm text-muted-foreground">No pending items.</div>)}
          </div>
        </div>
      )}
      {loading && (<div className="text-sm text-muted-foreground mt-3">Loading…</div>)}
      {!loading && hasMore && (
        <div className="mt-3">
          <button className="px-3 py-1.5 rounded border border-border" onClick={()=> setPage(p=>p+1)}>Load more</button>
        </div>
      )}
      {error && (<div className="text-sm text-red-600 mt-3">{error}</div>)}
      {showUpload && (
        <UploadDashboardModal
          open={showUpload}
          onClose={()=> setShowUpload(false)}
          onComplete={handleUploadsComplete}
          moderationEnabled={!!meta?.moderation_enabled}
          isOwner={!!meta?.is_owner}
        />
      )}
      {viewerIndex != null && thumbs[viewerIndex] && (
        <div className="fullscreen-viewer" onClick={closeViewer}>
          {/* Close button (top-left) */}
          <button
            className="absolute top-3 left-3 w-9 h-9 grid place-items-center rounded-full border border-border bg-card/80 text-foreground hover:bg-card z-[80]"
            onClick={(e) => { e.stopPropagation(); setSlideshowActive(false); closeViewer(); }}
            aria-label="Close"
            title="Close"
          >
            <XIcon className="w-5 h-5" />
          </button>
          {/* Prev */}
          <button
            className="absolute left-3 top-1/2 -translate-y-1/2 w-10 h-10 grid place-items-center rounded-full border border-border bg-card/80 text-foreground hover:bg-card z-[80]"
            onClick={goPrev}
            aria-label="Previous"
            title="Previous"
          >
            <ChevronLeft className="w-6 h-6" />
          </button>
          {/* Next */}
          <button
            className="absolute right-3 top-1/2 -translate-y-1/2 w-10 h-10 grid place-items-center rounded-full border border-border bg-card/80 text-foreground hover:bg-card z-[80]"
            onClick={goNext}
            aria-label="Next"
            title="Next"
          >
            <ChevronRight className="w-6 h-6" />
          </button>
          {/* Media: video with controls or image */}
          {forcedIsVideo ? (
            <>
              <video
                ref={videoViewerRef}
                className="fullscreen-image"
                src={`/api/ee/public/${encodeURIComponent(linkId)}/assets/${encodeURIComponent(thumbs[viewerIndex].asset_id)}/image?${qp}`}
                poster={`/api/ee/public/${encodeURIComponent(linkId)}/assets/${encodeURIComponent(thumbs[viewerIndex].asset_id)}/thumbnail?${qp}`}
                playsInline
                preload="metadata"
                muted={videoMuted}
                onClick={(e)=> e.stopPropagation()}
                onTimeUpdate={(e) => { try { setVideoTime(e.currentTarget.currentTime || 0); } catch {} }}
                onLoadedMetadata={(e) => { try { setVideoDuration(e.currentTarget.duration || 0); } catch {} }}
                onPlay={() => setVideoPaused(false)}
                onPause={() => setVideoPaused(true)}
                onEnded={() => { if (slideshowActive) { goNextWrap(); } }}
              />
              {/* Controls overlay */}
              <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-[90] bg-black/50 text-white rounded px-3 py-2 flex items-center gap-3"
                   onClick={(e)=> e.stopPropagation()}>
                <button className="w-8 h-8 grid place-items-center" onClick={() => { if (!videoViewerRef.current) return; if (videoPaused) { videoViewerRef.current.play(); } else { videoViewerRef.current.pause(); } }} title={videoPaused ? 'Play' : 'Pause'} aria-label={videoPaused ? 'Play' : 'Pause'}>
                  {videoPaused ? <Play className="w-5 h-5" /> : <Pause className="w-5 h-5" />}
                </button>
                <button className="w-8 h-8 grid place-items-center" onClick={() => { if (!videoViewerRef.current) return; videoViewerRef.current.muted = !videoViewerRef.current.muted; setVideoMuted(videoViewerRef.current.muted); }} title={videoMuted ? 'Unmute' : 'Mute'} aria-label={videoMuted ? 'Unmute' : 'Mute'}>
                  {videoMuted ? <VolumeX className="w-5 h-5" /> : <Volume2 className="w-5 h-5" />}
                </button>
                <input
                  type="range"
                  min={0}
                  max={videoDuration > 0 ? videoDuration : Math.max(1, videoTime)}
                  step={0.1}
                  value={Math.min(videoDuration || 0, videoTime)}
                  onChange={(e) => { const t = Number(e.target.value) || 0; setVideoTime(t); if (videoViewerRef.current) { try { videoViewerRef.current.currentTime = t; } catch {} } }}
                  onMouseDown={() => setScrubbing(true)}
                  onMouseUp={() => setScrubbing(false)}
                  className="w-64 h-1.5 bg-white/20 rounded accent-white"
                />
              </div>
            </>
          ) : (
            <PublicViewerImage linkId={linkId!} k={key!} pin={pin} assetId={thumbs[viewerIndex].asset_id} smkHex={smkHex} wrapCache={wrapCache} setWrapCache={setWrapCache} />
          )}
        </div>
      )}
  {/* Delete confirmation dialog */}
      {showDeleteConfirm && (
        <div className="fixed inset-0 z-[99999] bg-black/50" onClick={()=> setShowDeleteConfirm(false)}>
          <div className="absolute inset-x-0 bottom-0 md:inset-auto md:top-1/2 md:left-1/2 md:-translate-x-1/2 md:-translate-y-1/2 md:w-[480px] bg-background border border-border rounded-t-lg md:rounded-lg p-4" onClick={(e)=>e.stopPropagation()}>
            <div className="font-medium mb-2">{deleteContext==='pending' ? 'Delete pending items' : 'Delete items'}</div>
            <div className="text-sm text-muted-foreground mb-4">{deleteContext==='pending' ? 'Are you sure you want to delete the selected pending item(s)? They will be removed from this public link.' : 'Are you sure you want to delete the selected item(s)? They will be removed from this public link.'}</div>
            <div className="flex items-center justify-end gap-2">
              <button className="px-3 py-1.5 rounded border border-border" onClick={()=> setShowDeleteConfirm(false)}>Cancel</button>
              <button className="px-3 py-1.5 rounded bg-red-600 text-white disabled:opacity-50" onClick={async()=>{
                const ids = Array.from(selected);
                await fetch(`/api/ee/public/${encodeURIComponent(linkId!)}/moderate`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'delete', asset_ids: ids }) });
                setShowDeleteConfirm(false);
                setSelected(new Set()); setSelectMode(false);
                if (deleteContext === 'pending') {
                  // Refresh pending list & stats
                  try { const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId!)}/assets/pending?page=1&limit=200&_=${Date.now()}`); const j = await res.json().catch(()=>null); if (res.ok && j?.asset_ids) setPendingThumbs(j.asset_ids.map((id:string)=>({ asset_id:id }))); } catch {}
                  try { await refreshStats(); } catch {}
                } else {
                  // Refresh approved list & stats
                  setThumbs([]); setPage(1); setHasMore(true); setError('');
                  try { await refreshStats(); } catch {}
                }
              }}>Delete</button>
            </div>
          </div>
        </div>
      )}
      {/* Comments dialog (EE only) */}
      {EE_ENABLED && showCommentsFor && (
        <CommentsDialogPublic linkId={linkId} k={key!} pin={pin} assetId={showCommentsFor} onClose={()=> setShowCommentsFor(null)} onNew={(c)=> setLatestByAsset(prev => ({ ...prev, [showCommentsFor!]: c }))} />
      )}
    </div>
  );
}

function useWraps(linkId: string, k: string, pin: string, assetId: string, wrapCache: Map<string, { orig?: any; thumb?: any }>, setWrapCache: React.Dispatch<React.SetStateAction<Map<string, { orig?: any; thumb?: any }>>>) {
  return React.useCallback(async (): Promise<{ orig?: any; thumb?: any }> => {
    const cached = wrapCache.get(assetId);
    if (cached) return cached;
    try {
      const q = new URLSearchParams(); q.set('k', k); if (pin) q.set('pin', pin); q.set('asset_ids', assetId);
      const fetchOnce = async (): Promise<any> => {
        const r = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/e2ee/wraps?${q.toString()}`);
        const jj = await r.json().catch(()=>null);
        const m: any = {};
        if (r.ok && jj && Array.isArray(jj.items)) {
          for (const it of jj.items) { if (it && it.asset_id === assetId && (it.variant === 'orig' || it.variant === 'thumb')) { m[it.variant] = it; } }
        }
        return m;
      };
      let byVar: any = await fetchOnce();
      // If wraps are not ready yet (owner may be auto-preparing), retry once shortly.
      if (!byVar || Object.keys(byVar).length === 0) {
        await new Promise(r => setTimeout(r, 1200));
        byVar = await fetchOnce();
      }
      if (byVar && Object.keys(byVar).length > 0) {
        setWrapCache(prev => { const n = new Map(prev); n.set(assetId, byVar); return n; });
      }
      return byVar || {};
    } catch {
      return {};
    }
  }, [assetId, k, linkId, pin, wrapCache, setWrapCache]);
}

function PublicThumbImage({ linkId, k, pin, assetId, smkHex, wrapCache, setWrapCache }: { linkId: string; k: string; pin: string; assetId: string; smkHex: string | null; wrapCache: Map<string, {orig?: any; thumb?: any}>; setWrapCache: React.Dispatch<React.SetStateAction<Map<string, {orig?: any; thumb?: any}>>> }) {
  const [src, setSrc] = React.useState<string>('');
  const [err, setErr] = React.useState<string>('');
  const ensureWraps = useWraps(linkId, k, pin, assetId, wrapCache, setWrapCache);
  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setErr(''); setSrc('');
        const qp = new URLSearchParams(); qp.set('k', k); if (pin) qp.set('pin', pin); if (getViewerKeyFromHash()) qp.set('vk','1');
        const url = `/api/ee/public/${encodeURIComponent(linkId)}/assets/${encodeURIComponent(assetId)}/thumbnail?${qp}`;
        const { buf, contentType } = await fetchArrayBuffer(url);
        if (contentType && contentType.includes('image/')) {
          if (!cancelled) setSrc(bytesToBlobUrl(buf, contentType));
          return;
        }
        // Locked path
        if (!smkHex) { if (!cancelled) { setErr(''); setSrc(TRANSPARENT_PLACEHOLDER); } return; }
        const wraps = await ensureWraps();
        const wrap = wraps.thumb || wraps.orig; // server may fallback to orig
        if (!wrap) { if (!cancelled) { setErr(''); setSrc(TRANSPARENT_PLACEHOLDER); } return; }
        const out = await decryptPae3WithSmk(buf, smkHex, wrap.encrypted_by_user_id, { wrap_iv_b64: wrap.wrap_iv_b64, dek_wrapped_b64: wrap.dek_wrapped_b64 });
        if (!cancelled) setSrc(bytesToImageBlobUrl(out));
      } catch (e:any) { if (!cancelled) { try { console.warn('[PUBLIC] thumb decrypt failed', assetId, e); } catch {}; setErr(e?.message || ''); setSrc(TRANSPARENT_PLACEHOLDER); } }
    })();
    return () => { cancelled = true; };
  }, [linkId, k, pin, assetId, smkHex]);
  const directUrl = `/api/ee/public/${encodeURIComponent(linkId)}/assets/${encodeURIComponent(assetId)}/thumbnail?k=${encodeURIComponent(k)}${pin?`&pin=${encodeURIComponent(pin)}`:''}${getViewerKeyFromHash()?'&vk=1':''}`;
  // If E2EE context is present, avoid direct network src fallback to prevent infinite 404 retries
  const safeSrc = src || (smkHex ? TRANSPARENT_PLACEHOLDER : directUrl);
  return <img src={safeSrc} alt={assetId} className="w-full h-full object-cover" />
}

function PublicViewerImage({ linkId, k, pin, assetId, smkHex, wrapCache, setWrapCache }: { linkId: string; k: string; pin: string; assetId: string; smkHex: string | null; wrapCache: Map<string, {orig?: any; thumb?: any}>; setWrapCache: React.Dispatch<React.SetStateAction<Map<string, {orig?: any; thumb?: any}>>> }) {
  const [src, setSrc] = React.useState<string>('');
  const [err, setErr] = React.useState<string>('');
  const ensureWraps = useWraps(linkId, k, pin, assetId, wrapCache, setWrapCache);
  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setErr(''); setSrc('');
        const qp = new URLSearchParams(); qp.set('k', k); if (pin) qp.set('pin', pin); if (getViewerKeyFromHash()) qp.set('vk','1');
        const url = `/api/ee/public/${encodeURIComponent(linkId)}/assets/${encodeURIComponent(assetId)}/image?${qp}`;
        const { buf, contentType } = await fetchArrayBuffer(url);
        if (contentType && !contentType.includes('octet-stream')) {
          if (!cancelled) setSrc(bytesToBlobUrl(buf, contentType));
          return;
        }
        // Locked
        if (!smkHex) { if (!cancelled) { setErr(''); setSrc(TRANSPARENT_PLACEHOLDER); } return; }
        const wraps = await ensureWraps();
        const wrap = wraps.orig; // originals only
        if (!wrap) { if (!cancelled) { setErr(''); setSrc(TRANSPARENT_PLACEHOLDER); } return; }
        const out = await decryptPae3WithSmk(buf, smkHex, wrap.encrypted_by_user_id, { wrap_iv_b64: wrap.wrap_iv_b64, dek_wrapped_b64: wrap.dek_wrapped_b64 });
        if (!cancelled) setSrc(bytesToImageBlobUrl(out));
      } catch (e:any) { if (!cancelled) { try { console.warn('[PUBLIC] image decrypt failed', assetId, e); } catch {}; setErr(e?.message || ''); setSrc(TRANSPARENT_PLACEHOLDER); } }
    })();
    return () => { cancelled = true; };
  }, [linkId, k, pin, assetId, smkHex]);
  const directUrl = `/api/ee/public/${encodeURIComponent(linkId)}/assets/${encodeURIComponent(assetId)}/image?k=${encodeURIComponent(k)}${pin?`&pin=${encodeURIComponent(pin)}`:''}${getViewerKeyFromHash()?'&vk=1':''}`;
  const safeSrc = src || (smkHex ? TRANSPARENT_PLACEHOLDER : directUrl);
  return <img src={safeSrc} alt={assetId} className="fullscreen-image" onClick={(e) => e.stopPropagation()} />
}

function getViewerSessionId(): string {
  try {
    const k = 'publicViewerSessionId';
    const v = localStorage.getItem(k);
    if (v) return v;
    const id = crypto.randomUUID();
    localStorage.setItem(k, id);
    return id;
  } catch { return 'anon'; }
}

function getStoredDisplayName(): string {
  try {
    const k = 'publicDisplayName';
    const v = localStorage.getItem(k);
    if (v && v.trim()) return v.trim();
    return '';
  } catch { return ''; }
}

function CommentsDialogPublic({ linkId, k, pin, assetId, onClose, onNew }: { linkId: string; k: string; pin: string; assetId: string; onClose: ()=>void; onNew: (c: { id: string; author_display_name: string; body: string; created_at: number })=>void }) {
  const authName = useAuthStore((s) => s.user?.name || '');
  const hasHydrated = useAuthStore((s) => s.hasHydrated);
  const [items, setItems] = React.useState<any[]>([]);
  const [text, setText] = React.useState('');
  const [error, setError] = React.useState('');
  const [busyDel, setBusyDel] = React.useState<string | null>(null);
  const [name, setName] = React.useState<string>('');
  // Keep the name field visible until we confirm/persist a non-empty value
  const [nameConfirmed, setNameConfirmed] = React.useState<boolean>(false);
  // Locked assets are not commentable on public links
  const [locked, setLocked] = React.useState<boolean>(false);
  const nameInputRef = React.useRef<HTMLInputElement|null>(null);
  // Prefer authenticated user's name; otherwise use locally stored display name
  React.useEffect(() => {
    const n = (authName || '').trim();
    if (n) { setName(n); setNameConfirmed(true); }
    else {
      const stored = getStoredDisplayName();
      setName(stored);
      if (stored) setNameConfirmed(true);
    }
  }, [authName]);
  React.useEffect(()=>{
    (async ()=>{
      try {
        const u = new URL(`/api/ee/public/${encodeURIComponent(linkId)}/comments`, window.location.origin);
        u.searchParams.set('k', k);
        if (pin) u.searchParams.set('pin', pin);
        u.searchParams.set('asset_id', assetId);
        u.searchParams.set('limit', '100');
        const res = await fetch(u.toString());
        const j = await res.json().catch(()=>null);
        // 404 here more likely means "not found" link/asset; do not imply EE disabled
        if (res.status === 404) { setItems([]); return; }
        if (res.ok && Array.isArray(j)) setItems(j);
      } catch {}
    })();
  }, [linkId, k, pin, assetId]);

  // Probe asset meta to detect lock status and disable commenting if locked
  React.useEffect(() => {
    (async () => {
      try {
        const mu = new URL(`/api/ee/public/${encodeURIComponent(linkId)}/assets/${encodeURIComponent(assetId)}/meta`, window.location.origin);
        mu.searchParams.set('k', k);
        if (pin) mu.searchParams.set('pin', pin);
        const res = await fetch(mu.toString());
        const j = await res.json().catch(()=>null);
        if (res.ok && j && typeof j.locked === 'boolean') setLocked(!!j.locked);
      } catch {}
    })();
  }, [linkId, k, pin, assetId]);
  return (
    <div className="fixed inset-0 z-[99999] bg-black/50" onClick={onClose}>
      <div className="absolute inset-x-0 bottom-0 md:inset-auto md:top-1/2 md:left-1/2 md:-translate-x-1/2 md:-translate-y-1/2 md:w-[560px] bg-background border border-border rounded-t-lg md:rounded-lg p-3 relative" onClick={(e)=>e.stopPropagation()}>
        {/* Close icon (top-right) */}
        <button
          className="absolute top-2 right-2 p-1.5 rounded-full border border-border hover:bg-muted"
          onClick={onClose}
          aria-label="Close"
          title="Close"
        >
          <XIcon className="w-4 h-4" />
        </button>
        <div className="font-medium mb-2 text-center">Comments</div>
        {hasHydrated && !nameConfirmed && (
          <div className="mb-2">
            <input
              ref={nameInputRef}
              className="w-full border border-border rounded p-2 bg-background"
              placeholder="Enter your name to comment"
              value={name}
              onChange={(e)=> setName(e.target.value)}
              autoFocus
            />
          </div>
        )}
        <div className="max-h-64 overflow-auto space-y-2 mb-2">
          {items.map((it:any) => (
            <div key={it.id} className="text-sm flex items-center gap-2">
              <div className="flex-1"><span className="font-medium">{it.author_display_name}:</span> {it.body}</div>
              {(it.viewer_session_id && it.viewer_session_id === getViewerSessionId()) && (
              <button className="text-xs px-2 py-0.5 rounded border border-border hover:bg-muted disabled:opacity-50" disabled={busyDel===it.id}
                onClick={async()=>{
                  setBusyDel(it.id); setError('');
                  try {
                    const sid = getViewerSessionId();
                    const u = new URL(`/api/ee/public/${encodeURIComponent(linkId)}/comments/${encodeURIComponent(it.id)}`, window.location.origin);
                    u.searchParams.set('k', k);
                    if (pin) u.searchParams.set('pin', pin);
                    u.searchParams.set('asset_id', assetId);
                    u.searchParams.set('sid', sid);
                    const res = await fetch(u.toString(), { method: 'DELETE' });
                    // Always refetch from server to avoid client drift when delete not permitted
                    const u2 = new URL(`/api/ee/public/${encodeURIComponent(linkId)}/comments`, window.location.origin);
                    u2.searchParams.set('k', k);
                    if (pin) u2.searchParams.set('pin', pin);
                    u2.searchParams.set('asset_id', assetId);
                    u2.searchParams.set('limit', '100');
                    const r2 = await fetch(u2.toString());
                    const j2 = await r2.json().catch(()=>null);
                    if (r2.ok && Array.isArray(j2)) setItems(j2);
                  } catch (e:any) { setError(e?.message || 'Failed to delete'); }
                  finally { setBusyDel(null); }
                }} aria-label="Delete" title="Delete">
                <TrashIcon className="w-4 h-4" />
              </button>)}
            </div>
          ))}
          {items.length===0 && (<div className="text-sm text-muted-foreground">No comments yet.</div>)}
        </div>
        <div className="flex items-center gap-2">
          <input className="flex-1 border border-border rounded p-2 bg-background" placeholder="Write a comment" value={text} onChange={(e)=> setText(e.target.value)} disabled={locked} />
          <button className="px-3 py-2 rounded bg-primary text-primary-foreground disabled:opacity-50" disabled={locked || !text.trim()} onClick={async()=>{
            try {
              const sid = getViewerSessionId();
              const displayName = (name || '').trim();
              if (!displayName) { nameInputRef.current?.focus(); setError('Please enter your name'); return; }
              try { localStorage.setItem('publicDisplayName', displayName); setNameConfirmed(true); } catch { setNameConfirmed(true); }
              const res = await fetch(`/api/ee/public/${encodeURIComponent(linkId)}/comments`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ k, pin, asset_id: assetId, body: text, author_display_name: displayName, viewer_session_id: sid }) });
              if (res.status === 404) {
                let msg = 'Comment not allowed for this item (locked or not part of this link).';
                try { const j = await res.json(); if (j?.error) msg = j.error; } catch {}
                setError(msg);
                return;
              }
              const j = await res.json().catch(()=>null);
              if (!res.ok || !j) throw new Error((j && j.message) || `Failed`);
              setItems((prev:any[]) => [j, ...prev]); setText(''); onNew(j);
            } catch (e:any) { setError(e?.message || 'Failed'); }
          }}>Send</button>
        </div>
        {locked && (<div className="text-xs text-muted-foreground mt-1">Comments are not available for locked items.</div>)}
        {error && (<div className="text-xs text-red-600 mt-1">{error}</div>)}
      </div>
    </div>
  );
}
  
