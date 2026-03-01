// Lightweight E2EE helpers for public link viewing (browser-only)

export type WrapItem = {
  asset_id: string;
  variant: 'orig' | 'thumb';
  wrap_iv_b64: string;
  dek_wrapped_b64: string;
  encrypted_by_user_id: string;
};

function b64urlDecode(s: string): Uint8Array {
  let t = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = (4 - (t.length % 4)) % 4; if (pad) t += '='.repeat(pad);
  const bin = atob(t);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64urlToArrayBuffer(s: string): ArrayBuffer { return b64urlDecode(s).buffer as ArrayBuffer; }

function toHex(bytes: Uint8Array): string { let h = ''; for (let i = 0; i < bytes.length; i++) h += bytes[i].toString(16).padStart(2, '0'); return h; }

export function getViewerKeyFromHash(): Uint8Array | null {
  try {
    const hash = (typeof window !== 'undefined' ? window.location.hash : '') || '';
    if (!hash) return null;
    const params = new URLSearchParams(hash.startsWith('#') ? hash.slice(1) : hash);
    const vk = params.get('vk');
    if (!vk) return null;
    return b64urlDecode(vk);
  } catch { return null; }
}

async function importHmacKey(raw: any): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
}

async function hmacSha256(key: CryptoKey, data: any): Promise<ArrayBuffer> {
  return crypto.subtle.sign({ name: 'HMAC' }, key, data);
}

async function hkdfSha256(ikm: Uint8Array, info: Uint8Array, outLen: number, salt?: Uint8Array): Promise<Uint8Array> {
  const s = salt || new Uint8Array(32);
  // Extract
  const kS = await importHmacKey(s);
  const prk = await hmacSha256(kS, ikm);
  // Expand
  const prkKey = await importHmacKey(prk);
  let t = new Uint8Array(0);
  const out = new Uint8Array(outLen);
  let off = 0;
  for (let counter = 1; off < outLen; counter++) {
    const buf = new Uint8Array(t.length + info.length + 1);
    buf.set(t, 0); buf.set(info, t.length); buf[buf.length - 1] = counter;
    const block = new Uint8Array(await hmacSha256(prkKey, buf));
    const need = Math.min(block.length, outLen - off);
    out.set(block.subarray(0, need), off);
    off += need;
    t = block;
  }
  return out;
}

async function aesGcmDecryptRaw(keyBytes: Uint8Array, iv: Uint8Array, aad: Uint8Array | null, ct: Uint8Array): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', keyBytes as unknown as BufferSource, { name: 'AES-GCM' }, false, ['decrypt']);
  const p = { name: 'AES-GCM', iv, additionalData: aad || undefined, tagLength: 128 } as AesGcmParams;
  const pt = new Uint8Array(await crypto.subtle.decrypt(p, key, ct as unknown as BufferSource));
  return pt;
}

export async function unwrapSmkFromEnvelope(env: any, viewerKey: Uint8Array): Promise<Uint8Array> {
  // Envelope fields tolerance
  const ivB64 = env?.iv_b64url || env?.iv || env?.wrap_iv_b64url || env?.wrap_iv;
  const ctB64 = env?.smk_wrapped_b64url || env?.ct_b64url || env?.ct || env?.wrapped_b64url;
  if (!ivB64 || !ctB64) throw new Error('Malformed SMK envelope');
  const iv = b64urlDecode(String(ivB64));
  const ct = b64urlDecode(String(ctB64));
  const kEnv = await hkdfSha256(viewerKey, new TextEncoder().encode('env:v1'), 32);
  const smk = await aesGcmDecryptRaw(kEnv, iv, new Uint8Array(0), ct);
  if (smk.length !== 32) throw new Error('SMK length');
  return smk;
}

export async function decryptPae3WithSmk(
  container: ArrayBuffer,
  smkHex: string,
  encryptedByUserIdUtf8: string,
  overrideWrap: { wrap_iv_b64: string; dek_wrapped_b64: string }
): Promise<ArrayBuffer> {
  return new Promise((resolve, reject) => {
    try {
      const worker = new Worker(new URL('../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
      worker.onmessage = (ev: MessageEvent) => {
        const data = ev.data || {};
        if (data?.ok && data.kind === 'v3-decrypted') {
          try { worker.terminate(); } catch {}
          resolve(data.container as ArrayBuffer);
          return;
        }
        if (data?.ok === false) {
          try { worker.terminate(); } catch {}
          reject(new Error(data?.error || 'decrypt-v3-with-smk failed'));
        }
      };
      worker.onerror = (e) => { try { worker.terminate(); } catch {}; reject(e.error || new Error(String(e.message||e))); };
      worker.postMessage({ type: 'decrypt-v3-with-smk', smkHex, encryptedByUserIdUtf8, container, overrideWrap });
    } catch (e) { reject(e); }
  });
}

export async function fetchJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<T>;
}

export async function fetchArrayBuffer(url: string): Promise<{ buf: ArrayBuffer; contentType: string }> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const ct = res.headers.get('content-type') || '';
  const buf = await res.arrayBuffer();
  return { buf, contentType: ct };
}

export function bytesToBlobUrl(bytes: ArrayBuffer, contentType: string): string {
  const blob = new Blob([bytes], { type: contentType });
  return URL.createObjectURL(blob);
}

// Simple sniffing to determine image content type from magic bytes.
// Returns one of: 'image/jpeg' | 'image/png' | 'image/webp' | 'application/octet-stream'
export function sniffImageContentType(bytes: ArrayBuffer): string {
  try {
    const b = new Uint8Array(bytes);
    if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
    if (
      b.length >= 8 &&
      b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
      b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a
    ) return 'image/png';
    if (
      b.length >= 12 &&
      // 'RIFF'....'WEBP'
      b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
      b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
    ) return 'image/webp';
  } catch {}
  return 'application/octet-stream';
}

export function bytesToImageBlobUrl(bytes: ArrayBuffer): string {
  const ct = sniffImageContentType(bytes);
  const blob = new Blob([bytes], { type: ct });
  return URL.createObjectURL(blob);
}
