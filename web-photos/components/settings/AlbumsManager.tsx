'use client';

import React, { useEffect, useMemo, useRef, useState, useLayoutEffect } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import type { Album } from '@/lib/types/photo';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '@/components/ui/card';
import { ChevronRight, ChevronDown, Folder, FolderPlus, Pencil, Trash2, Plus, RefreshCw, Search, GripVertical, GitMerge } from 'lucide-react';
import { logger } from '@/lib/logger';

type TreeNode = Album & { children: TreeNode[] };

function buildTree(albums: Album[]): TreeNode[] {
  const idMap = new Map<number, TreeNode>();
  albums.forEach(a => idMap.set(a.id, { ...a, children: [] }));
  const roots: TreeNode[] = [];
  albums.forEach(a => {
    const node = idMap.get(a.id)!;
    if (a.parent_id == null) {
      roots.push(node);
    } else {
      const parent = idMap.get(a.parent_id);
      if (parent) parent.children.push(node); else roots.push(node);
    }
  });
  // Sort children by position/updated_at if present
  const sortFn = (a: TreeNode, b: TreeNode) => (a.position ?? 0) - (b.position ?? 0) || (b.updated_at - a.updated_at);
  const sortTree = (nodes: TreeNode[]) => {
    nodes.sort(sortFn);
    nodes.forEach(n => sortTree(n.children));
  };
  sortTree(roots);
  return roots;
}

export function AlbumsManager() {
  const qc = useQueryClient();
  const { data: albums, isLoading, isFetching, refetch } = useQuery({
    queryKey: ['albums'],
    queryFn: () => photosApi.getAlbums(),
    staleTime: 30_000,
  });

  const tree = useMemo(() => buildTree(albums || []), [albums]);
  const albumById = useMemo(() => new Map((albums || []).map(a => [a.id, a] as const)), [albums]);
  const [filter, setFilter] = useState('');
  const [expanded, setExpanded] = useState<Record<number, boolean>>({});
  const [editingId, setEditingId] = useState<number | null>(null);
  const [editingName, setEditingName] = useState('');
  const [creatingUnder, setCreatingUnder] = useState<number | null>(null);
  const [creatingName, setCreatingName] = useState('');
  const [creatingRoot, setCreatingRoot] = useState(false);
  const [creatingRootName, setCreatingRootName] = useState('');
  const [busyId, setBusyId] = useState<number | 'root' | null>(null);
  const [mergeOpenId, setMergeOpenId] = useState<number | null>(null);
  const [mergeTargetId, setMergeTargetId] = useState<number | null>(null);
  const [dragId, setDragId] = useState<number | null>(null);
  const [dropHint, setDropHint] = useState<{ targetId: number; zone: 'before'|'into'|'after' } | null>(null);
  const [mouseDragging, setMouseDragging] = useState(false);
  // Preserve caret position while editing to avoid jumps on re-render
  const editingCaretRef = useRef<{ start: number; end: number } | null>(null);
  const editingInputRef = useRef<HTMLInputElement | null>(null);

  // Reapply caret after each value update while editing
  useLayoutEffect(() => {
    const el = editingInputRef.current;
    const sel = editingCaretRef.current;
    if (el && sel && document.activeElement === el) {
      try { el.setSelectionRange(sel.start, sel.end); } catch {}
    }
  }, [editingName, editingId]);

  // Debug effect: log when albums load/update
  useEffect(() => {
    if (albums) {
      logger.debug('[AlbumsManager] albums loaded', { count: albums.length });
    }
  }, [albums]);

  // Debug effect: log drag/drop hint changes
  useEffect(() => {
    logger.debug('[AlbumsManager] dragId changed', dragId);
  }, [dragId]);

  useEffect(() => {
    logger.debug('[AlbumsManager] dropHint changed', dropHint);
  }, [dropHint]);

  // Mouse-based dragging: update dropHint on mouse move while dragging via handle
  useEffect(() => {
    if (!mouseDragging) return;
    const onMove = (e: MouseEvent) => {
      e.preventDefault();
      const el = document.elementFromPoint(e.clientX, e.clientY) as HTMLElement | null;
      const zoneEl = el?.closest('[data-drop-zone]') as HTMLElement | null;
      const rowEl = el?.closest('[data-album-id]') as HTMLElement | null;
      if (zoneEl && rowEl) {
        const zone = zoneEl.getAttribute('data-drop-zone') as 'before'|'into'|'after';
        const idAttr = rowEl.getAttribute('data-album-id');
        const targetId = idAttr ? Number(idAttr) : NaN;
        if (!isNaN(targetId)) {
          const changed = !(dropHint?.targetId === targetId && dropHint.zone === zone);
          if (changed) {
            logger.debug('[AlbumsManager] mousemove hint', { targetId, zone });
            setDropHint({ targetId, zone });
          }
          return;
        }
      }
      // fallback: over row area without specific zone -> treat as into
      if (rowEl) {
        const idAttr = rowEl.getAttribute('data-album-id');
        const targetId = idAttr ? Number(idAttr) : NaN;
        if (!isNaN(targetId)) {
          if (!(dropHint?.targetId === targetId && dropHint.zone === 'into')) {
            logger.debug('[AlbumsManager] mousemove hint (row)', { targetId, zone: 'into' });
            setDropHint({ targetId, zone: 'into' });
          }
          return;
        }
      }
      if (dropHint) setDropHint(null);
    };
    const onUp = () => {
      setMouseDragging(false);
    };
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp, { once: true });
    return () => {
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
    };
  }, [mouseDragging, dropHint]);

  // Global listeners to ensure cleanup if a drop occurs outside our zones
  useEffect(() => {
    const onWindowDrop = (e: DragEvent) => {
      logger.debug('[AlbumsManager] window drop', { target: (e.target as HTMLElement)?.tagName });
      setDropHint(null);
      setDragId(null);
    };
    const onWindowDragEnd = (e: DragEvent) => {
      logger.debug('[AlbumsManager] window dragend');
      setDropHint(null);
      setDragId(null);
    };
    const onWindowDragOver = (e: DragEvent) => {
      // Allow dropping anywhere; specific zones still handle the final drop
      e.preventDefault();
      try { if (e.dataTransfer) e.dataTransfer.dropEffect = 'move'; } catch {}
      const el = e.target as HTMLElement | null;
      const idAttr = el?.closest('[data-album-id]')?.getAttribute('data-album-id');
      const zoneAttr = el?.closest('[data-drop-zone]')?.getAttribute('data-drop-zone');
      if (idAttr && zoneAttr) {
        // Only log when hint actually changes to reduce noise
        const id = Number(idAttr);
        const zone = zoneAttr as 'before'|'into'|'after';
        const changed = !(dropHint?.targetId === id && dropHint.zone === zone);
        if (changed) logger.debug('[AlbumsManager] window dragover at', { id, zone });
      } else {
        // Still log occasionally for visibility
        // console.log('[AlbumsManager] window dragover target', el?.tagName);
      }
    };
    const onWindowMouseUp = (e: MouseEvent) => {
      // Fallback: treat mouseup with active drag + hint as drop
      if (dragId != null && dropHint != null) {
        const hint = dropHint;
        const src = dragId;
        logger.debug('[AlbumsManager] window mouseup fallback drop', { src, hint });
        (async () => {
          try {
            if (hint.zone === 'into') {
              if (src !== hint.targetId) {
                await photosApi.updateAlbum(src, { parent_id: hint.targetId });
                await qc.invalidateQueries({ queryKey: ['albums'] });
              }
            } else {
              // find target node in current tree
              const findById = (nodes: TreeNode[]): TreeNode | null => {
                for (const n of nodes) {
                  if (n.id === hint.targetId) return n;
                  const f = findById(n.children);
                  if (f) return f;
                }
                return null;
              };
              const target = findById(tree);
              if (target && src !== hint.targetId) {
                await reorderWithinSiblings(target, src, hint.zone);
              } else {
                logger.warn('[AlbumsManager] window mouseup fallback could not find target node', { hint });
              }
            }
          } catch (err) {
            logger.error('[AlbumsManager] window mouseup fallback error', err);
          } finally {
            logger.debug('[AlbumsManager] window mouseup fallback cleanup');
            setDropHint(null);
            setDragId(null);
          }
        })();
      } else if (dragId != null || dropHint != null) {
        logger.debug('[AlbumsManager] window mouseup cleanup', { hadDragId: dragId != null, hadDropHint: dropHint != null });
        setDropHint(null);
        setDragId(null);
      }
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        logger.debug('[AlbumsManager] ESC pressed - cancel drag');
        setDropHint(null);
        setDragId(null);
      }
    };
    window.addEventListener('drop', onWindowDrop);
    window.addEventListener('dragend', onWindowDragEnd);
    window.addEventListener('dragover', onWindowDragOver);
    window.addEventListener('mouseup', onWindowMouseUp);
    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('drop', onWindowDrop);
      window.removeEventListener('dragend', onWindowDragEnd);
      window.removeEventListener('dragover', onWindowDragOver);
      window.removeEventListener('mouseup', onWindowMouseUp);
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [dragId, dropHint, tree]);

  const toggle = (id: number) => {
    setExpanded(prev => {
      const next = { ...prev, [id]: !prev[id] };
      logger.debug('[AlbumsManager] toggle', { id, open: next[id] });
      return next;
    });
  };

  const handleCreate = async (parentId: number | null, name: string) => {
    if (!name.trim()) return;
    setBusyId(parentId ?? 'root');
    try {
      logger.info('[AlbumsManager] create album', { parentId, name });
      await photosApi.createAlbum({ name: name.trim(), parent_id: parentId ?? undefined });
      await qc.invalidateQueries({ queryKey: ['albums'] });
      logger.debug('[AlbumsManager] create album done');
    } catch (err) {
      logger.error('[AlbumsManager] create album error', err);
    } finally {
      setBusyId(null);
      setCreatingUnder(null);
      setCreatingName('');
      setCreatingRoot(false);
      setCreatingRootName('');
    }
  };

  const handleRename = async (id: number, name: string) => {
    if (!name.trim()) return setEditingId(null);
    setBusyId(id);
    try {
      logger.info('[AlbumsManager] rename', { id, name });
      await photosApi.updateAlbum(id, { name: name.trim() });
      await qc.invalidateQueries({ queryKey: ['albums'] });
      logger.debug('[AlbumsManager] rename done');
    } catch (err) {
      logger.error('[AlbumsManager] rename error', err);
    } finally {
      setBusyId(null);
      setEditingId(null);
      setEditingName('');
      editingCaretRef.current = null;
    }
  };

  const handleDelete = async (id: number, name: string) => {
    const ok = confirm(`Delete album "${name}" and all its sub-albums? Photos remain in the library.`);
    if (!ok) return;
    setBusyId(id);
    try {
      logger.info('[AlbumsManager] delete', { id });
      await photosApi.deleteAlbum(id);
      await qc.invalidateQueries({ queryKey: ['albums'] });
      logger.debug('[AlbumsManager] delete done');
    } catch (err) {
      logger.error('[AlbumsManager] delete error', err);
    } finally {
      setBusyId(null);
    }
  };

  const reorderWithinSiblings = async (target: TreeNode, draggedId: number, zone: 'before'|'after') => {
    // Build desired order within the target's sibling group
    const parentId = target.parent_id ?? undefined;
    const siblings = (albums || []).filter(a => (a.parent_id ?? undefined) === parentId).sort((a,b)=> (a.position ?? 0) - (b.position ?? 0));
    const ids = siblings.map(s => s.id).filter(id => id !== draggedId);
    const idx = ids.indexOf(target.id);
    const insertAt = zone === 'before' ? Math.max(0, idx) : Math.min(ids.length, idx + 1);
    ids.splice(insertAt, 0, draggedId);
    const beforeOrder = siblings.map(s => s.id);
    const afterOrder = ids;
    if (beforeOrder.length === afterOrder.length && beforeOrder.every((v,i)=>v===afterOrder[i])) {
      logger.debug('[AlbumsManager] reorderWithinSiblings no-op (order unchanged)');
      return;
    }
    // Persist sequential positions
    logger.info('[AlbumsManager] reorderWithinSiblings', { parentId, zone, targetId: target.id, draggedId, orderBefore: siblings.map(s=>({id:s.id,pos:s.position})) , orderAfter: ids });
    // timing kept with console.time for devtools grouping
    console.time('[AlbumsManager] reorderWithinSiblings duration');
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      const update: any = { position: i + 1 };
      if (id === draggedId) update.parent_id = parentId; // only change parent for the dragged album
      logger.debug('[AlbumsManager] update position', { id, position: i+1, parentId: update.parent_id });
      await photosApi.updateAlbum(id, update);
    }
    await qc.invalidateQueries({ queryKey: ['albums'] });
    console.timeEnd('[AlbumsManager] reorderWithinSiblings duration');
    logger.debug('[AlbumsManager] reorderWithinSiblings done');
  };

  const Node: React.FC<{ node: TreeNode; depth: number }> = ({ node, depth }) => {
    const isOpen = !!expanded[node.id];
    const hasChildren = node.children.length > 0;
    const isEditing = editingId === node.id;
    const isCreatingHere = creatingUnder === node.id;
    const isMergingHere = mergeOpenId === node.id;
    const formatAlbumName = (a: Album) => {
      const parent = a.parent_id ? albumById.get(a.parent_id) : undefined;
      return parent ? `${parent.name}/${a.name}` : a.name;
    };
    const eligibleTargets = useMemo(() => {
      const items = (albums || [])
        .filter(a => a.id !== node.id && !a.is_live);
      items.sort((a,b)=> formatAlbumName(a).localeCompare(formatAlbumName(b)));
      return items;
    }, [albums, node.id]);
    return (
      <div
        data-album-id={node.id}
        onDragEnter={()=>{ logger.debug('[AlbumsManager] dragEnter(node)', { targetId: node.id }); }}
        className="rounded"
      >
        {/* Top drop zone (before) */}
        <div
          data-drop-zone="before"
          className={`h-1 -mt-1 ${dropHint?.targetId===node.id && dropHint.zone==='before' ? 'bg-primary/60' : 'bg-transparent'}`}
          onDragOverCapture={(e)=>{ e.preventDefault(); /* ensure drop allowed anywhere in this zone */ }}
          onDragEnter={()=>{ logger.debug('[AlbumsManager] dragEnter(before)', { targetId: node.id }); }}
          onDragOver={(e)=>{ e.preventDefault(); try { e.dataTransfer.dropEffect = 'move'; } catch {} if (!(dropHint?.targetId===node.id && dropHint.zone==='before')) logger.debug('[AlbumsManager] dragOver(before)', { targetId: node.id }); setDropHint({ targetId: node.id, zone: 'before' }); }}
          onDragLeave={(e)=>{ if (dropHint?.targetId===node.id && dropHint.zone==='before') { logger.debug('[AlbumsManager] dragLeave(before)', { targetId: node.id }); setDropHint(null); } }}
          onDrop={async (e)=>{
            e.preventDefault();
            e.stopPropagation();
            try {
              const types = Array.from((e.dataTransfer?.types || []) as unknown as string[]);
              logger.info('[AlbumsManager] drop(before)', { targetId: node.id, dragId, types });
              const raw = e.dataTransfer.getData('text/album') || e.dataTransfer.getData('text/plain');
              const src = Number(raw||dragId);
              logger.debug('[AlbumsManager] drop(before) data', { raw, parsed: src });
              if (!isNaN(src) && src!==node.id) { await reorderWithinSiblings(node, src, 'before'); } else { logger.debug('[AlbumsManager] drop(before) ignored', { reason: isNaN(src) ? 'NaN src' : 'same target' }); }
              await qc.invalidateQueries({ queryKey: ['albums'] });
            } finally {
              logger.debug('[AlbumsManager] drop(before) cleanup');
              setDropHint(null);
              setDragId(null);
            }
          }}
        />
        <div className="flex items-center gap-2 py-1"
          data-drop-zone="into"
          onDragOverCapture={(e)=>{ e.preventDefault(); /* capture-phase to allow drop over any child */ }}
          onDragEnter={()=>{ logger.debug('[AlbumsManager] dragEnter(into)', { targetId: node.id }); }}
          onDragOver={(e)=>{ e.preventDefault(); try { e.dataTransfer.dropEffect = 'move'; } catch {} if (!(dropHint?.targetId===node.id && dropHint.zone==='into')) logger.debug('[AlbumsManager] dragOver(into)', { targetId: node.id }); setDropHint({ targetId: node.id, zone: 'into' }); }}
          onDragLeave={(e)=>{ if (dropHint?.targetId===node.id && dropHint.zone==='into') { logger.debug('[AlbumsManager] dragLeave(into)', { targetId: node.id }); setDropHint(null); } }}
          onDrop={async (e)=>{
            e.preventDefault();
            e.stopPropagation();
            try {
              const types = Array.from((e.dataTransfer?.types || []) as unknown as string[]);
              logger.info('[AlbumsManager] drop(into)', { targetId: node.id, dragId, types });
              const raw = e.dataTransfer.getData('text/album') || e.dataTransfer.getData('text/plain');
              const src = Number(raw||dragId);
              logger.debug('[AlbumsManager] drop(into) data', { raw, parsed: src });
              if (!isNaN(src) && src!==node.id) { await photosApi.updateAlbum(src, { parent_id: node.id }); await qc.invalidateQueries({ queryKey: ['albums'] }); } else { logger.debug('[AlbumsManager] drop(into) ignored', { reason: isNaN(src) ? 'NaN src' : 'same target' }); }
            } finally {
              logger.debug('[AlbumsManager] drop(into) cleanup');
              setDropHint(null);
              setDragId(null);
            }
          }}
        >
          <span
            className="p-1 cursor-grab active:cursor-grabbing"
            title="Drag"
            onMouseDown={(e)=>{
              e.preventDefault();
              setDragId(node.id);
              setMouseDragging(true);
              logger.debug('[AlbumsManager] mouse dragStart(handle)', { id: node.id });
            }}
          >
            <GripVertical className="w-4 h-4 text-gray-400" />
          </span>
          <button
            className={`p-1 rounded hover:bg-gray-100 disabled:opacity-50 ${dragId!=null ? 'pointer-events-none' : ''}`}
            onClick={() => toggle(node.id)}
            disabled={!hasChildren}
            aria-label={isOpen ? 'Collapse' : 'Expand'}
          >
            {hasChildren ? (isOpen ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />) : <span className="w-4 h-4" />}
          </button>
          <Folder className="w-4 h-4 text-gray-500" />
          <div className="flex-1">
            {isEditing ? (
              <form
                onSubmit={(e)=>{e.preventDefault(); handleRename(node.id, editingName)}}
                className="flex items-center gap-2"
              >
                <Input
                  ref={(el)=>{
                    editingInputRef.current = el;
                    if (el && editingCaretRef.current) {
                      try { el.setSelectionRange(editingCaretRef.current.start, editingCaretRef.current.end); } catch {}
                    }
                  }}
                  autoFocus
                  value={editingName}
                  onChange={(e)=>{
                    setEditingName(e.target.value);
                    const start = e.currentTarget.selectionStart ?? e.currentTarget.value.length;
                    const end = e.currentTarget.selectionEnd ?? start;
                    editingCaretRef.current = { start, end };
                  }}
                  onSelect={(e)=>{
                    const start = (e.target as HTMLInputElement).selectionStart ?? 0;
                    const end = (e.target as HTMLInputElement).selectionEnd ?? start;
                    editingCaretRef.current = { start, end };
                  }}
                  className="h-7"
                />
                <Button size="sm" type="submit" disabled={busyId===node.id}>Save</Button>
                <Button size="sm" type="button" variant="ghost" onClick={()=>{setEditingId(null); setEditingName(''); editingCaretRef.current = null;}}>Cancel</Button>
              </form>
            ) : (
              <div className="flex items-center gap-2">
                <span title={node.name}>{node.name}</span>
                <span className="text-xs text-gray-500">({node.photo_count})</span>
              </div>
            )}
          </div>
          {!isEditing && (
            <div className={`flex items-center gap-1 ${dragId!=null ? 'pointer-events-none' : ''}`}
              aria-hidden={dragId!=null}
            >
              <Button variant="ghost" size="sm" title="Add sub‑album" onClick={()=>{setCreatingUnder(node.id); setCreatingName(''); setExpanded(p=>({...p, [node.id]: true}));}}>
                <FolderPlus className="w-4 h-4" />
              </Button>
              <Button variant="ghost" size="sm" title="Rename" onClick={()=>{setEditingId(node.id); setEditingName(node.name);}}>
                <Pencil className="w-4 h-4" />
              </Button>
              {!node.is_live && !hasChildren && (
                <Button
                  variant="ghost"
                  size="sm"
                  title="Merge into…"
                  onClick={()=>{
                    if (mergeOpenId === node.id) { setMergeOpenId(null); setMergeTargetId(null); }
                    else {
                      setMergeOpenId(node.id);
                      const first = eligibleTargets[0]?.id ?? null;
                      setMergeTargetId(first);
                    }
                  }}
                >
                  <GitMerge className="w-4 h-4" />
                </Button>
              )}
              <Button variant="ghost" size="sm" title="Delete" onClick={()=>handleDelete(node.id, node.name)} disabled={busyId===node.id}>
                <Trash2 className="w-4 h-4 text-red-600" />
              </Button>
            </div>
          )}
        </div>
        {/* Merge inline UI */}
        {isMergingHere && (
          <div className="pl-6 py-1">
            {eligibleTargets.length === 0 ? (
              <div className="text-sm text-muted-foreground">No eligible target albums found.</div>
            ) : (
              <form
                className="flex items-center gap-2 w-full"
                onSubmit={async (e)=>{
                  e.preventDefault();
                  if (mergeTargetId == null) return;
                  setBusyId(node.id);
                  try {
                    await photosApi.mergeAlbums({ source_album_id: node.id, target_album_id: mergeTargetId, delete_source: true });
                    await qc.invalidateQueries({ queryKey: ['albums'] });
                    try { if (window.parent && window.parent !== window) window.parent.postMessage({ type: 'albums-updated' }, window.location.origin); } catch {}
                  } catch (err) {
                    logger.error('[AlbumsManager] merge error', err);
                  } finally {
                    setBusyId(null);
                    setMergeOpenId(null);
                    setMergeTargetId(null);
                  }
                }}
              >
                <Label className="text-sm">Merge into</Label>
                <select
                  className="h-8 border rounded px-3 pr-10 bg-background text-foreground flex-1 w-full min-w-0 min-w-[360px] sm:min-w-[420px] text-sm appearance-none"
                  value={mergeTargetId ?? ''}
                  onChange={(e)=>setMergeTargetId(e.target.value ? Number(e.target.value) : null)}
                >
                  {eligibleTargets.map(t => {
                    const label = formatAlbumName(t);
                    return (
                      <option key={t.id} value={t.id} title={label}>{label}</option>
                    );
                  })}
                </select>
                <Button size="sm" type="submit" disabled={busyId===node.id || mergeTargetId==null}>Merge</Button>
                <Button size="sm" type="button" variant="ghost" onClick={()=>{ setMergeOpenId(null); setMergeTargetId(null); }}>Cancel</Button>
              </form>
            )}
          </div>
        )}
        {/* Bottom drop zone (after) */}
        <div
          data-drop-zone="after"
          className={`h-1 ${dropHint?.targetId===node.id && dropHint.zone==='after' ? 'bg-primary/60' : 'bg-transparent'}`}
          onDragOverCapture={(e)=>{ e.preventDefault(); /* ensure drop allowed anywhere in this zone */ }}
          onDragEnter={()=>{ logger.debug('[AlbumsManager] dragEnter(after)', { targetId: node.id }); }}
          onDragOver={(e)=>{ e.preventDefault(); try { e.dataTransfer.dropEffect = 'move'; } catch {} if (!(dropHint?.targetId===node.id && dropHint.zone==='after')) logger.debug('[AlbumsManager] dragOver(after)', { targetId: node.id }); setDropHint({ targetId: node.id, zone: 'after' }); }}
          onDragLeave={(e)=>{ if (dropHint?.targetId===node.id && dropHint.zone==='after') { logger.debug('[AlbumsManager] dragLeave(after)', { targetId: node.id }); setDropHint(null); } }}
          onDrop={async (e)=>{
            e.preventDefault();
            e.stopPropagation();
            try {
              const types = Array.from((e.dataTransfer?.types || []) as unknown as string[]);
              logger.info('[AlbumsManager] drop(after)', { targetId: node.id, dragId, types });
              const raw = e.dataTransfer.getData('text/album') || e.dataTransfer.getData('text/plain');
              const src = Number(raw||dragId);
              logger.debug('[AlbumsManager] drop(after) data', { raw, parsed: src });
              if (!isNaN(src) && src!==node.id) { await reorderWithinSiblings(node, src, 'after'); } else { logger.debug('[AlbumsManager] drop(after) ignored', { reason: isNaN(src) ? 'NaN src' : 'same target' }); }
              await qc.invalidateQueries({ queryKey: ['albums'] });
            } finally {
              logger.debug('[AlbumsManager] drop(after) cleanup');
              setDropHint(null);
              setDragId(null);
            }
          }}
        />
        {isCreatingHere && (
          <div className="pl-6 py-1">
            <form onSubmit={(e)=>{e.preventDefault(); handleCreate(node.id, creatingName);}} className="flex items-center gap-2">
              <Input autoFocus placeholder="New sub‑album name" value={creatingName} onChange={e=>setCreatingName(e.target.value)} className="h-8 w-64 sm:w-80" />
              <Button size="sm" type="submit" disabled={!creatingName.trim() || busyId===node.id}>Create</Button>
              <Button size="sm" type="button" variant="ghost" onClick={()=>{setCreatingUnder(null); setCreatingName('');}}>Cancel</Button>
            </form>
          </div>
        )}
        {hasChildren && isOpen && (
          <div className="pl-6">
            {node.children.map(child => (
              <Node key={child.id} node={child} depth={depth+1} />
            ))}
          </div>
        )}
      </div>
    );
  };

  return (
    <Card className="mt-8">
      <CardHeader>
        <div className="flex items-center justify-between">
          <div>
            <CardTitle>Albums</CardTitle>
          </div>
          <div className="flex items-center gap-2">
            <Button variant="ghost" size="sm" onClick={()=>refetch()} disabled={isFetching} title="Refresh">
              <RefreshCw className={`w-4 h-4 ${isFetching ? 'animate-spin' : ''}`} />
            </Button>
            {!creatingRoot ? (
              <Button size="sm" className="whitespace-nowrap" onClick={()=>{setCreatingRoot(true); setCreatingRootName('');}}>
                <Plus className="w-4 h-4" /> New Album
              </Button>
            ) : (
              <form onSubmit={(e)=>{e.preventDefault(); handleCreate(null, creatingRootName);}} className="flex items-center gap-2">
                <Input autoFocus placeholder="New album name" value={creatingRootName} onChange={e=>setCreatingRootName(e.target.value)} className="h-8 w-64 sm:w-80" />
                <Button size="sm" type="submit" disabled={!creatingRootName.trim() || busyId==='root'}>Create</Button>
                <Button size="sm" variant="ghost" type="button" onClick={()=>{setCreatingRoot(false); setCreatingRootName('');}}>Cancel</Button>
              </form>
            )}
          </div>
        </div>
        <CardDescription className="mt-2">Organize your albums in a hierarchy. Create, rename, and delete albums.</CardDescription>
        {/* Search */}
        <div className="mt-3 flex items-center gap-2">
          <Search className="w-4 h-4 text-gray-500" />
          <Input placeholder="Search albums" value={filter} onChange={e=>setFilter(e.target.value)} className="h-8" />
        </div>
      </CardHeader>
      <CardContent>
        {isLoading ? (
          <div className="text-muted-foreground">Loading albums…</div>
        ) : (
          <div className="border rounded-md p-3 bg-card">
            {tree.length === 0 ? (
              <div className="text-muted-foreground">No albums yet. Create your first album.</div>
            ) : filter.trim() ? (
              (albums || [])
                .filter(a => a.name.toLowerCase().includes(filter.toLowerCase()))
                .map(a => (
                  <div key={a.id} className="py-1">
                    <div className="text-sm text-gray-600">{(a as any).breadcrumb || ''}</div>
                    <Node node={{...(a as any), children: []}} depth={0} />
                  </div>
                ))
            ) : (
              tree.map(node => <Node key={node.id} node={node} depth={0} />)
            )}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
