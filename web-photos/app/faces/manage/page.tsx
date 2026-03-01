'use client';

import React, { useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useRouter } from 'next/navigation';
import { photosApi } from '@/lib/api/photos';
import { logger } from '@/lib/logger';
import type { Face } from '@/lib/types/photo';
import { useToast } from '@/hooks/use-toast';
import ConfirmDialog from '@/components/ui/ConfirmDialog';
import { ArrowLeft } from 'lucide-react';
import EditFaceDialog from '@/components/faces/EditFaceDialog';

export default function ManageFacesPage() {
  const router = useRouter();

  const qc = useQueryClient();
  const { toast } = useToast();

  const { data: faces, isLoading } = useQuery({
    queryKey: ['faces', 'manage'],
    queryFn: () => photosApi.getFaces(),
    staleTime: 60_000,
  });

  type Mode = 'idle' | 'merge_select' | 'merge_choose_primary' | 'merge_edit' | 'merging';
  const [mode, setMode] = useState<Mode>('idle');
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const [primaryId, setPrimaryId] = useState<string | null>(null);
  const [editName, setEditName] = useState<string>('');
  const [editBirth, setEditBirth] = useState<string>('');
  const [editPersonId, setEditPersonId] = useState<string | null>(null);
  const [deleteOpen, setDeleteOpen] = useState<boolean>(false);

  // Preview: derive active person to preview
  const activePersonId = useMemo(() => {
    if (primaryId) return primaryId;
    const arr = Array.from(selection);
    return arr.length > 0 ? arr[arr.length - 1]! : null;
  }, [selection, primaryId]);

  const { data: preview, isLoading: previewLoading } = useQuery({
    queryKey: ['faces', 'items', activePersonId],
    queryFn: async () => {
      if (!activePersonId) return { items: [] as any[] };
      // Prefer the general photos listing with a faces filter for reliability across backends.
      // This reuses the same code path as the main grid and avoids discrepancies.
      try {
        const res = await photosApi.getPhotos({
          page: 1,
          limit: 30,
          filter_faces: [activePersonId],
          filter_faces_mode: 'any',
        } as any);
        return {
          items: (res?.photos || []).map((p) => ({
            asset_id: p.asset_id,
            is_video: !!p.is_video,
            duration_ms: p.duration_ms,
            filename: p.filename,
          }))
        };
      } catch (e) {
        logger.error('[ManageFaces] preview load failed via /photos fallback', e);
        // Fallback to the dedicated endpoint if available
        try { return await photosApi.filterPhotosByPerson(activePersonId); } catch { return { items: [] as any[] }; }
      }
    },
    staleTime: 30_000,
  });

  const toggle = (personId: string) => {
    setSelection((prev) => {
      const next = new Set(prev);
      if (next.has(personId)) next.delete(personId); else next.add(personId);
      return next;
    });
  };

  const total = faces?.length ?? 0;
  const selectedCount = selection.size;

  const items = useMemo(() => (faces || []).map((f) => ({
    personId: (f as Face).person_id,
    label: (f as Face).name || (f as any).display_name || (f as Face).person_id,
    count: (f as Face).photo_count,
    thumb: `${photosApi.getFaceThumbnailUrl((f as Face).person_id)}`,
  })), [faces]);

  // Helpers
  const faceById = useMemo(() => {
    const m = new Map<string, Face>();
    (faces || []).forEach((f) => m.set((f as Face).person_id, f as Face));
    return m;
  }, [faces]);

  const resetMergeFlow = () => {
    setMode('idle');
    setSelection(new Set());
    setPrimaryId(null);
    setEditName('');
    setEditBirth('');
  };

  const startMerge = () => {
    // Preserve existing selection. If user already selected ≥2, skip to choose-primary.
    setPrimaryId(null);
    if (selection.size >= 2) {
      setMode('merge_choose_primary');
    } else {
      setMode('merge_select');
    }
  };

  const nextFromSelect = () => {
    if (selection.size < 2) return;
    setPrimaryId(null);
    setMode('merge_choose_primary');
  };

  const isDefaultName = (name?: string | null) => {
    if (!name) return true;
    const t = String(name).trim();
    return /^p\d+$/i.test(t);
  };

  const getFaceName = (f?: Face | null): string | undefined => {
    if (!f) return undefined;
    return (f.name as any) || (f as any).display_name || undefined;
  };

  const nextFromChoosePrimary = () => {
    if (!primaryId) return;
    // Prefill edit fields from selected faces
    const sel = Array.from(selection).map(id => faceById.get(id)).filter(Boolean) as Face[];
    const primary = faceById.get(primaryId);
    // Prefer primary's non-default name; otherwise any non-default among the selected
    const primaryName = getFaceName(primary);
    let nameCandidate = (!isDefaultName(primaryName) ? primaryName : undefined);
    if (!nameCandidate) {
      const found = sel.map(getFaceName).find(n => n && !isDefaultName(n));
      nameCandidate = found;
    }
    nameCandidate = nameCandidate || '';
    const birthCandidate = (primary?.birth_date) || (sel.find(f => f.birth_date)?.birth_date) || '';
    setEditName(nameCandidate || '');
    setEditBirth((birthCandidate || '').slice(0,10));
    setMode('merge_edit');
  };

  const openEdit = (personId: string) => {
    const f = faceById.get(personId);
    setEditPersonId(personId);
    setEditName((f?.name as any) || (f as any)?.display_name || '');
    setEditBirth(((f as any)?.birth_date || '').slice(0, 10));
  };

  const submitMerge = async () => {
    if (!primaryId) return;
    const sources = Array.from(selection).filter(id => id !== primaryId);
    if (sources.length === 0) return;
    try {
      setMode('merging');
      await photosApi.mergeFaces(primaryId, sources);
      // Update details if provided
      const body: { display_name?: string; birth_date?: string } = {};
      if (editName && editName.trim().length) body.display_name = editName.trim();
      if (editBirth && editBirth.trim().length) body.birth_date = editBirth.trim();
      if (Object.keys(body).length > 0) {
        await photosApi.updatePerson(primaryId, body);
      }
      await qc.invalidateQueries({ queryKey: ['faces'] });
      await qc.invalidateQueries({ queryKey: ['faces', 'manage'] });
      toast({ title: `Merged ${sources.length + 1} faces`, description: `Kept ${primaryId}`, variant: 'success' });
      resetMergeFlow();
    } catch (e: any) {
      logger.error(e);
      toast({ title: 'Merge failed', description: e?.message || String(e), variant: 'destructive' });
      setMode('merge_edit');
    }
  };

  return (
    <div className="min-h-screen flex flex-col bg-background text-foreground">
      {/* Row 1: Back + Title */}
      <div className="sticky top-0 z-10 bg-background/80 backdrop-blur border-b border-border">
        <div className="max-w-6xl mx-auto px-4 h-14 flex items-center gap-3">
          <button
            className="h-10 w-10 grid place-items-center rounded-full border border-border hover:bg-muted text-foreground"
            onClick={() => router.back()}
            aria-label="Back"
            title="Back"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div className="font-semibold">Manage Faces</div>
          <div className="text-sm text-muted-foreground">{total} total</div>
          {selectedCount > 0 && (
            <div className="ml-auto text-sm text-muted-foreground">{selectedCount} selected</div>
          )}
        </div>
      </div>

      {/* Row 2: Toolbar */}
      <div className="border-b border-border bg-background">
        <div className="max-w-6xl mx-auto px-4 h-12 flex items-center gap-2">
          {mode === 'idle' && (
            <>
              <button
                className="px-3 py-1.5 rounded border border-border hover:bg-muted disabled:opacity-50 disabled:cursor-not-allowed"
                disabled={selectedCount < 2}
                onClick={startMerge}
              >Merge Faces</button>
              <button
                className="px-3 py-1.5 rounded border border-border hover:bg-muted disabled:opacity-50 disabled:cursor-not-allowed"
                disabled={selectedCount === 0}
                onClick={() => setDeleteOpen(true)}
              >Delete</button>
            </>
          )}

          {mode === 'merge_select' && (
            <>
              <div className="text-sm text-muted-foreground mr-2">Select at least two faces to merge</div>
              <button className="px-3 py-1.5 rounded border border-border hover:bg-muted" onClick={resetMergeFlow}>Cancel</button>
              <button
                className="px-3 py-1.5 rounded border border-border hover:bg-muted disabled:opacity-50 disabled:cursor-not-allowed"
                disabled={selection.size < 2}
                onClick={nextFromSelect}
              >Next</button>
            </>
          )}

          {mode === 'merge_choose_primary' && (
            <>
              <div className="text-sm text-muted-foreground mr-2">Pick the face to keep as primary</div>
              <button className="px-3 py-1.5 rounded border border-border hover:bg-muted" onClick={resetMergeFlow}>Cancel</button>
              <button
                className="px-3 py-1.5 rounded border border-border hover:bg-muted disabled:opacity-50 disabled:cursor-not-allowed"
                disabled={!primaryId}
                onClick={nextFromChoosePrimary}
              >Next</button>
            </>
          )}

          {mode === 'merge_edit' && (
            <>
              <div className="flex items-center gap-2 mr-2 text-sm">
                <label className="text-muted-foreground">Name</label>
                <input value={editName} onChange={e => setEditName(e.target.value)}
                  className="h-8 px-2 rounded border border-border bg-background text-foreground"
                  placeholder="Optional name" />
                <label className="ml-3 text-muted-foreground">Birth</label>
                <input type="date" value={editBirth} onChange={e => setEditBirth(e.target.value)}
                  className="h-8 px-2 rounded border border-border bg-background text-foreground" />
              </div>
              <button className="px-3 py-1.5 rounded border border-border hover:bg-muted" onClick={resetMergeFlow}>Cancel</button>
              <button
                className="px-3 py-1.5 rounded border border-border hover:bg-muted disabled:opacity-50 disabled:cursor-not-allowed"
                onClick={submitMerge}
              >Submit</button>
            </>
          )}

          {mode === 'merging' && (
            <div className="text-sm text-muted-foreground">Merging…</div>
          )}
        </div>
      </div>

      {/* Row 3: Grid of faces */}
      <div className="max-w-6xl mx-auto p-4 w-full" style={{ ['--face-size' as any]: '96px' }}>
        {isLoading ? (
          <div className="text-sm text-muted-foreground">Loading faces…</div>
        ) : (
          <div className="grid gap-3" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(var(--face-size), var(--face-size)))' }}>
            {items
              .filter(({ personId }) => {
                if (mode === 'merge_choose_primary' || mode === 'merge_edit') {
                  return selection.has(personId);
                }
                return true;
              })
              .map(({ personId, label, count, thumb }) => {
                const selected = selection.has(personId);
                const isPrimary = primaryId === personId;
                const onClick = () => {
                  if (mode === 'merge_choose_primary') {
                    setPrimaryId(personId);
                  } else {
                    // toggle selection in other modes
                    toggle(personId);
                  }
                };
                const highlightClass = (mode === 'merge_choose_primary' || mode === 'merge_edit')
                  ? (isPrimary ? 'border-primary ring-2 ring-primary/40' : 'border-border')
                  : (selected ? 'border-primary ring-2 ring-primary/30' : 'border-border');
                return (
                  <div
                    key={personId}
                    className={`text-left rounded-md overflow-hidden border transition-shadow ${highlightClass} bg-card`}
                    title={label}
                    style={{ width: '100%' }}
                  >
                    <button className="w-full" onClick={onClick} aria-label={`Select ${label}`}>
                      <div className="w-full" style={{ aspectRatio: '1 / 1' }}>
                        <img src={thumb} alt={label} className="w-full h-full object-cover bg-muted" loading="lazy" />
                      </div>
                    </button>
                    <button className="w-full p-2 text-xs flex items-center justify-between" onClick={() => openEdit(personId)} aria-label={`Edit ${label}`}>
                      <span className="truncate" title={label}>{label}</span>
                      {typeof count === 'number' && <span className="text-[10px] text-muted-foreground">({count})</span>}
                    </button>
                  </div>
                );
              })}
          </div>
        )}
      </div>

      {/* Row 4: Preview items for selected face */}
      <div className="border-t border-border bg-background">
        <div className="max-w-6xl mx-auto p-4">
          <div className="flex items-center justify-between mb-2">
            <div className="text-sm text-muted-foreground">
              {activePersonId ? `Items for ${activePersonId}` : 'Select a face to preview items'}
            </div>
          </div>
          {activePersonId && (
            previewLoading ? (
              <div className="text-sm text-muted-foreground">Loading items…</div>
            ) : (
              <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
                {(preview?.items || []).slice(0, 10).map((it, idx) => (
                  <div key={`${it.asset_id}-${idx}`} className="relative group rounded overflow-hidden bg-muted">
                    <img
                      src={`/api/thumbnails/${encodeURIComponent(it.asset_id)}`}
                      alt="Preview"
                      className="w-full h-full object-cover"
                      loading="lazy"
                      style={{ aspectRatio: '1 / 1' }}
                    />
                    {it.is_video ? (
                      <span className="absolute bottom-1 right-1 text-[10px] px-1 py-0.5 rounded bg-black/60 text-white">Video</span>
                    ) : null}
                  </div>
                ))}
                {(preview?.items || []).length === 0 && (
                  <div className="text-sm text-muted-foreground">No items found for this face.</div>
                )}
              </div>
            )
          )}
        </div>
      </div>
      <EditFaceDialog
        open={!!editPersonId}
        personId={editPersonId}
        initialName={editName}
        initialBirth={editBirth}
        onClose={() => setEditPersonId(null)}
      />
      <ConfirmDialog
        open={deleteOpen}
        title="Delete faces?"
        description={`Delete ${selection.size} face${selection.size>1?'s':''}. This cannot be undone.`}
        confirmLabel="Delete"
        cancelLabel="Cancel"
        variant="destructive"
        onClose={() => setDeleteOpen(false)}
        onConfirm={async () => {
          const ids = Array.from(selection);
          setDeleteOpen(false);
          try {
            await photosApi.deletePersons(ids);
            await qc.invalidateQueries({ queryKey: ['faces'] });
            await qc.invalidateQueries({ queryKey: ['faces', 'manage'] });
            setSelection(new Set());
            toast({ title: `Deleted ${ids.length} face${ids.length>1?'s':''}`, variant: 'success' });
          } catch (e: any) {
            toast({ title: 'Delete failed', description: e?.message || String(e), variant: 'destructive' });
          }
        }}
      />
    </div>
  );
}
