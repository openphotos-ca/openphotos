'use client';

import React, { useMemo, useState, useEffect, useCallback, useRef } from 'react';
import type { Album } from '@/lib/types/photo';
import { Heart, Filter as FilterIcon, TreePine, Sparkles, Lock as LockIcon } from 'lucide-react';
import { AuthenticatedImage } from '@/components/ui/AuthenticatedImage';
import { useQuery } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import { PinDialog } from '@/components/security/PinDialog';
import { useQueryState } from '@/hooks/useQueryState';
import AlbumPickerDialog from '@/components/albums/AlbumPickerDialog';

export function AlbumChips({ onOpenFilters }: { onOpenFilters?: () => void }) {
  const { state, setAlbum, setAlbums, toggleAlbum, setAlbumSubtree, setFavorite, setLocked } = useQueryState();
  const [showAlbumPicker, setShowAlbumPicker] = useState(false);
  const { data: albums } = useQuery({
    queryKey: ['albums'],
    queryFn: () => photosApi.getAlbums(),
    staleTime: 1000 * 60, // 1 min
  });

  // MRU tracking for album chips: store most recently used album ids in localStorage
  const [mru, setMru] = useState<number[]>(() => {
    try {
      const raw = typeof window !== 'undefined' ? localStorage.getItem('albums-mru') : null;
      const arr = raw ? JSON.parse(raw) : [];
      return Array.isArray(arr) ? (arr as number[]) : [];
    } catch { return []; }
  });

  const markAlbumUsed = useCallback((id: number) => {
    setMru(prev => {
      const next = [id, ...prev.filter(x => x !== id)].slice(0, 50);
      try { localStorage.setItem('albums-mru', JSON.stringify(next)); } catch {}
      return next;
    });
  }, []);

  // Build full dotted path for tooltip (e.g., Root.Trip.China.Beijing)
  const albumPathMap = useMemo(() => {
    const map = new Map<number, string>();
    const byId = new Map<number, Album>();
    (albums || []).forEach((a: Album) => byId.set(a.id, a));
    const compute = (id: number): string => {
      if (map.has(id)) return map.get(id)!;
      const node = byId.get(id);
      if (!node) return '';
      let parts: string[] = [node.name];
      let parentId = node.parent_id;
      let guard = 0;
      while (parentId && guard < 1024) {
        const p = byId.get(parentId);
        if (!p) break;
        parts.push(p.name);
        parentId = p.parent_id;
        guard++;
      }
      parts.reverse();
      const path = parts.join('.');
      map.set(id, path);
      return path;
    };
    (albums || []).forEach(a => { compute(a.id); });
    return map;
  }, [albums]);

  const isFavoriteActive = state.favorite === '1';
  const isLockedActive = state.locked === '1';

  // PIN dialog state for locked-only toggle
  const [pinOpen, setPinOpen] = useState(false);
  const [pinMode, setPinMode] = useState<'verify' | 'set'>("verify");
  const pinResolverRef = useRef<((ok: boolean) => void) | null>(null);

  const ensurePinVerified = async (): Promise<boolean> => {
    try {
      const st: any = await photosApi.getPinStatus();
      if (!st?.is_set) setPinMode('set');
      else if (!st?.verified) setPinMode('verify');
      else return true;
      setPinOpen(true);
      return await new Promise<boolean>((resolve) => { pinResolverRef.current = resolve; });
    } catch { return false; }
  };

  // When an album is clicked, if it contains any locked items, ensure PIN is verified and enable locked-only mode
  const maybePromptPinForAlbum = useCallback(async (albumId: number) => {
    try {
      const counts = await photosApi.getMediaCounts({ album_id: albumId, album_subtree: state.albumSubtree === '1' });
      const lockedCount = (counts as any)?.locked ?? 0;
      if (lockedCount > 0) {
        const ok = await ensurePinVerified();
        if (ok) {
          try { setLocked(true); } catch {}
        }
      }
    } catch {
      // best-effort only
    }
  }, [state.albumSubtree, ensurePinVerified, setLocked]);
  const selectedAlbumIds = useMemo(() => {
    const list = new Set<string>();
    if (state.albums && state.albums.length) state.albums.forEach(id => list.add(id));
    if (state.album) list.add(state.album);
    return Array.from(list);
  }, [state.album, state.albums]);

  // Order: Favorites first (handled in UI), then albums by MRU (most recently used) or by updated_at/created_at desc
  const orderedAlbums = useMemo(() => {
    if (!albums) return [] as Album[];
    const byId = new Map<number, Album>();
    albums.forEach(a => byId.set(a.id, a));
    const mruList = (mru || []).filter(id => byId.has(id));
    const mruAlbums = mruList.map(id => byId.get(id)!) as Album[];
    const rest = albums.filter(a => !mruList.includes(a.id));
    rest.sort((a, b) => (b.updated_at - a.updated_at) || (b.created_at - a.created_at));
    return [...mruAlbums, ...rest];
  }, [albums, mru]);

  return (
    <>
      <div className="sticky top-16 z-30 bg-background/80 backdrop-blur border-b border-border">
        <div className="px-4 sm:px-6 lg:px-8 py-2 flex items-center">
          <div className="flex gap-2 overflow-x-auto no-scrollbar pr-2 flex-1 items-center">
            {/* Filter button moved to the first position on the row */}
            <button
              onClick={onOpenFilters}
              className="shrink-0 inline-flex items-center gap-1 px-3 py-1.5 rounded-md border border-border bg-card text-foreground hover:bg-muted leading-none"
              title="Open filters"
            >
              <FilterIcon className="w-4 h-4" />
              Filter
            </button>
            {/* Subtle dot when any filter chip is active */}
            { (state.faces?.length || state.type?.length || state.start || state.end || state.country || state.region || state.city) ? (
              <span className="inline-block w-2 h-2 rounded-full bg-purple-500 ml-1 align-middle"/>
            ) : null }

            {/* Albums button */}
            <button
              onClick={() => setShowAlbumPicker(true)}
              className="shrink-0 inline-flex items-center gap-1 px-3 py-1.5 rounded-md border border-border bg-card text-foreground hover:bg-muted leading-none"
              title="Browse albums"
            >
              <TreePine className="w-4 h-4" />
              Albums
            </button>
            {/* Favorites */}
            <button
              onClick={() => (isFavoriteActive ? setFavorite(false) : setFavorite(true))}
              className={`shrink-0 inline-flex items-center gap-1 px-3 py-1.5 rounded-full border ${isFavoriteActive ? 'bg-primary text-primary-foreground border-primary hover:bg-primary/90' : 'bg-card text-foreground border-border hover:bg-muted'}`}
              aria-pressed={isFavoriteActive}
              title="Favorites"
              aria-label="Favorites"
            >
              <Heart className={`w-4 h-4 ${isFavoriteActive ? 'fill-red-600 text-red-600' : ''}`} />
            </button>

            {/* Locked-only (to the right of Favorites) */}
            <button
              onClick={async () => {
                if (isLockedActive) { setLocked(false); return; }
                const ok = await ensurePinVerified();
                if (ok) setLocked(true);
              }}
              className={`shrink-0 inline-flex items-center gap-1 px-3 py-1.5 rounded-full border ${isLockedActive ? 'bg-primary text-primary-foreground border-primary hover:bg-primary/90' : 'bg-card text-foreground border-border hover:bg-muted'}`}
              aria-pressed={isLockedActive}
              title="Locked"
              aria-label="Locked"
            >
              <LockIcon className={`w-4 h-4 ${isLockedActive ? 'fill-amber-600 text-amber-600' : ''}`} />
            </button>

            {/* User albums */}
            {orderedAlbums?.map(a => {
              const isSelected = selectedAlbumIds.includes(String(a.id));
              return (
              <button
                key={a.id}
                onClick={() => {
                  toggleAlbum(String(a.id));
                  markAlbumUsed(a.id);
                  // Fire-and-forget PIN prompt if album has locked items and this album is being selected
                  if (!isSelected) maybePromptPinForAlbum(a.id);
                }}
                className={`shrink-0 px-3 py-1.5 rounded-full border flex items-center gap-2 leading-none ${isSelected ? 'bg-primary text-primary-foreground border-primary hover:bg-primary/90' : 'bg-card text-foreground border-border hover:bg-muted'}`}
                aria-pressed={isSelected}
                title={albumPathMap.get(a.id) || a.name}
              >
                {a.cover_asset_id ? (
                  <img
                    src={`/api/thumbnails/${encodeURIComponent(a.cover_asset_id)}`}
                    alt="cover"
                    className="w-4 h-4 rounded object-cover"
                    loading="lazy"
                  />
                ) : null}
                <span className="truncate max-w-[12rem] inline-flex items-center gap-1">
                  {a.is_live ? <Sparkles className="w-4 h-4 text-purple-500" /> : null}
                  {a.name}
                  {a.is_live && typeof (a as any).rating_min === 'number' ? (
                    <span className="ml-1 text-[10px] text-red-500">★≥{(a as any).rating_min}</span>
                  ) : null}
                </span>
                {/* Hide counts on chips; counts can be misleading with filters/sub-albums */}
              </button>
            );
            })}
          </div>
        </div>
      </div>

      {/* Album Picker Dialog */}
      <AlbumPickerDialog
        open={showAlbumPicker}
        albums={albums || []}
        onClose={() => setShowAlbumPicker(false)}
        onConfirm={(albumId) => {
          setShowAlbumPicker(false);
          // Add or toggle selection from picker; supports multi-select mode
          toggleAlbum(String(albumId));
          // Non-blocking PIN prompt if the picked album has locked items and it's not already selected
          const preSelected = selectedAlbumIds.includes(String(albumId));
          if (!preSelected) maybePromptPinForAlbum(albumId);
        }}
      />

      {/* PIN dialog for locked toggle */}
      <PinDialog
        open={pinOpen}
        mode={pinMode}
        onClose={() => { setPinOpen(false); pinResolverRef.current?.(false); pinResolverRef.current = null; }}
        onVerified={() => { setPinOpen(false); pinResolverRef.current?.(true); pinResolverRef.current = null; }}
      />
    </>
  );
}
