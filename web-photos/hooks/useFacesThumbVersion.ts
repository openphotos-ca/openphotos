"use client";

import { useEffect, useState } from 'react';

export function useFacesThumbVersion() {
  const [v, setV] = useState<number>(() => {
    if (typeof window === 'undefined') return Date.now();
    try {
      const s = window.localStorage.getItem('facesThumbVersion');
      return s ? Number(s) || Date.now() : Date.now();
    } catch { return Date.now(); }
  });

  useEffect(() => {
    const onRefresh = (e: Event) => {
      const now = Date.now();
      setV(now);
      try { window.localStorage.setItem('facesThumbVersion', String(now)); } catch {}
    };
    window.addEventListener('faces-thumb-refresh', onRefresh as any);
    return () => window.removeEventListener('faces-thumb-refresh', onRefresh as any);
  }, []);

  return v;
}

