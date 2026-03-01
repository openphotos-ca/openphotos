'use client';

import { useAuthStore } from '@/lib/stores/auth';

export function getLivePhotoVideoUrl(assetId: string): string {
  return `/api/live/${encodeURIComponent(assetId)}`;
}

export async function prepareLockedLivePhotoVideoSource(assetId: string): Promise<string | null> {
  const { umkToHex } = await import('@/lib/e2eeClient');
  const umkHex = umkToHex();
  if (!umkHex) {
    try { (await import('@/lib/logger')).logger.debug('[E2EE] No UMK for locked live playback'); } catch {}
    return null;
  }

  // Fetch locked live container and decrypt in worker
  const token = useAuthStore.getState().token;
  const headers = token ? ({ Authorization: `Bearer ${token}` } as Record<string, string>) : undefined;
  const resp = await fetch(`/api/live-locked/${encodeURIComponent(assetId)}`, { headers });
  if (!resp.ok) return null;
  const ab = await resp.arrayBuffer();

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
  return URL.createObjectURL(blob);
}
