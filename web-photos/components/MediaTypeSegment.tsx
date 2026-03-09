'use client';

import React from 'react';
import { useQueryState, MediaFacet } from '@/hooks/useQueryState';
import { useQuery } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import ConfirmDialog from '@/components/ui/ConfirmDialog';

export interface Counts { all?: number; photos?: number; videos?: number; locked?: number; locked_photos?: number; locked_videos?: number; trash?: number }

interface Props {
  counts?: Counts;
  onEmptyTrash?: () => void;
}

export function MediaTypeSegment({ counts: countsProp, onEmptyTrash }: Props) {
  const { state, setMedia, setTrash } = useQueryState();
  const current: MediaFacet = state.media || 'all';
  const [showEmptyConfirm, setShowEmptyConfirm] = React.useState(false);
  
  const { data: countsData } = useQuery<Counts>({
    queryKey: ['media-counts', state.favorite, state.album, state.albums?.join(','), state.albumSubtree, state.q, state.country, state.region, state.city, state.faces?.join(','), state.locked, state.trash],
    queryFn: () => {
      const params: any = {};
      if (state.favorite === '1') params.filter_favorite = true;
      if (state.albums && state.albums.length) { params.album_ids = state.albums.join(','); params.album_subtree = state.albumSubtree === '1'; }
      else if (state.album) { params.album_id = Number(state.album); params.album_subtree = state.albumSubtree === '1'; }
      if (state.faces?.length) {
        params.filter_faces = state.faces.join(',');
        if (state.facesMode === 'any') params.filter_faces_mode = 'any';
      }
      if (state.country) params.filter_country = state.country;
      if (state.city) params.filter_city = state.city;
      if (state.start) params.filter_date_from = Math.floor(new Date(state.start).getTime()/1000);
      if (state.end) params.filter_date_to = Math.floor(new Date(state.end).getTime()/1000);
      if (state.type?.includes('screenshot')) params.filter_screenshot = true;
      if (state.type?.includes('live')) params.filter_live_photo = true;
      if (state.q) params.q = state.q;
      if (state.locked === '1') { params.filter_locked_only = true; params.include_locked = true; }
      if (state.trash === '1') { params.filter_trashed_only = true; }
      return photosApi.getMediaCounts(params);
    },
    staleTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: 0,
  });

  const handleMediaClick = (value: MediaFacet) => {
    if (state.trash === '1') {
      if (value === 'all') {
        setMedia('all');
        setTrash(false);
      } else {
        setMedia(value);
        // stay in trash mode
      }
    } else {
      setMedia(value);
    }
  };

  const btn = (value: MediaFacet, label: string, count?: number) => {
    const active = current === value && (state.trash !== '1' || value !== 'all');
    const showCount = !(state.trash === '1' && value === 'all');
    return (
      <button
        key={value}
        onClick={() => handleMediaClick(value)}
        className={`px-2 sm:px-3 py-1 sm:py-1.5 text-xs sm:text-sm whitespace-nowrap rounded-md border ${active ? 'bg-primary/10 text-primary border-primary/30 hover:bg-primary/20' : 'bg-card text-foreground border-border hover:bg-muted'}`}
        aria-pressed={active}
      >
        {label} {showCount && typeof count === 'number' ? `(${count})` : ''}
      </button>
    );
  };

  const counts = countsProp || countsData;

  // Use server-provided counts directly. Backend already includes locked in `all/photos/videos`
  // when `include_locked=true`, so no client-side addition is needed.
  const allDisplay = counts?.all;
  const photosDisplay = counts?.photos;
  const videosDisplay = counts?.videos;
  const trashDisplay = counts?.trash;
  const trashCount = typeof trashDisplay === 'number' ? trashDisplay : 0;
  const canEmptyTrash = !!onEmptyTrash && trashCount > 0;
  const isTrashActive = state.trash === '1';

  return (
    <div className="sticky top-[var(--top-2,4.5rem)] z-20 bg-background/80 backdrop-blur border-b border-border">
      <div className="px-4 sm:px-6 lg:px-8 py-2">
        <div className="inline-flex gap-2 items-center">
          {btn('all', 'All', allDisplay)}
          {btn('photo', 'Photos', photosDisplay)}
          {btn('video', 'Videos', videosDisplay)}
          <div className={`inline-flex items-center rounded-md border ${isTrashActive ? 'bg-primary/10 text-primary border-primary/30' : 'bg-card text-foreground border-border'}`}>
            <button
              onClick={() => setTrash(!isTrashActive)}
              className={`px-2 sm:px-3 py-1 sm:py-1.5 text-xs sm:text-sm whitespace-nowrap rounded-l-md ${isTrashActive ? 'hover:bg-primary/20' : 'hover:bg-muted'}`}
              aria-pressed={isTrashActive}
            >
              Trash ({trashCount})
            </button>
            {isTrashActive && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  if (canEmptyTrash) setShowEmptyConfirm(true);
                }}
                disabled={!canEmptyTrash}
                aria-label="Empty Trash"
                title="Empty Trash"
                className={`mr-1 h-5 w-5 rounded-full text-[11px] leading-none border flex items-center justify-center ${canEmptyTrash ? 'border-primary/40 text-primary hover:bg-primary/20' : 'border-border text-muted-foreground cursor-not-allowed'}`}
              >
                x
              </button>
            )}
          </div>
        </div>
      </div>
      <ConfirmDialog
        open={showEmptyConfirm}
        title="Empty Trash?"
        description={`This will permanently delete ${trashCount} item${trashCount === 1 ? '' : 's'} from Trash.`}
        confirmLabel="Empty Trash"
        cancelLabel="Cancel"
        variant="destructive"
        onClose={() => setShowEmptyConfirm(false)}
        onConfirm={() => {
          setShowEmptyConfirm(false);
          onEmptyTrash?.();
        }}
      />
    </div>
  );
}
