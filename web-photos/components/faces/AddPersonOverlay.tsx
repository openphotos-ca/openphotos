"use client";

import React, { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import type { Face } from '@/lib/types/photo';
import { ArrowLeft } from 'lucide-react';
import ConfirmDialog from '@/components/ui/ConfirmDialog';
import { useToast } from '@/hooks/use-toast';

export default function AddPersonOverlay({ assetId, onClose, onAssigned }: { assetId: string; onClose: () => void; onAssigned?: () => void }) {
  const qc = useQueryClient();
  const { toast } = useToast();
  const { data: faces, isLoading } = useQuery({ queryKey: ['faces'], queryFn: () => photosApi.getFaces(), staleTime: 60_000 });
  const items = useMemo(() => (faces || []).map((f) => ({
    personId: (f as Face).person_id,
    label: (f as any).name || (f as any).display_name || (f as Face).person_id,
    thumb: photosApi.getFaceThumbnailUrl((f as Face).person_id),
    count: (f as any).photo_count as number | undefined,
  })), [faces]);

  const [pending, setPending] = useState<{ personId: string; label: string } | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);

  const assign = async (pid: string) => {
    try {
      await photosApi.addPersonToPhoto(assetId, pid);
      // Notify filter chips/drawer to refresh thumbnails
      try { if (typeof window !== 'undefined') window.dispatchEvent(new CustomEvent('faces-thumb-refresh')); } catch {}
      await qc.invalidateQueries({ queryKey: ['photos'] });
      await qc.invalidateQueries({ queryKey: ['faces'] });
      await qc.invalidateQueries({ queryKey: ['asset-faces', assetId] });
      if (onAssigned) { try { onAssigned(); } catch {} }
      toast({ title: 'Added person', description: pid, variant: 'success' });
      onClose();
    } catch (e: any) {
      toast({ title: 'Add failed', description: e?.message || String(e), variant: 'destructive' });
    }
  };

  return (
    <div className="fixed inset-0 z-[80] bg-background">
      <div className="absolute top-3 left-3 z-20">
        <button className="px-3 py-1.5 bg-card text-foreground border border-border rounded hover:bg-muted" onClick={onClose} aria-label="Back">
          <ArrowLeft className="w-4 h-4 inline mr-1" /> Back
        </button>
      </div>
      <div className="absolute top-2 left-0 right-0 z-10 pointer-events-none">
        <h2 className="text-center text-xl md:text-2xl font-semibold tracking-wide text-foreground">Add Person</h2>
      </div>
      <div className="absolute inset-0 pt-16 overflow-y-auto">
        <div className="max-w-5xl mx-auto px-4">
          {isLoading ? (
            <div className="text-sm text-muted-foreground">Loading people…</div>
          ) : (
            <div className="grid gap-3" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(96px, 1fr))' }}>
              {items.map(({ personId, label, thumb, count }) => (
                <button key={personId} className="text-left rounded-md overflow-hidden border border-border bg-card hover:ring-2 hover:ring-primary/20"
                  onClick={() => { setPending({ personId, label }); setConfirmOpen(true); }} title={label}>
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
      </div>

      <ConfirmDialog
        open={confirmOpen}
        title="Add person to this photo?"
        description={pending ? `Add “${pending.label}” to this photo?` : 'Add selected person to this photo?'}
        confirmLabel="Add"
        cancelLabel="Cancel"
        onClose={() => setConfirmOpen(false)}
        onConfirm={async () => { setConfirmOpen(false); if (pending) await assign(pending.personId); }}
      />
    </div>
  );
}

