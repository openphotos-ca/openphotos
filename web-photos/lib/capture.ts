// Extract capture timestamp (epoch seconds) from an image/video Blob when possible.
// Tries EXIF/QuickTime DateTimeOriginal/CreateDate using exifr, with graceful fallback.

export async function getCaptureEpochSeconds(blob: Blob): Promise<number | null> {
  try {
    // Load exifr lazily to keep base bundle small
    const exifr: any = (await import('exifr')).default || (await import('exifr'));
    // exifr.parse returns an object with Date fields when possible
    // For HEIC/HEIF it may still work depending on browser support
    const out = await exifr.parse(blob as any, { tiff: true, ifd0: true, exif: true, icc: false, xmp: false, iptc: false });
    if (out) {
      const dt: Date | undefined = (out.DateTimeOriginal as Date) || (out.CreateDate as Date) || (out.ModifyDate as Date);
      if (dt && typeof dt.getTime === 'function') {
        const s = Math.floor(dt.getTime() / 1000);
        if (s > 0) return s;
      }
    }
  } catch {}
  return null;
}

