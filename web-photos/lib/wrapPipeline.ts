// Owner-side helper to produce SMK wraps for locked assets without full decrypt.
// For each asset_id, fetch the PAE3 container, extract DEK using UMK, and wrap it with SMK.

export async function rekeyWrapForSmk(umkHex: string, smkHex: string, container: ArrayBuffer): Promise<{ wrap_iv_b64: string; dek_wrapped_b64: string }> {
  return new Promise((resolve, reject) => {
    try {
      const worker = new Worker(new URL('../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
      worker.onmessage = (ev: MessageEvent) => {
        const data = ev.data || {};
        if (data?.ok && data.kind === 'wrap-rekeyed') {
          try { worker.terminate(); } catch {}
          resolve({ wrap_iv_b64: data.wrap_iv_b64, dek_wrapped_b64: data.dek_wrapped_b64 });
          return;
        }
        if (data?.ok === false) {
          try { worker.terminate(); } catch {}
          reject(new Error(data?.error || 'rekey-wrap failed'));
        }
      };
      worker.onerror = (e) => { try { worker.terminate(); } catch {}; reject(e.error || new Error(String(e.message||e))); };
      worker.postMessage({ type: 'rekey-wrap-for-smk', umkHex, smkHex, container });
    } catch (e) { reject(e); }
  });
}

export async function generateWrapsForAssets(
  umkHex: string,
  smkHex: string,
  ownerUserFetch: (assetId: string, variant: 'thumb' | 'orig') => Promise<ArrayBuffer>,
  assetIds: string[],
  variant?: 'orig' | 'thumb' | 'both',
): Promise<Array<{ asset_id: string; variant: 'orig' | 'thumb'; wrap_iv_b64: string; dek_wrapped_b64: string }>> {
  const out: Array<{ asset_id: string; variant: 'orig' | 'thumb'; wrap_iv_b64: string; dek_wrapped_b64: string }> = [];
  for (const aid of assetIds) {
    const mode = variant || 'both';
    // Thumbs first to make thumbnails viewable ASAP
    if (mode === 'both' || mode === 'thumb') {
      try {
        const bufT = await ownerUserFetch(aid, 'thumb');
        const wt = await rekeyWrapForSmk(umkHex, smkHex, bufT);
        out.push({ asset_id: aid, variant: 'thumb', ...wt });
      } catch {}
    }
    if (mode === 'both' || mode === 'orig') {
      try {
        const buf = await ownerUserFetch(aid, 'orig');
        const w = await rekeyWrapForSmk(umkHex, smkHex, buf);
        out.push({ asset_id: aid, variant: 'orig', ...w });
      } catch {}
    }
  }
  return out;
}
