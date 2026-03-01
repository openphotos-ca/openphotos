// E2EE helpers for account shares (recipient side). Fetches my SMK envelope and wraps,
// then uses the web worker's 'decrypt-v3-with-smk' path to decrypt PAE3 containers.

export type ShareWrapItem = {
  asset_id: string;
  variant: 'orig' | 'thumb';
  wrap_iv_b64: string;
  dek_wrapped_b64: string;
  encrypted_by_user_id: string;
};

export async function fetchMySmkEnvelope(shareId: string, headers?: HeadersInit): Promise<any | null> {
  const res = await fetch(
    `/api/ee/shares/${encodeURIComponent(shareId)}/e2ee/my-smk-envelope`,
    headers && Object.keys(headers).length ? { headers } : undefined
  );
  if (!res.ok) return null;
  const j = await res.json().catch(()=>null);
  return j?.env || null;
}

export async function fetchShareWraps(
  shareId: string,
  assetIds: string[],
  variant?: 'orig' | 'thumb',
  headers?: HeadersInit
): Promise<ShareWrapItem[]> {
  if (!assetIds.length) return [];
  const q = new URLSearchParams();
  q.set('asset_ids', assetIds.join(','));
  if (variant) q.set('variant', variant);
  const res = await fetch(
    `/api/ee/shares/${encodeURIComponent(shareId)}/e2ee/wraps?${q.toString()}`,
    headers && Object.keys(headers).length ? { headers } : undefined
  );
  const j = await res.json().catch(()=>null);
  if (!res.ok || !j || !Array.isArray(j.items)) return [];
  return j.items;
}

// --- Minimal ECIES (ECDH P-256 + AES-GCM) unwrap ---
// Envelope formats supported:
// 1) { smk_hex: "<64 hex>" }   -- dev/temporary
// 2) { alg?: 'ECIES-P256-AESGCM'|'ECIES-P256', epk_b64url, iv_b64url, ct_b64url }
//    - epk_b64url is raw uncompressed EC point (65 bytes) for P-256
//    - iv_b64url is 12-byte AES-GCM IV
//    - ct_b64url is AES-GCM ciphertext (SMK 32 bytes + 16-byte tag)

function b64urlDecode(s: string): Uint8Array {
  let t = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = (4 - (t.length % 4)) % 4; if (pad) t += '='.repeat(pad);
  const bin = atob(t);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function hexToBytes(hex: string): Uint8Array {
  const s = hex.startsWith('0x') ? hex.slice(2) : hex;
  if (s.length % 2 !== 0) throw new Error('Odd hex length');
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i*2, i*2+2), 16);
  return out;
}

async function importEcPrivateKeyFromPkcs8B64(b64: string): Promise<CryptoKey> {
  const raw = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
  return crypto.subtle.importKey('pkcs8', raw as unknown as BufferSource, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
}

async function importEcPublicRaw(b64url: string): Promise<CryptoKey> {
  const raw = b64urlDecode(b64url);
  // Expect 65-byte uncompressed point 0x04 || X || Y
  return crypto.subtle.importKey('raw', raw as unknown as BufferSource, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
}

async function deriveSharedSecret(priv: CryptoKey, pub: CryptoKey): Promise<Uint8Array> {
  const bits = await crypto.subtle.deriveBits({ name: 'ECDH', public: pub }, priv, 256);
  return new Uint8Array(bits);
}

async function importHmacKey(raw: any): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
}

async function hmacSha256(key: CryptoKey, data: any): Promise<ArrayBuffer> {
  return crypto.subtle.sign({ name: 'HMAC' }, key, data);
}

async function hkdfSha256(ikm: Uint8Array, info: Uint8Array, outLen: number, salt?: Uint8Array): Promise<Uint8Array> {
  const s = salt || new Uint8Array(32);
  const kS = await importHmacKey(s);
  const prk = await hmacSha256(kS, ikm);
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

export async function ensureIdentityKeyPairP256(): Promise<{ pub_raw_b64: string; priv_pkcs8_b64: string }> {
  // Persist to localStorage (simple MVP keystore). In real EE, this should use platform keystore.
  const pubKeyB64 = typeof localStorage !== 'undefined' ? localStorage.getItem('e2ee_identity_p256_pub_raw_b64') : null;
  const privKeyB64 = typeof localStorage !== 'undefined' ? localStorage.getItem('e2ee_identity_p256_pkcs8_b64') : null;
  if (pubKeyB64 && privKeyB64) return { pub_raw_b64: pubKeyB64, priv_pkcs8_b64: privKeyB64 };
  const kp = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const pubRaw = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
  const privPkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', kp.privateKey));
  const toB64 = (b: Uint8Array) => { let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s); };
  const pub_raw_b64 = toB64(pubRaw);
  const priv_pkcs8_b64 = toB64(privPkcs8);
  if (typeof localStorage !== 'undefined') {
    localStorage.setItem('e2ee_identity_p256_pub_raw_b64', pub_raw_b64);
    localStorage.setItem('e2ee_identity_p256_pkcs8_b64', priv_pkcs8_b64);
  }
  return { pub_raw_b64, priv_pkcs8_b64 };
}

export async function unwrapSmkWithPrivateKey(env: any): Promise<Uint8Array | null> {
  try {
    if (!env || typeof env !== 'object') return null;
    // Dev shortcut
    if (typeof env.smk_hex === 'string' && /^[0-9a-fA-F]{64}$/.test(env.smk_hex)) {
      return hexToBytes(env.smk_hex);
    }
    const epk = env.epk_b64url || env.epk || env.pub_b64url;
    const ivS = env.iv_b64url || env.iv;
    const ctS = env.ct_b64url || env.ct || env.smk_wrapped_b64url;
    if (!epk || !ivS || !ctS) return null;
    // Ensure local identity exists and import private key
    const { priv_pkcs8_b64 } = await ensureIdentityKeyPairP256();
    const priv = await importEcPrivateKeyFromPkcs8B64(priv_pkcs8_b64);
    const pub = await importEcPublicRaw(String(epk));
    const sec = await deriveSharedSecret(priv, pub);
    const kEnv = await hkdfSha256(sec, new TextEncoder().encode('share:smk:env:v1'), 32);
    const smk = await aesGcmDecryptRaw(kEnv, b64urlDecode(String(ivS)), null, b64urlDecode(String(ctS)));
    if (smk.length !== 32) return null;
    return smk;
  } catch {
    return null;
  }
}

// Decryption is delegated to existing publicE2EE decrypt helper via worker; share pages can reuse it.
export { decryptPae3WithSmk } from './publicE2EE';
