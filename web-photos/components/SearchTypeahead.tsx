'use client';

import React, { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';

export type Suggestion =
  | { kind: 'submit'; label: string; payload?: never }
  | { kind: 'face'; label: string; personId: string }
  | { kind: 'album'; label: string; albumId: number }
  | { kind: 'city'; label: string; city: string }
  | { kind: 'country'; label: string; country: string };

export function SearchTypeahead({ value, onPick, onSubmit, activeIndex, onActiveIndexChange, onSuggestionsChange }: { value: string; onPick: (s: Suggestion) => void; onSubmit: (q: string) => void; activeIndex?: number; onActiveIndexChange?: (i: number) => void; onSuggestionsChange?: (s: Suggestion[]) => void }) {
  const { data: faces } = useQuery({ queryKey: ['faces'], queryFn: () => photosApi.getFaces(), staleTime: 60_000 });
  const { data: albums } = useQuery({ queryKey: ['albums'], queryFn: () => photosApi.getAlbums(), staleTime: 60_000 });
  const { data: meta } = useQuery({ queryKey: ['filters-quick'], queryFn: () => photosApi.getFilterMetadata(), staleTime: 5 * 60_000 });

  const suggestions = useMemo<Suggestion[]>(() => {
    const q = value.trim().toLowerCase();
    if (!q) return [];
    const items: Suggestion[] = [{ kind: 'submit', label: `Search for "${value}"` }];
    // Faces
    for (const f of faces || []) {
      const name = f.name || f.person_id;
      if (name.toLowerCase().includes(q)) {
        items.push({ kind: 'face', label: name, personId: f.person_id });
        if (items.length > 6) break;
      }
    }
    // Albums
    for (const a of albums || []) {
      if (a.name.toLowerCase().includes(q) && items.length < 10) {
        items.push({ kind: 'album', label: a.name, albumId: a.id });
      }
    }
    // Cities / Countries
    for (const c of meta?.cities || []) {
      if (c.toLowerCase().includes(q) && items.length < 12) items.push({ kind: 'city', label: c, city: c });
    }
    for (const c of meta?.countries || []) {
      if (c.toLowerCase().includes(q) && items.length < 14) items.push({ kind: 'country', label: c, country: c });
    }
    return items.slice(0, 14);
  }, [value, faces, albums, meta]);

  React.useEffect(() => {
    onSuggestionsChange?.(suggestions);
  }, [suggestions, onSuggestionsChange]);

  if (!value || suggestions.length === 0) return null;

  return (
    <div className="absolute left-0 right-0 top-full mt-1 bg-card border border-border rounded-md shadow-lg z-50">
      <ul className="max-h-72 overflow-auto py-1 text-sm">
        {suggestions.map((s, idx) => (
          <li key={idx}>
            <button className={`w-full text-left px-3 py-2 hover:bg-muted ${activeIndex === idx ? 'bg-muted' : ''}`} onMouseEnter={() => onActiveIndexChange?.(idx)} onClick={() => s.kind === 'submit' ? onSubmit(value) : onPick(s)}>
              {s.label}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
