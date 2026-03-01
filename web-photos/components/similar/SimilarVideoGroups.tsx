'use client';

import React, { useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { similarApi, SimilarGroup } from '@/lib/api/similar';
import { photosApi } from '@/lib/api/photos';
import { logger } from '@/lib/logger';

export function SimilarVideoGroups({ onOpenAsset }: { onOpenAsset?: (assetId: string, group: string[], index: number) => void }) {
  const [cursor, setCursor] = useState<number>(0);
  const [groups, setGroups] = useState<SimilarGroup[]>([]);
  const [done, setDone] = useState<boolean>(false);
  const [minGroupSize] = useState<number>(2);

  const { data, isLoading } = useQuery({
    queryKey: ['similar-video-groups', cursor, minGroupSize],
    queryFn: async () => similarApi.getVideoGroups({ min_group_size: minGroupSize, limit: 50, cursor }),
  });

  useEffect(() => {
    if (!data) return;
    logger.debug('[SIMILAR VIDEOS VIEW] Received groups', { total: data.total_groups, pageCount: data.groups.length, next_cursor: data.next_cursor, cursor });
    if (cursor === 0) setGroups(data.groups);
    else setGroups(prev => [...prev, ...data.groups]);
    setDone(!data.next_cursor);
  }, [data, cursor]);

  const loadMore = () => { if (!done) setCursor(groups.length); };

  return (
    <div className="p-4">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-semibold">Similar Video Groups</h2>
        <div className="text-sm text-muted-foreground">{groups.length} groups loaded</div>
      </div>
      {groups.length === 0 && !isLoading && (
        <div className="text-muted-foreground">No similar video groups found.</div>
      )}
      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
        {groups.map((g, idx) => (
          <VideoGroupGrid key={idx} group={g} onOpenAsset={onOpenAsset} />
        ))}
      </div>
      <div className="mt-6 flex justify-center">
        <button className="px-4 py-2 rounded border border-border bg-card hover:bg-muted disabled:opacity-50" disabled={done || isLoading} onClick={loadMore}>
          {done ? 'All loaded' : (isLoading ? 'Loading…' : 'Load more')}
        </button>
      </div>
    </div>
  );
}

function VideoGroupGrid({ group, onOpenAsset }: { group: SimilarGroup; onOpenAsset?: (assetId: string, group: string[], index: number) => void }) {
  const queryClient = useQueryClient();
  const baseItems = useMemo(() => (
    group.members.includes(group.representative)
      ? [group.representative, ...group.members.filter(a => a !== group.representative)]
      : group.members
  ), [group.members, group.representative]);
  const [removedIds, setRemovedIds] = useState<Set<string>>(new Set());
  const items = useMemo(() => baseItems.filter(a => !removedIds.has(a)), [baseItems, removedIds]);
  const containerRef = React.useRef<HTMLDivElement | null>(null);
  const [layout, setLayout] = React.useState<{ cols: number; columnWidth: number; tile: number }>({ cols: 3, columnWidth: 200, tile: 192 });
  const recalc = React.useCallback(() => {
    const el = containerRef.current; if (!el) return;
    const w = el.clientWidth; const min=150, max=300, gap=8;
    let sz = Math.max(min, Math.min(max, Math.floor((w - gap*2) / Math.max(2, Math.floor(w/200)))));
    const cols = Math.max(1, Math.floor((w + gap) / (sz + gap)));
    const cw = Math.floor(w / cols);
    setLayout({ cols, columnWidth: cw, tile: cw - 8 });
  }, []);
  React.useEffect(() => { recalc(); const onResize = () => recalc(); window.addEventListener('resize', onResize); return () => window.removeEventListener('resize', onResize); }, [recalc]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  // Lazily fetched sizes for items in this group
  const [sizes, setSizes] = useState<Record<string, number>>({});

  const toggleSelectAll = () => {
    if (selected.size === 0) setSelected(new Set(items)); else setSelected(new Set());
  };
  const toggleSelect = (id: string) => {
    setSelected(prev => { const next = new Set(prev); if (next.has(id)) next.delete(id); else next.add(id); return next; });
  };
  // Quick-select: all but the largest by file size (fetch sizes on demand)
  const selectInferior = async () => {
    if (items.length === 0) return;
    let local = sizes;
    // Fetch sizes if missing for this set
    const missing = items.filter(id => local[id] === undefined);
    if (missing.length > 0) {
      try {
        const photos = await photosApi.getPhotosByAssetIds(items, true);
        const map: Record<string, number> = {};
        for (const p of photos) map[p.asset_id] = p.size || 0;
        local = { ...local, ...map };
        setSizes(local);
      } catch {}
    }
    let maxId = items[0], maxSize = local[items[0]] ?? 0;
    for (const id of items) {
      const sz = local[id] ?? 0;
      if (sz > maxSize) { maxSize = sz; maxId = id; }
    }
    setSelected(new Set(items.filter(id => id !== maxId)));
  };

  // Delete moves to Trash immediately (no confirm dialog)
  const deleteSelected = async () => {
    if (selected.size === 0) return;
    await confirmDeleteNow();
  };
  const confirmDeleteNow = async () => {
    const ids = Array.from(selected);
    try {
      const res = await photosApi.deletePhotos(ids);
      logger.info('[SIMILAR-VIDEO] delete result', res);
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
          <span className="text-sm text-foreground font-medium">Similar video group</span>
          <span className="text-xs px-2 py-0.5 rounded-full border border-primary/30 bg-primary/10 text-primary">{items.length} / {group.count}</span>
        </div>
        <div className="flex items-center gap-2">
          <button className="flex items-center gap-1 text-sm px-2 py-1 rounded border border-border bg-background hover:bg-muted" onClick={toggleSelectAll} aria-label="Select">Select{selected.size ? ` (${selected.size})` : ''}</button>
          <button className="flex items-center gap-1 text-sm px-2 py-1 rounded border border-border bg-background hover:bg-muted" onClick={selectInferior} aria-label="Select inferior" title="Select all but largest">Select Inferior</button>
          {selected.size > 0 && (
            <button className="text-xs text-muted-foreground hover:underline" onClick={() => setSelected(new Set())} aria-label="Select none" title="Select none">None</button>
          )}
          <button className={`flex items-center gap-1 text-sm px-2 py-1 rounded border ${selected.size ? 'border-destructive/40 bg-destructive/10 text-destructive hover:bg-destructive/20' : 'border-border bg-muted text-muted-foreground cursor-not-allowed'}`} onClick={deleteSelected} disabled={selected.size===0} aria-label="Delete selected">Delete</button>
        </div>
      </div>
      <div ref={containerRef} className="p-3 grid" style={{ gridTemplateColumns: `repeat(${layout.cols}, ${layout.columnWidth}px)` }}>
        {items.map((a, i) => (
          <button key={a} className={`relative group border ${selected.has(a) ? 'border-primary ring-2 ring-primary/40' : 'border-border'} rounded overflow-hidden bg-background`} onClick={() => { if (selected.size>0) toggleSelect(a); else onOpenAsset && onOpenAsset(a, items, i); }} aria-label="Open video" style={{ width: layout.tile, height: layout.tile, margin: 4 }}>
            <img src={`/api/thumbnails/${encodeURIComponent(a)}`} alt="Member" className="w-full h-full object-cover group-hover:opacity-90" loading="lazy" />
            {selected.size>0 && (<span className={`absolute top-1 left-1 w-5 h-5 rounded-full ${selected.has(a)?'bg-primary text-primary-foreground':'bg-background text-foreground'} border border-border grid place-items-center text-[11px]`}>✓</span>)}
          </button>
        ))}
      </div>
    </section>
  );
}
