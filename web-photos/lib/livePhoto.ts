'use client';

import { useAuthStore } from '@/lib/stores/auth';

function liveWebLog(level: 'info' | 'warn' | 'error', message: string, extra?: Record<string, unknown>) {
  try {
    const fn = level === 'info' ? console.info : (level === 'warn' ? console.warn : console.error);
    if (extra) fn(`[LIVE-WEB] ${message}`, extra);
    else fn(`[LIVE-WEB] ${message}`);
  } catch {}
}

export function isChromiumBrowser(): boolean {
  if (typeof navigator === 'undefined') return false;
  const ua = (navigator.userAgent || '').toLowerCase();
  return (ua.includes('chrome/') || ua.includes('chromium') || ua.includes('edg/')) && !ua.includes('opr/');
}

export function isFirefoxBrowser(): boolean {
  if (typeof navigator === 'undefined') return false;
  const ua = (navigator.userAgent || '').toLowerCase();
  return ua.includes('firefox/');
}

export function shouldPreferCompatLiveVideo(): boolean {
  return isChromiumBrowser() || isFirefoxBrowser();
}

export function getLivePhotoVideoUrl(
  assetId: string,
  options?: { preferCompat?: boolean },
): string {
  const preferCompat = options?.preferCompat ?? shouldPreferCompatLiveVideo();
  if (!preferCompat) return `/api/live/${encodeURIComponent(assetId)}`;
  return `/api/live/${encodeURIComponent(assetId)}?compat=1`;
}

export async function prepareLivePhotoVideoSource(
  assetId: string,
  options?: { preferCompat?: boolean },
): Promise<string | null> {
  const token = useAuthStore.getState().token;
  const headers = token
    ? ({ Authorization: `Bearer ${token}` } as Record<string, string>)
    : undefined;
  const preferCompat = options?.preferCompat ?? shouldPreferCompatLiveVideo();
  const url = getLivePhotoVideoUrl(assetId, { preferCompat });
  liveWebLog('info', 'fetch live source start', { assetId, hasToken: !!token, preferCompat, url });
  const resp = await fetch(url, { headers });
  if (!resp.ok) {
    liveWebLog('warn', 'fetch live source failed', { assetId, status: resp.status });
    return null;
  }
  const contentType = (resp.headers.get('content-type') || 'video/mp4').toLowerCase();
  const liveSource = resp.headers.get('x-live-source') || '';
  const liveCompat = resp.headers.get('x-live-compat') || '';
  const ab = await resp.arrayBuffer();
  liveWebLog('info', 'fetch live source success', {
    assetId,
    status: resp.status,
    contentType,
    bytes: ab.byteLength,
    liveSource,
    liveCompat,
  });
  const blob = new Blob([ab], {
    type: contentType.startsWith('video/') ? contentType : 'video/mp4',
  });
  return URL.createObjectURL(blob);
}

export async function prepareLockedLivePhotoVideoSource(assetId: string): Promise<string | null> {
  const { umkToHex } = await import('@/lib/e2eeClient');
  const umkHex = umkToHex();
  if (!umkHex) {
    liveWebLog('warn', 'locked fallback skipped: missing UMK', { assetId });
    try { (await import('@/lib/logger')).logger.debug('[E2EE] No UMK for locked live playback'); } catch {}
    return null;
  }

  // Fetch locked live container and decrypt in worker
  const token = useAuthStore.getState().token;
  const headers = token ? ({ Authorization: `Bearer ${token}` } as Record<string, string>) : undefined;
  liveWebLog('info', 'fetch locked live source start', { assetId, hasToken: !!token });
  const resp = await fetch(`/api/live-locked/${encodeURIComponent(assetId)}`, { headers });
  if (!resp.ok) {
    liveWebLog('warn', 'fetch locked live source failed', { assetId, status: resp.status });
    return null;
  }
  const ab = await resp.arrayBuffer();
  liveWebLog('info', 'fetch locked live source success', { assetId, status: resp.status, bytes: ab.byteLength });

  // Decrypt via worker
  // @ts-ignore
  const worker = new Worker(new URL('../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
  const plain: ArrayBuffer = await new Promise((resolve, reject) => {
    worker.onmessage = (ev: MessageEvent) => {
      const d: any = ev.data;
      if (d?.ok && d.kind === 'v3-decrypted') {
        try { worker.terminate(); } catch {}
        resolve(d.container);
      } else if (d?.ok === false) {
        try { worker.terminate(); } catch {}
        reject(new Error(d.error || 'decrypt failed'));
      }
    };
    worker.onerror = (er: any) => {
      try { worker.terminate(); } catch {}
      reject(er?.error || new Error(String(er?.message || er)));
    };
    const userId = useAuthStore.getState().user?.user_id || '';
    worker.postMessage({ type: 'decrypt-v3', umkHex, userIdUtf8: userId, container: ab }, [ab]);
  });

  const blob = new Blob([plain], { type: 'video/quicktime' });
  liveWebLog('info', 'locked live source decrypted', { assetId, bytes: plain.byteLength });
  return URL.createObjectURL(blob);
}
