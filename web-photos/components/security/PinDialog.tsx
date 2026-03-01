"use client";

import React, { useEffect, useMemo, useRef, useState } from "react";
import { Lock as LockIcon } from "lucide-react";
import { PinInput } from "@/components/security/PinInput";
import { useE2EEStore } from "@/lib/stores/e2ee";
import { cryptoApi } from "@/lib/api/crypto";

type Mode = "verify" | "set";

export function PinDialog({
  open,
  mode,
  onClose,
  onVerified,
  title,
  description,
}: {
  open: boolean;
  mode: Mode;
  onClose: () => void;
  onVerified?: () => void; // called after successful set/verify
  title?: string;
  description?: string;
}) {
  const [phase, setPhase] = useState<"enter" | "confirm">("enter");
  const [code, setCode] = useState<string>("");
  const [first, setFirst] = useState<string>("");
  const [error, setError] = useState<string>("");
  const [busy, setBusy] = useState<boolean>(false);
  const inputRef = useRef<HTMLInputElement | null>(null);

  // Auto-focus hidden input when dialog opens
  useEffect(() => {
    if (open) {
      setTimeout(() => inputRef.current?.focus(), 10);
    } else {
      // reset state when closing
      setPhase("enter");
      setCode("");
      setFirst("");
      setError("");
      setBusy(false);
    }
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        if (!busy) onClose();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, busy, onClose]);

  const effectiveTitle = useMemo(() => {
    if (title) return title;
    if (mode === "set") return phase === "confirm" ? "Confirm your PIN" : "Set an 8‑character PIN";
    return "Enter your PIN";
  }, [mode, phase, title]);

  const effectiveDescription = useMemo(() => {
    if (description) return description;
    if (mode === "set") {
      return phase === "confirm"
        ? "Re‑enter the PIN to confirm"
        : "This protects locked items. Use 8 characters.";
    }
    return "To view locked items, enter your 8‑character PIN.";
  }, [mode, phase, description]);

  const submit = async (pin: string) => {
    setBusy(true);
    setError("");
    try {
      if (mode === "verify") {
        // Ensure we have an envelope
        const st = useE2EEStore.getState();
        if (!st.envelope) {
          try { await st.loadEnvelope(); } catch {}
        }
        if (!useE2EEStore.getState().envelope) {
          throw new Error('No PIN is set on this account');
        }
        // Unwrap UMK using worker
        // @ts-ignore
        const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
        const umkB64: string = await new Promise((resolve, reject) => {
          worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind === 'umk') { try{worker.terminate();}catch{}; resolve(d.umkB64); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'Unlock failed')); } };
          worker.onerror = (er) => { try{worker.terminate();}catch{}; reject(er.error||new Error(String(er.message||er))); };
          worker.postMessage({ type: 'unwrap-umk', password: pin, envelope: useE2EEStore.getState().envelope });
        });
        const raw = atob(umkB64.replace(/-/g,'+').replace(/_/g,'/'));
        const umk = new Uint8Array(raw.length); for (let i=0;i<raw.length;i++) umk[i] = raw.charCodeAt(i);
        useE2EEStore.getState().setUMK(umk);
      } else {
        // Set mode: generate a fresh UMK and wrap it with Argon2id params
        const umk = new Uint8Array(32); crypto.getRandomValues(umk);
        let umkHex = ''; for (let i=0;i<umk.length;i++) umkHex += umk[i].toString(16).padStart(2,'0');
        // @ts-ignore
        const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
        const env: any = await new Promise((resolve, reject) => {
          worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind === 'envelope') { try{worker.terminate();}catch{}; resolve(d.envelope); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'Wrap failed')); } };
          worker.onerror = (er) => { try{worker.terminate();}catch{}; reject(er.error||new Error(String(er.message||er))); };
          const params = useE2EEStore.getState().params || { m: 128, t: 3, p: 1 };
          worker.postMessage({ type: 'wrap-umk', umkHex, password: pin, params });
        });
        // Persist envelope locally (and attempt server save best-effort)
        try {
          await useE2EEStore.getState().saveEnvelope(env);
        } catch {
          // Even if server save fails (e.g., 401), keep local envelope to enable offline unlock
          useE2EEStore.setState({ envelope: env, envelopeUpdatedAt: new Date().toISOString() });
        }
        useE2EEStore.getState().setUMK(umk);
      }
      onVerified?.();
    } catch (e: any) {
      const msg = (e?.message || "").toString();
      if (mode === "verify") {
        setError(msg || "Incorrect PIN code");
      } else {
        setError(msg || "Invalid PIN. Try again.");
      }
      setCode("");
      setPhase(mode === "set" && first ? "confirm" : "enter");
      setTimeout(() => inputRef.current?.focus(), 10);
      return;
    } finally {
      setBusy(false);
    }
    // Parent onVerified closes the dialog; do not call onClose here to avoid races.
  };

  const onInput = (value: string) => {
    if (busy) return;
    const s = (value || "").slice(0, 8);
    setError("");
    setCode(s);
    if (s.length === 8) {
      if (mode === "set") {
        if (phase === "enter") {
          setFirst(s);
          setCode("");
          setPhase("confirm");
          // keep focus for confirm step
          setTimeout(() => inputRef.current?.focus(), 10);
        } else {
          if (s !== first) {
            setError("PINs do not match");
            setCode("");
            setTimeout(() => inputRef.current?.focus(), 10);
          } else {
            submit(s);
          }
        }
      } else {
        submit(s);
      }
    }
  };

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-[100]">
      <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={() => !busy && onClose()} />
      <div className="absolute inset-0 flex items-center justify-center p-4">
        <div className="w-full max-w-lg bg-background text-foreground border border-border rounded-xl shadow-2xl">
          <div className="p-6 flex flex-col items-center text-center">
            <div className="w-12 h-12 rounded-full bg-primary/10 text-primary grid place-items-center mb-4">
              <LockIcon className="w-6 h-6" />
            </div>
            <h2 className="text-lg font-semibold mb-1">{effectiveTitle}</h2>
            <p className="text-sm text-muted-foreground mb-4">{effectiveDescription}</p>

            {/* 8 boxes input */}
            <div className="mb-3">
              <PinInput value={code} onChange={onInput} length={8} autoFocus ariaLabel="PIN" />
            </div>

            {error && (
              <div className="text-sm text-red-500 mb-2" role="alert">{error}</div>
            )}

            <div className="mt-1 flex items-center justify-center gap-3">
              <button
                type="button"
                className="px-4 py-2 rounded-md border border-border bg-card hover:bg-muted disabled:opacity-50"
                onClick={() => !busy && onClose()}
                disabled={busy}
              >
                Cancel
              </button>
              <button
                type="button"
                className="px-4 py-2 rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
                onClick={() => submit(code)}
                disabled={busy || (mode === "set" ? (phase === "enter" ? code.length !== 8 : code.length !== 8) : code.length !== 8)}
              >
                {mode === "verify" ? (busy ? "Verifying..." : "Verify") : phase === "enter" ? (busy ? "Setting..." : "Next") : (busy ? "Setting..." : "Set PIN")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
