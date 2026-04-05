'use client';

import React from 'react';
import { useE2EEStore } from '@/lib/stores/e2ee';
import Uppy from '@uppy/core';
import Dashboard from '@uppy/dashboard';
import Tus from '@uppy/tus';
import '@uppy/dashboard/dist/style.min.css';
import { useAuthStore } from '@/lib/stores/auth';
import { useUploadDebugStore } from '@/lib/stores/uploadDebug';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import type { Album } from '@/lib/types/photo';
import AlbumPickerDialog from '@/components/albums/AlbumPickerDialog';
import { TreePine, X as XIcon } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { PinDialog } from '@/components/security/PinDialog';
import { UnlockModal } from '@/components/security/UnlockModal';

const BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function base58Encode(bytes: Uint8Array): string {
  if (bytes.length === 0) return '';
  const digits: number[] = [0];
  for (let i = 0; i < bytes.length; i++) {
    let carry = bytes[i];
    for (let j = 0; j < digits.length; j++) {
      const x = (digits[j] << 8) + carry;
      digits[j] = x % 58;
      carry = Math.floor(x / 58);
    }
    while (carry > 0) {
      digits.push(carry % 58);
      carry = Math.floor(carry / 58);
    }
  }
  let zeros = 0;
  for (let i = 0; i < bytes.length && bytes[i] === 0; i++) zeros++;
  const out: string[] = [];
  for (let i = 0; i < zeros; i++) out.push('1');
  for (let i = digits.length - 1; i >= 0; i--) out.push(BASE58_ALPHABET[digits[i]]);
  return out.join('') || '1';
}

async function computeAssetIdB58(blob: Blob, userId: string): Promise<string | null> {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle || typeof subtle.importKey !== 'function' || typeof subtle.sign !== 'function') {
    return null;
  }
  if (!userId) return null;
  const keyData = new TextEncoder().encode(userId);
  const key = await subtle.importKey('raw', keyData, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const bytes = await blob.arrayBuffer();
  const mac = new Uint8Array(await subtle.sign('HMAC', key, bytes));
  return base58Encode(mac.slice(0, 16));
}

export function UploadDashboardModal({ open, onClose, onComplete, moderationEnabled, isOwner }: { open: boolean; onClose: () => void; onComplete?: () => void; moderationEnabled?: boolean; isOwner?: boolean }) {
  const { token } = useAuthStore();
  const uppyRef = React.useRef<any>(null);
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const onCloseRef = React.useRef(onClose);
  const onCompleteRef = React.useRef(onComplete);
  const moderationEnabledRef = React.useRef(moderationEnabled);
  const isOwnerRef = React.useRef(isOwner);
  const tokenRef = React.useRef(token);
  const toastRef = React.useRef(toast);

  // Album selection state (persisted)
  const [pickerOpen, setPickerOpen] = React.useState(false);
  const [selectedAlbumId, setSelectedAlbumId] = React.useState<number | undefined>(undefined);
  const selectedAlbumIdRef = React.useRef<number | undefined>(undefined);

  // Load albums (for picker)
  const { data: albums, isError: albumsError, isFetching: albumsFetching, refetch: refetchAlbums } = useQuery<Album[]>({
    queryKey: ['albums'],
    queryFn: () => photosApi.getAlbums(),
    staleTime: 60_000,
    enabled: open, // only when modal is open
  });

  const selectedAlbum = React.useMemo(() => (albums || []).find(a => a.id === selectedAlbumId), [albums, selectedAlbumId]);
  // E2EE (locked upload) toggle
  const [lockedUpload, setLockedUpload] = React.useState<boolean>(() => {
    try { return localStorage.getItem('bulkUpload.locked') === '1'; } catch { return false; }
  });
  const lockedUploadRef = React.useRef(lockedUpload);
  const e2ee = useE2EEStore();
  const isUnlocked = e2ee.isUnlocked;
  const canEncrypt = e2ee.canEncrypt;

  // Track HEIC→JPEG conversion/encryption progress for locked uploads
  const heicIdsRef = React.useRef<Set<string>>(new Set());
  const heicDoneIdsRef = React.useRef<Set<string>>(new Set());
  const [heicTotal, setHeicTotal] = React.useState<number>(0);
  const [heicDone, setHeicDone] = React.useState<number>(0);

  // PIN dialog state for enabling locked uploads
  const [pinOpen, setPinOpen] = React.useState(false);
  const [pinMode, setPinMode] = React.useState<'verify'|'set'>('verify');
  const pinResolverRef = React.useRef<((ok: boolean) => void) | null>(null);

  const ensurePinVerified = React.useCallback(async (): Promise<boolean> => {
    // Skip for unauthenticated/public uploads
    if (!token) return true;
    try {
      const st: any = await photosApi.getPinStatus();
      if (!st?.is_set) setPinMode('set');
      else if (!st?.verified) setPinMode('verify');
      else return true;
      setPinOpen(true);
      return await new Promise<boolean>((resolve) => { pinResolverRef.current = resolve; });
    } catch {
      return false;
    }
  }, [token]);

  // Ensure E2EE UMK is unlocked in this session; if an envelope exists, open Unlock modal
  const [unlockOpen, setUnlockOpen] = React.useState(false);
  const unlockResolverRef = React.useRef<((ok: boolean) => void) | null>(null);
  const ensureUnlocked = React.useCallback(async (): Promise<boolean> => {
    if (!token) return true;
    if (useE2EEStore.getState().umk) return true;
    try { if (!useE2EEStore.getState().envelope) await useE2EEStore.getState().loadEnvelope(); } catch {}
    if (!useE2EEStore.getState().envelope) {
      try { toast({ title: 'PIN required', description: 'Set your PIN in Settings → Security, then unlock to enable locked uploads.', variant: 'destructive' }); } catch {}
      return false;
    }
    // Envelope freshness: if server envelope updated_at differs from last-seen, force typed unlock
    try {
      const res = await (await import('@/lib/api/crypto')).cryptoApi.getEnvelope();
      const updatedAt = res.updated_at || null;
      const lastSeen = (typeof localStorage !== 'undefined') ? (localStorage.getItem('e2ee.last_envelope_updated_at') || null) : null;
      if (updatedAt && lastSeen && updatedAt !== lastSeen) {
        setUnlockOpen(true);
        const ok = await new Promise<boolean>((resolve) => { unlockResolverRef.current = resolve; });
        if (ok) {
          try { localStorage.setItem('e2ee.last_envelope_updated_at', updatedAt); } catch {}
        }
        return ok;
      }
    } catch {}
    setUnlockOpen(true);
    return await new Promise<boolean>((resolve) => { unlockResolverRef.current = resolve; });
  }, [token, toast]);

  React.useEffect(() => { onCloseRef.current = onClose; }, [onClose]);
  React.useEffect(() => { onCompleteRef.current = onComplete; }, [onComplete]);
  React.useEffect(() => { moderationEnabledRef.current = moderationEnabled; }, [moderationEnabled]);
  React.useEffect(() => { isOwnerRef.current = isOwner; }, [isOwner]);
  React.useEffect(() => { tokenRef.current = token; }, [token]);
  React.useEffect(() => { toastRef.current = toast; }, [toast]);
  React.useEffect(() => { selectedAlbumIdRef.current = selectedAlbumId; }, [selectedAlbumId]);
  React.useEffect(() => { lockedUploadRef.current = lockedUpload; }, [lockedUpload]);

  // Initialize selectedAlbumId from localStorage when opening
  React.useEffect(() => {
    if (!open) return;
    try {
      const raw = localStorage.getItem('bulkUpload.selectedAlbumId');
      if (raw) {
        const n = Number(raw);
        if (!Number.isNaN(n)) setSelectedAlbumId(n);
      }
    } catch {}
  }, [open]);

  // Validate persisted album against current list; clear if missing/deleted
  React.useEffect(() => {
    if (!open) return;
    if (!albums || selectedAlbumId == null) return;
    const exists = (albums || []).some(a => a.id === selectedAlbumId);
    if (!exists) {
      setSelectedAlbumId(undefined);
      try { localStorage.removeItem('bulkUpload.selectedAlbumId'); } catch {}
      toast({ title: 'Album not found', description: 'It may have been deleted. Continuing without album.', variant: 'destructive' });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [albums]);

  // While open, prevent background scroll (block the home screen)
  React.useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { document.body.style.overflow = prev; };
  }, [open]);

  // Apply albumId meta to all current files whenever selection changes
  React.useEffect(() => {
    const uppy = uppyRef.current;
    if (!uppy) return;
    try {
      const files = uppy.getFiles ? uppy.getFiles() : [];
      for (const f of files) {
        const currentMeta = f?.meta || {};
        const albumIdStr = (selectedAlbumId != null) ? String(selectedAlbumId) : '';
        const base: any = { ...currentMeta, albumId: albumIdStr };
        // Only set locked metadata when the client can encrypt
        if (lockedUpload && isUnlocked && canEncrypt) {
          base.locked = '1';
          base.crypto_version = '3';
          base.kind = 'orig';
        }
        uppy.setFileMeta(f.id, base);
      }
      // Also set global meta for future files (best-effort)
      const albumIdStr = (selectedAlbumId != null) ? String(selectedAlbumId) : '';
      const g: any = { albumId: albumIdStr };
      if (lockedUpload && isUnlocked && canEncrypt) {
        g.locked = '1'; g.crypto_version = '3'; g.kind = 'orig';
      }
      if (uppy.setMeta) uppy.setMeta(g);
    } catch {}
  }, [selectedAlbumId, lockedUpload, isUnlocked, canEncrypt]);

  React.useEffect(() => {
    if (!open) return;
    // Reset HEIC/prepare counters each time the modal opens
    try { heicIdsRef.current.clear(); heicDoneIdsRef.current.clear(); } catch {}
    setHeicTotal(0); setHeicDone(0);
    const uppy: any = new (Uppy as any)({ autoProceed: false, allowMultipleUploadBatches: true });
    // If running on a public link page (identified by URL params), always include
    // the public link context in TUS metadata so uploads are associated with the link
    // even if the viewer happens to be logged in in this browser.
    if (typeof window !== 'undefined') {
      try {
        const url = new URL(window.location.href);
        const lid = url.searchParams.get('l');
        const key = url.searchParams.get('k');
        const p = url.searchParams.get('pin');
        if (lid && key) {
          // Pull viewer session and display name from localStorage (best-effort)
          let sid = '';
          let dname = '';
          try { sid = localStorage.getItem('publicViewerSessionId') || ''; } catch {}
          try { dname = localStorage.getItem('publicDisplayName') || ''; } catch {}
          if (uppy.setMeta) uppy.setMeta({ public_link_id: lid, public_link_key: key, public_link_pin: p || '', viewer_session_id: sid, uploader_display_name: dname });
        }
      } catch {}
    }

    // Assign a shared content_id for files that appear to be Live Photo pairs
    const cidByStem = new Map<string, string>();
    const normalizeStem = (name: string) => {
      const base = name.replace(/^.*\//, '').replace(/\.[^.]+$/, '').trim();
      const up = base.toUpperCase();
      return up.startsWith('IMG_E') ? `IMG_${up.slice(5)}` : up;
    };
    const genCID = () => `cid-${Date.now().toString(36)}-${Math.random().toString(36).slice(2,8)}`;
    uppy.on('file-added', (file: any) => {
      try {
        // Additional validation: Check if file is actually a photo or video
        const fileType = file?.type?.toLowerCase() || '';
        const fileName = file?.name?.toLowerCase() || '';

        // Check if it's an image or video by MIME type or extension
        const isImage = fileType.startsWith('image/') ||
                       /\.(jpg|jpeg|png|gif|bmp|webp|svg|heic|heif|tiff|tif)$/i.test(fileName);
        const isVideo = fileType.startsWith('video/') ||
                       /\.(mp4|avi|mov|wmv|flv|mkv|webm|m4v|mpg|mpeg|3gp|3g2)$/i.test(fileName);

        if (!isImage && !isVideo) {
          // Remove non-photo/video files
          uppy.removeFile(file.id);
          toastRef.current?.({
            title: "File type not supported",
            description: `Only photos and videos are allowed. "${file.name}" was removed.`,
            variant: "destructive"
          });
          return;
        }

        const stem = normalizeStem(file?.name || '');
        if (!stem) return;
        let cid = cidByStem.get(stem);
        if (!cid) { cid = genCID(); cidByStem.set(stem, cid); }
        const albumIdStr = (selectedAlbumIdRef.current != null) ? String(selectedAlbumIdRef.current) : '';
        uppy.setFileMeta(file.id, { content_id: cid, filename: file?.name, albumId: albumIdStr });
      } catch {}
      // If locked uploads are enabled and UMK is unlocked, encrypt immediately on add.
      (async () => {
        try {
          const e2 = require('@/lib/stores/e2ee');
          const st = e2.useE2EEStore.getState();
          const canDo = lockedUploadRef.current && st.isUnlocked && st.canEncrypt;
          if (!canDo) return;
          if (file?.meta?.alreadyEncrypted) return;
          const { encryptV3WithWorker, fileToArrayBuffer, generateImageThumb, generateVideoThumb, umkToHex } = await import('@/lib/e2eeClient');
          const { getCaptureEpochSeconds } = await import('@/lib/capture');
          const { maybeConvertHeicToJpeg } = await import('@/lib/heic');
          const umkHex = umkToHex(); if (!umkHex) return;
          const user = require('@/lib/stores/auth').useAuthStore.getState().user;
          const userIdUtf8 = user?.user_id || '';
          let originalBlob: File = file.data;
          let isVideo = /^video\//i.test(originalBlob.type);
          // Extract capture time from original before any conversion
          const exifEpoch = await getCaptureEpochSeconds(originalBlob);
          // For locked HEIC uploads in browsers without HEIC support, convert to JPEG before encryption
          let blob: File = originalBlob;
          const isHeic = !isVideo && (((originalBlob.type||'').toLowerCase().includes('heic')) || /\.(heic|heif)$/i.test(file?.name||''));
          if (isHeic) {
            // Count conversions so the Upload button can be hidden until ready
            if (!heicIdsRef.current.has(file.id)) { heicIdsRef.current.add(file.id); setHeicTotal((t) => t + 1); }
          }
          if (!isVideo) {
            const conv = await maybeConvertHeicToJpeg(originalBlob as Blob, file?.name);
            if (conv.converted) {
              blob = new File([conv.blob], conv.filename || (file?.name || 'image.jpg'), { type: 'image/jpeg' });
            }
          }
          const bytes = await fileToArrayBuffer(blob);
          // Prefer EXIF DateTimeOriginal (from original); fallback to file.lastModified
          const lm = exifEpoch ? new Date(exifEpoch * 1000) : ((originalBlob as any).lastModified ? new Date((originalBlob as any).lastModified) : new Date());
          const y = lm.getUTCFullYear(); const m = String(lm.getUTCMonth()+1).padStart(2,'0'); const d = String(lm.getUTCDate()).padStart(2,'0');
          let width = 0, height = 0, duration_s = 0;
          if (!isVideo) {
            try { const bmp = await createImageBitmap(blob); width = bmp.width; height = bmp.height; try { bmp.close(); } catch {} } catch {}
          }
          const metadata = {
            capture_ymd: `${y}-${m}-${d}`,
            size_kb: Math.max(1, Math.round(blob.size / 1024)),
            width, height, orientation: 1, is_video: isVideo ? 1 : 0, duration_s, mime_hint: (!isVideo ? 'image/jpeg' : (blob.type || 'video/mp4')), kind: 'orig',
          };
          if (exifEpoch && exifEpoch > 0) { (metadata as any).created_at = String(exifEpoch); }
          const enc = await encryptV3WithWorker(umkHex, userIdUtf8, bytes, metadata, 1024*1024);
          console.info('[LOCKED-UPLOAD] file-added: encrypted orig', { name: file?.name, asset_id_b58: enc.asset_id_b58, size: bytes.byteLength, isVideo });
          const encBlob = new Blob([enc.container], { type: 'application/octet-stream' });
          const albumIdStr = file?.meta?.albumId || '';
          uppy.setFileState(file.id, {
            data: encBlob,
            name: `${enc.asset_id_b58}.pae3`,
            size: encBlob.size,
            meta: {
              ...file.meta,
              locked: '1', crypto_version: '3', kind: 'orig', asset_id_b58: enc.asset_id_b58, alreadyEncrypted: true,
              albumId: albumIdStr,
              capture_ymd: metadata.capture_ymd, created_at: exifEpoch ? String(exifEpoch) : undefined,
              size_kb: String(metadata.size_kb), width: String(width||0), height: String(height||0), orientation: '1', is_video: isVideo ? '1' : '0', duration_s: String(duration_s||0), mime_hint: metadata.mime_hint,
            }
          });
          // Generate encrypted thumbnail now and queue as a new file
          let tBlob: Blob | null = null;
          if (!isVideo) { try { tBlob = await generateImageThumb(blob); } catch {} }
          else { try { tBlob = await generateVideoThumb(blob, 0.5); } catch {} }
          if (tBlob) {
            const tBytes = await fileToArrayBuffer(tBlob);
            const tEnc = await encryptV3WithWorker(umkHex, userIdUtf8, tBytes, { ...metadata, kind: 'thumb' }, 256*1024);
            try {
              await uppy.addFile({
                name: `${enc.asset_id_b58}_t.pae3`,
                type: 'application/octet-stream',
                data: new Blob([tEnc.container], { type: 'application/octet-stream' }),
                meta: {
                  locked: '1', crypto_version: '3', kind: 'thumb', asset_id_b58: enc.asset_id_b58, alreadyEncrypted: true,
                  albumId: albumIdStr,
                  capture_ymd: metadata.capture_ymd, created_at: exifEpoch ? String(exifEpoch) : undefined,
                  size_kb: String(Math.max(1, Math.round(tBlob.size/1024))), width: String(width||0), height: String(height||0), orientation: '1', is_video: isVideo ? '1' : '0', duration_s: String(duration_s||0), mime_hint: 'image/jpeg',
                },
              });
              console.info('[LOCKED-UPLOAD] file-added: queued encrypted thumb', { asset_id_b58: enc.asset_id_b58, tSize: tBytes.byteLength });
            } catch (e) {
              console.warn('[LOCKED-UPLOAD] file-added: failed to add thumb file', e);
            }
          }
          if (isHeic) {
            if (!heicDoneIdsRef.current.has(file.id)) {
              heicDoneIdsRef.current.add(file.id);
              setHeicDone((d) => d + 1);
            }
          }
          // Mark this HEIC conversion as tracked (in case of late detection)
          if (isHeic && !heicIdsRef.current.has(file.id)) {
            heicIdsRef.current.add(file.id);
            setHeicTotal((t) => t + 1);
            if (!heicDoneIdsRef.current.has(file.id)) setHeicDone((d) => d + 1);
          }
        } catch (e) {
          console.warn('[LOCKED-UPLOAD] file-added encryption failed', e);
          // Do not let the UI stall: count this HEIC item as "processed" so the user can proceed
          try {
            const e2 = require('@/lib/stores/e2ee');
            const st = e2.useE2EEStore.getState();
            const canDo = lockedUploadRef.current && st.isUnlocked && st.canEncrypt;
            // Only touch counters for locked HEIC flow
            if (canDo) {
              const originalBlob: File = file.data;
              const isVideo = /^video\//i.test(originalBlob.type);
              const isHeic = !isVideo && (((originalBlob.type||'').toLowerCase().includes('heic')) || /\.(heic|heif)$/i.test(file?.name||''));
              if (isHeic && !heicDoneIdsRef.current.has(file.id)) {
                heicDoneIdsRef.current.add(file.id);
                setHeicDone((d) => d + 1);
              }
            }
          } catch {}
        }
      })();
    });
    // Keep counts consistent on removal
    uppy.on('file-removed', (file: any) => {
      const fid = file?.id;
      if (!fid) return;
      let decTotal = false;
      if (heicIdsRef.current.has(fid)) { heicIdsRef.current.delete(fid); decTotal = true; }
      if (decTotal) setHeicTotal((t) => Math.max(0, t - 1));
      if (heicDoneIdsRef.current.has(fid)) {
        heicDoneIdsRef.current.delete(fid);
        setHeicDone((d) => Math.max(0, d - 1));
      }
    });
    // Define allowed file types for photos and videos
    const allowedFileTypes = [
      // Image types
      '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.heic', '.heif', '.tiff', '.tif',
      'image/*',
      // Video types
      '.mp4', '.avi', '.mov', '.wmv', '.flv', '.mkv', '.webm', '.m4v', '.mpg', '.mpeg', '.3gp', '.3g2',
      'video/*'
    ];

    const dashOpts: any = {
      inline: true,
      target: '#uppy-dashboard-mount',
      proudlyDisplayPoweredByUppy: false,
      showProgressDetails: true,
      note: 'Only photos and videos are supported',
      hideUploadButton: false,
      restrictions: {
        allowedFileTypes: allowedFileTypes,
      },
    };
    uppy.use(Dashboard as any, dashOpts);
    uppy.use(Tus as any, {
      endpoint: '/files/',
      chunkSize: 10 * 1024 * 1024,
      retryDelays: [0, 1000, 3000, 5000],
      headers: () => {
        const currentToken = tokenRef.current;
        return currentToken ? { Authorization: `Bearer ${currentToken}` } : undefined;
      },
      onBeforeRequest: (req: any) => {
        const currentToken = tokenRef.current;
        if (!currentToken) {
          try {
            const xhr: any = req?.getUnderlyingObject?.();
            if (xhr && 'withCredentials' in xhr) { xhr.withCredentials = true; }
          } catch {}
        }
        // Debug entry for request
        try {
          const add = useUploadDebugStore.getState().add;
          const method = req?.getMethod?.();
          const url = req?.getURL?.();
          add({ id: `${Date.now()}-${Math.random().toString(36).slice(2,8)}`, ts: Date.now(), source: 'uppy-tus', method, url, reqHeaders: { Authorization: currentToken ? 'Bearer …' : undefined } });
        } catch {}
      },
      onAfterResponse: (req: any, res: any) => {
        try {
          const add = useUploadDebugStore.getState().add;
          const method = req?.getMethod?.();
          const url = req?.getURL?.();
          const status = res?.getStatus?.();
          const rh = (name: string) => { try { return res?.getHeader?.(name) || undefined; } catch { return undefined; } };
          add({ id: `${Date.now()}-${Math.random().toString(36).slice(2,8)}`, ts: Date.now(), source: 'uppy-tus', method, url, status, resHeaders: {
            'Tus-Resumable': rh('Tus-Resumable'),
            'Tus-Version': rh('Tus-Version'),
            'Tus-Extension': rh('Tus-Extension'),
            'Tus-Max-Size': rh('Tus-Max-Size'),
            'Upload-Offset': rh('Upload-Offset'),
            'Upload-Length': rh('Upload-Length'),
            'Location': rh('Location'),
          }});
        } catch {}
      },
    } as any);

    uppy.on('complete', () => {
      try { onCompleteRef.current?.(); } catch {}
      try {
        if (!tokenRef.current && moderationEnabledRef.current && !isOwnerRef.current) {
          toastRef.current?.({ title: 'Upload submitted', description: 'Your uploads will be visible after the link owner approves them.', variant: 'default' });
        }
      } catch {}
      // Close after a short delay to let uploads finish UI updates
      setTimeout(() => onCloseRef.current?.(), 500);
    });

    uppyRef.current = uppy;
    // Preprocessor to encrypt locked uploads client-side (orig + thumb)
    const preproc = async (fileIDs: string[]) => {
      console.debug('[LOCKED-UPLOAD] preprocessor start', { fileIDs: [...fileIDs] });
      const e2 = require('@/lib/stores/e2ee');
      const st = e2.useE2EEStore.getState();
      const canDo = lockedUploadRef.current && st.isUnlocked && st.canEncrypt;
      if (!canDo) { console.debug('[LOCKED-UPLOAD] preprocessor skip: canDo=false', { lockedUpload: lockedUploadRef.current, isUnlocked: st.isUnlocked, canEncrypt: st.canEncrypt }); return; }
      // Ensure envelope freshness prior to encrypting
      try {
        const res = await (await import('@/lib/api/crypto')).cryptoApi.getEnvelope();
        const updatedAt = res.updated_at || null;
        const lastSeen = (typeof localStorage !== 'undefined') ? (localStorage.getItem('e2ee.last_envelope_updated_at') || null) : null;
        if (updatedAt && lastSeen && updatedAt !== lastSeen) {
          setUnlockOpen(true);
          const ok = await new Promise<boolean>((resolve) => { unlockResolverRef.current = resolve; });
          if (!ok) return;
          try { localStorage.setItem('e2ee.last_envelope_updated_at', updatedAt); } catch {}
        }
      } catch {}
      const { encryptV3WithWorker, fileToArrayBuffer, generateImageThumb, generateVideoThumb, umkToHex } = await import('@/lib/e2eeClient');
      const umkHex = umkToHex();
      if (!umkHex) { console.warn('[LOCKED-UPLOAD] UMK missing at preproc time; skipping'); return; }
      const user = require('@/lib/stores/auth').useAuthStore.getState().user;
      const userIdUtf8 = user?.user_id || '';
      for (const id of fileIDs) {
        const f = uppy.getFile(id);
        if (!f || f?.meta?.alreadyEncrypted) continue;
        const blob: File = f.data;
        const isVideo = /^video\//i.test(blob.type);
        try {
          const bytes = await fileToArrayBuffer(blob);
          const lm = (blob as any).lastModified ? new Date((blob as any).lastModified) : new Date();
          const y = lm.getUTCFullYear(); const m = String(lm.getUTCMonth()+1).padStart(2,'0'); const d = String(lm.getUTCDate()).padStart(2,'0');
          let width = 0, height = 0, duration_s = 0;
          if (!isVideo) {
            try { const bmp = await createImageBitmap(blob); width = bmp.width; height = bmp.height; try { bmp.close(); } catch {} } catch {}
          }
          const metadata = {
            capture_ymd: `${y}-${m}-${d}`,
            size_kb: Math.max(1, Math.round(blob.size / 1024)),
            width, height, orientation: 1, is_video: isVideo ? 1 : 0, duration_s, mime_hint: blob.type || (isVideo ? 'video/mp4' : 'image/jpeg'), kind: 'orig',
          };
          const enc = await encryptV3WithWorker(umkHex, userIdUtf8, bytes, metadata, 1024*1024);
          console.debug('[LOCKED-UPLOAD] encrypted orig', { name: f?.name, asset_id_b58: enc.asset_id_b58, size: bytes.byteLength, isVideo });
          const encBlob = new Blob([enc.container], { type: 'application/octet-stream' });
          const albumIdStr = f?.meta?.albumId || '';
          uppy.setFileState(id, {
            data: encBlob,
            name: `${enc.asset_id_b58}.pae3`,
            size: encBlob.size,
            meta: {
              ...f.meta,
              locked: '1', crypto_version: '3', kind: 'orig', asset_id_b58: enc.asset_id_b58, alreadyEncrypted: true,
              albumId: albumIdStr,
              capture_ymd: metadata.capture_ymd, size_kb: String(metadata.size_kb), width: String(width||0), height: String(height||0), orientation: '1', is_video: isVideo ? '1' : '0', duration_s: String(duration_s||0), mime_hint: metadata.mime_hint,
            }
          });
          // Add encrypted thumbnail
          let tBlob: Blob | null = null;
          if (!isVideo) tBlob = await generateImageThumb(blob);
          else {
            try { tBlob = await generateVideoThumb(blob, 0.5); } catch {}
          }
          if (tBlob) {
            const tBytes = await fileToArrayBuffer(tBlob);
            const tEnc = await encryptV3WithWorker(umkHex, userIdUtf8, tBytes, { ...metadata, kind: 'thumb' }, 256*1024);
            try {
              await uppy.addFile({
                name: `${enc.asset_id_b58}_t.pae3`,
                type: 'application/octet-stream',
                data: new Blob([tEnc.container], { type: 'application/octet-stream' }),
                meta: {
                  locked: '1', crypto_version: '3', kind: 'thumb', asset_id_b58: enc.asset_id_b58, alreadyEncrypted: true,
                  albumId: albumIdStr,
                  capture_ymd: metadata.capture_ymd, size_kb: String(Math.max(1, Math.round(tBlob.size/1024))), width: String(width||0), height: String(height||0), orientation: '1', is_video: isVideo ? '1' : '0', duration_s: String(duration_s||0), mime_hint: 'image/jpeg',
                },
              });
              console.debug('[LOCKED-UPLOAD] added thumb', { asset_id_b58: enc.asset_id_b58, tSize: tBytes.byteLength });
            } catch (e) {
              console.error('[LOCKED-UPLOAD] failed to add thumb file', e);
            }
          }
        } catch (e) {
          console.warn('[Uppy] Encryption failed for file', f?.name, e);
          try { toastRef.current?.({ title: 'Encryption failed', description: `Uploaded plaintext for ${f?.name || 'file'}`, variant: 'destructive' }); } catch {}
        }
      }
    };
    uppy.addPreProcessor(preproc);

    // Pre-upload existence check: resolve asset_id for each file and skip ones already fully backed up.
    const preflightSkipExisting = async (fileIDs: string[]) => {
      try {
        const auth = useAuthStore.getState();
        const userId = auth?.user?.user_id || '';
        if (!userId) return;

        const idByFile = new Map<string, string>();
        for (const id of fileIDs) {
          const f: any = uppy.getFile(id);
          if (!f) continue;
          let aid: string | null = (f?.meta?.asset_id_b58 as string | undefined) || (f?.meta?.asset_id as string | undefined) || null;
          if (!aid) {
            const data = f.data as Blob | undefined;
            if (!data || typeof Blob === 'undefined' || !(data instanceof Blob)) continue;
            aid = await computeAssetIdB58(data, userId);
            if (aid) uppy.setFileMeta(id, { asset_id: aid });
          }
          if (aid) idByFile.set(id, aid);
        }
        if (idByFile.size === 0) return;

        const ids = Array.from(new Set(Array.from(idByFile.values())));
        const headers: Record<string, string> = { 'Content-Type': 'application/json' };
        if (tokenRef.current) headers.Authorization = `Bearer ${tokenRef.current}`;
        const res = await fetch('/api/photos/exists', {
          method: 'POST',
          headers,
          credentials: 'same-origin',
          body: JSON.stringify({ asset_ids: ids }),
        });
        if (!res.ok) return;
        const j = await res.json().catch(() => ({} as any));
        const present = new Set<string>(Array.isArray(j?.present_asset_ids) ? j.present_asset_ids : []);
        if (present.size === 0) return;

        let skipped = 0;
        for (const [fid, aid] of Array.from(idByFile.entries())) {
          if (!present.has(aid)) continue;
          try { uppy.removeFile(fid); skipped++; } catch {}
        }
        if (skipped > 0) {
          toastRef.current?.({
            title: 'Skipped existing uploads',
            description: `${skipped} file${skipped === 1 ? '' : 's'} already exist on the server.`,
          });
        }
      } catch (e) {
        try { console.warn('[UPLOAD-PREFLIGHT] exists check failed', e); } catch {}
      }
    };
    uppy.addPreProcessor(preflightSkipExisting);

    return () => {
      try { uppy?.close?.({ reason: 'unmount' }); } catch {}
      try { uppy?.destroy?.(); } catch {}
      if (uppyRef.current === uppy) uppyRef.current = null;
    };
  }, [open]);

  // Dynamically toggle the Dashboard upload button based on conversion progress
  React.useEffect(() => {
    const uppy = uppyRef.current;
    if (!uppy) return;
    const dash = uppy.getPlugin('Dashboard');
    if (dash?.setOptions) {
      dash.setOptions({ hideUploadButton: (lockedUpload && (heicTotal > 0) && (heicDone < heicTotal)) });
    }
  }, [heicTotal, heicDone, lockedUpload]);

  // Persist selection changes
  React.useEffect(() => {
    try {
      if (selectedAlbumId != null) localStorage.setItem('bulkUpload.selectedAlbumId', String(selectedAlbumId));
      else localStorage.removeItem('bulkUpload.selectedAlbumId');
    } catch {}
  }, [selectedAlbumId]);

  if (!open) return null;

  return (
    <>
    <div className="fixed inset-0 z-[90]">
      {/* Backdrop: solid color distinct from dialog */}
      <div className="absolute inset-0 bg-[hsl(var(--overlay))]" onClick={onClose} />
      <div className="absolute inset-0 grid place-items-center p-4">
        <div className="w-full max-w-3xl bg-card text-foreground border border-border rounded-lg shadow-2xl">
          <div className="px-4 py-3 border-b border-border font-medium flex items-center justify-between gap-3">
            <div>Bulk Upload</div>
            <div className="flex items-center gap-3">
              {selectedAlbum ? (
                <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full border border-border bg-muted text-sm" title={selectedAlbum.name}>
                  <span className="truncate max-w-[180px]">{selectedAlbum.name}</span>
                  <button
                    className="w-5 h-5 grid place-items-center rounded hover:bg-background/60"
                    aria-label="Clear album"
                    onClick={() => setSelectedAlbumId(undefined)}
                    title="Clear"
                  >
                    <XIcon className="w-3.5 h-3.5" />
                  </button>
                </span>
              ) : null}
              <label className="inline-flex items-center gap-2 text-sm mr-2" title={canEncrypt ? '' : 'Client encryption not ready'}>
                <input
                  type="checkbox"
                  className="accent-primary"
                  checked={lockedUpload}
                  onChange={async (e) => {
                    const v = e.currentTarget.checked;
                    if (v) {
                      const okPin = await ensurePinVerified();
                      if (!okPin) {
                        try { e.currentTarget.checked = false; } catch {}
                        setLockedUpload(false);
                        try { localStorage.setItem('bulkUpload.locked', '0'); } catch {}
                        return;
                      }
                      const okUnlock = await ensureUnlocked();
                      if (!okUnlock) {
                        try { e.currentTarget.checked = false; } catch {}
                        setLockedUpload(false);
                        try { localStorage.setItem('bulkUpload.locked', '0'); } catch {}
                        return;
                      }
                    }
                    setLockedUpload(v);
                    try { localStorage.setItem('bulkUpload.locked', v ? '1' : '0'); } catch {}
                  }}
                  disabled={!canEncrypt}
                />
                <span>Locked?</span>
              </label>
              <button
                className="w-8 h-8 grid place-items-center rounded hover:bg-muted"
                aria-label="Select album"
                title="Select album"
                onClick={async () => {
                  // Ensure albums are fresh; handle network failure with a toast and allow retry
                  try {
                    const res = await refetchAlbums();
                    if ((res as any)?.error) {
                      toast({ title: 'Failed to load albums', description: 'Check connection and try again.' , variant: 'destructive' });
                      return;
                    }
                  } catch {
                    toast({ title: 'Failed to load albums', description: 'Check connection and try again.' , variant: 'destructive' });
                    return;
                  }
                  setPickerOpen(true);
                }}
              >
                <TreePine className="w-5 h-5" />
              </button>
              {/* Close icon button with extra leading space to separate from Album button */}
              <button
                className="w-8 h-8 grid place-items-center rounded hover:bg-muted ml-4"
                aria-label="Close"
                title="Close"
                onClick={onClose}
              >
                <XIcon className="w-5 h-5" />
              </button>
            </div>
          </div>
          <div className="p-3">
            {/* HEIC conversion progress for locked uploads */}
            {lockedUpload && heicTotal > 0 && heicDone < heicTotal ? (
              <div className="mb-3">
                <div className="text-sm text-muted-foreground mb-1">Preparing encrypted files… ({heicDone}/{heicTotal})</div>
                <div className="w-full h-2 bg-muted rounded overflow-hidden"><div className="h-2 bg-primary" style={{ width: `${Math.round((heicDone/heicTotal)*100)}%` }} /></div>
              </div>
            ) : null}
            <div id="uppy-dashboard-mount" />
            {!canEncrypt && (
              <p className="text-xs text-muted-foreground mt-2">Locked uploads require client-side encryption support. This is initializing.</p>
            )}
          </div>
          {/* Bottom action bar removed — Close is now in the top-right */}
          <AlbumPickerDialog
            open={pickerOpen}
            onClose={() => setPickerOpen(false)}
            onConfirm={(id) => {
              setSelectedAlbumId(id);
              setPickerOpen(false);
              // Invalidate albums for freshness (position counts may change on create)
              try { queryClient.invalidateQueries({ queryKey: ['albums'] }); } catch {}
            }}
            albums={albums || []}
            initialSelectedId={selectedAlbumId}
            showIncludeSubtree={false}
          />
        </div>
      </div>
    </div>
    {/* PIN dialog for enabling locked uploads */}
    <PinDialog
      open={pinOpen}
      mode={pinMode}
      onClose={() => { setPinOpen(false); pinResolverRef.current?.(false); pinResolverRef.current = null; }}
      onVerified={() => { setPinOpen(false); pinResolverRef.current?.(true); pinResolverRef.current = null; }}
      description={pinMode === 'verify' ? 'Enter your 8‑character PIN to enable locked uploads.' : undefined}
    />
    <UnlockModal
      open={unlockOpen}
      onClose={() => {
        setUnlockOpen(false);
        const ok = !!useE2EEStore.getState().umk;
        unlockResolverRef.current?.(ok);
        unlockResolverRef.current = null;
      }}
    />
    </>
  );
}
