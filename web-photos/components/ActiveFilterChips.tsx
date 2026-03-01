'use client';

import React, { useMemo, useCallback, useState } from 'react';
import { X, Heart, Sparkles, Snowflake, Lock as LockIcon } from 'lucide-react';
import dynamic from 'next/dynamic';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useQueryState } from '@/hooks/useQueryState';
import { photosApi } from '@/lib/api/photos';
import { useFacesThumbVersion } from '@/hooks/useFacesThumbVersion';
import { PhotoListQuery } from '@/lib/types/photo';
import SaveLiveAlbumModal from '@/components/modals/SaveLiveAlbumModal';
import FreezeAlbumModal from '@/components/modals/FreezeAlbumModal';

export function ActiveFilterChips() {
  const EEShareButton: any = dynamic(() => import('@ee/components/ShareButton'));
  const queryClient = useQueryClient();
  const { state, setFaces, setTypes, setLocation, setDateRange, setFavorite, setAlbum, setAlbums, toggleAlbum, setAlbumSubtree, clearAllFilters, setSort, setQ, setLocked, setRating } = useQueryState();
  // Load albums (cached) to resolve selected album name/cover(s)
  const { data: albums } = useQuery({ queryKey: ['albums'], queryFn: () => photosApi.getAlbums(), staleTime: 60_000 });
  const selectedAlbumIds = useMemo(() => {
    const list = new Set<string>();
    if (state.albums && state.albums.length) state.albums.forEach(id => list.add(id));
    if (state.album) list.add(state.album);
    return Array.from(list);
  }, [state.album, state.albums]);
  const selectedAlbums = useMemo(() => {
    const byId = new Map<number, any>();
    (albums || []).forEach(a => byId.set(a.id, a));
    return selectedAlbumIds
      .map(id => byId.get(Number(id)))
      .filter(Boolean) as any[];
  }, [albums, selectedAlbumIds]);
  const hasAny = !!(selectedAlbumIds.length || state.q || state.faces?.length || state.type?.length || state.start || state.end || state.country || state.region || state.city || state.favorite === '1' || state.locked === '1' || state.rating);
  const anySelectedHasChildren = useMemo(() => {
    if (!selectedAlbums.length) return false;
    const ids = new Set(selectedAlbums.map(a => a.id));
    return (albums || []).some(a => a.parent_id != null && ids.has(a.parent_id));
  }, [albums, selectedAlbums]);
  const hasOtherFilters = !!(
    state.q ||
    state.favorite === '1' ||
    (state.faces && state.faces.length > 0) ||
    (state.type && state.type.length > 0) ||
    state.country || state.region || state.city ||
    state.start || state.end || state.rating ||
    (state.media && state.media !== 'all')
  );
  const facesThumbV = useFacesThumbVersion();
  const [showSaveModal, setShowSaveModal] = useState(false);
  const [showFreezeModal, setShowFreezeModal] = useState(false);
  // Show the bar when there are active filters OR when inside an album (even if no other filters)
  if (!hasAny) return null;

  const Chip = ({ label, onClear }: { label: string; onClear: () => void }) => (
    <span className="chip-pop inline-flex items-center gap-1 bg-primary/10 text-primary border border-primary/30 hover:bg-primary/20 px-2 py-1 rounded-full text-sm">
      {label}
      <button onClick={onClear} className="hover:underline" aria-label={`Clear ${label}`}>
        <X className="w-3 h-3" />
      </button>
    </span>
  );

  return (
    <div className="sticky top-0 z-20 bg-background/80 backdrop-blur border-b border-border">
      <div className="relative px-4 sm:px-6 lg:px-8 py-2 flex flex-wrap gap-2 pr-40">
        {/* Album chips (multiple supported) */}
        {selectedAlbums.map(a => (
          <span key={a.id} className="relative chip-pop inline-flex items-center gap-2 bg-card/80 border border-border rounded-full px-2 py-0.5 pr-8 text-sm">
            {a?.cover_asset_id ? (
              <img
                src={`/api/thumbnails/${encodeURIComponent(a.cover_asset_id)}`}
                alt="cover"
                className="w-5 h-5 rounded-full object-cover border border-border"
                loading="lazy"
              />
            ) : null}
            <span className="max-w-[16rem] truncate inline-flex items-center gap-1">
              {a?.is_live ? <Sparkles className="w-4 h-4 text-purple-600" /> : null}
              {a?.name || `Album #${a?.id}`}
              {a?.is_live && typeof (a as any).rating_min === 'number' ? (
                <span className="ml-1 text-[10px] text-red-500">★≥{(a as any).rating_min}</span>
              ) : null}
            </span>
            <button
              className="absolute top-0 right-0 w-5 h-5 rounded-full bg-foreground text-background hover:opacity-90 flex items-center justify-center shadow"
              onClick={() => toggleAlbum(String(a.id))}
              aria-label="Remove album filter"
              title="Remove album filter"
            >
              <X className="w-3 h-3" />
            </button>
          </span>
        ))}
        {selectedAlbums.length > 0 && anySelectedHasChildren ? (
          <label className="inline-flex items-center gap-1 text-xs text-foreground select-none">
            <input
              type="checkbox"
              checked={state.albumSubtree === '1'}
              onChange={(e) => setAlbumSubtree(e.target.checked)}
            />
            sub‑albums
          </label>
        ) : null}
        {/* Rating chip */}
        {state.rating ? (
          <Chip label={`Rating ≥ ${state.rating}`} onClear={() => setRating(undefined)} />
        ) : null}
        {/* Search query chip */}
        {(state.q || '').trim().length > 0 && (
          <Chip label={`Search: ${(state.q || '').trim()}`} onClear={() => setQ(undefined)} />
        )}
        {/* Favorites chip */}
        {state.favorite === '1' && (
          <span className="relative chip-pop inline-flex items-center gap-1 bg-card/80 border border-border rounded-full px-2 py-0.5 pr-7 text-sm">
            <Heart className="w-4 h-4 text-red-600 fill-red-600" />
            <span>Favorites</span>
            <button
              className="absolute top-0 right-0 w-5 h-5 rounded-full bg-foreground text-background hover:opacity-90 flex items-center justify-center shadow"
              onClick={() => setFavorite(false)}
              aria-label="Clear favorites filter"
              title="Clear favorites filter"
            >
              <X className="w-3 h-3" />
            </button>
          </span>
        )}

        {/* Locked-only chip (use default chip background for consistency) */}
        {state.locked === '1' && (
          <span className="relative chip-pop inline-flex items-center gap-2 bg-card/80 border border-border rounded-full px-2 py-0.5 pr-8 text-sm">
            <LockIcon className="w-4 h-4 text-amber-600 fill-amber-600" />
            <span>Locked</span>
            <button
              className="absolute top-0 right-0 w-5 h-5 rounded-full bg-foreground text-background hover:opacity-90 flex items-center justify-center shadow"
              onClick={() => setLocked(false)}
              aria-label="Remove locked filter"
              title="Remove locked filter"
            >
              <X className="w-3 h-3" />
            </button>
          </span>
        )}

        {state.faces?.length ? (
          <div className="chip-pop inline-flex items-center gap-1 bg-primary/5 border border-primary/30 text-primary rounded-full px-1 py-0.5">
            {state.faces.slice(0,3).map((id) => (
              <span key={id} className="relative inline-flex items-center pr-5 mr-1">
                <img
                  src={`${photosApi.getFaceThumbnailUrl(id)}&t=${facesThumbV}`}
                  alt={id}
                  className="w-6 h-6 rounded-full object-cover border border-border"
                  title={id}
                />
                <button
                  className="absolute top-0 right-0 bg-foreground text-background rounded-full w-5 h-5 flex items-center justify-center shadow"
                  onClick={() => setFaces((state.faces || []).filter(f => f !== id))}
                  aria-label={`Remove face ${id}`}
                >
                  <X className="w-3 h-3" />
                </button>
              </span>
            ))}
            {state.faces.length > 3 && (
              <span className="text-xs text-muted-foreground px-1">+{state.faces.length - 3}</span>
            )}
          </div>
        ) : null}
        {state.type?.includes('screenshot') ? <Chip label="Screenshots" onClear={() => setTypes((state.type || []).filter(t => t !== 'screenshot') as any)} /> : null}
        {state.type?.includes('live') ? <Chip label="Live Photos" onClear={() => setTypes((state.type || []).filter(t => t !== 'live') as any)} /> : null}
        {(state.start || state.end) ? (
          <Chip label={`Time ${state.start ? state.start.slice(0,10) : ''}${state.end ? ' → ' + state.end.slice(0,10) : ''}`} onClear={() => setDateRange({ start: undefined, end: undefined })} />
        ) : null}
        {state.country ? <Chip label={`Country ${state.country}`} onClear={() => setLocation({ country: undefined, region: state.region, city: state.city })} /> : null}
        {state.region ? <Chip label={`Region ${state.region}`} onClear={() => setLocation({ country: state.country, region: undefined, city: state.city })} /> : null}
        {state.city ? <Chip label={`City ${state.city}`} onClear={() => setLocation({ country: state.country, region: state.region, city: undefined })} /> : null}

        {/* Actions on the right edge */}
        <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
          {/* Save as Live Album (hide when current album is live) */}
          {(!selectedAlbums.some(a => a?.is_live)) && (selectedAlbums.length === 0 || hasOtherFilters || selectedAlbumIds.length > 1) && (
          <button
            className="px-2 py-1 rounded-md bg-primary/10 text-primary border border-primary/30 hover:bg-primary/20 text-xs flex items-center gap-1"
            onClick={() => setShowSaveModal(true)}
            title="Save current filters as a Live Album"
          >
            <Sparkles className="w-4 h-4" /> Save as Live
          </button>
          )}

          {/* Freeze to Static: only show if current album is a live album */}
          {selectedAlbums.length === 1 && selectedAlbums[0]?.is_live ? (
            <button
              className="px-2 py-1 rounded-md bg-card text-foreground border border-border hover:bg-muted text-xs flex items-center gap-1"
              onClick={() => setShowFreezeModal(true)}
              title="Create a static snapshot of this live album"
            >
              <Snowflake className="w-4 h-4" /> Freeze
            </button>
          ) : null}

          {/* EE: Share button (only when exactly one album is selected) */}
          {selectedAlbums.length === 1 && (
            <EEShareButton albumId={selectedAlbums[0]?.id} defaultMode="album" className="px-2 py-1 rounded-md bg-card text-foreground border border-border hover:bg-muted text-xs" />
          )}

          {/* Clear-all button */}
          <button
            className="w-7 h-7 rounded-full bg-foreground text-background hover:opacity-90 flex items-center justify-center shadow"
            onClick={() => {
              clearAllFilters();
              try { window.postMessage({ type: 'clear-all-filters' }, window.location.origin); } catch {}
            }}
            aria-label="Clear all filters"
            title="Clear all filters"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      </div>
      {/* Modals */}
      <SaveLiveAlbumModal
        open={showSaveModal}
        onCancel={() => setShowSaveModal(false)}
        onConfirm={async (name: string) => {
          const crit: PhotoListQuery = {} as any;
          if (state.q) crit.q = state.q;
          if (state.favorite === '1') crit.filter_favorite = true;
          if (state.media === 'photo') crit.filter_is_video = false;
          if (state.media === 'video') crit.filter_is_video = true;
          if (state.faces?.length) {
            (crit as any).filter_faces = state.faces.join(',');
            if (state.facesMode === 'any') (crit as any).filter_faces_mode = 'any';
          }
          if (state.country) crit.filter_country = state.country;
          if (state.city) crit.filter_city = state.city;
          if (state.start) crit.filter_date_from = Math.floor(new Date(state.start).getTime() / 1000);
          if (state.end) crit.filter_date_to = Math.floor(new Date(state.end).getTime() / 1000) + 86399;
          if (state.type?.includes('screenshot')) crit.filter_screenshot = true;
          if (state.type?.includes('live')) crit.filter_live_photo = true;
          if (state.rating) { const n = parseInt(state.rating,10); if (!Number.isNaN(n) && n>=1 && n<=5) (crit as any).filter_rating_min = n; }
          // Locked filter → persist in live criteria so album enforces locked-only
          if (state.locked === '1') {
            (crit as any).filter_locked_only = true;
            (crit as any).include_locked = true;
          }
          if (selectedAlbumIds.length > 1) {
            (crit as any).album_ids = selectedAlbumIds.join(',');
            (crit as any).album_subtree = state.albumSubtree === '1';
          } else if (selectedAlbumIds.length === 1) {
            const n = Number(selectedAlbumIds[0]);
            if (!Number.isNaN(n)) (crit as any).album_id = n;
            (crit as any).album_subtree = state.albumSubtree === '1';
          }
          if (state.sort === 'newest') { crit.sort_by = 'created_at'; crit.sort_order = 'DESC'; }
          if (state.sort === 'oldest') { crit.sort_by = 'created_at'; crit.sort_order = 'ASC'; }
          if (state.sort === 'largest') { crit.sort_by = 'size'; crit.sort_order = 'DESC'; }
          if (state.sort === 'random') { (crit as any).sort_by = 'random'; (crit as any).sort_random_seed = state.seed ?? Math.floor(Math.random()*1_000_000); }

          const album = await photosApi.createLiveAlbum({ name: name.trim(), description: undefined, parent_id: undefined, criteria: crit });
          try { await queryClient.invalidateQueries({ queryKey: ['albums'] }); } catch {}
          clearAllFilters();
          setAlbum(String(album.id));
          if (state.sort) setSort(state.sort, state.seed);
          setShowSaveModal(false);
        }}
      />
      <FreezeAlbumModal
        open={showFreezeModal}
        onCancel={() => setShowFreezeModal(false)}
        onConfirm={async (name: string) => {
          const targetId = selectedAlbums[0]?.id;
          if (!targetId) return;
          const frozen = await photosApi.freezeAlbum(targetId, name);
          try { await queryClient.invalidateQueries({ queryKey: ['albums'] }); } catch {}
          clearAllFilters();
          setAlbum(String(frozen.id));
          if (state.sort) setSort(state.sort, state.seed);
          setShowFreezeModal(false);
        }}
      />
    </div>
  );
}
