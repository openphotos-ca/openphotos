'use client';

import React, { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { Input } from '@/components/ui/input';

export default function FreezeAlbumModal({ open, onCancel, onConfirm }: { open: boolean; onCancel: () => void; onConfirm: (name: string) => void | Promise<void>; }) {
  const [name, setName] = useState('');
  const [mounted, setMounted] = useState(false);
  useEffect(() => { setMounted(true); }, []);
  useEffect(() => { if (open) setName(''); }, [open]);

  if (!open || !mounted) return null;

  const content = (
    <div className="fixed inset-0 z-[1000]">
      <div className="absolute inset-0 bg-black/50" onClick={onCancel} />
      <div className="absolute inset-0 flex items-center justify-center p-4">
        <div className="w-full max-w-md rounded-lg border border-border bg-background text-foreground shadow-xl">
          <div className="px-4 py-3 border-b border-border">
            <h3 className="text-base font-semibold">Freeze to Static Album</h3>
            <p className="text-sm text-muted-foreground mt-1">Create an immutable album from current results. Name is optional.</p>
          </div>
          <div className="p-4 space-y-3">
            <label className="block text-sm font-medium">Static album name</label>
            <Input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Type a name"
            />
          </div>
          <div className="px-4 py-3 border-t border-border flex justify-end gap-2">
            <button onClick={onCancel} className="px-3 py-1.5 rounded-md border border-border bg-card hover:bg-muted">Cancel</button>
            <button
              onClick={() => onConfirm(name.trim())}
              className="px-3 py-1.5 rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
              disabled={!name.trim()}
            >
              Create
            </button>
          </div>
        </div>
      </div>
    </div>
  );

  return createPortal(content, document.body);
}
