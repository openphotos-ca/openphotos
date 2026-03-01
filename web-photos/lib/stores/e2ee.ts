import { create } from 'zustand';
import { cryptoApi } from '@/lib/api/crypto';
import { idbGet, idbSet, idbDel } from '@/lib/idb';
import { logger } from '@/lib/logger';

export interface Argon2Params {
  m: number; // memory in MiB
  t: number; // iterations
  p: number; // parallelism
}

interface E2EEState {
  // In-memory UMK (never persisted)
  umk: Uint8Array | null;
  isUnlocked: boolean;
  // Cached server envelope (ciphertext JSON blob)
  envelope: any | null;
  envelopeUpdatedAt?: string | null;
  // KDF calibration params (not secret)
  params: Argon2Params | null;
  // Capability flags
  canEncrypt: boolean; // true when worker + algorithms are ready

  // Actions
  loadEnvelope: () => Promise<void>;
  saveEnvelope: (env: any) => Promise<void>;
  setUMK: (umk: Uint8Array | null) => void;
  setParams: (p: Argon2Params | null) => void;
}

export const useE2EEStore = create<E2EEState>((set, get) => ({
  umk: null,
  isUnlocked: false,
  envelope: null,
  envelopeUpdatedAt: null,
  params: null,
  canEncrypt: false, // flipped to true when worker is wired with Argon2 + WebCrypto

  async loadEnvelope() {
    // Prefer local cache first to avoid network 401s causing app logout
    try {
      const envLocal = await idbGet('envelope');
      if (envLocal) {
        set({ envelope: envLocal, envelopeUpdatedAt: null });
        logger.info('[E2EE] Loaded envelope (IndexedDB)');
        return;
      }
    } catch {}
    // Fall back to server
    try {
      const res = await cryptoApi.getEnvelope();
      const env = res.envelope || null;
      set({ envelope: env, envelopeUpdatedAt: res.updated_at || null });
      if (env) {
        try { await idbSet('envelope', env); } catch {}
      }
      logger.info('[E2EE] Loaded envelope (server)');
    } catch (e) {
      logger.warn('[E2EE] No envelope available from server');
      set({ envelope: null, envelopeUpdatedAt: null });
    }
  },

  async saveEnvelope(envelope: any) {
    try { await cryptoApi.saveEnvelope(envelope); } catch {}
    try { await idbSet('envelope', envelope); } catch {}
    set({ envelope, envelopeUpdatedAt: new Date().toISOString() });
  },

  setUMK(umk: Uint8Array | null) {
    set({ umk, isUnlocked: !!umk });
  },

  setParams(p: Argon2Params | null) {
    set({ params: p });
  },
}));
