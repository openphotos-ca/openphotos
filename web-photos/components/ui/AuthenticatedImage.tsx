'use client';

import { useState, useEffect, useRef } from 'react';
import { useInView } from 'react-intersection-observer';
import { useAuthStore } from '@/lib/stores/auth';
import { useE2EEStore } from '@/lib/stores/e2ee';
import { logger } from '@/lib/logger';

const THUMBNAIL_CACHE_MAX_ENTRIES = 800;
let thumbnailCacheScopeKey: string | null = null;
const thumbnailObjectUrlCache = new Map<string, string>(); // LRU via insertion order
const THUMBNAIL_FETCH_CONCURRENCY = 4;
let activeThumbnailFetches = 0;
const thumbnailFetchWaiters: Array<() => void> = [];
let thumbnailNetworkCooldownUntilMs = 0;

function sleep(ms: number) {
  return new Promise<void>((resolve) => window.setTimeout(resolve, ms));
}

function normalizeErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message.toLowerCase();
  return String(error ?? '').toLowerCase();
}

function isTransientNetworkError(error: unknown): boolean {
  if (error instanceof DOMException) {
    const name = (error.name || '').toLowerCase();
    if (name === 'networkerror' || name === 'aborterror') return true;
  }
  const msg = normalizeErrorMessage(error);
  return (
    msg.includes('failed to fetch') ||
    msg.includes('network changed') ||
    msg.includes('networkerror') ||
    msg.includes('err_network_changed') ||
    msg.includes('load failed')
  );
}

async function waitForThumbnailFetchSlot() {
  if (activeThumbnailFetches < THUMBNAIL_FETCH_CONCURRENCY) {
    activeThumbnailFetches += 1;
    return;
  }
  await new Promise<void>((resolve) => {
    thumbnailFetchWaiters.push(resolve);
  });
  activeThumbnailFetches += 1;
}

function releaseThumbnailFetchSlot() {
  activeThumbnailFetches = Math.max(0, activeThumbnailFetches - 1);
  const next = thumbnailFetchWaiters.shift();
  if (next) next();
}

async function waitForThumbnailNetworkCooldown() {
  const waitMs = thumbnailNetworkCooldownUntilMs - Date.now();
  if (waitMs > 0) await sleep(waitMs);
}

function bumpThumbnailNetworkCooldown(ms: number) {
  thumbnailNetworkCooldownUntilMs = Math.max(thumbnailNetworkCooldownUntilMs, Date.now() + ms);
}

function clearThumbnailObjectUrlCache() {
  thumbnailObjectUrlCache.forEach((url) => {
    try { URL.revokeObjectURL(url); } catch {}
  });
  thumbnailObjectUrlCache.clear();
}

function ensureThumbnailCacheScope(scopeKey: string | null) {
  if (thumbnailCacheScopeKey !== scopeKey) {
    clearThumbnailObjectUrlCache();
    thumbnailCacheScopeKey = scopeKey;
  }
}

function getCachedThumbnailUrl(cacheKey: string): string | null {
  const url = thumbnailObjectUrlCache.get(cacheKey) || null;
  if (!url) return null;
  // refresh LRU
  thumbnailObjectUrlCache.delete(cacheKey);
  thumbnailObjectUrlCache.set(cacheKey, url);
  return url;
}

function putCachedThumbnailUrl(cacheKey: string, url: string) {
  const existing = thumbnailObjectUrlCache.get(cacheKey);
  if (existing) {
    try { URL.revokeObjectURL(existing); } catch {}
    thumbnailObjectUrlCache.delete(cacheKey);
  }
  thumbnailObjectUrlCache.set(cacheKey, url);
  while (thumbnailObjectUrlCache.size > THUMBNAIL_CACHE_MAX_ENTRIES) {
    const oldestKey = thumbnailObjectUrlCache.keys().next().value as string | undefined;
    if (!oldestKey) break;
    const oldestUrl = thumbnailObjectUrlCache.get(oldestKey);
    thumbnailObjectUrlCache.delete(oldestKey);
    if (oldestUrl) {
      try { URL.revokeObjectURL(oldestUrl); } catch {}
    }
  }
}

interface AuthenticatedImageProps {
  assetId: string;
  alt: string;
  className?: string;
  width?: number;
  height?: number;
  variant?: 'thumbnail' | 'original';
  progressive?: boolean; // if true and variant==='original', show thumb first then swap
  prefetchFullUrl?: string; // optional preloaded full image object URL
  lazy?: boolean; // when true, defers fetching until in view (default: true for thumbnails)
  lazyRootMargin?: string; // IntersectionObserver root margin (default: '800px')
  // Optional URL overrides for fetching. When present, these take precedence
  // over the default `/api/{thumbnails|images}/:assetId` endpoints.
  urlMap?: { thumbnail?: string; original?: string };
  [key: string]: any;
}

export function AuthenticatedImage({ 
  assetId, 
  alt, 
  className, 
  width, 
  height, 
  variant = 'thumbnail',
  progressive = false,
  prefetchFullUrl,
  lazy,
  lazyRootMargin,
  urlMap,
  ...props 
}: AuthenticatedImageProps) {
  const [blobUrl, setBlobUrl] = useState<string | null>(null);
  const [blobOwned, setBlobOwned] = useState(false);
  const [error, setError] = useState(false);
  const [lockedBlocked, setLockedBlocked] = useState(false);
  const [loading, setLoading] = useState(true);
  // Progressive states
  const [thumbUrl, setThumbUrl] = useState<string | null>(null);
  const [thumbOwned, setThumbOwned] = useState(false);
  const [fullUrl, setFullUrl] = useState<string | null>(null);
  const [fullReady, setFullReady] = useState(false);
  const [upgrading, setUpgrading] = useState(false); // indicates higher quality (e.g., AVIF) is loading
  const [fullOwned, setFullOwned] = useState(false); // whether this component created fullUrl (so it should revoke)
  const fullErrorRetriesRef = useRef<Map<string, number>>(new Map());
  const authState = useAuthStore();
  const { token } = authState;

  // Subscribe to unlock state; when it flips to true (remembered unlock), refetch
  const isUnlocked = useE2EEStore(s => s.isUnlocked);

  const lazyEnabled = (lazy ?? (variant === 'thumbnail')) && !(progressive && variant === 'original');
  const { ref: inViewRef, inView } = useInView({
    rootMargin: lazyRootMargin ?? '800px',
    triggerOnce: true,
    fallbackInView: true,
  });

  useEffect(() => {
    let isMounted = true;
		  // Reset state on asset/variant changes to avoid showing previous image while new loads
    setError(false);
    setLockedBlocked(false);
    if (progressive && variant === 'original') {
      setThumbUrl(null);
      setThumbOwned(false);
      setFullUrl(null);
      setFullReady(false);
      setUpgrading(false);
      setFullOwned(false);
      // progressive path manages its own skeleton; don't block on global loading state
      setLoading(false);
    } else {
      setBlobUrl(null);
      setBlobOwned(false);
      setLoading(true);
    }

    if (lazyEnabled && !inView) {
      // Don't start network work until the image is close to the viewport.
      return () => {
        isMounted = false;
        if (blobUrl && blobOwned) { try { URL.revokeObjectURL(blobUrl); } catch {} }
        if (thumbUrl && thumbOwned) { try { URL.revokeObjectURL(thumbUrl); } catch {} }
        if (fullUrl && fullOwned) { try { URL.revokeObjectURL(fullUrl); } catch {} }
      };
	    }

    const fetchBlobOrDecrypt = async (endpoint: 'images' | 'thumbnails') => {
      const override = endpoint === 'thumbnails' ? urlMap?.thumbnail : urlMap?.original;
      const url = override ?? `/api/${endpoint}/${encodeURIComponent(assetId)}`;
      const response = await fetch(url, {
        headers: { 'Authorization': `Bearer ${token}` },
      });
      if (!response.ok) { throw new Error(`HTTP ${response.status}`); }
      const ctype = (response.headers.get('content-type') || '').toLowerCase();
      // Read bytes once so we can robustly detect PAE3 containers even if mislabelled
      const ab = await response.arrayBuffer();
      const u8 = new Uint8Array(ab);
      const isPae3 = u8.length >= 4 && u8[0] === 0x50 /*P*/ && u8[1] === 0x41 /*A*/ && u8[2] === 0x45 /*E*/ && u8[3] === 0x33 /*3*/;
      const isLockedLike = ctype.includes('application/octet-stream') || isPae3;
      if (isLockedLike) {
        const st = useE2EEStore.getState();
        const umk = st.umk;
        const user = useAuthStore.getState().user;
        if (!umk || !user?.user_id) { setLockedBlocked(true); throw new Error('LOCKED_NEEDS_UNLOCK'); }
        // Hexify UMK
        let hex = ''; for (let i=0;i<umk.length;i++) hex += umk[i].toString(16).padStart(2,'0');
        // Spin a fresh worker
        // @ts-ignore
        const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
        const decBlob: Blob = await new Promise((resolve, reject) => {
          worker.onmessage = (ev: MessageEvent) => {
            const data = ev.data || {};
            if (data?.ok && data.kind === 'v3-decrypted') {
              try { worker.terminate(); } catch {}
              try {
                // Create a typed Blob using simple magic-byte sniffing for better compatibility
                // eslint-disable-next-line @typescript-eslint/no-var-requires
                const { sniffImageContentType } = require('@/lib/publicE2EE');
                const ct = sniffImageContentType(data.container as ArrayBuffer);
                resolve(new Blob([data.container], { type: ct }));
              } catch {
                resolve(new Blob([data.container]));
              }
            } else if (data?.ok === false) {
              try { worker.terminate(); } catch {}
              reject(new Error(data?.error || 'decrypt-v3 failed'));
            }
          };
          worker.onerror = (e) => { try { worker.terminate(); } catch {}; reject(e.error || new Error(String(e.message||e))); };
          worker.postMessage({ type: 'decrypt-v3', umkHex: hex, userIdUtf8: user.user_id, container: ab }, [ab]);
        });
        // Opportunistically store UMK if remember is enabled and not already stored
        try {
          const mins = parseInt((localStorage.getItem('pin.remember.min')||'60') as string, 10);
          const hasBlob = !!localStorage.getItem('pin.remember.blob');
          if (mins > 0 && !hasBlob) {
            const { rememberUMK } = await import('@/lib/remember');
            await rememberUMK(umk, mins);
            logger.debug('[AUTHIMG] remembered UMK from decrypt path', { mins });
          }
        } catch {}
        return { blob: decBlob, cacheable: false };
      }
      // Unlocked media path
      return {
        blob: new Blob([ab], { type: ctype || 'application/octet-stream' }),
        cacheable: endpoint === 'thumbnails',
      };
    };

    const getOrCreateThumbnailObjectUrl = async (): Promise<{ url: string; owned: boolean }> => {
      const override = urlMap?.thumbnail;
      const cacheKey = override ?? `/api/thumbnails/${encodeURIComponent(assetId)}`;
      const cacheScope = useAuthStore.getState().user?.user_id ?? null;
      ensureThumbnailCacheScope(cacheScope);
      if (cacheScope) {
        const cached = getCachedThumbnailUrl(cacheKey);
        if (cached) return { url: cached, owned: false };
      }

	      let lastError: unknown = null;
	      for (let attempt = 0; attempt < 3; attempt += 1) {
	        await waitForThumbnailNetworkCooldown();
	        await waitForThumbnailFetchSlot();
	        try {
	          const { blob, cacheable } = await fetchBlobOrDecrypt('thumbnails');
	          const url = URL.createObjectURL(blob);
	          if (cacheScope && cacheable) {
	            putCachedThumbnailUrl(cacheKey, url);
	            return { url, owned: false };
	          }
	          return { url, owned: true };
	        } catch (e) {
	          lastError = e;
	          // Locked assets need explicit unlock; retrying won't help.
	          if (e instanceof Error && e.message === 'LOCKED_NEEDS_UNLOCK') {
	            throw e;
	          }
	          if (isTransientNetworkError(e)) {
	            // Briefly pause additional thumbnail requests while connectivity stabilizes.
	            bumpThumbnailNetworkCooldown(900);
	          }
	          if (attempt < 2) {
	            await sleep(150 * (attempt + 1));
	          }
	        } finally {
	          releaseThumbnailFetchSlot();
	        }
	      }
	      throw lastError instanceof Error ? lastError : new Error('thumbnail fetch failed');
	    };

    const fetchImage = async () => {
      if (!token) {
        logger.debug('AuthenticatedImage: No token available, setting error state');
        setError(true);
        setLoading(false);
        return;
      }

      try {
        setLoading(true);
        setError(false);
	        logger.debug('[AUTHIMG] fetch start', { assetId, variant, progressive, tokenPresent: !!token, isUnlocked: useE2EEStore.getState().isUnlocked });

	        if (progressive && variant === 'original') {
	          // Start both requests; show thumbnail immediately when ready, then swap to full when decoded
	          setUpgrading(true);
	          const thumbPromise = getOrCreateThumbnailObjectUrl();
	          // Prefer prefetch if provided; else fetch now
	          const fullPromise = prefetchFullUrl
	            ? Promise.resolve(prefetchFullUrl)
	            : fetchBlobOrDecrypt('images').then(({ blob }) => {
	                const u = URL.createObjectURL(blob);
	                setFullOwned(true);
	                return u;
	              });

	          // Set thumb as soon as it arrives
		          thumbPromise.then(({ url, owned }) => {
		            if (isMounted) {
	                setThumbUrl(url);
	                setThumbOwned(owned);
	              }
		          }).catch((e) => {
		            const tag = `[AUTH-IMG] Thumbnail error for ${assetId.substring(0, 12)}...`;
		            if (isTransientNetworkError(e)) {
		              logger.debug(tag, e);
		            } else {
		              logger.error(tag, e);
		            }
		          });

          // Prepare full; wait for decode to avoid flash of unstyled
          fullPromise.then((u) => {
            if (!isMounted) return;
            setFullUrl(u);
            setFullOwned(!prefetchFullUrl);
            // create an Image to wait for decode
            const img = new Image();
            img.src = u;
            img.decode?.()
              .then(() => { if (isMounted) { setFullReady(true); setUpgrading(false); } })
	              .catch(async () => {
	                // Prefetched URL may have been revoked; fetch fresh and retry once
	                if (!isMounted) return;
	                try {
	                  const { blob } = await fetchBlobOrDecrypt('images');
	                  const u2 = URL.createObjectURL(blob);
	                  setFullOwned(true);
	                  setFullUrl(u2);
	                  const img2 = new Image(); img2.src = u2; await img2.decode?.();
	                } catch {}
                if (isMounted) { setFullReady(true); setUpgrading(false); }
              });
          }).catch((e) => {
            logger.error('AuthenticatedImage progressive full load error:', e);
            if (isMounted) setUpgrading(false);
          });

          if (isMounted) {
            // We consider "loading" only for the base placeholder
            setLoading(false);
          }
	        } else {
	          // Simple single fetch
            if (variant === 'thumbnail') {
              const { url, owned } = await getOrCreateThumbnailObjectUrl();
              if (isMounted) {
                setBlobUrl(url);
                setBlobOwned(owned);
                setLoading(false);
              }
              return;
            }

	          const { blob } = await fetchBlobOrDecrypt('images');
	          if (isMounted) {
	            const url = URL.createObjectURL(blob);
	            setBlobUrl(url);
              setBlobOwned(true);
	            setLoading(false);
	          }
	        }
	      } catch (error) {
	        if (isTransientNetworkError(error)) {
	          logger.debug('Transient network issue loading authenticated image', { assetId, variant });
	        } else {
	          logger.error('Error loading authenticated image:', error);
	          logger.debug('[AUTHIMG] error', { assetId, variant, tokenPresent: !!token, isUnlocked: useE2EEStore.getState().isUnlocked });
	        }
	        if (isMounted) {
	          setError(true);
	          setLoading(false);
	        }
	      }
    };

    fetchImage();

	    // Cleanup blob URL when component unmounts
	    return () => {
	      isMounted = false;
	    };
	  // eslint-disable-next-line react-hooks/exhaustive-deps
	  }, [assetId, token, progressive, variant, prefetchFullUrl, isUnlocked, inView, lazyEnabled]);

  // Cleanup blob URL when it changes
  useEffect(() => {
    return () => {
      if (blobUrl && blobOwned) { URL.revokeObjectURL(blobUrl); }
      if (thumbUrl && thumbOwned) { URL.revokeObjectURL(thumbUrl); }
      if (fullUrl && fullOwned) { URL.revokeObjectURL(fullUrl); }
    };
  }, [blobUrl, blobOwned, thumbUrl, thumbOwned, fullUrl, fullOwned]);

  // Lazy thumbnail placeholder (avoid network work until near viewport).
  if (lazyEnabled && !inView && variant === 'thumbnail' && !blobUrl && !error && !lockedBlocked) {
    return (
      <div
        ref={inViewRef}
        className={`bg-gray-200 animate-pulse ${className || ''}`}
        style={{ width, height }}
      />
    );
  }

  if (loading) {
    return (
      <div 
        ref={inViewRef}
        className={`bg-gray-200 animate-pulse flex items-center justify-center ${className}`}
        style={{ width, height }}
      >
        <span className="text-gray-400 text-sm">Loading...</span>
      </div>
    );
  }

  // Progressive render path first: show layered UI regardless of blobUrl
  if (progressive && variant === 'original') {
    // Render layered images: thumbnail (base) then full when ready; apply wrapper transform via props.style if present
    const { style, ...imgProps } = props;
    const wrapperStyle: React.CSSProperties = {
      // Fill available space, but respect viewer constraints
      maxWidth: '90vw',
      maxHeight: 'calc(100vh - 120px)',
      width: '100%',
      height: '100%',
      ...style,
    };
    // If neither thumb nor full are available yet (rare), show skeleton container
    if (!thumbUrl && !fullUrl) {
      return (
        <div ref={inViewRef} className={`bg-gray-200 animate-pulse ${className || ''}`} style={wrapperStyle} />
      );
    }
    return (
      <div ref={inViewRef} className={`${className || ''} relative`} style={wrapperStyle}>
        {thumbUrl && (
          <img
            src={thumbUrl}
            alt={alt}
            className="absolute inset-0 w-full h-full object-contain"
            width={width}
            height={height}
            draggable={false}
          />
        )}
        {fullUrl && (
          <img
            src={fullUrl}
            alt={alt}
            className={`absolute inset-0 w-full h-full object-contain transition-opacity duration-200 ${fullReady ? 'opacity-100' : 'opacity-0'}`}
            width={width}
            height={height}
            onLoad={() => setFullReady(true)}
            onError={async () => {
              const attempts = fullErrorRetriesRef.current.get(assetId) ?? 0;
              if (attempts >= 1) {
                // Stop retry loops for permanently broken media (corrupt bytes, missing file, etc).
                setError(true);
                setUpgrading(false);
                setFullUrl(null);
                setFullReady(false);
                return;
              }
              fullErrorRetriesRef.current.set(assetId, attempts + 1);
              try {
                // Try fetching a fresh full image with decrypt support if needed
                const b = await (async () => {
                  // Reuse the same helper which decrypts locked containers
                  const override = urlMap?.original;
                  const u = override ?? `/api/images/${encodeURIComponent(assetId)}`;
                  const response = await fetch(u, {
                    headers: { 'Authorization': `Bearer ${useAuthStore.getState().token}` },
                  });
                  if (!response.ok) throw new Error(`HTTP ${response.status}`);
                  const ct = response.headers.get('content-type') || '';
                  if (ct.includes('application/octet-stream')) {
                    const ab = await response.arrayBuffer();
                    const st = useE2EEStore.getState();
                    const umk = st.umk; const user = useAuthStore.getState().user;
                    if (!umk || !user?.user_id) throw new Error('LOCKED_NEEDS_UNLOCK');
                    let hex = ''; for (let i=0;i<umk.length;i++) hex += umk[i].toString(16).padStart(2,'0');
                    // @ts-ignore
                    const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
                    const dec: ArrayBuffer = await new Promise((resolve, reject) => {
                      worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind==='v3-decrypted') { try{worker.terminate();}catch{}; resolve(d.container); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'decrypt failed')); } };
                      worker.onerror = (er:any) => { try{worker.terminate();}catch{}; reject(er?.error||new Error(String(er?.message||er))); };
                      worker.postMessage({ type:'decrypt-v3', umkHex: hex, userIdUtf8: user.user_id, container: ab }, [ab]);
                    });
                    return new Blob([dec]);
                  }
                  return await response.blob();
                })();
                const url = URL.createObjectURL(b);
                setFullOwned(true);
                setFullUrl(url);
                setFullReady(true);
                setUpgrading(false);
              } catch {
                setError(true);
                setUpgrading(false);
              }
            }}
            draggable={false}
            {...imgProps}
          />
        )}
        {upgrading && (
          <div className="absolute left-1/2 -translate-x-1/2 z-[60] pointer-events-none" style={{ bottom: '24px' }}>
            <div className="bg-card/80 text-foreground border border-border rounded-full px-2.5 py-1 text-xs flex items-center gap-2">
              <span className="inline-block w-3 h-3 rounded-full border-2 border-border border-t-transparent animate-spin"></span>
              <span>Loading high‑res…</span>
            </div>
          </div>
        )}
      </div>
    );
  }

  // Non-progressive path; handle errors/fallbacks
  if (error || !blobUrl) {
    if (lockedBlocked) {
      return (
        <div 
          ref={inViewRef}
          className={`bg-gray-100 flex items-center justify-center text-xs text-muted-foreground ${className}`}
          style={{ width, height }}
        >
          🔒 Locked — Unlock to view
        </div>
      );
    }
    return (
      <div 
        ref={inViewRef}
        className={`bg-gray-200 flex items-center justify-center ${className}`}
        style={{ width, height }}
      >
        <span className="text-gray-400 text-sm">Failed to load</span>
      </div>
    );
  }

  return (
    <img
      ref={inViewRef}
      src={blobUrl}
      alt={alt}
      className={className}
      width={width}
      height={height}
      {...props}
    />
  );
}
