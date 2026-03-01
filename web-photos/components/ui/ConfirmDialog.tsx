'use client';

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { X, AlertTriangle } from 'lucide-react';

export function ConfirmDialog({
  open,
  title,
  description,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  variant = 'default',
  onConfirm,
  onClose,
}: {
  open: boolean;
  title: string;
  description?: string;
  confirmLabel?: string;
  cancelLabel?: string;
  variant?: 'default' | 'destructive';
  onConfirm: () => void;
  onClose: () => void;
}) {
  const dialogRef = useRef<HTMLDivElement | null>(null);
  const [firstFocusable, setFirstFocusable] = useState<HTMLElement | null>(null);
  const [lastFocusable, setLastFocusable] = useState<HTMLElement | null>(null);

  useEffect(() => {
    if (!open) return;
    const root = dialogRef.current;
    if (!root) return;
    const focusables = Array.from(
      root.querySelectorAll<HTMLElement>(
        'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
      )
    ).filter(el => !el.hasAttribute('disabled'));
    setFirstFocusable(focusables[0] || null);
    setLastFocusable(focusables[focusables.length - 1] || null);
    // Prefer Cancel (first button in footer) as initial focus for safety
    const cancelBtn = root.querySelector<HTMLElement>('button[data-cancel]');
    (cancelBtn || focusables[0])?.focus();
  }, [open]);

  if (!open) return null;
  const confirmClass = variant === 'destructive'
    ? 'bg-red-600 text-white hover:bg-red-700'
    : 'bg-primary text-primary-foreground hover:bg-primary/90';

  return (
    <div
      className="fixed inset-0 z-[70] flex items-center justify-center"
      role="dialog"
      aria-modal="true"
      aria-label={title}
      onClick={onClose}
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
    >
      <div className="absolute inset-0 bg-background/95" />
      <div
        className="relative bg-background rounded-lg shadow-2xl border-2 border-foreground/20 w-full max-w-md overflow-hidden"
        onClick={(e) => e.stopPropagation()}
        ref={dialogRef}
      >
        <div className="flex items-center justify-between px-4 py-3 border-b bg-background">
          <div className="flex items-center gap-2 text-sm font-medium text-foreground">
            <AlertTriangle className="w-4 h-4 text-red-600" />
            {title}
          </div>
          <button className="w-6 h-6 rounded-full grid place-items-center bg-foreground text-background hover:opacity-90" onClick={onClose} aria-label="Close">
            <X className="w-4 h-4" />
          </button>
        </div>
        {description && (
          <div className="px-4 py-3 text-sm text-muted-foreground">{description}</div>
        )}
        <div className="flex items-center justify-end gap-2 px-4 py-3 border-t bg-background">
          <button data-cancel className="px-3 py-1.5 rounded border border-border text-foreground hover:bg-muted" onClick={onClose}>{cancelLabel}</button>
          <button className={`px-3 py-1.5 rounded ${confirmClass}`} onClick={onConfirm}>{confirmLabel}</button>
        </div>
      </div>
    </div>
  );
}

export default ConfirmDialog;
