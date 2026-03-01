'use client';

import React from 'react';
import { X, Sparkles } from 'lucide-react';
import EEShareButton from '@ee/components/ShareButton';
import { useQueryState } from '@/hooks/useQueryState';

export default function ActiveFilterChipsFallback() {
  const { state, toggleAlbum, setAlbumSubtree, clearAllFilters } = useQueryState();
  const selectedAlbumIds = React.useMemo(() => {
    const list = new Set<string>();
    if (state.albums && state.albums.length) state.albums.forEach((id) => list.add(id));
    if (state.album) list.add(state.album);
    return Array.from(list);
  }, [state.album, state.albums]);

  const hasAny = !!(
    selectedAlbumIds.length ||
    state.favorite === '1' ||
    (state.faces && state.faces.length > 0) ||
    (state.type && state.type.length > 0) ||
    state.country || state.region || state.city ||
    state.start || state.end
  );

  if (!hasAny) return null;

  return (
    <div className="sticky top-0 z-20 bg-background/80 backdrop-blur border-b border-border">
      <div className="relative px-4 sm:px-6 lg:px-8 py-2 flex flex-wrap gap-2 pr-40">
        {selectedAlbumIds.map((id) => (
          <span key={id} className="relative chip-pop inline-flex items-center gap-2 bg-card/80 border border-border rounded-full px-2 py-0.5 pr-8 text-sm">
            <span className="max-w-[16rem] truncate inline-flex items-center gap-1">
              {/* We do not fetch album names here to avoid query deps; show a generic label. */}
              <Sparkles className="w-4 h-4 text-purple-600" />
              Album #{id}
            </span>
            <button
              className="absolute top-0 right-0 w-5 h-5 rounded-full bg-foreground text-background hover:opacity-90 flex items-center justify-center shadow"
              onClick={() => toggleAlbum(String(id))}
              aria-label="Remove album filter"
              title="Remove album filter"
            >
              <X className="w-3 h-3" />
            </button>
          </span>
        ))}

        {selectedAlbumIds.length > 0 && (
          <label className="inline-flex items-center gap-1 text-xs text-foreground select-none">
            <input
              type="checkbox"
              checked={state.albumSubtree === '1'}
              onChange={(e) => setAlbumSubtree(e.target.checked)}
            />
            sub‑albums
          </label>
        )}

        <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
          {selectedAlbumIds.length === 1 && (
            <EEShareButton albumId={Number(selectedAlbumIds[0])} defaultMode="album" className="px-2 py-1 rounded-md bg-card text-foreground border border-border hover:bg-muted text-xs" />
          )}
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
    </div>
  );
}

