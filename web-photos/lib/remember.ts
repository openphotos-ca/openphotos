// Client-side "remember unlock" helper.
// Stores the UMK encrypted under a local secret with an expiry.

const SECRET_KEY = 'pin.remember.secret';
const BLOB_KEY = 'pin.remember.blob';
const MINUTES_KEY = 'pin.remember.min';

function b64url(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}
function b64urlDecode(s: string): Uint8Array {
  let t = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = (4 - (t.length % 4)) % 4; if (pad) t += '='.repeat(pad);
  const bin = atob(t);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function importKey(raw: Uint8Array): Promise<CryptoKey> {
  // Ensure we pass an ArrayBuffer (slice to account for byteOffset/length)
  const buf = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
  if (!crypto || !crypto.subtle || typeof crypto.subtle.importKey !== 'function') {
    throw new Error('WebCrypto unavailable');
  }
  return await crypto.subtle.importKey('raw', buf, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

function toAB(u8: Uint8Array): ArrayBuffer {
  return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
}

function getOrCreateSecret(): Uint8Array {
  try {
    const raw = localStorage.getItem(SECRET_KEY);
    if (raw) return b64urlDecode(raw);
  } catch {}
  const b = new Uint8Array(32); crypto.getRandomValues(b);
  try { localStorage.setItem(SECRET_KEY, b64url(b)); } catch {}
  return b;
}

export function getRememberMinutes(): number {
  // Default to 60 minutes if not configured
  try {
    const raw = localStorage.getItem(MINUTES_KEY);
    const v = parseInt(raw == null ? '60' : raw, 10);
    return isNaN(v) ? 60 : Math.max(0, v);
  } catch { return 60; }
}

export function setRememberMinutes(mins: number) {
  try { localStorage.setItem(MINUTES_KEY, String(Math.max(0, Math.floor(mins)))); } catch {}
}

export async function rememberUMK(umk: Uint8Array, minutes: number): Promise<void> {
  if (!minutes || minutes <= 0) return;
  logger.debug('[REMEMBER] storing UMK for minutes=', minutes);
  const secret = getOrCreateSecret();
  const exp = Math.floor(Date.now() / 1000) + (minutes * 60);
  // Prefer AES-GCM via WebCrypto when available; gracefully fall back when not in a secure context.
  try {
    const key = await importKey(secret);
    const iv = new Uint8Array(12); crypto.getRandomValues(iv);
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: toAB(iv) }, key, toAB(umk)));
    const blob = { v: 1, alg: 'gcm', iv: b64url(iv), ct: b64url(ct), exp } as const;
    try { localStorage.setItem(BLOB_KEY, JSON.stringify(blob)); } catch {}
    logger.debug('[REMEMBER] stored exp(unix)=', exp, 'alg=gcm');
    return;
  } catch (e) {
    // Fallback: environments served over http on non-localhost lack SubtleCrypto. Use a lightweight XOR keystream fallback
    // derived from the local secret + IV via SHA-256. This is weaker than AES-GCM but keeps the feature usable in dev/LAN.
    logger.debug('[REMEMBER] WebCrypto unavailable, using XOR fallback');
    // Lazy import to avoid adding a heavy dependency to the main bundle path.
    const { sha256 } = await import('@noble/hashes/sha256');
    const iv = new Uint8Array(16); crypto.getRandomValues(iv);
    // Generate 32-byte keystream using H(secret || iv || counter)
    const stream = new Uint8Array(32);
    let offset = 0; let counter = 0;
    while (offset < stream.length) {
      const input = new Uint8Array(secret.length + iv.length + 4);
      input.set(secret, 0); input.set(iv, secret.length);
      input[secret.length + iv.length + 0] = (counter >>> 24) & 0xff;
      input[secret.length + iv.length + 1] = (counter >>> 16) & 0xff;
      input[secret.length + iv.length + 2] = (counter >>> 8) & 0xff;
      input[secret.length + iv.length + 3] = counter & 0xff;
      const h = sha256(input);
      const take = Math.min(stream.length - offset, h.length);
      for (let i = 0; i < take; i++) stream[offset + i] = h[i];
      offset += take; counter++;
    }
    const ct = new Uint8Array(umk.length);
    for (let i = 0; i < umk.length; i++) ct[i] = umk[i] ^ stream[i % stream.length];
    const blob = { v: 1, alg: 'xorsha256', iv: b64url(iv), ct: b64url(ct), exp } as const;
    try { localStorage.setItem(BLOB_KEY, JSON.stringify(blob)); } catch {}
    logger.debug('[REMEMBER] stored exp(unix)=', exp, 'alg=xorsha256');
  }
}

export async function tryRestoreUMK(): Promise<Uint8Array | null> {
  let rec: any = null;
  try { rec = JSON.parse(localStorage.getItem(BLOB_KEY) || 'null'); } catch { rec = null; }
  logger.debug('[REMEMBER] blob present?', !!rec, 'raw=', localStorage.getItem(BLOB_KEY));
  if (!rec || typeof rec.exp !== 'number' || rec.exp <= Math.floor(Date.now() / 1000)) return null;
  try {
    logger.debug('[REMEMBER] attempting restore; exp=', rec.exp, 'now=', Math.floor(Date.now()/1000));
    const secret = getOrCreateSecret();
    const iv = b64urlDecode(rec.iv || '');
    const ct = b64urlDecode(rec.ct || '');
    const alg = (rec.alg || 'gcm') as string;
    if (alg === 'gcm') {
      const key = await importKey(secret);
      const pt = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: toAB(iv) }, key, toAB(ct)));
      logger.debug('[REMEMBER] restore ok; bytes=', pt.length, 'alg=gcm');
      return pt;
    }
    if (alg === 'xorsha256') {
      const { sha256 } = await import('@noble/hashes/sha256');
      // Recreate the keystream
      const stream = new Uint8Array(32);
      let offset = 0; let counter = 0;
      while (offset < stream.length) {
        const input = new Uint8Array(secret.length + iv.length + 4);
        input.set(secret, 0); input.set(iv, secret.length);
        input[secret.length + iv.length + 0] = (counter >>> 24) & 0xff;
        input[secret.length + iv.length + 1] = (counter >>> 16) & 0xff;
        input[secret.length + iv.length + 2] = (counter >>> 8) & 0xff;
        input[secret.length + iv.length + 3] = counter & 0xff;
        const h = sha256(input);
        const take = Math.min(stream.length - offset, h.length);
        for (let i = 0; i < take; i++) stream[offset + i] = h[i];
        offset += take; counter++;
      }
      const pt = new Uint8Array(ct.length);
      for (let i = 0; i < ct.length; i++) pt[i] = ct[i] ^ stream[i % stream.length];
      logger.debug('[REMEMBER] restore ok; bytes=', pt.length, 'alg=xorsha256');
      return pt;
    }
    return null;
  } catch { return null; }
}

export function clearRememberedUMK() {
  try { localStorage.removeItem(BLOB_KEY); } catch {}
}
import { logger } from '@/lib/logger';
