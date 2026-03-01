'use client';

import React from 'react';
import { X } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import { useAuthStore } from '@/lib/stores/auth';

type Progress = { processed: number; total: number; stage?: string };

export function ReindexProvider({ children }: { children: React.ReactNode }) {
  const queryClient = useQueryClient();
  const { token } = useAuthStore();
  const [jobId, setJobId] = React.useState<string | null>(null);
  const [progress, setProgress] = React.useState<Progress | null>(null);
  const [progressMin, setProgressMin] = React.useState(false);
  const [cancelRequested, setCancelRequested] = React.useState(false);
  const esRef = React.useRef<EventSource | null>(null);
  const refreshTimerRef = React.useRef<number | null>(null);
  const lastProcessedRef = React.useRef<number>(0);
  const jobIdRef = React.useRef<string | null>(null);
  const lastRefreshTsRef = React.useRef<number>(0);
  const [confirmOpen, setConfirmOpen] = React.useState(false);
  const [uploadToast, setUploadToast] = React.useState<string | null>(null);
  const uploadToastTimerRef = React.useRef<number | null>(null);
  const uploadsRefreshTimerRef = React.useRef<number | null>(null);
  const uploadsEsRef = React.useRef<EventSource | null>(null);

  const stop = React.useCallback(() => {
    if (esRef.current) { try { esRef.current.close(); } catch {} esRef.current = null; }
    if (refreshTimerRef.current) { window.clearInterval(refreshTimerRef.current); refreshTimerRef.current = null; }
    setJobId(null);
    jobIdRef.current = null;
    setTimeout(() => setProgress(null), 1500);
  }, []);

  const tickRefresh = React.useCallback(() => {
    // Invalidate active queries; React Query will refetch actives automatically.
    try {
      queryClient.invalidateQueries({ queryKey: ['photos'], exact: false });
      queryClient.invalidateQueries({ queryKey: ['media-counts'], exact: false });
      // Also refresh albums so newly created folder-mapped albums appear promptly
      queryClient.invalidateQueries({ queryKey: ['albums'], exact: false });
      lastRefreshTsRef.current = Date.now();
    } catch {}
  }, [queryClient]);

  const scheduleUploadsRefresh = React.useCallback(() => {
    if (uploadsRefreshTimerRef.current) return;
    uploadsRefreshTimerRef.current = window.setTimeout(() => {
      uploadsRefreshTimerRef.current = null;
      try {
        queryClient.invalidateQueries({ queryKey: ['photos'], exact: false });
        queryClient.invalidateQueries({ queryKey: ['media-counts'], exact: false });
        queryClient.invalidateQueries({ queryKey: ['albums'], exact: false });
      } catch {}
    }, 700);
  }, [queryClient]);

  const attach = React.useCallback((jid: string) => {
    if (!jid) return;
    // Guard: ignore duplicate attaches for the same job
    if (jobIdRef.current === jid) return;
    // Close any existing
    if (esRef.current) { try { esRef.current.close(); } catch {}; esRef.current = null; }
    setJobId(jid);
    jobIdRef.current = jid;
    // Start SSE
    try {
      const es = new EventSource(`/api/reindex/stream?jobId=${encodeURIComponent(jid)}`);
      esRef.current = es;
      // Start 5s refresh cadence unconditionally
      if (refreshTimerRef.current) { window.clearInterval(refreshTimerRef.current); }
      refreshTimerRef.current = window.setInterval(async () => {
        tickRefresh();
        // Also check if job is still active; if not, stop
        try {
          if (token) {
            const res = await fetch(`/api/reindex/active`, { headers: { Authorization: `Bearer ${token}` } });
            if (res.ok) {
              const j = await res.json();
              if (!j?.active) { stop(); }
            }
          }
        } catch {}
      }, 5_000);

      es.onmessage = (evt) => {
        try {
          const data = JSON.parse(evt.data);
          if (data?.type === 'progress') {
            if (typeof data.processed === 'number' && typeof data.total === 'number') {
              setProgress({ processed: data.processed, total: data.total, stage: data.stage });
            }
            // Throttle refresh: only refresh if we advanced by >=10 items or 2.5s elapsed
            const proc = typeof data.processed === 'number' ? data.processed : 0;
            const advancedBy = Math.max(0, proc - lastProcessedRef.current);
            const elapsed = Date.now() - lastRefreshTsRef.current;
            if (advancedBy >= 10 || elapsed >= 2500) {
              lastProcessedRef.current = proc;
              try { tickRefresh(); } catch {}
            }
          } else if (data?.type === 'done') {
            // Final refresh and stop
            tickRefresh();
            stop();
          } else if (data?.type === 'cancelled') {
            // Ensure the grid updates after cancellation
            try { tickRefresh(); } catch {}
            setTimeout(() => { try { tickRefresh(); } catch {} }, 1000);
            stop();
          } else if (data?.type === 'cancel-requested') {
            // Backend broadcast: show stopping state
            setCancelRequested(true);
          }
        } catch {}
      };
      es.onerror = () => {
        // Fallback: keep polling every 5s even if SSE broke (the interval above continues)
        // No-op here; the interval above continues regardless
      };
    } catch {}
    // Kick an initial refresh immediately after attach
    try { tickRefresh(); } catch {}
  }, [tickRefresh, stop, token]);

  // Listen for cross-frame and in-page messages
  React.useEffect(() => {
    const onMsg = (e: MessageEvent) => {
      try {
        if (e.origin !== window.location.origin) return;
        const data = e.data;
        if (data && data.type === 'reindex-started' && typeof data.jobId === 'string') {
          attach(data.jobId);
          // Also send a message to close any open modals
          window.postMessage({ type: 'close-modals' }, window.location.origin);
        }
      } catch {}
    };
    window.addEventListener('message', onMsg);
    return () => window.removeEventListener('message', onMsg);
  }, [attach]);

  // Uploads SSE: auto-refresh grid and show small toast on upload_ingested
  React.useEffect(() => {
    // Reconnect whenever auth state changes (token/cookie likely changed)
    // Only attach when authenticated (token or auth cookie present). This avoids
    // unauthenticated requests that show up as 401/500 in server logs before login.
    const hasAuthCookie = (() => {
      try {
        if (typeof document === 'undefined') return false;
        return document.cookie.split(';').some(c => c.trim().startsWith('auth-token='));
      } catch { return false; }
    })();
    if (!token && !hasAuthCookie) {
      return () => { /* noop when not authenticated */ };
    }
    try {
      // Close previous if any
      try { uploadsEsRef.current?.close(); } catch {}
      uploadsEsRef.current = null;
      const url = token ? `/api/uploads/stream?token=${encodeURIComponent(token)}` : `/api/uploads/stream`;
      const es = new EventSource(url);
      uploadsEsRef.current = es;
      es.onmessage = (evt) => {
        try {
          const data = JSON.parse(evt.data);
          if (data?.type === 'upload_ingested') {
            // Batch upload-driven refreshes to avoid request spikes during sync bursts.
            scheduleUploadsRefresh();
            // Singleton toast update (bottom center): filename only (no extra request)
            const path: string | undefined = data?.path;
            const fileName = (() => {
              if (typeof path === 'string' && path.length) {
                const idx = path.lastIndexOf('/');
                return idx >= 0 ? path.slice(idx + 1) : path;
              }
              return data?.asset_id || 'Uploaded photo';
            })();
            setUploadToast(`Upload processed: ${fileName}`);
            if (uploadToastTimerRef.current) { window.clearTimeout(uploadToastTimerRef.current); }
            uploadToastTimerRef.current = window.setTimeout(() => setUploadToast(null), 2500);
          } else if (data?.type === 'wrap_needed') {
            // Owner nudge to generate wraps quickly for new locked items
            (async () => {
              try {
                const mod: any = await import('@ee/autoPrep');
                const fn = mod?.startOwnerAutoWrapFor as ((s:{ shareId:string; assetIds:string[]; variant?: 'thumb'|'orig' })=>Promise<void>) | undefined;
                if (!fn) return;
                const sid = String(data?.share_id || '');
                const aids = Array.isArray(data?.asset_ids) ? data.asset_ids.filter((x:any)=> typeof x === 'string') : [];
                if (!sid || aids.length === 0) return;
                await fn({ shareId: sid, assetIds: aids, variant: 'thumb' });
              } catch {}
            })();
          }
        } catch {}
      };
      es.onerror = () => {
        // Auto-close on error; a subsequent auth change or navigation will reconnect
        try { uploadsEsRef.current?.close(); } catch {}
        uploadsEsRef.current = null;
      };
    } catch {}
    return () => {
      try { uploadsEsRef.current?.close(); } catch {}
      uploadsEsRef.current = null;
      if (uploadsRefreshTimerRef.current) {
        window.clearTimeout(uploadsRefreshTimerRef.current);
        uploadsRefreshTimerRef.current = null;
      }
    };
  }, [queryClient, scheduleUploadsRefresh, token]);

  // On mount, if authenticated, try to resume any active job
  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        if (!token) return;
        const res = await fetch(`/api/reindex/active`, {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (!cancelled && res.ok) {
          const j = await res.json();
          if (j?.active && j?.job_id) {
            // Close modals before attaching to existing job
            try { window.postMessage({ type: 'close-modals' }, window.location.origin); } catch {}
            attach(j.job_id);
          }
        }
      } catch {}
    })();
    return () => { cancelled = true; };
  }, [token, attach]);

  return (
    <>
      {children}
      {/* Singleton upload toast (bottom center) */}
      {uploadToast && (
        <div className="fixed bottom-6 left-1/2 -translate-x-1/2 z-[80] pointer-events-none">
          <div className="pointer-events-auto rounded-md shadow-lg ring-1 ring-black/10 px-3 py-2 text-sm bg-gray-900 text-white min-w-[240px] text-center">
            {uploadToast}
          </div>
        </div>
      )}
      {jobId && (
        <div className="fixed left-4 bottom-4 z-[60] pointer-events-auto">
          <div className="relative bg-card/90 backdrop-blur border border-border text-foreground rounded-md shadow px-3 py-2 min-w-[260px]">
            {/* Close button for indexing progress */}
            <button
              aria-label="Close"
              title="Close"
              onClick={() => setConfirmOpen(true)}
              className="absolute top-1.5 right-1.5 p-1 rounded hover:bg-muted/60 text-muted-foreground hover:text-foreground"
              data-testid="reindex-close"
            >
              <X className="w-4 h-4" />
            </button>
            <div className="flex items-center justify-between mb-1 pr-6">
              <span className="text-sm text-foreground select-none">
                {cancelRequested ? 'Stopping…' : `Indexing${progress?.stage && progress.stage !== 'indexing' ? ` • ${progress.stage}` : ''}`}
              </span>
              <div className="flex items-center gap-2">
                {!cancelRequested && (
                  <button onClick={() => setProgressMin(!progressMin)} className="text-gray-500 text-xs hover:text-foreground">
                  {progressMin ? 'Expand' : 'Minimize'}
                  </button>
                )}
              </div>
            </div>
            {!progressMin && (
              <>
                <div className="w-full h-2 bg-gray-200 rounded">
                  <div className="h-2 bg-primary rounded" style={{ width: `${Math.min(100, Math.round((((progress?.processed ?? 0) / Math.max(1, progress?.total ?? 1)) * 100))) }%` }} />
                </div>
                <div className="text-xs text-gray-600 mt-1">
                  {(() => {
                    const proc = typeof progress?.processed === 'number' ? progress!.processed : 0;
                    const tot = typeof progress?.total === 'number' ? progress!.total : 0;
                    return `${Math.min(proc, tot)} / ${tot}`;
                  })()}
                </div>
              </>
            )}
          </div>
        </div>
      )}

      {/* Stop indexing confirmation modal */}
      {confirmOpen && (
        <div className="fixed inset-0 z-[70] flex items-center justify-center">
          <div className="absolute inset-0 bg-black/50" onClick={() => setConfirmOpen(false)} />
          <div className="relative bg-background text-foreground border border-border rounded-md shadow-lg w-[90vw] max-w-sm p-4">
            <h3 className="text-lg font-semibold mb-2">Stop indexing?</h3>
            <p className="text-sm text-muted-foreground mb-4">This will cancel the current indexing job. You can restart it later from Settings.</p>
            <div className="flex justify-end gap-2">
              <button
                className="px-3 py-1.5 rounded-md border border-border bg-muted hover:bg-muted/80"
                onClick={() => setConfirmOpen(false)}
              >
                Continue
              </button>
              <button
                className="px-3 py-1.5 rounded-md bg-destructive text-destructive-foreground hover:bg-destructive/90"
                onClick={async () => {
                  setConfirmOpen(false);
                  try {
                    const jid = jobIdRef.current || jobId;
                    if (jid && token) {
              await fetch(`/api/reindex/stop`, {
                method: 'POST',
                headers: {
                  'Authorization': `Bearer ${token}`,
                          'Content-Type': 'application/json',
                        },
                        body: JSON.stringify({ job_id: jid }),
                      });
                    }
                  } catch {}
                  // Keep SSE alive; show stopping state; periodic 5s poll continues
                  setCancelRequested(true);
                  // Fallback: if backend doesn't emit, force-refresh a couple of times
                  setTimeout(() => { try { tickRefresh(); } catch {} }, 1000);
                  setTimeout(() => { try { tickRefresh(); } catch {} }, 5000);
                }}
              >
                Stop Indexing
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
