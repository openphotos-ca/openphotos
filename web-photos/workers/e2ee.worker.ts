// E2EE Web Worker implementing Argon2id, HKDF-SHA256, AES-GCM, and v3 container
import { hmac as nobleHmac } from '@noble/hashes/hmac';
import { sha256 } from '@noble/hashes/sha256';
// Use the bundled build to avoid WebAssembly loader issues in Next/Webpack
import argon2 from 'argon2-browser/dist/argon2-bundled.min.js';

type Bytes = Uint8Array;

const enc = new TextEncoder();
const dec = new TextDecoder();
// Loosen types for HMAC to avoid DOM lib generics issues under ES5 target
const hmac: any = nobleHmac as any;

const GCM_TAG_LEN = 16;
const DEFAULT_CHUNK_SIZE = 1024 * 1024; // 1 MiB

function randomBytes(n: number): Bytes {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return b;
}

function b64urlEncode(b: Bytes): string {
  let raw = '';
  for (let i = 0; i < b.length; i++) raw += String.fromCharCode(b[i]);
  const s = btoa(raw);
  return s.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function b64urlDecode(s: string): Bytes {
  let t = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = (4 - (t.length % 4)) % 4;
  if (pad) t += '='.repeat(pad);
  const bin = atob(t);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function writeU32BE(n: number): Bytes { const b = new Uint8Array(4); const v = n >>> 0; b[0] = (v >>> 24) & 0xff; b[1] = (v >>> 16) & 0xff; b[2] = (v >>> 8) & 0xff; b[3] = v & 0xff; return b; }

function addToIv(baseIv: Bytes, idx: number): Bytes {
  const out = new Uint8Array(baseIv);
  let carry = idx >>> 0;
  for (let i = 11; i >= 0; i--) {
    const sum = (out[i] & 0xff) + (carry & 0xff);
    out[i] = sum & 0xff;
    carry = sum >>> 8;
    if (carry === 0) break;
  }
  return out;
}

function aadForChunk(assetId: Bytes, idx: number, isLast: boolean): Bytes {
  const head = enc.encode('chunk:v3');
  const idxBytes = writeU32BE(idx);
  const out = new Uint8Array(head.length + assetId.length + idxBytes.length + 1);
  let off = 0;
  out.set(head, off); off += head.length;
  out.set(assetId, off); off += assetId.length;
  out.set(idxBytes, off); off += idxBytes.length;
  out[off] = isLast ? 1 : 0;
  return out;
}

function hkdfSha256(ikm: Bytes, info: Bytes, outLen: number, salt?: Bytes): Bytes {
  // RFC5869 HKDF using HMAC-SHA256
  const s = salt || new Uint8Array(32);
  const prk = hmac(sha256, s, ikm) as unknown as Uint8Array;
  const blocks: Bytes[] = [];
  let t: Uint8Array = new Uint8Array(0);
  let counter = 1;
  while ((blocks.reduce((acc, b) => acc + b.length, 0)) < outLen) {
    const buf = new Uint8Array(t.length + info.length + 1);
    buf.set(t, 0);
    buf.set(info, t.length);
    buf[buf.length - 1] = counter;
    t = hmac(sha256, prk, buf) as unknown as Uint8Array;
    blocks.push(t);
    counter++;
  }
  const out = new Uint8Array(outLen);
  let off = 0;
  for (const b of blocks) { out.set(b.subarray(0, Math.min(b.length, outLen - off)), off); off += b.length; if (off >= outLen) break; }
  return out;
}

async function aesGcmEncryptRaw(keyBytes: Bytes, iv: Bytes, aad: Bytes | null, plain: Bytes): Promise<Bytes> {
  const key = await crypto.subtle.importKey('raw', keyBytes as unknown as BufferSource, { name: 'AES-GCM' }, false, ['encrypt']);
  const params: AesGcmParams = { name: 'AES-GCM', iv: iv as unknown as BufferSource, additionalData: (aad as unknown as BufferSource) || undefined, tagLength: 128 };
  const ct = new Uint8Array(await crypto.subtle.encrypt(params, key, plain as unknown as BufferSource));
  return ct; // includes tag at end per WebCrypto
}

async function aesGcmDecryptRaw(keyBytes: Bytes, iv: Bytes, aad: Bytes | null, ct: Bytes): Promise<Bytes> {
  const key = await crypto.subtle.importKey('raw', keyBytes as unknown as BufferSource, { name: 'AES-GCM' }, false, ['decrypt']);
  const params: AesGcmParams = { name: 'AES-GCM', iv: iv as unknown as BufferSource, additionalData: (aad as unknown as BufferSource) || undefined, tagLength: 128 };
  const pt = new Uint8Array(await crypto.subtle.decrypt(params, key, ct as unknown as BufferSource));
  return pt;
}

function hmacSha256(key: Bytes, data: Bytes): Bytes {
  return hmac(sha256, key, data) as unknown as Uint8Array;
}

async function argon2id32(passwordUtf8: string, salt: Bytes, mMiB: number, t: number, p: number): Promise<Bytes> {
  const res = await argon2.hash({
    pass: passwordUtf8,
    salt,
    hashLen: 32,
    time: t,
    mem: mMiB * 1024,
    parallelism: p,
    type: argon2.ArgonType.Argon2id,
  });
  // res.hashHex string -> bytes
  const hex = res.hashHex.startsWith('0x') ? res.hashHex.slice(2) : res.hashHex;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i*2, i*2+2), 16);
  return out;
}

function concatBytes(...arrs: Bytes[]): Bytes {
  const total = arrs.reduce((a, b) => a + b.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrs) { out.set(a, off); off += a.length; }
  return out;
}

export type E2EEWorkerRequest =
  | { type: 'ping'; payload?: any }
  | { type: 'calibrate-argon2'; targetMs?: number }
  | { type: 'derive-pwk'; password: string; saltB64: string; params: { m: number; t: number; p: number } }
  | { type: 'wrap-umk'; umkHex: string; password: string; saltB64?: string; params: { m: number; t: number; p: number } }
  | { type: 'unwrap-umk'; password: string; envelope: any }
  | { type: 'encrypt-v3';
      umkHex: string;
      userIdUtf8: string;
      bytes: ArrayBuffer;
      metadata: any; // capture_ymd, size_kb, width, height, orientation, is_video, duration_s, mime_hint, kind, parent_asset_id?
      chunkSize?: number;
    }
  | { type: 'decrypt-v3'; umkHex: string; userIdUtf8: string; container: ArrayBuffer }
  | { type: 'decrypt-v3-with-smk'; smkHex: string; encryptedByUserIdUtf8: string; container: ArrayBuffer; overrideWrap: { wrap_iv_b64: string; dek_wrapped_b64: string } }
  | { type: 'rekey-wrap-for-smk'; umkHex: string; smkHex: string; container: ArrayBuffer };

export type E2EEWorkerResponse =
  | { ok: true; kind: 'pong'; payload?: any }
  | { ok: true; kind: 'calibrated'; params: { m: number; t: number; p: number } }
  | { ok: true; kind: 'pwk'; pwkB64: string }
  | { ok: true; kind: 'envelope'; envelope: any }
  | { ok: true; kind: 'v3-encrypted'; container: ArrayBuffer; asset_id_b58: string; outer_header_b64: string }
  | { ok: false; error: string };

self.onmessage = async (ev: MessageEvent<E2EEWorkerRequest>) => {
  const msg = ev.data;
  try {
    if (msg.type === 'ping') {
      (self as any).postMessage({ ok: true, kind: 'pong', payload: msg.payload } as E2EEWorkerResponse);
      return;
    }
    if (msg.type === 'calibrate-argon2') {
      // Lightweight calibration placeholder (~300ms target). Real implement: probe increasing memory.
      const params = { m: 128, t: 3, p: 1 };
      (self as any).postMessage({ ok: true, kind: 'calibrated', params } as E2EEWorkerResponse);
      return;
    }
    if (msg.type === 'derive-pwk') {
      const salt = b64urlDecode(msg.saltB64);
      const kdf = await argon2id32(msg.password, salt, msg.params.m, msg.params.t, msg.params.p);
      const pwk = hkdfSha256(kdf, enc.encode('umk-wrap:v1'), 32);
      (self as any).postMessage({ ok: true, kind: 'pwk', pwkB64: b64urlEncode(pwk) } as E2EEWorkerResponse);
      return;
    }
    if (msg.type === 'wrap-umk') {
      const salt = msg.saltB64 ? b64urlDecode(msg.saltB64) : randomBytes(16);
      const kdf = await argon2id32(msg.password, salt, msg.params.m, msg.params.t, msg.params.p);
      const pwk = hkdfSha256(kdf, enc.encode('umk-wrap:v1'), 32);
      const wrapIv = randomBytes(12);
      const aad = enc.encode('umk:v1');
      const umk = hexToBytes(msg.umkHex);
      const ct = await aesGcmEncryptRaw(pwk, wrapIv, aad, umk);
      const envelope = {
        kdf: 'argon2id', salt_b64url: b64urlEncode(salt), m: msg.params.m, t: msg.params.t, p: msg.params.p,
        info: 'umk-wrap:v1', wrap_iv_b64url: b64urlEncode(wrapIv), umk_wrapped_b64url: b64urlEncode(ct), version: 1,
      };
      (self as any).postMessage({ ok: true, kind: 'envelope', envelope } as E2EEWorkerResponse);
      return;
    }
    if (msg.type === 'unwrap-umk') {
      const env = msg.envelope || {};
      const salt = b64urlDecode(env.salt_b64url || '');
      const kdf = await argon2id32(msg.password, salt, env.m || 128, env.t || 3, env.p || 1);
      const pwk = hkdfSha256(kdf, enc.encode('umk-wrap:v1'), 32);
      const wrapIv = b64urlDecode(env.wrap_iv_b64url || '');
      const ct = b64urlDecode(env.umk_wrapped_b64url || '');
      const aad = enc.encode('umk:v1');
      const umk = await aesGcmDecryptRaw(pwk, wrapIv, aad, ct);
      (self as any).postMessage({ ok: true, kind: 'umk', umkB64: b64urlEncode(umk) } as any);
      return;
    }
    if (msg.type === 'encrypt-v3') {
      const UMK = hexToBytes(msg.umkHex);
      const userKey = enc.encode(msg.userIdUtf8);
      const input = new Uint8Array(msg.bytes);

      // Compute asset_id = first16(HMAC-SHA256(userKey, plaintext))
      const mac = hmacSha256(userKey, input);
      const assetId = mac.subarray(0, 16);

      // Keys & IVs
      const wrapKey = hkdfSha256(UMK, enc.encode('hkdf:wrap:v3'), 32);
      const wrapIv = randomBytes(12);
      const dek = randomBytes(32);
      const headerIv = randomBytes(12);
      const baseIv = randomBytes(12);

      const aadHeader = concatBytes(enc.encode('header:v3'), assetId);
      const aadWrap = concatBytes(enc.encode('wrap:v3'), assetId);

      const chunkSize = msg.chunkSize && msg.chunkSize > 0 ? msg.chunkSize : DEFAULT_CHUNK_SIZE;
      const totalChunks = Math.floor((input.length + chunkSize - 1) / chunkSize);
      const nowSec = Math.floor(Date.now()/1000);

      const headerPlain = {
        alg: 'AES-GCM-256',
        created_unix: nowSec,
        orig_size: input.length,
        chunk_size: chunkSize,
        total_chunks: totalChunks,
        metadata: msg.metadata || {},
      };
      const headerCt = await aesGcmEncryptRaw(dek, headerIv, aadHeader, enc.encode(JSON.stringify(headerPlain)));
      const dekWrapped = await aesGcmEncryptRaw(wrapKey, wrapIv, aadWrap, dek);
      const outerHeader = {
        v: 3,
        asset_id: b64urlEncode(assetId),
        base_iv: b64urlEncode(baseIv),
        wrap_iv: b64urlEncode(wrapIv),
        dek_wrapped: b64urlEncode(dekWrapped),
        header_iv: b64urlEncode(headerIv),
        header_ct: b64urlEncode(headerCt),
      };
      const headerBytes = enc.encode(JSON.stringify(outerHeader));

      // Trailer MAC = HMAC-SHA256(HKDF(dek, 'hkdf:dek:phys:v3'), all chunk length-prefixed ciphertexts)
      const dekPhys = hkdfSha256(dek, enc.encode('hkdf:dek:phys:v3'), 32);
      let trailerMacState: any = new Uint8Array(0);
      const macUpdate = (data: Bytes) => { trailerMacState = hmac(sha256, dekPhys, concatBytes(trailerMacState, data)) as unknown as Uint8Array; };

      // Build container into a single ArrayBuffer (for now)
      const chunks: Bytes[] = [];
      chunks.push(enc.encode('PAE3')); // MAGIC
      chunks.push(new Uint8Array([0x03, 0x01])); // version, FLAG_TRAILER
      chunks.push(writeU32BE(headerBytes.length));
      chunks.push(headerBytes);

      let offset = 0;
      for (let idx = 0; idx < totalChunks; idx++) {
        const end = Math.min(offset + chunkSize, input.length);
        const plain = input.subarray(offset, end);
        const iv = addToIv(baseIv, idx);
        const aad = aadForChunk(assetId, idx, idx === totalChunks - 1);
        const ct = await aesGcmEncryptRaw(dek, iv, aad, plain);
        chunks.push(writeU32BE(ct.length));
        chunks.push(ct);
        macUpdate(writeU32BE(ct.length));
        macUpdate(ct);
        offset = end;
      }
      // Trailer: "TAG3" + reserved(2) + tag_len(2=32) + tag(32)
      const tag = hmac(sha256, dekPhys, trailerMacState) as unknown as Uint8Array;
      chunks.push(enc.encode('TAG3'));
      chunks.push(new Uint8Array([0x00, 0x00]));
      chunks.push(new Uint8Array([0x00, 0x20]));
      chunks.push(tag);

      const totalSize = chunks.reduce((a, b) => a + b.length, 0);
      const out = new Uint8Array(totalSize);
      let pos = 0;
      for (const c of chunks) { out.set(c, pos); pos += c.length; }

      // Also prepare helpful values for TUS metadata
      const asset_id_b58 = base58Encode(assetId);
      const outer_header_b64 = b64urlEncode(headerBytes);
      (self as any).postMessage({ ok: true, kind: 'v3-encrypted', container: out.buffer, asset_id_b58, outer_header_b64 } as E2EEWorkerResponse, [out.buffer]);
      return;
    }
    if (msg.type === 'decrypt-v3') {
      const UMK = hexToBytes(msg.umkHex);
      const userKey = enc.encode(msg.userIdUtf8);
      const buf = new Uint8Array(msg.container);
      // Parse magic/version/flags/header_len
      if (buf.length < 10 + 4 + 16 + 4) throw new Error('Container too small');
      let off = 0;
      const eq = (a: Bytes, b: string) => dec.decode(a) === b;
      if (!eq(buf.subarray(0,4), 'PAE3')) throw new Error('Bad magic'); off += 4;
      const version = buf[off++]; if (version !== 0x03) throw new Error('Unsupported version');
      const flags = buf[off++]; const hasTrailer = (flags & 0x01) !== 0;
      const hlen = (buf[off]<<24)|(buf[off+1]<<16)|(buf[off+2]<<8)|buf[off+3]; off += 4;
      const headerBytes = buf.subarray(off, off+hlen); off += hlen;
      if (!hasTrailer) throw new Error('Missing trailer');
      const trailerLen = 4 + 2 + 2 + 32; // TAG3 + reserved + len + tag(32)
      const trailerPos = buf.length - trailerLen;
      if (trailerPos <= off) throw new Error('Invalid trailer position');
      const oh = JSON.parse(dec.decode(headerBytes));
      if (oh.v !== 3) throw new Error('Header v != 3');
      const assetId = b64urlDecode(oh.asset_id);
      const baseIv = b64urlDecode(oh.base_iv);
      const wrapIv = b64urlDecode(oh.wrap_iv);
      const dekWrapped = b64urlDecode(oh.dek_wrapped);
      const headerIv = b64urlDecode(oh.header_iv);
      const headerCt = b64urlDecode(oh.header_ct);
      const wrapKey = hkdfSha256(UMK, enc.encode('hkdf:wrap:v3'), 32);
      const aadWrap = concatBytes(enc.encode('wrap:v3'), assetId);
      const dek = await aesGcmDecryptRaw(wrapKey, wrapIv, aadWrap, dekWrapped);
      const aadHeader = concatBytes(enc.encode('header:v3'), assetId);
      const headerPlainBytes = await aesGcmDecryptRaw(dek, headerIv, aadHeader, headerCt);
      const hp = JSON.parse(dec.decode(headerPlainBytes));
      const chunkCount = hp.total_chunks >>> 0;
      // Trailer MAC re-compute
      const dekPhys = hkdfSha256(dek, enc.encode('hkdf:dek:phys:v3'), 32);
      let macState: any = new Uint8Array(0);
      const macUpdate = (data: Bytes) => { macState = hmac(sha256, dekPhys, concatBytes(macState, data)) as unknown as Uint8Array; };
      const out = new Uint8Array(hp.orig_size >>> 0);
      let outOff = 0;
      for (let idx = 0; idx < chunkCount; idx++) {
        const clen = (buf[off]<<24)|(buf[off+1]<<16)|(buf[off+2]<<8)|buf[off+3]; off += 4;
        const ct = buf.subarray(off, off+clen); off += clen;
        macUpdate(writeU32BE(clen)); macUpdate(ct);
        const iv = addToIv(baseIv, idx);
        const aad = aadForChunk(assetId, idx, idx === chunkCount - 1);
        const plain = await aesGcmDecryptRaw(dek, iv, aad, ct);
        out.set(plain, outOff); outOff += plain.length;
      }
      const tagMagic = dec.decode(buf.subarray(off, off+4)); off += 4; if (tagMagic !== 'TAG3') throw new Error('Bad trailer magic');
      off += 2; // reserved
      const tlen = (buf[off]<<8)|buf[off+1]; off += 2; if (tlen !== 32) throw new Error('Bad tag len');
      const tag = buf.subarray(off, off+tlen); off += tlen;
      const expected = hmac(sha256, dekPhys, macState);
      if (expected.length !== tag.length || !expected.every((v: number, i: number) => v === tag[i])) throw new Error('Trailer HMAC mismatch');
      // Optional: verify asset_id matches HMAC(userKey, plaintext)
      const mac2 = hmac(sha256, userKey, out).subarray(0, 16);
      if (!mac2.every((v: number, i: number)=>v===assetId[i])) throw new Error('asset_id mismatch');
      (self as any).postMessage({ ok: true, kind: 'v3-decrypted', container: out.buffer } as any, [out.buffer]);
      return;
    }
    if (msg.type === 'decrypt-v3-with-smk') {
      const SMK = hexToBytes(msg.smkHex);
      const userKey = enc.encode(msg.encryptedByUserIdUtf8);
      const buf = new Uint8Array(msg.container);
      if (buf.length < 10 + 4 + 16 + 4) throw new Error('Container too small');
      let off = 0;
      const eq = (a: Bytes, b: string) => dec.decode(a) === b;
      if (!eq(buf.subarray(0,4), 'PAE3')) throw new Error('Bad magic'); off += 4;
      const version = buf[off++]; if (version !== 0x03) throw new Error('Unsupported version');
      const flags = buf[off++]; const hasTrailer = (flags & 0x01) !== 0;
      const hlen = (buf[off]<<24)|(buf[off+1]<<16)|(buf[off+2]<<8)|buf[off+3]; off += 4;
      const headerBytes = buf.subarray(off, off+hlen); off += hlen;
      if (!hasTrailer) throw new Error('Missing trailer');
      const trailerLen = 4 + 2 + 2 + 32; // TAG3 + reserved + len + tag(32)
      const trailerPos = buf.length - trailerLen;
      if (trailerPos <= off) throw new Error('Invalid trailer position');
      const oh = JSON.parse(dec.decode(headerBytes));
      if (oh.v !== 3) throw new Error('Header v != 3');
      const assetId = b64urlDecode(oh.asset_id);
      const baseIv = b64urlDecode(oh.base_iv);
      // Override wrap values from sidecar
      const wrapIv = b64urlDecode(msg.overrideWrap.wrap_iv_b64);
      const dekWrapped = b64urlDecode(msg.overrideWrap.dek_wrapped_b64);
      const headerIv = b64urlDecode(oh.header_iv);
      const headerCt = b64urlDecode(oh.header_ct);
      const wrapKey = hkdfSha256(SMK, enc.encode('hkdf:wrap:v3'), 32);
      const aadWrap = concatBytes(enc.encode('wrap:v3'), assetId);
      const dek = await aesGcmDecryptRaw(wrapKey, wrapIv, aadWrap, dekWrapped);
      const aadHeader = concatBytes(enc.encode('header:v3'), assetId);
      const headerPlainBytes = await aesGcmDecryptRaw(dek, headerIv, aadHeader, headerCt);
      const hp = JSON.parse(dec.decode(headerPlainBytes));
      const chunkCount = hp.total_chunks >>> 0;
      const dekPhys = hkdfSha256(dek, enc.encode('hkdf:dek:phys:v3'), 32);
      let macState: any = new Uint8Array(0);
      const macUpdate = (data: Bytes) => { macState = hmac(sha256, dekPhys, concatBytes(macState, data)) as unknown as Uint8Array; };
      const out = new Uint8Array(hp.orig_size >>> 0);
      let outOff = 0;
      for (let idx = 0; idx < chunkCount; idx++) {
        const clen = (buf[off]<<24)|(buf[off+1]<<16)|(buf[off+2]<<8)|buf[off+3]; off += 4;
        const ct = buf.subarray(off, off+clen); off += clen;
        macUpdate(writeU32BE(clen)); macUpdate(ct);
        const iv = addToIv(baseIv, idx);
        const aad = aadForChunk(assetId, idx, idx === chunkCount - 1);
        const plain = await aesGcmDecryptRaw(dek, iv, aad, ct);
        out.set(plain, outOff); outOff += plain.length;
      }
      const tagMagic = dec.decode(buf.subarray(off, off+4)); off += 4; if (tagMagic !== 'TAG3') throw new Error('Bad trailer magic');
      off += 2; // reserved
      const tlen = (buf[off]<<8)|buf[off+1]; off += 2; if (tlen !== 32) throw new Error('Bad tag len');
      const tag = buf.subarray(off, off+tlen); off += tlen;
      const expected = hmac(sha256, dekPhys, macState);
      if (expected.length !== tag.length || !expected.every((v: number, i: number) => v === tag[i])) throw new Error('Trailer HMAC mismatch');
      // Integrity against owner's user_id
      const mac2 = hmac(sha256, userKey, out).subarray(0, 16);
      if (!mac2.every((v: number, i: number)=>v===assetId[i])) throw new Error('asset_id mismatch');
      (self as any).postMessage({ ok: true, kind: 'v3-decrypted', container: out.buffer } as any, [out.buffer]);
      return;
    }
    if (msg.type === 'rekey-wrap-for-smk') {
      const UMK = hexToBytes(msg.umkHex);
      const SMK = hexToBytes(msg.smkHex);
      const buf = new Uint8Array(msg.container);
      if (buf.length < 10 + 4 + 16 + 4) throw new Error('Container too small');
      let off = 0;
      const eq = (a: Bytes, b: string) => dec.decode(a) === b;
      if (!eq(buf.subarray(0,4), 'PAE3')) throw new Error('Bad magic'); off += 4;
      const version = buf[off++]; if (version !== 0x03) throw new Error('Unsupported version');
      const _flags = buf[off++];
      const hlen = (buf[off]<<24)|(buf[off+1]<<16)|(buf[off+2]<<8)|buf[off+3]; off += 4;
      const headerBytes = buf.subarray(off, off+hlen);
      const oh = JSON.parse(dec.decode(headerBytes));
      if (oh.v !== 3) throw new Error('Header v != 3');
      const assetId = b64urlDecode(oh.asset_id);
      const wrapIvOld = b64urlDecode(oh.wrap_iv);
      const dekWrappedOld = b64urlDecode(oh.dek_wrapped);
      const wrapKeyOld = hkdfSha256(UMK, enc.encode('hkdf:wrap:v3'), 32);
      const aadWrap = concatBytes(enc.encode('wrap:v3'), assetId);
      const dek = await aesGcmDecryptRaw(wrapKeyOld, wrapIvOld, aadWrap, dekWrappedOld);
      const wrapKeyNew = hkdfSha256(SMK, enc.encode('hkdf:wrap:v3'), 32);
      const wrapIvNew = randomBytes(12);
      const dekWrappedNew = await aesGcmEncryptRaw(wrapKeyNew, wrapIvNew, aadWrap, dek);
      (self as any).postMessage({ ok: true, kind: 'wrap-rekeyed', wrap_iv_b64: b64urlEncode(wrapIvNew), dek_wrapped_b64: b64urlEncode(dekWrappedNew) } as any);
      return;
    }
    (self as any).postMessage({ ok: false, error: 'Unknown request' } as E2EEWorkerResponse);
  } catch (e: any) {
    (self as any).postMessage({ ok: false, error: e?.message || String(e) } as E2EEWorkerResponse);
  }
};

function hexToBytes(hex: string): Bytes {
  const s = hex.startsWith('0x') || hex.startsWith('0X') ? hex.slice(2) : hex;
  if (s.length % 2 !== 0) throw new Error('Odd hex length');
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i*2, i*2+2), 16);
  return out;
}

// Minimal Base58 encoder for asset_id (using Bitcoin alphabet)
const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function base58Encode(bytes: Bytes): string {
  if (bytes.length === 0) return '';
  const digits: number[] = [0];
  for (let i = 0; i < bytes.length; i++) {
    let carry = bytes[i];
    for (let j = 0; j < digits.length; j++) {
      const x = (digits[j] << 8) + carry;
      digits[j] = x % 58;
      carry = Math.floor(x / 58);
    }
    while (carry > 0) { digits.push(carry % 58); carry = Math.floor(carry / 58); }
  }
  let zeros = 0; for (let i = 0; i < bytes.length && bytes[i] === 0; i++) zeros++;
  const out: string[] = [];
  for (let k = 0; k < zeros; k++) out.push('1');
  for (let i = digits.length - 1; i >= 0; i--) out.push(ALPHABET[digits[i]]);
  return out.join('') || '1';
}
