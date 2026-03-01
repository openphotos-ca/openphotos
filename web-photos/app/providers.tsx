'use client';

import React, { useEffect, useState } from 'react';
import { usePathname } from 'next/navigation';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ToastProvider } from '@/hooks/use-toast';
import { Toaster } from '@/components/ui/Toaster';
import { ReindexProvider } from '@/components/providers/ReindexProvider';
import { AuthRefreshProvider } from '@/components/providers/AuthRefreshProvider';
import { useE2EEStore } from '@/lib/stores/e2ee';
import { logger } from '@/lib/logger';
import { useAuthStore } from '@/lib/stores/auth';
import { tryRestoreUMK } from '@/lib/remember';

export function Providers({ children }: { children: React.ReactNode }) {
  const pathname = (() => {
    try { return typeof window === 'undefined' ? '' : undefined; } catch { return ''; }
  })();
  const currentPath = (() => {
    try {
      // usePathname only works client-side; guard for build/SSR
      // eslint-disable-next-line react-hooks/rules-of-hooks
      const p = usePathname?.();
      return typeof p === 'string' ? p : '';
    } catch { return ''; }
  })();
  // Treat public links (/public) as non-library views. Skip UMK remember/restore on these routes.
  const isPublicViewer = (() => {
    const p = (currentPath || '');
    return p.startsWith('/public');
  })();
  // More specific flag: authenticated share viewer (owners/recipients under /shared)
  const isSharedViewer = (() => {
    const p = (currentPath || '');
    return p.startsWith('/shared');
  })();

  const [queryClient] = useState(() => new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 1000 * 60 * 5, // 5 minutes
        gcTime: 1000 * 60 * 30, // 30 minutes
        retry: (failureCount, error: any) => {
          // Don't retry on 401/403 errors
          if (error?.status === 401 || error?.status === 403) {
            return false;
          }
          return failureCount < 3;
        },
      },
    },
  }));

  // Suppress noisy console logs in production (client-side only)
  useEffect(() => {
    if (process.env.NODE_ENV === 'production') {
      try {
        const noop = () => {};
        // Keep warnings and errors; silence log/debug
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (console as any).log = noop;
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (console as any).debug = noop;
      } catch {}
    }
  }, []);

  // Initialize E2EE worker calibration (sets canEncrypt and params)
  useEffect(() => {
    let terminated = false;
    (async () => {
      try {
        const st = useE2EEStore.getState();
        // Avoid re-init if already calibrated
        if (st.canEncrypt && st.params) return;
        // Lazy-load worker via new Worker URL
        // @ts-ignore - bundler will resolve worker
        const worker = new Worker(new URL('../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
        worker.onmessage = (ev: MessageEvent) => {
          const data = ev.data || {};
          if (data?.ok && data.kind === 'calibrated') {
            useE2EEStore.getState().setParams(data.params);
            useE2EEStore.setState({ canEncrypt: true });
          }
        };
        worker.postMessage({ type: 'calibrate-argon2', targetMs: 300 });
        // Keep a reference if you want to reuse worker — for now we terminate after calibration
        setTimeout(() => { try { worker.terminate(); } catch {} }, 1000);
      } catch {}
    })();
    return () => { terminated = true; };
  }, []);

  // Try to restore remembered unlock (if user configured it and not expired)
  useEffect(() => {
    if (isPublicViewer) return; // skip on public viewer
    (async () => {
      try {
        if (useE2EEStore.getState().umk) return;
        const umk = await tryRestoreUMK();
        if (umk && umk.length === 32) {
          logger.debug('[E2EE] Restored UMK from remember store');
          useE2EEStore.getState().setUMK(umk);
        } else {
          logger.debug('[E2EE] No remembered UMK available');
        }
      } catch {}
    })();
  }, [isPublicViewer]);

  // Load security settings to hydrate remember-minutes locally so unlock flow can persist UMK
  const token = useAuthStore(s => s.token);
  useEffect(() => {
    if (isPublicViewer) return; // skip on public viewer
    if (!token) return;
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch('/api/settings/security', { headers: { 'Authorization': `Bearer ${token}` } });
        if (!res.ok) return;
        const j = await res.json().catch(()=>null);
        if (!j) return;
        if (cancelled) return;
        try {
          if (typeof localStorage !== 'undefined') {
            const rm = (typeof j.remember_minutes === 'number') ? j.remember_minutes : 60;
            localStorage.setItem('pin.remember.min', String(rm));
            // Also mirror locked metadata preferences used by client-only code
            if (j.include_location !== undefined) localStorage.setItem('lockedMeta.include_location', j.include_location ? '1' : '0');
            if (j.include_caption !== undefined) localStorage.setItem('lockedMeta.include_caption', j.include_caption ? '1' : '0');
            if (j.include_description !== undefined) localStorage.setItem('lockedMeta.include_description', j.include_description ? '1' : '0');
          }
        } catch {}
      } catch {}
    })();
    return () => { cancelled = true; };
  }, [token, isPublicViewer]);

  // Ensure the E2EE envelope is available on the authenticated share viewer so owners can unlock.
  // We still skip remember/restore on /shared, but the Unlock dialog needs the envelope.
  useEffect(() => {
    if (!isSharedViewer) return;
    if (!token) return; // only attempt when authenticated
    (async () => {
      try {
        const st = useE2EEStore.getState();
        if (!st.envelope) {
          await st.loadEnvelope();
        }
      } catch {}
    })();
  }, [isSharedViewer, token]);

  // If already unlocked and remember-minutes is set, ensure UMK is stored once
  const isUnlocked = useE2EEStore(s => s.isUnlocked);
  useEffect(() => {
    if (isPublicViewer) return; // skip on public viewer
    if (!isUnlocked) return;
    (async () => {
      try {
        const mins = parseInt((localStorage.getItem('pin.remember.min')||'60') as string, 10);
        const hasBlob = !!localStorage.getItem('pin.remember.blob');
        if (mins > 0 && !hasBlob) {
          const umk = useE2EEStore.getState().umk;
          if (umk && umk.length === 32) {
            const { rememberUMK } = await import('@/lib/remember');
            await rememberUMK(umk, mins);
          }
        }
      } catch {}
    })();
  }, [isUnlocked, isPublicViewer]);

  // Process pending share-prep queue when UMK becomes available
  useEffect(() => {
    if (isPublicViewer) return;
    if (!isUnlocked) return;
    (async () => {
      try {
        // Read and clear queue eagerly to avoid double-runs across tabs
        const raw = typeof localStorage !== 'undefined' ? localStorage.getItem('ee.pendingSharePrep') : null;
        const list: Array<{ id: string; object_kind: string; object_id: string }>|null = raw ? JSON.parse(raw) : null;
        if (!list || list.length === 0) return;
        localStorage.removeItem('ee.pendingSharePrep');
        // Lazy import EE helper if available; stub does nothing in OSS builds
        const mod: any = await import('@ee/autoPrep');
        const run = mod?.startOwnerAutoPrepare as ((s:{id:string;object_kind:string;object_id:string})=>Promise<void>) | undefined;
        if (!run) return;
        for (const s of list) {
          try { await run(s); } catch {}
        }
      } catch {}
    })();
  }, [isUnlocked, isPublicViewer]);

  // Process pending public-link wrap prep when UMK becomes available
  useEffect(() => {
    if (isPublicViewer) return;
    if (!isUnlocked) return;
    (async () => {
      try {
        const raw = typeof localStorage !== 'undefined' ? localStorage.getItem('ee.pendingPublicWraps') : null;
        const list: Array<{ id: string; album_id?: number; smk_hex: string; asset_ids?: string[] }>|null = raw ? JSON.parse(raw) : null;
        if (!list || list.length === 0) return;
        localStorage.removeItem('ee.pendingPublicWraps');
        const mod: any = await import('@ee/autoPrep');
        const run = mod?.startPublicAutoPrepare as ((s:{ linkId:string; albumId?: number; smkHex:string; assetIds?: string[] })=>Promise<void>) | undefined;
        if (!run) return;
        for (const s of list) {
          try {
            await run({
              linkId: s.id,
              albumId: s.album_id,
              smkHex: s.smk_hex,
              assetIds: Array.isArray(s.asset_ids) ? s.asset_ids : undefined,
            });
          } catch {}
        }
      } catch {}
    })();
  }, [isUnlocked, isPublicViewer]);

  // EE: Owner-side catch-up for album shares — ensure wraps exist for any newly matched locked items
  useEffect(() => {
    if (isPublicViewer) return;
    if (!isUnlocked) return;
    if (!token) return;
    let stopped = false;
    const run = async () => {
      try {
        if (typeof document !== 'undefined' && document.visibilityState !== 'visible') return;
        // Lazy import EE helper; in OSS builds the alias resolves to a stub
        const mod: any = await import('@ee/autoPrep');
        const catchUp = mod?.startOwnerAutoCatchUp as ((s:{id:string;object_kind:string;object_id:string})=>Promise<void>) | undefined;
        if (!catchUp) return;
        const res = await fetch('/api/ee/shares/outgoing', { headers: { Authorization: `Bearer ${token}` } });
        const list = await res.json().catch(()=>null);
        if (!res.ok || !Array.isArray(list)) return;
        const now = Date.now();
        for (const s of list) {
          if (!s || s.object_kind !== 'album') continue;
          const key = `ee.prep.last:${s.id}`;
          let last = 0;
          try { last = parseInt((localStorage.getItem(key) || '0') as string, 10) || 0; } catch {}
          // Throttle per share to avoid hammering (45s window)
          if (now - last < 45 * 1000) continue;
          await catchUp({ id: s.id, object_kind: s.object_kind, object_id: s.object_id });
          try { localStorage.setItem(key, String(now)); } catch {}
          if (stopped) break;
        }
      } catch {}
    };
    run();
    // Run periodically but with a wider cadence to reduce network traffic
    const id = setInterval(run, 45 * 1000);
    return () => { stopped = true; clearInterval(id); };
  }, [isUnlocked, isPublicViewer, token]);

  return (
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        {isPublicViewer ? (
          <>{children}</>
        ) : (
          <AuthRefreshProvider>
            <ReindexProvider>
              {children}
            </ReindexProvider>
          </AuthRefreshProvider>
        )}
        <Toaster />
      </ToastProvider>
    </QueryClientProvider>
  );
}
