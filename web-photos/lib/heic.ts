// Lightweight HEIC → JPEG conversion helper used only in the browser.
// Dynamically imports the decoder on demand to keep initial bundles small.

export async function maybeConvertHeicToJpeg(input: Blob | File, filename?: string): Promise<{ blob: Blob; filename: string; converted: boolean }> {
  const name = (filename || (input as any)?.name || '').toLowerCase();
  const type = (input as Blob).type || '';
  const looksHeic = type === 'image/heic' || type === 'image/heif' || /\.(heic|heif)$/.test(name);
  if (!looksHeic) {
    return { blob: input, filename: filename || (name || 'image'), converted: false };
  }
  // Convert to JPEG via heic2any (WASM libheif under the hood)
  try {
    const mod = await import('heic2any');
    const heic2any: any = (mod as any)?.default || mod;
    const out = await heic2any({ blob: input, toType: 'image/jpeg', quality: 0.95 });
    const blob: Blob = Array.isArray(out) ? new Blob(out, { type: 'image/jpeg' }) : (out as Blob);
    const newName = (name || 'image').replace(/\.(heic|heif)$/i, '.jpg') || 'image.jpg';
    return { blob, filename: newName, converted: true };
  } catch (e) {
    // If conversion fails, return original blob; the caller may handle failure.
    return { blob: input, filename: filename || (name || 'image'), converted: false };
  }
}

