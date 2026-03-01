'use client';

import React, { useEffect, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';

export default function EditFaceDialog({
  open,
  personId,
  initialName,
  initialBirth,
  onClose,
  onSaved,
}: {
  open: boolean;
  personId: string | null;
  initialName?: string;
  initialBirth?: string;
  onClose: () => void;
  onSaved?: () => Promise<void> | void;
}) {
  const qc = useQueryClient();
  const [name, setName] = useState<string>('');
  const [birth, setBirth] = useState<string>('');

  useEffect(() => {
    if (open && personId) {
      setName(initialName || '');
      setBirth((initialBirth || '').slice(0, 10));
    }
  }, [open, personId, initialName, initialBirth]);

  if (!open || !personId) return null;

  const onSave = async () => {
    await photosApi.updatePerson(personId, {
      display_name: name || undefined,
      birth_date: birth || undefined,
    });
    try { await qc.invalidateQueries({ queryKey: ['faces'] }); } catch {}
    try { await qc.invalidateQueries({ queryKey: ['faces', 'manage'] }); } catch {}
    if (onSaved) await onSaved();
    onClose();
  };

  return (
    <div className="fixed inset-0 z-50">
      <div className="absolute inset-0 bg-background/80 backdrop-blur-sm" onClick={onClose} />
      <div className="absolute inset-0 flex items-center justify-center p-4">
        <div className="bg-background border border-border rounded-md shadow-xl w-full max-w-sm">
          <div className="p-4 border-b border-border font-semibold text-foreground">Edit Face</div>
          <div className="p-4 space-y-3">
            <div>
              <label className="block text-xs text-muted-foreground mb-1">Name</label>
              <input
                value={name}
                onChange={(e) => setName(e.target.value)}
                className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent"
              />
            </div>
            <div>
              <label className="block text-xs text-muted-foreground mb-1">Birth date</label>
              <input
                type="date"
                value={birth}
                onChange={(e) => setBirth(e.target.value)}
                className="w-full border border-border bg-background text-foreground rounded px-2 py-1 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent"
              />
            </div>
          </div>
          <div className="p-4 border-t border-border flex justify-end gap-2">
            <button className="px-3 py-1.5 text-foreground hover:bg-muted rounded transition-colors" onClick={onClose}>
              Cancel
            </button>
            <button className="px-3 py-1.5 bg-primary text-primary-foreground rounded hover:bg-primary/90 transition-colors" onClick={onSave}>
              Save
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

