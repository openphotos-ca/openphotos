"use client";

import React, { createContext, useCallback, useContext, useMemo, useState } from 'react';

export interface ToastItem {
  id: string;
  title: string;
  description?: string;
  variant?: 'default' | 'destructive' | 'success';
  duration?: number; // ms
}

interface ToastContextValue {
  toast: (t: Omit<ToastItem, 'id'>) => void;
  remove: (id: string) => void;
  items: ToastItem[];
}

const ToastContext = createContext<ToastContextValue | null>(null);

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);

  const remove = useCallback((id: string) => {
    setItems(prev => prev.filter(t => t.id !== id));
  }, []);

  const toast = useCallback((t: Omit<ToastItem, 'id'>) => {
    console.log('[Toast Hook] toast() called with:', t);
    // Singleton behavior: always show a single toast, updating its contents
    const id = 'singleton-toast';
    const duration = t.duration ?? 2200;
    const item: ToastItem = { id, ...t };
    console.log('[Toast Hook] Setting toast item:', item);
    setItems([item]);
    if (duration > 0) {
      setTimeout(() => remove(id), duration);
    }
  }, [remove]);

  const value = useMemo(() => ({ toast, remove, items }), [toast, remove, items]);
  return (
    <ToastContext.Provider value={value}>{children}</ToastContext.Provider>
  );
}

export function useToast() {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToast must be used within <ToastProvider>');
  return { toast: ctx.toast };
}

export function useToastsState() {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToastsState must be used within <ToastProvider>');
  return ctx;
}
