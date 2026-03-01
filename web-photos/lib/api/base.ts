export function resolveApiBaseUrl(baseUrl?: string): string {
  const raw = baseUrl || '/api';
  try {
    const isAbsolute = /^https?:\/\//i.test(raw);
    if (typeof window !== 'undefined' && isAbsolute) {
      const baked = new URL(raw);
      const current = window.location;
      const bakedIsLocal = baked.hostname === 'localhost' || baked.hostname === '127.0.0.1';
      const onDifferentHost = current && baked.hostname !== current.hostname;
      if (bakedIsLocal && onDifferentHost) {
        return '/api';
      }
    }
  } catch {}
  return raw;
}
