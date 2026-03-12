'use client';

import React, { useMemo, useRef, useEffect, useState, useCallback } from 'react';
import { useInView } from 'react-intersection-observer';
import { Check, Play } from 'lucide-react';

import { Photo } from '@/lib/types/photo';
import { AuthenticatedImage } from '@/components/ui/AuthenticatedImage';
import { photosApi } from '@/lib/api/photos';
import { logger } from '@/lib/logger';

interface TimelineViewProps {
  photos: Photo[];
  selectedPhotos: string[];
  onPhotoClick: (photo: Photo) => void;
  onPhotoSelect: (assetId: string, selected: boolean) => void;
  onLoadMore?: () => void;
  onJumpToPage?: (page: number) => Promise<void>;
  perPage?: number;
  hasMore?: boolean;
  isLoading?: boolean;
  scrollContainerRef?: React.RefObject<HTMLElement | null>;
  bucketQuery?: Record<string, any>;
  bucketKey?: string;
}

function formatDay(ts: number) {
  const d = new Date((ts || 0) * 1000);
  return d.toLocaleDateString(undefined, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  });
}

function yearOf(ts: number) {
  return new Date((ts || 0) * 1000).getFullYear();
}

type DayGroup = { key: string; date: number; year: number; photos: Photo[] };

function dayKeyOf(ts: number) {
  const d = new Date((ts || 0) * 1000);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function formatDuration(ms?: number) {
  if (!ms || ms <= 0) return '';
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => n.toString().padStart(2, '0');
  if (h > 0) return `${h}:${pad(m)}:${pad(s)}`;
  return `${m}:${pad(s)}`;
}

function buildGroupsFromPhotos(photos: Photo[]): DayGroup[] {
  const byDay = new Map<string, DayGroup>();
  for (const p of photos) {
    const key = dayKeyOf(p.created_at);
    const y = yearOf(p.created_at);
    const ex = byDay.get(key);
    if (ex) {
      ex.photos.push(p);
    } else {
      byDay.set(key, { key, date: p.created_at, year: y, photos: [p] });
    }
  }
  const out = Array.from(byDay.values());
  out.sort((a, b) => b.date - a.date);
  return out;
}

function appendPhotosToGroups(prevGroups: DayGroup[], newPhotos: Photo[]): DayGroup[] {
  if (!newPhotos.length) return prevGroups;

  // Chunk new photos by day to minimize array copies when appending to the last day.
  const chunks: DayGroup[] = [];
  for (const p of newPhotos) {
    const key = dayKeyOf(p.created_at);
    const y = yearOf(p.created_at);
    const last = chunks[chunks.length - 1];
    if (last && last.key === key) {
      last.photos.push(p);
    } else {
      chunks.push({ key, date: p.created_at, year: y, photos: [p] });
    }
  }

  let out = prevGroups.slice();
  for (const chunk of chunks) {
    const lastIdx = out.length - 1;
    const last = lastIdx >= 0 ? out[lastIdx] : undefined;
    if (last && last.key === chunk.key) {
      out[lastIdx] = { ...last, photos: [...last.photos, ...chunk.photos] };
    } else {
      out.push(chunk);
    }
  }
  return out;
}

function TimelinePhoto({
  photo,
  isSelected,
  onPhotoClick,
  onPhotoSelect,
}: {
  photo: Photo;
  isSelected: boolean;
  onPhotoClick: (p: Photo) => void;
  onPhotoSelect: (id: string, sel: boolean) => void;
}) {
  const [hover, setHover] = useState(false);
  return (
    <div
      className="relative rounded overflow-hidden bg-muted"
      style={{ width: 220, height: 160 }}
      onClick={(e) => {
        if (e.ctrlKey || e.metaKey || e.shiftKey) {
          e.preventDefault();
          onPhotoSelect(photo.asset_id, !isSelected);
        } else {
          onPhotoClick(photo);
        }
      }}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      <AuthenticatedImage
        assetId={photo.asset_id}
        alt={photo.filename}
        title={photo.filename}
        className="absolute inset-0 w-full h-full object-cover"
      />
      {photo.is_video && (
        <>
          <div className="absolute top-2 left-2 bg-black bg-opacity-70 rounded-full p-1">
            <Play className="w-3 h-3 text-white" fill="white" />
          </div>
          <div className="absolute bottom-2 right-2 bg-black bg-opacity-70 text-white text-xs px-1.5 py-0.5 rounded">
            {formatDuration(photo.duration_ms)}
          </div>
        </>
      )}
      {photo.is_live_photo && hover && (
        <div className="absolute top-2 left-2 bg-black/70 rounded-full p-1 text-white">
          <Play className="w-3 h-3" />
        </div>
      )}
      <button
        className={`absolute top-2 right-2 w-6 h-6 rounded-full border-2 border-white flex items-center justify-center transition-all duration-200 ${
          isSelected ? 'bg-primary border-primary' : 'bg-black/30 hover:bg-black/50'
        } ${hover || isSelected ? 'opacity-100' : 'opacity-0'}`}
        onClick={(e) => {
          e.preventDefault();
          e.stopPropagation();
          onPhotoSelect(photo.asset_id, !isSelected);
        }}
      >
        {isSelected && <Check className="w-4 h-4 text-white" />}
      </button>
      {/* Always mounted to persist local state */}
      <StarRatingOverlay assetId={photo.asset_id} initialRating={photo.rating} interactive={hover} />
    </div>
  );
}

function StarRatingOverlay({ assetId, initialRating, interactive }: { assetId: string; initialRating?: number | null; interactive?: boolean }) {
  const isUnrated = initialRating == null;
  const [editing, setEditing] = useState<boolean>(isUnrated);
  const [hoverN, setHoverN] = useState<number>(0);
  const [current, setCurrent] = useState<number | undefined>(initialRating == null ? undefined : initialRating);
  React.useEffect(()=>{ setCurrent(initialRating == null ? undefined : initialRating); }, [initialRating]);
  const solid = editing ? (hoverN || current || 0) : (current || 0);
  const onClick = async (n: number) => {
    try { setCurrent(n); await photosApi.updatePhotoRating(assetId, n); setEditing(false); } catch {}
  };
  const onClear = async () => {
    try { await photosApi.updatePhotoRating(assetId, null); setCurrent(undefined); setHoverN(0); setEditing(true); } catch {}
  };
  const Star = ({ idx }: { idx: number }) => {
    const filled = solid >= idx;
    return (
      <button type="button" aria-label={`Rate ${idx} stars`} className={`w-5 h-5 inline-flex items-center justify-center ${canInteract ? 'cursor-pointer' : 'cursor-default'}`}
        onMouseEnter={() => { if (editing) setHoverN(idx); }} onMouseLeave={() => { if (editing) setHoverN(0); }}
        onClick={(e)=>{ e.stopPropagation(); if (canInteract && (editing || (current ?? 0) === 0)) onClick(idx); }} onDoubleClick={(e)=>{ e.stopPropagation(); setEditing(true); }}>
        <span className={`${filled ? 'text-red-500' : 'text-red-500/60'}`} style={{fontSize: 18, lineHeight: 1}}>{filled ? '★' : '☆'}</span>
      </button>
    );
  };
  const canInteract = !!interactive;
  const visible = canInteract || ((current ?? 0) > 0);
  return (
    <div className={`absolute bottom-0 left-0 right-0 p-1 ${canInteract ? 'bg-black/40' : 'bg-transparent'} z-50 ${canInteract ? 'pointer-events-auto cursor-pointer' : 'pointer-events-none cursor-default'}`} onDoubleClick={(e)=>{ if (!canInteract) return; e.stopPropagation(); setEditing(true); }}>
      <div className={`flex items-center justify-center gap-1 select-none ${visible ? '' : 'invisible'}`}>
        {[1,2,3,4,5].map(i => <Star key={i} idx={i} />)}
        {canInteract && (current != null && current > 0) ? (
          <button className="ml-2 px-1.5 py-0.5 text-xs rounded border border-border bg-background/60 hover:bg-background cursor-pointer" onClick={(e)=>{ e.stopPropagation(); onClear(); }} title="Clear rating">Clear</button>
        ) : null}
      </div>
    </div>
  );
}

const TimelineDaySection = React.memo(function TimelineDaySection({
  group,
  insertYearAnchor,
  insertQuarterAnchor,
  quarterKey,
  selectedSet,
  onPhotoClick,
  onPhotoSelect,
  anchorsRef,
  quarterAnchorsRef,
}: {
  group: DayGroup;
  insertYearAnchor: boolean;
  insertQuarterAnchor: boolean;
  quarterKey: string;
  selectedSet: Set<string>;
  onPhotoClick: (photo: Photo) => void;
  onPhotoSelect: (assetId: string, selected: boolean) => void;
  anchorsRef: React.MutableRefObject<Map<number, HTMLElement>>;
  quarterAnchorsRef: React.MutableRefObject<Map<string, HTMLElement>>;
}) {
  return (
    <section className="mb-6">
      {insertYearAnchor && (
        <div
          id={`year-${group.year}`}
          data-year-anchor
          ref={(el) => {
            if (el) anchorsRef.current.set(group.year, el);
            else anchorsRef.current.delete(group.year);
          }}
          className="h-0"
        />
      )}
      {insertQuarterAnchor && (
        <div
          id={`quarter-${quarterKey}`}
          className="h-0"
          ref={(el) => {
            if (el) quarterAnchorsRef.current.set(quarterKey, el);
            else quarterAnchorsRef.current.delete(quarterKey);
          }}
        />
      )}
      <h3 className="text-lg font-semibold text-foreground mb-3">{formatDay(group.date)}</h3>
      <div className="flex flex-wrap gap-3">
        {group.photos.map((p) => (
          <TimelinePhoto
            key={p.asset_id}
            photo={p}
            isSelected={selectedSet.has(p.asset_id)}
            onPhotoClick={onPhotoClick}
            onPhotoSelect={onPhotoSelect}
          />
        ))}
      </div>
    </section>
  );
});

export function TimelineView({
  photos,
  selectedPhotos,
  onPhotoClick,
  onPhotoSelect,
  onLoadMore,
  onJumpToPage,
  perPage = 100,
  hasMore = false,
  isLoading = false,
  scrollContainerRef,
  bucketQuery,
  bucketKey,
}: TimelineViewProps) {
  type YearBucket = { year: number; count: number; first_ts: number; last_ts?: number };
  type QuarterBucket = { quarter: number; count: number; first_ts: number; last_ts?: number };
  const [yearBuckets, setYearBuckets] = useState<YearBucket[] | null>(null);
  const [quarterBuckets, setQuarterBuckets] = useState<Map<number, QuarterBucket[]>>(new Map());
  const [loadingJumpKey, setLoadingJumpKey] = useState<string | null>(null);
  const debugJumpRef = useRef<boolean>(false);
  debugJumpRef.current = (() => {
    try {
      return typeof window !== 'undefined' && window.localStorage.getItem('debug-timeline-jump') === '1';
    } catch {
      return false;
    }
  })();
  const tlog = useCallback((level: 'info' | 'debug', ...args: any[]) => {
    // Production builds default to LOG_LEVEL=warn, so logger.debug/info won't show.
    // Emit minimal console logs for jump operations, and full logs when explicitly enabled.
    if (debugJumpRef.current) {
      console.log(...args);
      return;
    }
    if (level === 'info') {
      // Use warn so it shows up in production console filters more reliably.
      console.warn(...args);
      return;
    }
    logger.debug(...args);
  }, []);

  const bucketQueryString = useMemo(() => {
    try {
      const params = new URLSearchParams();
      const entries = Object.entries(bucketQuery || {}).filter(([, v]) => v !== undefined && v !== null && v !== '');
      entries.sort(([a], [b]) => a.localeCompare(b));
      for (const [k, v] of entries) {
        if (Array.isArray(v)) {
          for (const item of v) params.append(k, String(item));
        } else {
          params.append(k, String(v));
        }
      }
      return params.toString();
    } catch {
      return '';
    }
  }, [bucketKey, bucketQuery]);

  const timelinePhotos = useMemo(() => {
    return (photos || []).map((p: any, idx) => {
      if (!p || typeof p !== 'object') return null;
      const assetId = typeof p.asset_id === 'string' && p.asset_id.length > 0
        ? p.asset_id
        : (typeof p.id === 'number' ? String(p.id) : `invalid-${idx}`);
      const created = typeof p.created_at === 'number' ? p.created_at : Number(p.created_at);
      const createdAt = Number.isFinite(created) ? created : 0;
      return { ...p, asset_id: assetId, created_at: createdAt } as Photo;
    }).filter(Boolean) as Photo[];
  }, [photos]);

  // Build day groups incrementally so paging/jump doesn't re-render the entire timeline.
  const [groups, setGroups] = useState<DayGroup[]>([]);
  const prevPhotosRef = useRef<Photo[] | null>(null);
  const prevBucketKeyRef = useRef<string | undefined>(bucketKey);
  useEffect(() => {
    const prevBucketKey = prevBucketKeyRef.current;
    const prevPhotos = prevPhotosRef.current;
    const prevLen = prevPhotos?.length ?? 0;
    const prevFirst = prevPhotos?.[0]?.asset_id;
    const currFirst = timelinePhotos?.[0]?.asset_id;
    const bucketChanged = prevBucketKey !== bucketKey;
    prevBucketKeyRef.current = bucketKey;

    if (!timelinePhotos.length) {
      prevPhotosRef.current = timelinePhotos;
      setGroups([]);
      return;
    }

    // Timeline expects newest-first ordering. If the caller isn't providing it, fall back to a full rebuild.
    const isLikelyDesc = timelinePhotos.length < 2 || timelinePhotos[0]!.created_at >= timelinePhotos[timelinePhotos.length - 1]!.created_at;
    const shouldRebuild =
      bucketChanged ||
      !prevPhotos ||
      timelinePhotos.length < prevLen ||
      (prevFirst && currFirst && prevFirst !== currFirst) ||
      !isLikelyDesc;

    if (shouldRebuild) {
      prevPhotosRef.current = timelinePhotos;
      try {
        setGroups(buildGroupsFromPhotos(timelinePhotos));
      } catch (e) {
        console.warn('[TIMELINE_DEBUG] buildGroupsFromPhotos failed', e);
        setGroups([]);
      }
      return;
    }

    if (timelinePhotos.length === prevLen) {
      prevPhotosRef.current = timelinePhotos;
      return;
    }

    const newSlice = timelinePhotos.slice(prevLen);
    prevPhotosRef.current = timelinePhotos;
    setGroups((prevGroups) => appendPhotosToGroups(prevGroups, newSlice));
  }, [timelinePhotos, bucketKey]);

  const fallbackGroups = useMemo(() => {
    if (!timelinePhotos.length) return [] as DayGroup[];
    try { return buildGroupsFromPhotos(timelinePhotos); } catch { return [] as DayGroup[]; }
  }, [timelinePhotos]);
  const groupsForRender = groups.length > 0 ? groups : fallbackGroups;

  const selectedSet = useMemo(() => new Set(selectedPhotos), [selectedPhotos]);

  useEffect(() => {
    try {
      const snapshot = {
        photosLen: photos.length,
        timelinePhotosLen: timelinePhotos.length,
        groupsLen: groups.length,
        renderGroupsLen: groupsForRender.length,
        selectedLen: selectedPhotos.length,
        hasMore,
        isLoading,
      };
      console.log('[TIMELINE_DEBUG] snapshot', snapshot);
      if (timelinePhotos.length > 0 && groupsForRender.length === 0 && !isLoading) {
        console.warn('[TIMELINE_DEBUG] photos present but no groups rendered', snapshot);
      }
    } catch {}
  }, [photos.length, timelinePhotos.length, groups.length, groupsForRender.length, selectedPhotos.length, hasMore, isLoading]);

  const years = useMemo(() => {
    if (yearBuckets && yearBuckets.length) return yearBuckets.map((b) => b.year);
    if (!timelinePhotos.length) return [] as number[];
    let min = Infinity;
    let max = -Infinity;
    for (const p of timelinePhotos) {
      const y = yearOf(p.created_at);
      if (y < min) min = y;
      if (y > max) max = y;
    }
    const out: number[] = [];
    for (let y = max; y >= min; y--) out.push(y);
    return out;
  }, [timelinePhotos, yearBuckets]);

  // Map each year to the first group's index for anchor placement
  const yearToIndex = useMemo(() => {
    const m = new Map<number, number>();
    groupsForRender.forEach((g, idx) => {
      if (!m.has(g.year)) m.set(g.year, idx);
    });
    return m;
  }, [groupsForRender]);

  const [activeYear, setActiveYear] = useState<number | null>(years[0] ?? null);
  useEffect(() => { if (years.length && activeYear == null) setActiveYear(years[0]); }, [years]);
  const anchorsRef = useRef<Map<number, HTMLElement>>(new Map());
  const quarterAnchorsRef = useRef<Map<string, HTMLElement>>(new Map());
  const [activeQuarterKey, setActiveQuarterKey] = useState<string | null>(null);
  const [lockedQuarterKey, setLockedQuarterKey] = useState<string | null>(null);
  const [lockedYear, setLockedYear] = useState<number | null>(null);

  // Keep latest paging state in refs so jump-loading can await real fetch completion.
  const photosLenRef = useRef<number>(photos.length);
  const isLoadingRef = useRef<boolean>(isLoading);
  const onLoadMoreRef = useRef<typeof onLoadMore>(onLoadMore);
  // `hasMore` is falsey during page transitions because the parent query's data is undefined while loading.
  // Preserve the last known value while `isLoading` is true to avoid prematurely stopping jump loading.
  const hasMoreStableRef = useRef<boolean>(hasMore);
  const oldestLoadedTsRef = useRef<number | undefined>(undefined);
  photosLenRef.current = timelinePhotos.length;
  isLoadingRef.current = isLoading;
  onLoadMoreRef.current = onLoadMore;
  if (!isLoading) hasMoreStableRef.current = hasMore;
  oldestLoadedTsRef.current = groupsForRender.length ? groupsForRender[groupsForRender.length - 1]!.date : undefined;

  // Reset cached buckets when filters change (but not when just paging).
  useEffect(() => {
    setYearBuckets(null);
    setQuarterBuckets(new Map());
    setLoadingJumpKey(null);
    tlog('debug', '[TimelineBuckets] reset', { bucketKey, bucketQueryString });
  }, [bucketKey, bucketQueryString, tlog]);

  // Scroll spy: update active year as the user scrolls within the provided container
  useEffect(() => {
    const c = scrollContainerRef?.current;
    if (!c) return;
    const handler = () => {
      try {
        const cRect = c.getBoundingClientRect();
        const focusY = cRect.top + cRect.height * 0.35; // focus line 35% from top
        const pairs: Array<{ yr: number; top: number }> = [];
        anchorsRef.current.forEach((el, yr) => {
          const r = el.getBoundingClientRect();
          const top = r.top; // viewport-based; compare to focusY
          pairs.push({ yr, top });
        });
        let targetYear: number | null = null;
        const below = pairs.filter(p => p.top <= focusY);
        if (below.length) {
          // pick the last one below focus line
          targetYear = below.sort((a,b) => b.top - a.top)[0].yr;
        } else if (pairs.length) {
          // pick the closest above focus
          targetYear = pairs.sort((a,b) => a.top - b.top)[0].yr;
        }
        if (!lockedYear && targetYear !== null && targetYear !== activeYear) setActiveYear(targetYear);

        // Quarter scroll spy
        const qpairs: Array<{ key: string; top: number }> = [];
        quarterAnchorsRef.current.forEach((el, key) => {
          const r = el.getBoundingClientRect();
          const top = r.top;
          qpairs.push({ key, top });
        });
        // Choose the nearest quarter to the focus line by absolute distance
        const qtarget = qpairs.length
          ? qpairs.sort((a,b) => Math.abs(a.top - focusY) - Math.abs(b.top - focusY))[0]
          : undefined;
        if (!lockedQuarterKey && qtarget && qtarget.key !== activeQuarterKey) {
          setActiveQuarterKey(qtarget.key);
        }
      } catch {}
    };
    c.addEventListener('scroll', handler, { passive: true });
    handler();
    return () => c.removeEventListener('scroll', handler as any);
  }, [scrollContainerRef, groupsForRender, years, activeYear]);

  const scrollToYear = useCallback((yr: number, behavior: ScrollBehavior = 'auto'): boolean => {
    const c = scrollContainerRef?.current;
    const el = anchorsRef.current.get(yr);
    if (!c || !el) return false;
    try {
      const cRect = c.getBoundingClientRect();
      const r = el.getBoundingClientRect();
      const focusOffset = cRect.height * 0.35;
      const targetTop = r.top - cRect.top + c.scrollTop - focusOffset;
      c.scrollTo({ top: targetTop, behavior });
      return true;
    } catch {
      el.scrollIntoView({ behavior, block: 'start' });
      return true;
    }
  }, [scrollContainerRef]);

  const scrollElementToFocus = useCallback((el: HTMLElement, behavior: ScrollBehavior = 'auto'): boolean => {
    const c = scrollContainerRef?.current;
    if (!c) return false;
    try {
      const cRect = c.getBoundingClientRect();
      const r = el.getBoundingClientRect();
      const focusOffset = cRect.height * 0.35;
      const targetTop = r.top - cRect.top + c.scrollTop - focusOffset;
      c.scrollTo({ top: targetTop, behavior });
      return true;
    } catch {
      el.scrollIntoView({ behavior, block: 'center' });
      return true;
    }
  }, [scrollContainerRef]);

  const computePageForYear = useCallback((yr: number): { page: number; offset: number } | null => {
    if (!yearBuckets?.length) return null;
    const size = Math.max(1, Math.floor(perPage || 100));
    let offset = 0;
    for (const b of yearBuckets) {
      if (b.year > yr) offset += b.count;
    }
    const page = Math.floor(offset / size) + 1; // 1-based
    return { page, offset };
  }, [yearBuckets, perPage]);

  const waitForEl = useCallback(async (id: string, timeoutMs: number): Promise<boolean> => {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (document.getElementById(id)) return true;
      await new Promise((r) => setTimeout(r, 60));
    }
    return false;
  }, []);

  // Helper: ensure anchor exists by paging until the target timestamp is within the loaded range.
  const ensureAnchorFor = useCallback(async (opts: { year?: number; quarterKey?: string; targetTs?: number }) => {
    const targetTs = opts.targetTs;

    const anchorExists = (): boolean => {
      if (opts.year) return anchorsRef.current.has(opts.year) || !!document.getElementById(`year-${opts.year}`);
      if (opts.quarterKey) return quarterAnchorsRef.current.has(opts.quarterKey) || !!document.getElementById(`quarter-${opts.quarterKey}`);
      return false;
    };

    const shouldStopByOldest = (): boolean => {
      const oldest = oldestLoadedTsRef.current;
      if (oldest !== undefined && targetTs !== undefined && oldest <= targetTs) return true;
      return false;
    };

    const waitUntil = async (pred: () => boolean, timeoutMs: number): Promise<boolean> => {
      const start = Date.now();
      while (Date.now() - start < timeoutMs) {
        if (pred()) return true;
        await new Promise((r) => setTimeout(r, 60));
      }
      return false;
    };

    let loads = 0;
    const maxLoads = 5000;
    const startedAt = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
    tlog('info', '[TimelineJump] ensureAnchorFor start', {
      ...opts,
      targetTs,
      photosLoaded: photosLenRef.current,
      oldestLoadedTs: oldestLoadedTsRef.current,
      hasMore: hasMoreStableRef.current,
      isLoading: isLoadingRef.current,
    });
    while (loads < maxLoads) {
      if (anchorExists()) {
        tlog('info', '[TimelineJump] ensureAnchorFor stop: anchor exists', { loads });
        return;
      }
      if (!onLoadMoreRef.current) {
        tlog('info', '[TimelineJump] ensureAnchorFor stop: no onLoadMore', { loads });
        return;
      }
      if (!hasMoreStableRef.current) {
        tlog('info', '[TimelineJump] ensureAnchorFor stop: hasMore=false', { loads });
        return;
      }
      if (shouldStopByOldest()) {
        // We should have loaded past the target; give React a moment to mount the anchor.
        const ok = await waitUntil(anchorExists, 3000);
        tlog('info', '[TimelineJump] ensureAnchorFor stop: reached targetTs', {
          loads,
          targetTs,
          oldestLoadedTs: oldestLoadedTsRef.current,
          anchorNow: ok,
        });
        return;
      }

      // Wait for any in-flight page load to complete.
      if (isLoadingRef.current) {
        const ok = await waitUntil(() => !isLoadingRef.current, 20_000);
        if (!ok) {
          tlog('info', '[TimelineJump] ensureAnchorFor stop: wait for isLoading timed out', { loads });
          return;
        }
        continue;
      }

      const beforeLen = photosLenRef.current;
      const beforeOldest = oldestLoadedTsRef.current;
      onLoadMoreRef.current?.();
      loads += 1;

      // Wait until new photos arrive (or we learn there are no more pages).
      const progressed = await waitUntil(
        () => photosLenRef.current > beforeLen || !hasMoreStableRef.current || anchorExists(),
        20_000,
      );
      if (!progressed) {
        tlog('info', '[TimelineJump] ensureAnchorFor stop: no progress', {
          loads,
          beforeLen,
          afterLen: photosLenRef.current,
          beforeOldest,
          afterOldest: oldestLoadedTsRef.current,
          hasMore: hasMoreStableRef.current,
          isLoading: isLoadingRef.current,
        });
        return;
      }
      if (loads === 1 || loads % 10 === 0) {
        tlog('debug', '[TimelineJump] ensureAnchorFor progress', {
          loads,
          beforeLen,
          afterLen: photosLenRef.current,
          beforeOldest,
          afterOldest: oldestLoadedTsRef.current,
          hasMore: hasMoreStableRef.current,
          anchor: anchorExists(),
        });
      }
      if (loads === 1 || loads % 25 === 0) {
        const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
        tlog('info', '[TimelineJump] ensureAnchorFor progress', {
          loads,
          photosLoaded: photosLenRef.current,
          oldestLoadedTs: oldestLoadedTsRef.current,
          hasMore: hasMoreStableRef.current,
          anchor: anchorExists(),
          elapsedMs: now - startedAt,
        });
      }
    }
    const endedAt = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
    tlog('info', '[TimelineJump] ensureAnchorFor stop: maxLoads reached', { loads, elapsedMs: endedAt - startedAt });
  }, []);

  // Quarter anchors mapping
  const quarterToIndex = useMemo(() => {
    const m = new Map<string, number>();
    groupsForRender.forEach((g, idx) => {
      const d = new Date(g.date * 1000);
      const q = Math.floor(d.getMonth() / 3) + 1;
      const key = `${g.year}-Q${q}`;
      if (!m.has(key)) m.set(key, idx);
    });
    return m;
  }, [groupsForRender]);

  // Fetch year buckets
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const url = bucketQueryString ? `/api/buckets/years?${bucketQueryString}` : '/api/buckets/years';
        tlog('debug', '[TimelineBuckets] fetch years', { url });
        const r = await fetch(url, { credentials: 'same-origin' });
        if (!r.ok) return;
        const data: YearBucket[] = await r.json();
        if (!cancelled) {
          setYearBuckets(data);
          const maxYear = data.length ? data[0]!.year : undefined;
          const minYear = data.length ? data[data.length - 1]!.year : undefined;
          tlog('debug', '[TimelineBuckets] years loaded', { years: data.length, minYear, maxYear });
        }
      } catch {}
    })();
    return () => { cancelled = true; };
  }, [bucketKey, bucketQueryString, tlog]);

  // Fetch quarter buckets for rail years
  useEffect(() => {
    let cancelled = false;
    (async () => {
      for (const y of years) {
        if (cancelled) break;
        if (quarterBuckets.has(y)) continue;
        try {
          const url = bucketQueryString
            ? `/api/buckets/quarters?year=${y}&${bucketQueryString}`
            : `/api/buckets/quarters?year=${y}`;
          const r = await fetch(url, { credentials: 'same-origin' });
          if (!r.ok) continue;
          const data: QuarterBucket[] = await r.json();
          if (cancelled) break;
          setQuarterBuckets((prev) => new Map(prev).set(y, data));
        } catch {}
      }
    })();
    return () => { cancelled = true; };
  }, [years, bucketKey, bucketQueryString]);

  const { ref: loadMoreRef, inView } = useInView({ threshold: 0, triggerOnce: false });
  useEffect(() => {
    if (inView && hasMore && !isLoading && onLoadMore) onLoadMore();
  }, [inView, hasMore, isLoading, onLoadMore]);

  if (groupsForRender.length === 0 && !isLoading) {
    return (
      <div className="flex flex-col items-center justify-center h-64 text-gray-500">
        <div className="text-5xl mb-3">📷</div>
        <h3 className="text-lg font-medium mb-1">No photos found</h3>
        <p className="text-sm text-center max-w-md">
          Try adjusting your filters or search.
        </p>
      </div>
    );
  }

  return (
    <div className="flex gap-4">
      <div className="flex-1 pr-2">
        {groupsForRender.map((g, idx) => {
          const insertYearAnchor = yearToIndex.get(g.year) === idx;
          const d = new Date(g.date * 1000);
          const q = Math.floor(d.getMonth() / 3) + 1;
          const quarterKey = `${g.year}-Q${q}`;
          const insertQuarterAnchor = quarterToIndex.get(quarterKey) === idx;
          return (
            <TimelineDaySection
              key={g.key}
              group={g}
              insertYearAnchor={insertYearAnchor}
              insertQuarterAnchor={insertQuarterAnchor}
              quarterKey={quarterKey}
              selectedSet={selectedSet}
              onPhotoClick={onPhotoClick}
              onPhotoSelect={onPhotoSelect}
              anchorsRef={anchorsRef}
              quarterAnchorsRef={quarterAnchorsRef}
            />
          );
        })}

        {/* Load more sentinel */}
        {hasMore && (
          <div ref={loadMoreRef} className="py-6 flex items-center justify-center">
            {isLoading ? (
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
            ) : (
              <span className="text-muted-foreground">Load more…</span>
            )}
          </div>
        )}
      </div>
      {/* Right rail */}
      <aside className="hidden lg:block w-28 shrink-0">
        <div className="sticky top-4 max-h-[calc(100vh-2rem)] overflow-auto pr-1">
          <ul className="flex flex-col items-end gap-3">
            {years.map((yr) => (
              <li key={yr}>
                <div className="flex flex-col items-center w-20">
                  <button
                    title={`${yr}${yearBuckets ? ` • ${(yearBuckets.find(b => b.year===yr)?.count ?? 0)} items` : ''}`}
                     onClick={async () => {
                       setLoadingJumpKey(`year-${yr}`);
                       try {
                        setLockedYear(yr);
                        setActiveYear(yr);
                        const fb = yearBuckets?.find(b => b.year === yr);
                        tlog('info', '[TimelineJump] year click', {
                          year: yr,
                          bucket: fb,
                          perPage,
                          photosLoaded: photosLenRef.current,
                          oldestLoadedTs: oldestLoadedTsRef.current,
                          hasMore: hasMoreStableRef.current,
                          isLoading: isLoadingRef.current,
                        });
                         const tryJumpYear = () => {
                           if (scrollToYear(yr, 'auto')) return true;
                           const el = document.getElementById(`year-${yr}`);
                           if (el) { scrollElementToFocus(el, 'auto'); return true; }
                           return false;
                         };
                         if (tryJumpYear()) return;
                         const pageInfo = onJumpToPage ? computePageForYear(yr) : null;
                         if (pageInfo && onJumpToPage) {
                           tlog('info', '[TimelineJump] year jumpToPage', {
                             year: yr,
                             page: pageInfo.page,
                             offset: pageInfo.offset,
                             perPage,
                           });
                           await onJumpToPage(pageInfo.page);
                           await waitForEl(`year-${yr}`, 15_000);
                           tryJumpYear();
                         } else {
                           await ensureAnchorFor({ year: yr, targetTs: fb?.last_ts ?? fb?.first_ts });
                           tryJumpYear();
                         }
                       } finally {
                         setLoadingJumpKey(null);
                         setTimeout(() => setLockedYear(null), 800);
                       }
                     }}
                    className={`text-xs px-2 py-1 rounded-full transition-colors ${
                      (lockedYear ?? activeYear) === yr ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'
                    }`}
                  >
                    {loadingJumpKey === `year-${yr}` ? '…' : yr}
                  </button>
                  {/* Inter-year gap area with dots vertically centered (tighter) */}
                  <div className="relative w-full h-8 mt-1">
                    <div className="absolute inset-0 flex flex-col items-center justify-center gap-1">
                    {[1,2,3,4].map((q) => {
                      const qb = quarterBuckets.get(yr);
                      const qInfo = qb?.find((b) => b.quarter === q);
                      const count = qInfo?.count ?? 0;
                      const title = `${yr} • Q${q}${qb ? ` • ${count} items` : ''}`;
                      const anchorId = `quarter-${yr}-Q${q}`;
                      const loading = loadingJumpKey === `q-${yr}-${q}`;
                      const dotActive = activeQuarterKey === `${yr}-Q${q}`;
                      return (
                        <button
                          key={`q-${yr}-${q}`}
                          title={title}
                           onClick={async () => {
                             setLoadingJumpKey(`q-${yr}-${q}`);
                             try {
                               // Lock highlight to clicked quarter during jump
                               setLockedQuarterKey(`${yr}-Q${q}`);
                               setActiveQuarterKey(`${yr}-Q${q}`);
                               setLockedYear(yr);
                               setActiveYear(yr);

                               // Ensure we have quarter buckets for this year so jump-to-page math is accurate.
                               let qbNow = quarterBuckets.get(yr);
                               if (!qbNow) {
                                 try {
                                   const url = bucketQueryString
                                     ? `/api/buckets/quarters?year=${yr}&${bucketQueryString}`
                                     : `/api/buckets/quarters?year=${yr}`;
                                   const r = await fetch(url, { credentials: 'same-origin' });
                                   if (r.ok) {
                                     const data: QuarterBucket[] = await r.json();
                                     qbNow = data;
                                     setQuarterBuckets((prev) => new Map(prev).set(yr, data));
                                   }
                                 } catch {}
                               }
                               const qInfoNow = qbNow?.find((b) => b.quarter === q) ?? qInfo;

                               tlog('info', '[TimelineJump] quarter click', {
                                 year: yr,
                                 quarter: q,
                                 bucket: qInfoNow,
                                 perPage,
                                 photosLoaded: photosLenRef.current,
                                 oldestLoadedTs: oldestLoadedTsRef.current,
                                 hasMore: hasMoreStableRef.current,
                                 isLoading: isLoadingRef.current,
                               });
                               const tryJump = () => {
                                 const el = document.getElementById(anchorId);
                                 if (el) { scrollElementToFocus(el, 'auto'); return true; }
                                 return false;
                               };
                               if (tryJump()) return;

                               const yInfo = onJumpToPage ? computePageForYear(yr) : null;
                               const size = Math.max(1, Math.floor(perPage || 100));
                               const offsetYears = yInfo?.offset ?? 0;
                               const offsetQuarters = qbNow?.reduce((sum, b) => sum + (b.quarter > q ? b.count : 0), 0) ?? 0;
                               const targetPage = Math.floor((offsetYears + offsetQuarters) / size) + 1;

                               if (onJumpToPage && yInfo && qbNow?.length) {
                                 tlog('info', '[TimelineJump] quarter jumpToPage', {
                                   year: yr,
                                   quarter: q,
                                   page: targetPage,
                                   offset: offsetYears + offsetQuarters,
                                   offsetYears,
                                   offsetQuarters,
                                   perPage,
                                 });
                                 await onJumpToPage(targetPage);
                                 await waitForEl(anchorId, 15_000);
                                 tryJump();
                               } else {
                                 const fb = qInfoNow?.last_ts ?? qInfoNow?.first_ts;
                                 await ensureAnchorFor({ quarterKey: `${yr}-Q${q}`, targetTs: fb });
                                 tryJump();
                               }
                             } finally {
                               setLoadingJumpKey(null);
                               // Release lock shortly after scroll begins
                               setTimeout(() => setLockedQuarterKey(null), 800);
                               setTimeout(() => setLockedYear(null), 800);
                             }
                           }}
                          className={`relative w-2.5 h-2.5 rounded-full flex items-center justify-center ${
                            loading
                              ? 'bg-transparent'
                              : count > 0
                                ? (dotActive ? 'bg-primary' : 'bg-muted-foreground/70 hover:bg-muted-foreground')
                                : 'bg-muted/40'
                          }`}
                          aria-label={`Jump to ${yr} Q${q}`}
                        >
                          {loading && (
                            <span className="w-2.5 h-2.5 border-2 border-muted-foreground border-t-transparent rounded-full animate-spin" />
                          )}
                        </button>
                      );
                    })}
                    </div>
                  </div>
                </div>
              </li>
            ))}
          </ul>
          {/* Back to top button (aligned to same column center as year pills) */}
          <div className="mt-4 flex justify-end">
            <div className="w-20 flex justify-center">
              <button
                onClick={async () => {
                  const c = scrollContainerRef?.current;
                  const topYear = years[0];
                  setLoadingJumpKey('top');
                  try {
                    if (topYear) {
                      // Lock highlight to first dot of the top year
                      const qb = quarterBuckets.get(topYear);
                      const firstAvailable = qb && qb.length ? (qb.find(q => q.count > 0)?.quarter ?? 1) : 1;
                      setLockedYear(topYear);
                      setActiveYear(topYear);
                      setLockedQuarterKey(`${topYear}-Q${firstAvailable}`);
                      setActiveQuarterKey(`${topYear}-Q${firstAvailable}`);
                    }
                    tlog('info', '[TimelineJump] top click', {
                      topYear,
                      perPage,
                      photosLoaded: photosLenRef.current,
                      oldestLoadedTs: oldestLoadedTsRef.current,
                      hasMore: hasMoreStableRef.current,
                      isLoading: isLoadingRef.current,
                    });

                    const topYearIsLoaded = topYear
                      ? (anchorsRef.current.has(topYear) || !!document.getElementById(`year-${topYear}`))
                      : true;

                    // If we jumped to an old page, the newest years may not be loaded; reset to page 1.
                    if (!topYearIsLoaded && onJumpToPage) {
                      tlog('info', '[TimelineJump] top jumpToPage', { page: 1, topYear, perPage });
                      await onJumpToPage(1);
                      if (topYear) {
                        await waitForEl(`year-${topYear}`, 15_000);
                      }
                      try { scrollContainerRef?.current?.scrollTo({ top: 0, behavior: 'auto' }); } catch {}
                      return;
                    }

                    if (c) c.scrollTo({ top: 0, behavior: 'smooth' });
                  } finally {
                    setTimeout(() => { setLockedYear(null); setLockedQuarterKey(null); }, 800);
                    setLoadingJumpKey(null);
                  }
                }}
                className="text-[11px] px-2 py-1 rounded-full bg-muted text-foreground hover:bg-muted/80"
                title="Back to top"
              >
                {loadingJumpKey === 'top' ? '…' : '↑ Top'}
              </button>
            </div>
          </div>
        </div>
      </aside>
    </div>
  );
}

export default TimelineView;
