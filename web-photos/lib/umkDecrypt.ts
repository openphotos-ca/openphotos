// Small helper to decrypt PAE3 containers using UMK via the worker.

export async function decryptV3WithUmk(container: ArrayBuffer, umkHex: string, userIdUtf8: string): Promise<ArrayBuffer> {
  return new Promise((resolve, reject) => {
    try {
      const worker = new Worker(new URL('../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
      worker.onmessage = (ev: MessageEvent) => {
        const data = (ev as any).data || {};
        if (data?.ok && data.kind === 'v3-decrypted') {
          try { worker.terminate(); } catch {}
          resolve(data.container as ArrayBuffer);
          return;
        }
        if (data?.ok === false) {
          try { worker.terminate(); } catch {}
          reject(new Error(data?.error || 'decrypt-v3 failed'));
        }
      };
      worker.onerror = (e: any) => { try { worker.terminate(); } catch {}; reject(e?.error || new Error(String(e?.message || e))); };
      worker.postMessage({ type: 'decrypt-v3', umkHex, userIdUtf8, container }, [container as unknown as ArrayBuffer]);
    } catch (e) { reject(e); }
  });
}

