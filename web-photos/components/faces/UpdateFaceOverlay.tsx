"use client";

import React, { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import type { AssetFace, Face } from '@/lib/types/photo';
import { ArrowLeft, Pencil, Plus } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import ConfirmDialog from '@/components/ui/ConfirmDialog';
import { useFacesThumbVersion } from '@/hooks/useFacesThumbVersion';

export function UpdateFaceOverlay({ assetId, onClose, onAssigned }: { assetId: string; onClose: () => void; onAssigned?: () => void }) {
  const qc = useQueryClient();
  const { toast } = useToast();
  const facesThumbV = useFacesThumbVersion();

  const { data: faces, isLoading: facesLoading } = useQuery({
    queryKey: ['asset-faces', assetId],
    queryFn: () => photosApi.getPhotoFaces(assetId),
    staleTime: 10_000,
  });

  const { data: persons, isLoading: personsLoading } = useQuery({
    queryKey: ['faces'],
    queryFn: () => photosApi.getFaces(),
    staleTime: 30_000,
  });

  const [selectedFaceId, setSelectedFaceId] = useState<string | null>(null);
  const [peopleMode, setPeopleMode] = useState<'assign' | 'add' | null>(null);
  const [confirmOpen, setConfirmOpen] = useState<boolean>(false);
  const [confirmTarget, setConfirmTarget] = useState<{ mode: 'assign' | 'add'; personId: string; label: string } | null>(null);

  const faceItems = useMemo(() => (faces || []).map((f: AssetFace) => ({
    faceId: f.face_id,
    thumb: f.thumbnail || '',
    personId: f.person_id || undefined,
  })), [faces]);

  const personItems = useMemo(() => (persons || []).map((p: Face) => ({
    personId: (p as any).person_id as string,
    label: (p as any).name || (p as any).display_name || (p as any).person_id,
    thumb: `${photosApi.getFaceThumbnailUrl((p as any).person_id)}&t=${facesThumbV}`,
    count: (p as any).photo_count as number,
  })), [persons, facesThumbV]);

  const assignTo = async (personId: string) => {
    let fid: string | null = selectedFaceId;
    if (!fid) {
      // If there is exactly one face, auto-select it for convenience
      if ((faces?.length || 0) === 1 && faces?.[0]) {
        fid = faces[0].face_id;
        setSelectedFaceId(fid);
      } else {
        toast({ title: 'Pick a face first', variant: 'default' });
        return;
      }
    }
    try {
      await photosApi.assignFace(fid!, personId);
      toast({ title: 'Face updated', variant: 'success' });
      // Notify listeners to refresh face thumbnails used in filters/chips
      try {
        if (typeof window !== 'undefined') {
          window.dispatchEvent(new CustomEvent('faces-thumb-refresh'));
        }
      } catch {}
      await qc.invalidateQueries({ queryKey: ['asset-faces', assetId] });
      await qc.invalidateQueries({ queryKey: ['faces'] });
      if (onAssigned) {
        try { onAssigned(); } catch {}
      }
      setPeopleMode(null);
      setSelectedFaceId(null);
    } catch (e: any) {
      toast({ title: 'Update failed', description: e?.message || String(e), variant: 'destructive' });
    }
  };

  const addPersonToPhoto = async (personId: string) => {
    try {
      await photosApi.addPersonToPhoto(assetId, personId);
      toast({ title: 'Added person', variant: 'success' });
      try {
        if (typeof window !== 'undefined') {
          window.dispatchEvent(new CustomEvent('faces-thumb-refresh'));
        }
      } catch {}
      await qc.invalidateQueries({ queryKey: ['photos'] });
      await qc.invalidateQueries({ queryKey: ['faces'] });
      await qc.invalidateQueries({ queryKey: ['asset-faces', assetId] });
      if (onAssigned) {
        try { onAssigned(); } catch {}
      }
      setPeopleMode(null);
    } catch (e: any) {
      toast({ title: 'Add failed', description: e?.message || String(e), variant: 'destructive' });
    }
  };

  return (
    <div className="fixed inset-0 z-[80] bg-background">
      {/* Top row: back and title */}
      <div className="absolute top-3 left-3 z-20">
        <button
          className="px-3 py-1.5 bg-card text-foreground border border-border rounded hover:bg-muted"
          onClick={onClose}
          aria-label="Back"
        >
          <ArrowLeft className="w-4 h-4 inline mr-1" /> Back
        </button>
      </div>
      <div className="absolute top-2 left-0 right-0 z-10 pointer-events-none">
        <h2 className="text-center text-xl md:text-2xl font-semibold tracking-wide text-foreground">
          Update Face
        </h2>
      </div>

      {/* Content */}
      <div className="absolute inset-0 pt-16 overflow-y-auto">
        <div className="max-w-5xl mx-auto px-4 space-y-6">
          {/* Row 1: Faces in this photo */}
          <div>
            <div className="flex items-center justify-between mb-2">
              <div className="text-sm text-muted-foreground">Faces in this photo</div>
              <button
                type="button"
                className="inline-flex items-center justify-center w-7 h-7 rounded border border-border bg-card text-foreground hover:bg-muted"
                aria-label="Add person to this photo"
                title="Add person"
                onClick={() => {
                  setSelectedFaceId(null);
                  setPeopleMode(prev => (prev === 'add' ? null : 'add'));
                }}
              >
                <Plus className="w-4 h-4" />
              </button>
            </div>
            {facesLoading ? (
              <div className="text-sm text-muted-foreground">Loading faces…</div>
            ) : faceItems.length === 0 ? (
              <div className="text-sm text-muted-foreground">No faces detected for this photo</div>
            ) : (
              <div className="flex gap-3 overflow-x-auto pb-1">
                {faceItems.map(({ faceId, thumb, personId }) => {
                  const selected = selectedFaceId === faceId;
                  const displayThumb = personId ? `${photosApi.getFaceThumbnailUrl(personId)}&t=${facesThumbV}` : thumb;
                  return (
                    <div
                      key={faceId}
                      className={`shrink-0 rounded-md overflow-hidden border ${selected ? 'border-primary ring-2 ring-primary/40' : 'border-border'} bg-card relative`}
                      title={`face ${faceId} ${personId ? `→ ${personId}` : ''}`}
                      style={{ width: 96 }}
                    >
                      <div className="w-full" style={{ aspectRatio: '1 / 1' }}>
                        {displayThumb ? (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img src={displayThumb} alt="face" className="w-full h-full object-cover bg-muted" />
                        ) : (
                          <div className="w-full h-full bg-muted" />
                        )}
                      </div>
                      <button
                        type="button"
                        className="absolute top-1 right-1 rounded bg-background/70 hover:bg-background/90 border border-border p-1 text-foreground"
                        aria-label="Edit this face"
                        onClick={(e) => {
                          e.preventDefault();
                          e.stopPropagation();
                          setSelectedFaceId(faceId);
                          setPeopleMode('assign');
                        }}
                      >
                        <Pencil className="w-3.5 h-3.5" />
                      </button>
                      {/* confidence percentage removed per UX request */}
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          {/* Row 2: People grid */}
          {peopleMode && (
            <div>
              <div className="text-sm text-muted-foreground mb-2">
                {peopleMode === 'assign' ? 'Replace with' : 'Add person to this photo'}
              </div>
              {personsLoading ? (
                <div className="text-sm text-muted-foreground">Loading people…</div>
              ) : (
                <div className="grid gap-3" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(96px, 1fr))' }}>
                  {personItems.map(({ personId, label, thumb, count }) => (
                    <button
                      key={personId}
                      className={`text-left rounded-md overflow-hidden border border-border bg-card hover:ring-2 hover:ring-primary/20`}
                      onClick={() => {
                        if (peopleMode === 'assign') {
                          if (!selectedFaceId) {
                            toast({ title: 'Pick a face to edit first', variant: 'default' });
                            return;
                          }
                          setConfirmTarget({ mode: 'assign', personId, label });
                        } else {
                          setConfirmTarget({ mode: 'add', personId, label });
                        }
                        setConfirmOpen(true);
                      }}
                      title={label}
                    >
                      <div className="w-full" style={{ aspectRatio: '1 / 1' }}>
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img src={thumb} alt={label} className="w-full h-full object-cover bg-muted" />
                      </div>
                      <div className="p-2 text-[11px] flex items-center justify-between">
                        <span className="truncate" title={label}>{label}</span>
                        {typeof count === 'number' && <span className="text-[10px] text-muted-foreground">({count})</span>}
                      </div>
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
      {/* Confirm assignment dialog */}
      <ConfirmDialog
        open={confirmOpen}
        title={confirmTarget?.mode === 'add' ? 'Add person to photo?' : 'Assign face?'}
        description={
          confirmTarget?.mode === 'add'
            ? (confirmTarget ? `Add “${confirmTarget.label}” to this photo?` : 'Add this person to the photo?')
            : (confirmTarget ? `Assign the selected face to “${confirmTarget.label}”?` : 'Assign the selected face?')
        }
        confirmLabel={confirmTarget?.mode === 'add' ? 'Add' : 'Assign'}
        cancelLabel="Cancel"
        onClose={() => setConfirmOpen(false)}
        onConfirm={async () => {
          if (!confirmTarget) return;
          const pid = confirmTarget.personId;
          const mode = confirmTarget.mode;
          setConfirmOpen(false);
          if (mode === 'add') {
            await addPersonToPhoto(pid);
          } else {
            await assignTo(pid);
          }
        }}
      />
    </div>
  );
}

export default UpdateFaceOverlay;
