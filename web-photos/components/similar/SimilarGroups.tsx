'use client';

import React, { useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { similarApi, SimilarGroup, AssetMeta } from '@/lib/api/similar';
import { TreePine, X } from 'lucide-react';
import { photosApi } from '@/lib/api/photos';
import AlbumPickerDialog from '@/components/albums/AlbumPickerDialog';
import { logger } from '@/lib/logger';

export function SimilarGroups({ onOpenPhoto }: { onOpenPhoto?: (assetId: string, group: string[], index: number) => void }) {
  const [cursor, setCursor] = useState<number>(0);
  const [groups, setGroups] = useState<SimilarGroup[]>([]);
  const [meta, setMeta] = useState<Record<string, AssetMeta>>({});
  const [done, setDone] = useState<boolean>(false);
  const [threshold] = useState<number>(8);
  const [minGroupSize] = useState<number>(2);

  const { data, isLoading, refetch } = useQuery({
    queryKey: ['similar-groups', cursor, threshold, minGroupSize],
    queryFn: async () => similarApi.getGroups({ threshold, min_group_size: minGroupSize, limit: 50, cursor }),
  });

  // Sync local list with fetched data (avoids state updates inside queryFn)
  useEffect(() => {
    if (!data) return;
    logger.debug('[SIMILAR VIEW] Received groups', { total: data.total_groups, pageCount: data.groups.length, next_cursor: data.next_cursor, cursor });
    if (cursor === 0) setGroups(data.groups);
    else setGroups(prev => [...prev, ...data.groups]);
    if (data.metadata) setMeta(prev => ({ ...prev, ...data.metadata! }));
    setDone(!data.next_cursor);
  }, [data, cursor]);

  const loadMore = () => {
    if (!done) setCursor(groups.length);
  };

  return (
    <div className="p-4">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-semibold">Similar Photo Groups</h2>
        <div className="text-sm text-muted-foreground">{groups.length} groups loaded</div>
      </div>
      {groups.length === 0 && !isLoading && (
        <div className="text-muted-foreground">No similar photo groups found. Try indexing more photos.</div>
      )}
      <div className="flex flex-col gap-6">
        {groups.map((g, idx) => (
          <GroupGrid key={idx} group={g} onOpenPhoto={onOpenPhoto} metadata={meta} />
        ))}
      </div>
      <div className="mt-6 flex justify-center">
        <button
          className="px-4 py-2 rounded border border-border bg-card hover:bg-muted disabled:opacity-50"
          disabled={done || isLoading}
          onClick={loadMore}
        >
          {done ? 'All loaded' : (isLoading ? 'Loading…' : 'Load more')}
        </button>
      </div>
    </div>
  );
}

function GroupGrid({ group, onOpenPhoto, metadata }: { group: SimilarGroup; onOpenPhoto?: (assetId: string, group: string[], index: number) => void; metadata: Record<string, AssetMeta> }) {
  const queryClient = useQueryClient();
  // Render all members in a responsive grid; highlight the representative first
  const baseItems = useMemo(() => (
    group.members.includes(group.representative)
      ? [group.representative, ...group.members.filter(a => a !== group.representative)]
      : group.members
  ), [group.members, group.representative]);
  const [filteredItems, setFilteredItems] = useState<string[] | null>(null);
  const [sortKind, setSortKind] = useState<'date' | 'size'>('date');
  const itemsUnsorted = filteredItems ?? baseItems;
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [removedIds, setRemovedIds] = useState<Set<string>>(new Set());
  const items = useMemo(() => {
    const arr = itemsUnsorted.filter(a => !removedIds.has(a)).slice();
    if (sortKind === 'date') {
      arr.sort((a, b) => (metadata[b]?.created_at || 0) - (metadata[a]?.created_at || 0));
    } else {
      arr.sort((a, b) => (metadata[b]?.size || 0) - (metadata[a]?.size || 0));
    }
    return arr;
  }, [itemsUnsorted, sortKind, metadata, removedIds]);

  // Album selection dialog and data
  const [showAlbumPicker, setShowAlbumPicker] = useState(false);
  const [selectedAlbumId, setSelectedAlbumId] = useState<number | null>(null);
  const { data: albums } = useQuery({ queryKey: ['albums'], queryFn: () => photosApi.getAlbums(), staleTime: 60_000 });
  const selectedAlbumName = useMemo(() => (
    (selectedAlbumId && (albums || []).find(a => a.id === selectedAlbumId)?.name) || undefined
  ), [selectedAlbumId, albums]);
  const containerRef = React.useRef<HTMLDivElement | null>(null);
  const [layout, setLayout] = React.useState<{ cols: number; columnWidth: number; tile: number }>({ cols: 3, columnWidth: 200, tile: 192 });

  const recalc = React.useCallback(() => {
    const el = containerRef.current;
    if (!el) return;
    const w = el.clientWidth;
    const minPhotoSize = 150;
    const maxPhotoSize = 300;
    const gap = 8;
    let photoSize = Math.max(
      minPhotoSize,
      Math.min(maxPhotoSize, Math.floor((w - gap * 2) / Math.max(2, Math.floor(w / 200))))
    );
    const cols = Math.max(1, Math.floor((w + gap) / (photoSize + gap)));
    const actualColumnWidth = Math.floor(w / cols);
    setLayout({ cols, columnWidth: actualColumnWidth, tile: actualColumnWidth - 8 });
  }, []);

  React.useEffect(() => {
    recalc();
    const onResize = () => recalc();
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, [recalc]);

  // Filter logic: intersect group items with selected album contents
  const filterByAlbum = async (albumId: number) => {
    try {
      const targetSet = new Set(baseItems);
      const found = new Set<string>();
      let page = 1;
      const limit = 250;
      let hasMore = true;
      while (hasMore && found.size < targetSet.size) {
        const resp = await photosApi.getPhotos({ page, limit, sort_by: 'created_at', sort_order: 'DESC', album_id: albumId } as any);
        for (const p of resp.photos) {
          if (targetSet.has(p.asset_id)) found.add(p.asset_id);
        }
        hasMore = resp.has_more;
        page += 1;
      }
      const filtered = baseItems.filter(id => found.has(id));
      setFilteredItems(filtered.length ? filtered : []);
      setSelectedAlbumId(albumId);
      setSelected(new Set());
    } catch (e) {
      logger.warn('Failed to filter group by album', e);
      setFilteredItems(null);
      setSelectedAlbumId(null);
    }
  };

  const toggleSelectAll = () => {
    if (selected.size === 0) {
      setSelected(new Set(items));
    } else {
      setSelected(new Set());
    }
  };

  const toggleSelect = (id: string) => {
    setSelected(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  // Quick-select: all but the largest by file size
  const selectInferior = () => {
    if (items.length === 0) return;
    let maxId = items[0];
    let maxSize = (metadata[maxId]?.size || 0) as number;
    for (const id of items) {
      const sz = (metadata[id]?.size || 0) as number;
      if (sz > maxSize) { maxSize = sz; maxId = id; }
    }
    setSelected(new Set(items.filter(id => id !== maxId)));
  };

  // Delete moves photos to Trash immediately (no confirm dialog)
  const deleteSelected = async () => {
    if (selected.size === 0) return;
    await confirmDeleteNow();
  };
  const confirmDeleteNow = async () => {
    const ids = Array.from(selected);
    try {
      const res = await photosApi.deletePhotos(ids);
      logger.info('[SIMILAR] delete result', res);
      setRemovedIds(prev => { const next = new Set(prev); ids.forEach(id => next.add(id)); return next; });
      setSelected(new Set());
      try {
        await queryClient.invalidateQueries({ queryKey: ['albums'] });
        await queryClient.invalidateQueries({ predicate: (q) => Array.isArray(q.queryKey) && q.queryKey[0] === 'media-counts' });
      } catch {}
    } catch (e) {
      logger.error('Delete failed', e);
    }
  };
  return (
    <section className="border border-border rounded-md bg-card overflow-hidden">
      <div className="px-3 py-2 border-b border-border flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="text-sm text-foreground font-medium">Similar group</span>
          <span className="text-xs px-2 py-0.5 rounded-full border border-primary/30 bg-primary/10 text-primary">
            {items.length} / {group.count}
          </span>
          {selectedAlbumId ? (
            <span className="relative inline-flex items-center gap-1 text-xs px-2 py-0.5 rounded-full border border-border bg-background">
              <TreePine className="w-3 h-3" />
              <span className="max-w-[12rem] truncate" title={selectedAlbumName || String(selectedAlbumId)}>
                {selectedAlbumName || `Album #${selectedAlbumId}`}
              </span>
              <button
                className="ml-1 w-5 h-5 rounded-full bg-foreground text-background flex items-center justify-center hover:opacity-90"
                onClick={() => { setSelectedAlbumId(null); setFilteredItems(null); }}
                aria-label="Clear album filter"
                title="Clear album filter"
              >
                <X className="w-3 h-3" />
              </button>
            </span>
          ) : null}
        </div>
        <div className="flex items-center gap-2">
          {/* Selection controls */}
          <button
            className="flex items-center gap-1 text-sm px-2 py-1 rounded border border-border bg-background hover:bg-muted"
            onClick={toggleSelectAll}
            aria-label="Select"
            title="Select"
          >
            Select{selected.size ? ` (${selected.size})` : ''}
          </button>
          <button
            className="flex items-center gap-1 text-sm px-2 py-1 rounded border border-border bg-background hover:bg-muted"
            onClick={selectInferior}
            aria-label="Select inferior"
            title="Select all but largest"
          >
            Select Inferior
          </button>
          {selected.size > 0 && (
            <button
              className="text-xs text-muted-foreground hover:underline"
              onClick={() => setSelected(new Set())}
              aria-label="Select none"
              title="Select none"
            >
              None
            </button>
          )}
          <button
            className={`flex items-center gap-1 text-sm px-2 py-1 rounded border ${selected.size ? 'border-destructive/40 bg-destructive/10 text-destructive hover:bg-destructive/20' : 'border-border bg-muted text-muted-foreground cursor-not-allowed'}`}
            onClick={deleteSelected}
            disabled={selected.size === 0}
            aria-label="Delete selected"
            title={selected.size ? 'Delete selected' : 'Select photos to enable'}
          >
            Delete
          </button>
          {/* Sort dropdown */}
          <div className="relative">
            <button
              className="flex items-center gap-1 text-sm px-2 py-1 rounded border border-border bg-background hover:bg-muted"
              onClick={(e) => {
                const menu = (e.currentTarget.nextSibling as HTMLElement | null);
                if (menu) menu.style.display = menu.style.display === 'block' ? 'none' : 'block';
              }}
              aria-haspopup="menu"
              aria-label="Sort"
              title="Sort"
            >
              Sort
            </button>
            <div className="absolute right-0 mt-1 w-56 bg-background border border-border rounded shadow-xl z-10" style={{ display: 'none' }}
                 onMouseLeave={(e) => { (e.currentTarget as HTMLElement).style.display = 'none'; }} aria-label="Sort menu">
              <button className="block w-full text-left px-3 py-2 text-sm hover:bg-muted" onClick={(e) => { setSortKind('date'); (e.currentTarget.parentElement as HTMLElement).style.display = 'none'; }}>Date (Newest First)</button>
              <button className="block w-full text-left px-3 py-2 text-sm hover:bg-muted" onClick={(e) => { setSortKind('size'); (e.currentTarget.parentElement as HTMLElement).style.display = 'none'; }}>File Size (Largest First)</button>
            </div>
          </div>
          <button
            className="flex items-center gap-1 text-sm px-2 py-1 rounded border border-border bg-background hover:bg-muted"
            onClick={() => setShowAlbumPicker(true)}
            aria-label="Filter by album"
            title="Filter by album"
          >
            <TreePine className="w-4 h-4" /> Album
          </button>
        </div>
      </div>
      <div ref={containerRef} className="p-3 grid" style={{ gridTemplateColumns: `repeat(${layout.cols}, ${layout.columnWidth}px)` }}>
        {items.map((a, i) => {
          const m = metadata[a] || {};
          const type = (m.mime_type || '').split('/')[1]?.toUpperCase() || 'UNKNOWN';
          const size = formatBytes(m.size);
          const time = m.created_at ? new Date((m.created_at as number) * 1000).toLocaleString() : '';
          return (
            <div key={a} style={{ width: layout.columnWidth, margin: 4 }} className={`rounded overflow-hidden border ${selected.has(a) ? 'border-primary ring-2 ring-primary/40' : 'border-border'} bg-background`}>
              <button
                className="relative group block bg-background"
                onClick={(e) => { if (selected.size > 0) { e.preventDefault(); toggleSelect(a); } else { onOpenPhoto && onOpenPhoto(a, items, i); } }}
                aria-label="Open photo"
                style={{ width: layout.tile, height: layout.tile, margin: 'auto' }}
              >
                <img
                  src={`/api/thumbnails/${encodeURIComponent(a)}`}
                  alt="Member"
                  className="w-full h-full object-cover group-hover:opacity-90"
                  loading="lazy"
                />
                {selected.size > 0 && (
                  <span className={`absolute top-1 left-1 w-5 h-5 rounded-full ${selected.has(a) ? 'bg-primary text-primary-foreground' : 'bg-background text-foreground'} border border-border grid place-items-center text-[11px]`}>✓</span>
                )}
              </button>
              <div className="px-2 py-1 text-[11px] text-muted-foreground flex items-center justify-between gap-2">
                <span className="truncate" title={m.mime_type || ''}>{type}</span>
                <span className="truncate" title={`${m.size ?? 0} bytes`}>{size}</span>
                <span className="truncate" title={time}>{time}</span>
              </div>
            </div>
          );
        })}
      </div>
      <AlbumPickerDialog
        open={showAlbumPicker}
        albums={albums || []}
        onClose={() => setShowAlbumPicker(false)}
        onConfirm={(albumId) => { setShowAlbumPicker(false); filterByAlbum(albumId); }}
      />
    </section>
  );
}

function formatBytes(n?: number) {
  const v = typeof n === 'number' ? n : 0;
  if (v < 1024) return `${v} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let p = v;
  let i = -1;
  do { p /= 1024; i++; } while (p >= 1024 && i < units.length - 1);
  return `${p.toFixed(p >= 100 ? 0 : 1)} ${units[i]}`;
}
