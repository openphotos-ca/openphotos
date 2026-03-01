'use client';

import { useCallback, useEffect, useMemo } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';

export type MediaFacet = 'all' | 'photo' | 'video';
export type SortFacet = 'newest' | 'oldest' | 'largest' | 'random' | 'imported_newest' | 'imported_oldest';
export type LayoutFacet = 'grid' | 'timeline';

export type SearchModeFacet = 'auto' | 'all' | 'semantic' | 'text';

export interface QueryState {
  q?: string;
  qmode?: SearchModeFacet; // search mode for q
  favorite?: '1';
  album?: string;
  albums?: string[];
  albumSubtree?: '1';
  faces?: string[];
  // Face match mode: 'all' (AND) or 'any' (OR)
  facesMode?: 'all' | 'any';
  media?: MediaFacet;
  type?: ('screenshot' | 'live' | 'duplicates')[];
  sort?: SortFacet;
  seed?: number;
  // UI layout (grid vs. timeline)
  layout?: LayoutFacet;
  start?: string; // ISO
  end?: string;   // ISO
  country?: string;
  region?: string;
  city?: string;
  // minimum star rating (1..5)
  rating?: string;
  // show only locked items (requires PIN)
  locked?: '1';
  trash?: '1';
  view?: 'similar';
}

function csvGet(sp: URLSearchParams, key: string): string[] | undefined {
  const val = sp.get(key);
  if (!val) return undefined;
  return val.split(',').filter(Boolean);
}

function csvSet(sp: URLSearchParams, key: string, arr?: string[]) {
  if (!arr || arr.length === 0) {
    sp.delete(key);
  } else {
    sp.set(key, arr.join(','));
  }
}

export function useQueryState() {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();

  const state = useMemo<QueryState>(() => {
    const media = (params.get('media') as MediaFacet) || undefined;
    const sort = (params.get('sort') as SortFacet) || undefined;
    const layout = (params.get('layout') as LayoutFacet) || undefined;
    const seedStr = params.get('seed');
    const facesModeParam = params.get('facesMode') as 'all' | 'any' | null;
    return {
      q: params.get('q') || undefined,
      qmode: (params.get('qmode') as SearchModeFacet) || undefined,
      favorite: (params.get('favorite') === '1') ? '1' : undefined,
      album: params.get('album') || undefined,
      albums: csvGet(params, 'albums'),
      albumSubtree: (params.get('albumSubtree') === '1') ? '1' : undefined,
      faces: csvGet(params, 'faces'),
      facesMode: facesModeParam || undefined,
      media,
      type: csvGet(params, 'type') as ('screenshot' | 'live' | 'duplicates')[] | undefined,
      sort,
      layout,
      seed: seedStr ? Number(seedStr) : undefined,
      start: params.get('start') || undefined,
      end: params.get('end') || undefined,
      country: params.get('country') || undefined,
      region: params.get('region') || undefined,
      city: params.get('city') || undefined,
      rating: params.get('rating') || undefined,
      locked: params.get('locked') === '1' ? '1' : undefined,
      trash: params.get('trash') === '1' ? '1' : undefined,
      view: (params.get('view') as 'similar' | null) || undefined,
    };
  }, [params]);

  const replaceParams = useCallback((updater: (sp: URLSearchParams) => void) => {
    // Build from the latest URL to avoid races with stale SearchParams snapshots
    const current = typeof window !== 'undefined' ? window.location.search : (params?.toString() || '');
    const sp = new URLSearchParams(current);
    updater(sp);
    const qs = sp.toString();

    // Preserve the hash fragment when updating URL
    const hash = typeof window !== 'undefined' ? window.location.hash : '';
    const target = `${pathname}${qs ? `?${qs}` : ''}${hash}`;

    try { router.replace(target); } catch {}
    // Fallback: also update the URL directly to avoid any router/query merge edge cases
    try { if (typeof window !== 'undefined') window.history.replaceState({}, '', target); } catch {}
  }, [pathname, router, params]);

  useEffect(() => {
    // Default media/layout if not present; avoid forcing sort to prevent races
    const hasMedia = params.has('media');
    const hasLayout = params.has('layout');
    const hasQMode = params.has('qmode');
    if (!hasMedia || !hasLayout || !hasQMode) {
      replaceParams(sp => {
        if (!hasMedia) sp.set('media', 'all');
        if (!hasLayout) sp.set('layout', 'grid');
        if (!hasQMode) sp.set('qmode', 'auto');
      });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const setFavorite = useCallback((on: boolean) => {
    replaceParams(sp => {
      if (on) {
        sp.set('favorite', '1');
        // keep album/albums; allow combining with favorites
      } else {
        sp.delete('favorite');
      }
    });
  }, [replaceParams]);

  const setAlbum = useCallback((albumId?: string) => {
    replaceParams(sp => {
      if (albumId) {
        sp.set('album', albumId);
        // keep favorite and multi selection
        sp.delete('albums');
      } else {
        sp.delete('album');
        sp.delete('albumSubtree');
        sp.delete('albums');
      }
    });
  }, [replaceParams]);

  const setAlbums = useCallback((albumIds?: string[]) => {
    replaceParams(sp => {
      const ids = (albumIds || []).filter(Boolean);
      if (ids.length === 0) {
        sp.delete('albums');
        sp.delete('album');
        sp.delete('albumSubtree');
        return;
      }
      if (ids.length === 1) {
        sp.set('album', ids[0]!);
        sp.delete('albums');
      } else {
        csvSet(sp, 'albums', ids);
        sp.delete('album');
      }
      // keep favorite
    });
  }, [replaceParams]);

  const toggleAlbum = useCallback((albumId: string) => {
    replaceParams(sp => {
      const currentSingle = sp.get('album') || undefined;
      const currentMulti = csvGet(sp, 'albums') || [];
      let next: string[] = [];
      if (currentSingle && currentMulti.length === 0) {
        // Start from single selection and toggle into multi when adding a different one
        if (currentSingle === albumId) {
          // toggle off
          next = [];
        } else {
          next = [currentSingle, albumId];
        }
      } else {
        const set = new Set(currentMulti);
        if (set.has(albumId)) set.delete(albumId); else set.add(albumId);
        next = Array.from(set);
      }
      // Normalize params based on next size
      if (next.length === 0) {
        sp.delete('albums');
        sp.delete('album');
        sp.delete('albumSubtree');
      } else if (next.length === 1) {
        sp.set('album', next[0]!);
        sp.delete('albums');
      } else {
        csvSet(sp, 'albums', next);
        sp.delete('album');
      }
      // keep favorite
    });
  }, [replaceParams]);

  const setAlbumSubtree = useCallback((on: boolean) => {
    replaceParams(sp => {
      if (on) sp.set('albumSubtree', '1'); else sp.delete('albumSubtree');
    });
  }, [replaceParams]);

  const setTrash = useCallback((on: boolean) => {
    replaceParams(sp => {
      if (on) {
        sp.set('trash', '1');
        sp.delete('favorite');
        sp.delete('locked');
        sp.set('media', 'all');
      } else {
        sp.delete('trash');
      }
    });
  }, [replaceParams]);

  const clearFavoriteAndAlbum = useCallback(() => {
    replaceParams(sp => {
      sp.delete('favorite');
      sp.delete('album');
      sp.delete('albums');
      sp.delete('albumSubtree');
      sp.delete('trash');
    });
  }, [replaceParams]);

  // Clear all filters to show all photos.
  // Keeps sort/media as-is, but removes favorites, album, faces and filter params.
  const clearAllFilters = useCallback(() => {
    replaceParams(sp => {
      sp.delete('q');
      sp.delete('favorite');
      sp.delete('album');
      sp.delete('albums');
      sp.delete('albumSubtree');
      sp.delete('faces');
      sp.delete('facesMode');
      sp.delete('type');
      sp.delete('country');
      sp.delete('region');
      sp.delete('city');
      sp.delete('start');
      sp.delete('end');
      // Also clear rating filter when clearing all filters
      sp.delete('rating');
      sp.delete('locked');
      sp.delete('trash');
      // Note: do not touch 'media', 'sort', or 'seed'
    });
  }, [replaceParams]);

  const setMedia = useCallback((m: MediaFacet) => {
    replaceParams(sp => { sp.set('media', m); });
  }, [replaceParams]);

  const setSort = useCallback((s: SortFacet, seed?: number) => {
    replaceParams(sp => {
      sp.set('sort', s);
      if (s === 'random') {
        const val = typeof seed === 'number' ? seed : Math.floor(Math.random() * 1000000);
        sp.set('seed', String(val));
      } else {
        sp.delete('seed');
      }
    });
  }, [replaceParams]);

  const setLayout = useCallback((layout: LayoutFacet) => {
    replaceParams(sp => {
      sp.set('layout', layout);
    });
  }, [replaceParams]);

  const setQ = useCallback((q?: string) => {
    replaceParams(sp => {
      if (q && q.length) sp.set('q', q); else sp.delete('q');
    });
  }, [replaceParams]);

  const setQMode = useCallback((mode: SearchModeFacet) => {
    replaceParams(sp => {
      sp.set('qmode', mode);
    });
  }, [replaceParams]);

  const setFaces = useCallback((faces?: string[]) => {
    replaceParams(sp => csvSet(sp, 'faces', faces));
  }, [replaceParams]);

  const setFacesMode = useCallback((mode: 'all' | 'any') => {
    replaceParams(sp => {
      if (mode === 'all') sp.delete('facesMode');
      else sp.set('facesMode', mode);
    });
  }, [replaceParams]);

  const setTypes = useCallback((types?: ('screenshot'|'live'|'duplicates')[]) => {
    replaceParams(sp => csvSet(sp, 'type', types));
  }, [replaceParams]);

  const setLocation = useCallback((loc: { country?: string; region?: string; city?: string }) => {
    replaceParams(sp => {
      if (loc.country) sp.set('country', loc.country); else sp.delete('country');
      if (loc.region) sp.set('region', loc.region); else sp.delete('region');
      if (loc.city) sp.set('city', loc.city); else sp.delete('city');
    });
  }, [replaceParams]);

  const setRating = useCallback((min?: number) => {
    replaceParams(sp => {
      if (typeof min === 'number' && min >= 1 && min <= 5) sp.set('rating', String(min));
      else sp.delete('rating');
    });
  }, [replaceParams]);

  const setLocked = useCallback((on: boolean) => {
    replaceParams(sp => { if (on) sp.set('locked', '1'); else sp.delete('locked'); });
  }, [replaceParams]);

  const setDateRange = useCallback((range: { start?: string; end?: string }) => {
    replaceParams(sp => {
      if (range.start) sp.set('start', range.start); else sp.delete('start');
      if (range.end) sp.set('end', range.end); else sp.delete('end');
    });
  }, [replaceParams]);

  const setView = useCallback((view?: 'similar') => {
    replaceParams(sp => {
      if (view) sp.set('view', view); else sp.delete('view');
    });
  }, [replaceParams]);

  return { state, setFavorite, setAlbum, setAlbums, toggleAlbum, setAlbumSubtree, setTrash, clearFavoriteAndAlbum, clearAllFilters, setMedia, setSort, setLayout, setQ, setQMode, setFaces, setFacesMode, setTypes, setLocation, setDateRange, setLocked, setView, setRating };
}
