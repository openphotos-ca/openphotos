'use client';

import React, { useMemo, useState } from 'react';
import type { Album } from '@/lib/types/photo';
import { X, Check, TreePine, ChevronRight, ChevronDown, Folder, Home, Sparkles, PlusCircle, XCircle } from 'lucide-react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useQueryState } from '@/hooks/useQueryState';
import { photosApi } from '@/lib/api/photos';
import { useToast } from '@/hooks/use-toast';

interface AlbumPickerDialogProps {
  open: boolean;
  albums: Album[];
  onClose: () => void;
  onConfirm: (albumId: number) => void;
  initialSelectedId?: number;
  showIncludeSubtree?: boolean; // controls the "Include sub‑albums" toggle visibility
  allowSelectRoot?: boolean; // when true, allow selecting pseudo Root (no album)
}

type TreeNode = Album & { children: TreeNode[] };
const ROOT_NODE_ID = -1;

export function AlbumPickerDialog({ open, albums, onClose, onConfirm, initialSelectedId, showIncludeSubtree = true, allowSelectRoot = false }: AlbumPickerDialogProps) {
  const { state: qsState, setAlbumSubtree } = useQueryState();
  const [selectedId, setSelectedId] = useState<number | undefined>(initialSelectedId);
  const [firstFocusable, setFirstFocusable] = useState<HTMLButtonElement | null>(null);
  const [lastFocusable, setLastFocusable] = useState<HTMLButtonElement | null>(null);
  const [creatingParentId, setCreatingParentId] = useState<number | undefined>(undefined);
  const [creatingName, setCreatingName] = useState('');
  const [showCreate, setShowCreate] = useState(false);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const queryClient = useQueryClient();
  const { toast } = useToast();
  const [expanded, setExpanded] = useState<Set<number>>(new Set());

  const createMutation = useMutation({
    mutationFn: async (vars: { parent_id?: number; name: string }) => {
      const album = await photosApi.createAlbum({ name: vars.name.trim(), parent_id: vars.parent_id });
      // Optimistically add to albums cache
      queryClient.setQueryData<Album[]>(['albums'], (prev) => {
        const list = prev ? [...prev] : [];
        // Avoid duplicates
        if (!list.find(a => a.id === album.id)) list.unshift(album as Album);
        return list;
      });
      return album as Album;
    },
    onSuccess: (album) => {
      toast({ title: `Created album`, description: album.name, variant: 'success' });
      setCreatingName('');
      setShowCreate(false);
      setSelectedId(album.id);
      try { queryClient.invalidateQueries({ queryKey: ['albums'] }); } catch {}
    },
    onError: (e: any) => {
      toast({ title: 'Failed to create album', description: e?.message || String(e), variant: 'destructive' });
    },
  });

  const deleteMutation = useMutation({
    mutationFn: async (id: number) => {
      // Cascade delete: remove photos from target album and all sub‑albums, then delete bottom‑up
      const toDelete: number[] = [];
      const stack: number[] = [id];
      const childrenByParent = new Map<number, number[]>();
      (albums || []).forEach(a => {
        if (a.parent_id != null) {
          if (!childrenByParent.has(a.parent_id)) childrenByParent.set(a.parent_id, []);
          childrenByParent.get(a.parent_id)!.push(a.id);
        }
      });
      // DFS to collect all descendants
      while (stack.length) {
        const cur = stack.pop()!;
        toDelete.push(cur);
        const kids = childrenByParent.get(cur) || [];
        for (const k of kids) stack.push(k);
      }
      // Process bottom‑up: children first
      toDelete.reverse();
      for (const aid of toDelete) {
        // Remove all photo associations in chunks
        try {
          let page = 1; const limit = 500;
          // Collect numeric photo ids for this album
          const photoIds: number[] = [];
          while (true) {
            const resp: any = await photosApi.getPhotos({ album_id: aid, page, limit } as any);
            const batch = (resp?.photos || []).map((p: any) => p.id).filter((n: any): n is number => typeof n === 'number');
            if (batch.length) photoIds.push(...batch);
            if (!resp?.has_more || batch.length === 0) break;
            page += 1;
          }
          // Remove in chunks of 500 to avoid payload bloat
          const CH = 500;
          for (let i = 0; i < photoIds.length; i += CH) {
            const slice = photoIds.slice(i, i + CH);
            if (slice.length) await photosApi.removePhotosFromAlbum(aid, slice);
          }
        } catch { /* best effort */ }
        // Now delete the album itself
        await photosApi.deleteAlbum(aid);
        // Optimistically drop from cache
        queryClient.setQueryData<Album[]>(['albums'], (prev) => (prev || []).filter(a => a.id !== aid));
      }
      return id;
    },
    onSuccess: (id) => {
      toast({ title: 'Album deleted' });
      if (selectedId === id) setSelectedId(undefined);
      try { queryClient.invalidateQueries({ queryKey: ['albums'] }); } catch {}
      setDeletingId(null);
    },
    onError: (e: any) => {
      toast({ title: 'Failed to delete album', description: e?.message || String(e), variant: 'destructive' });
    },
  });

  const tree = useMemo(() => {
    const byParent = new Map<number | 'root', TreeNode[]>();
    const nodes = new Map<number, TreeNode>();
    for (const a of albums) {
      nodes.set(a.id, { ...a, children: [] });
    }
    nodes.forEach((node) => {
      const key = (node.parent_id ?? undefined) === undefined ? 'root' : (node.parent_id as number);
      if (!byParent.has(key)) byParent.set(key, []);
      byParent.get(key)!.push(node);
    });
    const sortNodes = (arr: TreeNode[]) => arr.sort((a, b) => {
      const pa = a.position ?? 0; const pb = b.position ?? 0;
      if (pa !== pb) return pa - pb;
      return a.name.localeCompare(b.name);
    });
    byParent.forEach((arr) => { sortNodes(arr); });
    const attach = (parent: TreeNode) => {
      const kids = byParent.get(parent.id) || [];
      parent.children = kids;
      kids.forEach(attach);
    };
    const roots = ((byParent.get('root') as TreeNode[] | undefined) || []).slice();
    roots.forEach(attach);
    // Pseudo root node to allow selecting root for creation target
    const rootNode: TreeNode = {
      id: ROOT_NODE_ID,
      name: 'Root',
      description: undefined,
      parent_id: undefined,
      position: 0,
      cover_photo_id: undefined,
      cover_asset_id: undefined,
      photo_count: 0,
      created_at: 0,
      updated_at: 0,
      depth: 0,
      children: roots,
    } as TreeNode;
    return [rootNode];
  }, [albums]);

  // Quick lookup for selection properties
  const albumsById = useMemo(() => {
    const m = new Map<number, Album>();
    (albums || []).forEach(a => m.set(a.id, a));
    return m;
  }, [albums]);
  const selectedIsLive = selectedId !== undefined ? (albumsById.get(selectedId || -9999)?.is_live === true) : false;

  // Initialize expansion: expand root and its first-level children
  React.useEffect(() => {
    if (!tree.length) return;
    const next = new Set<number>();
    const root = tree[0];
    const expandAll = albums.length < 50;
    if (expandAll) {
      const visit = (n: TreeNode) => { next.add(n.id); n.children?.forEach(visit); };
      visit(root);
    } else {
      next.add(root.id);
      for (const c of root.children) next.add(c.id); // expand first level
    }
    setExpanded(next);
  }, [tree, albums.length]);

  const handleConfirm = () => {
    if (selectedId === undefined) return;
    if (selectedId === ROOT_NODE_ID) {
      if (allowSelectRoot) onConfirm(selectedId);
      return;
    }
    onConfirm(selectedId);
  };

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-[70] flex items-center justify-center"
      role="dialog"
      aria-modal="true"
      aria-label="Choose an album"
      onKeyDown={(e) => {
        if (e.key === 'Escape') { e.stopPropagation(); onClose(); }
        if (e.key === 'Tab') {
          const active = document.activeElement as HTMLElement | null;
          if (e.shiftKey) {
            if (active === firstFocusable) { e.preventDefault(); lastFocusable?.focus(); }
          } else {
            if (active === lastFocusable) { e.preventDefault(); firstFocusable?.focus(); }
          }
        }
      }}
      onClick={onClose}
    >
      <div className="absolute inset-0 bg-background/95" />
      <div className="relative bg-background rounded-lg shadow-2xl border-2 border-foreground/20 w-full max-w-lg max-h-[80vh] overflow-hidden" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-4 py-3 border-b bg-background">
          <div className="flex items-center gap-2 text-sm font-medium text-foreground">
            <TreePine className="w-4 h-4" />
            Choose an album
          </div>
          <button className="w-6 h-6 rounded-full grid place-items-center bg-foreground text-background hover:opacity-90" onClick={onClose} aria-label="Close">
            <X className="w-4 h-4" />
          </button>
        </div>
        {/* Include sub‑albums toggle (optional) */}
        {showIncludeSubtree ? (
          <div className="px-4 pt-3 bg-background border-b flex items-center gap-2">
            <label className="inline-flex items-center gap-2 text-sm select-none">
              <input
                type="checkbox"
                checked={qsState.albumSubtree === '1'}
                onChange={(e) => setAlbumSubtree(e.target.checked)}
              />
              Include sub‑albums
            </label>
          </div>
        ) : null}

        {/* Prompt to create a new album (root or child) */}
        {showCreate ? (
          <div className="px-3 pt-2 bg-background border-b">
            <div className="flex items-center gap-2">
              <input
                type="text"
                autoFocus
                value={creatingName}
                onChange={e => setCreatingName(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter' && creatingName.trim()) { createMutation.mutate({ parent_id: creatingParentId, name: creatingName }); } if (e.key === 'Escape') { setShowCreate(false); setCreatingName(''); } }}
                placeholder={creatingParentId ? 'New sub‑album name' : 'New album name'}
                className={`flex-1 px-2 py-1 rounded border-2 border-input bg-background text-foreground text-sm focus:border-primary focus:outline-none`}
              />
              <button
                className={`px-2.5 py-1 rounded text-sm ${(!creatingName.trim()) ? 'bg-gray-300 text-gray-600 cursor-not-allowed' : 'bg-primary text-primary-foreground hover:bg-primary/90'}`}
                disabled={!creatingName.trim() || createMutation.isPending}
                onClick={() => createMutation.mutate({ parent_id: creatingParentId, name: creatingName })}
              >Create</button>
              <button className="px-2.5 py-1 rounded text-sm border border-border hover:bg-muted" onClick={() => { setShowCreate(false); setCreatingName(''); }}>Cancel</button>
            </div>
          </div>
        ) : null}
        <div className="p-3 overflow-auto max-h-[60vh] bg-background">
          <ul className="tree bg-background">
            {tree.map((node, idx) => (
              <TreeItem
                key={node.id}
                node={node}
                selectedId={selectedId}
                onSelect={setSelectedId}
                expanded={expanded}
                setExpanded={setExpanded}
                onAdd={(parentId) => { setCreatingParentId(parentId === ROOT_NODE_ID ? undefined : parentId); setCreatingName(''); setShowCreate(true); }}
                onDelete={(id) => { setDeletingId(id); }}
                setFirstLast={(first, last) => { if (idx === 0 && first) setFirstFocusable(first); if (last) setLastFocusable(last); }}
              />
            ))}
          </ul>
        </div>
        {/* Delete confirm */}
        {deletingId ? (
          <div className="px-4 py-2 border-t bg-background text-sm text-foreground">
            <div className="flex items-center justify-between gap-2">
              <span>Delete this album? Sub‑albums are also removed. Photos are not deleted.</span>
              <div className="flex items-center gap-2">
                <button className="px-2 py-1 rounded border border-border hover:bg-muted" onClick={() => setDeletingId(null)}>Cancel</button>
                <button className="px-2 py-1 rounded bg-red-600 text-white hover:bg-red-700" onClick={() => { if (deletingId) deleteMutation.mutate(deletingId); }}>Delete</button>
              </div>
            </div>
          </div>
        ) : null}
        <div className="flex items-center justify-end gap-2 px-4 py-3 border-t bg-background">
          <button className="px-3 py-1.5 rounded border border-border text-foreground hover:bg-muted" onClick={onClose}>Cancel</button>
          <button
            className={`px-3 py-1.5 rounded ${(selectedId === undefined || (selectedId === ROOT_NODE_ID && !allowSelectRoot)) ? 'bg-gray-300 text-gray-600 cursor-not-allowed' : 'bg-primary text-primary-foreground hover:bg-primary/90'}`}
            onClick={handleConfirm}
            disabled={selectedId === undefined || (selectedId === ROOT_NODE_ID && !allowSelectRoot)}
          >
            <Check className="w-4 h-4 inline mr-1" /> OK
          </button>
        </div>
      </div>
    </div>
  );
}

function TreeItem({ node, depth = 0, selectedId, onSelect, expanded, setExpanded, onAdd, onDelete, setFirstLast }: { node: TreeNode; depth?: number; selectedId?: number; onSelect: (id: number) => void; expanded: Set<number>; setExpanded: (s: Set<number>) => void; onAdd: (parentId: number) => void; onDelete: (id: number) => void; setFirstLast?: (first?: HTMLButtonElement | null, last?: HTMLButtonElement | null) => void }) {
  const ref = React.useRef<HTMLButtonElement | null>(null);
  React.useEffect(() => {
    if (depth === 0 && setFirstLast) {
      setFirstLast(ref.current, undefined);
    }
  }, [setFirstLast, depth]);
  const hasChildren = !!(node.children && node.children.length);
  const isExpanded = expanded.has(node.id);
  const isRoot = node.id === ROOT_NODE_ID;
  const toggle = (e: React.MouseEvent) => {
    e.stopPropagation();
    const next = new Set(expanded);
    if (isExpanded) next.delete(node.id); else next.add(node.id);
    setExpanded(next);
  };

  return (
    <li>
      <div className="tree-row flex items-center">
        <button
          className="tree-toggle mr-1 text-gray-500 hover:text-gray-700 w-4 h-4 flex items-center justify-center"
          onClick={toggle}
          aria-label={isExpanded ? 'Collapse' : 'Expand'}
          aria-expanded={isExpanded}
          style={{ visibility: hasChildren ? 'visible' : 'hidden' }}
        >
          {isExpanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
        </button>
        <button
          className={`flex-1 text-left px-2 py-1 rounded flex items-center justify-between ${
            selectedId === node.id ? 'bg-primary/10 text-primary' : 'hover:bg-muted'
          }`}
          ref={ref}
          onClick={() => { onSelect(node.id); }}
        >
          <span className="truncate flex items-center gap-2">
            {isRoot ? (
              <span title="Root">
                <Home className="w-4 h-4 text-amber-500" aria-label="Root (top level)" />
              </span>
            ) : (
              <>
                {node.is_live ? (
                  <Sparkles className="w-4 h-4 text-purple-500" />
                ) : (
                  <Folder className="w-4 h-4 text-amber-500" />
                )}
                <span className="inline-flex items-center gap-1">{node.name}</span>
              </>
            )}
          </span>
          {/* Trailing actions when row is selected */}
          {(selectedId === node.id || isRoot) ? (
            <span className="flex items-center gap-2 ml-2">
              {/* Add: disabled for live albums; enabled for root */}
              <button
                className={`w-6 h-6 grid place-items-center rounded hover:bg-muted ${(!isRoot && node.is_live) ? 'opacity-40 cursor-not-allowed' : ''}`}
                onClick={(e) => { e.stopPropagation(); if (!node.is_live || isRoot) onAdd(node.id); }}
                title={isRoot ? 'Create top-level album' : (node.is_live ? 'Cannot create under live album' : 'Create sub‑album')}
                aria-label="Add sub-album"
                disabled={!isRoot && node.is_live}
              >
                <PlusCircle className="w-5 h-5 text-primary" />
              </button>
              {/* Delete: not for root */}
              {!isRoot && selectedId === node.id ? (
                <button
                  className="w-6 h-6 grid place-items-center rounded hover:bg-muted"
                  onClick={(e) => { e.stopPropagation(); onDelete(node.id); }}
                  title="Delete album"
                  aria-label="Delete album"
                >
                  <XCircle className="w-5 h-5 text-red-600" />
                </button>
              ) : null}
            </span>
          ) : null}
        </button>
      </div>
      {hasChildren && isExpanded ? (
        <ul>
          {node.children.map((c, idx, arr) => (
            <TreeItem
              key={c.id}
              node={c}
              depth={depth + 1}
              selectedId={selectedId}
              onSelect={onSelect}
              expanded={expanded}
              setExpanded={setExpanded}
              onAdd={onAdd}
              onDelete={onDelete}
              setFirstLast={(first, last) => {
                if (setFirstLast) {
                  // Bubble last focusable reference for trap
                  if (idx === arr.length - 1) setFirstLast(undefined, last ?? first ?? ref.current);
                }
              }}
            />
          ))}
        </ul>
      ) : null}
    </li>
  );
}

export default AlbumPickerDialog;
