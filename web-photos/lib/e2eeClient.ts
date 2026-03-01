import { useE2EEStore } from '@/lib/stores/e2ee';

type EncryptResult = { container: ArrayBuffer; asset_id_b58: string; outer_header_b64: string };

export async function encryptV3WithWorker(
  umkHex: string,
  userIdUtf8: string,
  bytes: ArrayBuffer,
  metadata: Record<string, any>,
  chunkSize?: number,
): Promise<EncryptResult> {
  return new Promise((resolve, reject) => {
    try {
      const worker = new Worker(new URL('../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
      worker.onmessage = (ev: MessageEvent) => {
        const data = ev.data || {};
        if (data?.ok && data.kind === 'v3-encrypted') {
          try { worker.terminate(); } catch {}
          resolve({ container: data.container, asset_id_b58: data.asset_id_b58, outer_header_b64: data.outer_header_b64 });
          return;
        }
        if (data?.ok === false) {
          try { worker.terminate(); } catch {}
          reject(new Error(data?.error || 'encrypt-v3 failed'));
        }
      };
      worker.onerror = (e) => { try { worker.terminate(); } catch {}; reject(e.error || new Error(String(e.message||e))); };
      worker.postMessage({ type: 'encrypt-v3', umkHex, userIdUtf8, bytes, metadata, chunkSize });
    } catch (e) { reject(e); }
  });
}

export async function fileToArrayBuffer(f: Blob): Promise<ArrayBuffer> {
  return await f.arrayBuffer();
}

export async function generateImageThumb(file: File, maxSide = 1024, quality = 0.85): Promise<Blob> {
  const bmp = await createImageBitmap(file);
  const { width: w, height: h } = bmp;
  const scale = w >= h ? (maxSide / w) : (maxSide / h);
  const tw = Math.max(1, Math.round(w * scale));
  const th = Math.max(1, Math.round(h * scale));
  const canvas = document.createElement('canvas');
  canvas.width = tw; canvas.height = th;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('Canvas 2D unavailable');
  ctx.drawImage(bmp, 0, 0, tw, th);
  const blob: Blob = await new Promise((resolve, reject) => {
    canvas.toBlob((b) => b ? resolve(b) : reject(new Error('toBlob failed')), 'image/jpeg', quality);
  });
  try { bmp.close(); } catch {}
  return blob;
}

export async function generateVideoThumb(file: File, atPct = 0.5, maxSide = 1024, quality = 0.85): Promise<Blob> {
  const url = URL.createObjectURL(file);
  try {
    const video = document.createElement('video');
    video.src = url; video.crossOrigin = 'anonymous'; video.muted = true; video.playsInline = true;
    await video.play().catch(() => {});
    await new Promise<void>((resolve) => { video.onloadedmetadata = () => resolve(); });
    const t = Math.min(Math.max(0.0, (video.duration || 0) * atPct), Math.max(0, (video.duration || 0) - 0.001));
    await new Promise<void>((resolve) => { const handler = () => { video.removeEventListener('seeked', handler); resolve(); }; video.addEventListener('seeked', handler); video.currentTime = isFinite(t) ? t : 0; });
    const w = video.videoWidth || 640; const h = video.videoHeight || 480;
    const scale = w >= h ? (maxSide / w) : (maxSide / h);
    const tw = Math.max(1, Math.round(w * scale));
    const th = Math.max(1, Math.round(h * scale));
    const canvas = document.createElement('canvas');
    canvas.width = tw; canvas.height = th;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('Canvas 2D unavailable');
    ctx.drawImage(video, 0, 0, tw, th);
    const blob: Blob = await new Promise((resolve, reject) => {
      canvas.toBlob((b) => b ? resolve(b) : reject(new Error('toBlob failed')), 'image/jpeg', quality);
    });
    return blob;
  } finally {
    try { URL.revokeObjectURL(url); } catch {}
  }
}

export function umkToHex(): string | null {
  const st = useE2EEStore.getState();
  const umk = st.umk;
  if (!umk) return null;
  let hex = '';
  for (let i = 0; i < umk.length; i++) hex += umk[i].toString(16).padStart(2, '0');
  return hex;
}

