"use client";

import React from 'react';
import { PinInput } from '@/components/security/PinInput';
import { useToast } from '@/hooks/use-toast';
import { useE2EEStore } from '@/lib/stores/e2ee';
import { getRememberMinutes, rememberUMK } from '@/lib/remember';

export function UnlockModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [pin, setPin] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState('');
  const e2ee = useE2EEStore();
  const { toast } = useToast();

  // Ensure envelope is loaded when the dialog opens so owners can unlock even on /shared
  React.useEffect(() => {
    if (!open) return;
    (async () => {
      try { if (!useE2EEStore.getState().envelope) await useE2EEStore.getState().loadEnvelope(); } catch {}
    })();
  }, [open]);

  // Defer early return until after hooks are declared so the hooks order is
  // consistent across renders (avoids React error #310 in production builds).
  if (!open) return null;

  return (
    <div className="fixed inset-0 z-[80]">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className="absolute inset-0 grid place-items-center p-4">
        <div className="w-full max-w-sm bg-background text-foreground border border-border rounded-lg shadow-2xl">
          <div className="px-4 py-3 border-b border-border font-medium flex items-center justify-between gap-3">
            <div>Unlock</div>
            <button className="px-2 py-1 text-xs border border-border rounded hover:bg-muted" onClick={onClose}>Close</button>
          </div>
          <div className="p-4 space-y-3">
            {!e2ee.envelope ? (
              <div className="text-sm text-muted-foreground">No PIN set. Go to Settings → Security to create one.</div>
            ) : (
              <>
                <div>
                  <div className="mb-2 text-sm">Enter your 8‑character PIN</div>
                  <PinInput value={pin} onChange={(v)=>{ setPin(v); setError(''); }} autoFocus ariaLabel="PIN" />
                </div>
                {error && <div className="text-sm text-red-500">{error}</div>}
                <div className="pt-1 flex items-center justify-end">
                  <button
                    onClick={async () => {
                      if (pin.length !== 8) return;
                      setBusy(true); setError('');
                      try {
                        // @ts-ignore
                        const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
                        const umkB64: string = await new Promise((resolve, reject) => {
                          worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind === 'umk') { try{worker.terminate();}catch{}; resolve(d.umkB64); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'unlock failed')); } };
                          worker.onerror = (er) => { try{worker.terminate();}catch{}; reject(er.error||new Error(String(er.message||er))); };
                          worker.postMessage({ type: 'unwrap-umk', password: pin, envelope: e2ee.envelope });
                        });
                        const raw = atob(umkB64.replace(/-/g,'+').replace(/_/g,'/'));
                        const umk = new Uint8Array(raw.length); for (let i=0;i<raw.length;i++) umk[i] = raw.charCodeAt(i);
                        e2ee.setUMK(umk);
                        // Record last-seen envelope updated_at so future freshness checks can bypass
                        try {
                          const updatedAt = useE2EEStore.getState().envelopeUpdatedAt || null;
                          if (updatedAt) { localStorage.setItem('e2ee.last_envelope_updated_at', updatedAt); }
                        } catch {}
                        try {
                          const mins = getRememberMinutes();
                          try { console.warn('[UNLOCK] remember minutes=', mins); } catch {}
                          if (mins && mins > 0) { await rememberUMK(umk, mins); }
                        } catch {}
                        try { toast({ title: 'Unlocked', description: 'E2EE session is now unlocked', variant: 'success' }); } catch {}
                        onClose();
                      } catch (e:any) { setError(e?.message||'Unlock failed'); }
                      finally { setBusy(false); }
                    }}
                    disabled={busy || pin.length!==8}
                    className="px-3 py-1.5 rounded border border-border bg-primary/80 text-white hover:bg-primary"
                  >{busy ? 'Unlocking…' : 'Unlock'}</button>
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
