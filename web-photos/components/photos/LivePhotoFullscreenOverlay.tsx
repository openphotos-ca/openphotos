'use client';

import { useEffect, useRef, useState } from 'react';
import { Play } from 'lucide-react';

import {
  getLivePhotoVideoUrl,
  prepareLivePhotoVideoSource,
  prepareLockedLivePhotoVideoSource,
} from '@/lib/livePhoto';

type Phase = 'loading' | 'playing' | 'ended' | 'error';

function liveWebLog(level: 'info' | 'warn' | 'error', message: string, extra?: Record<string, unknown>) {
  try {
    const fn = level === 'info' ? console.info : (level === 'warn' ? console.warn : console.error);
    if (extra) fn(`[LIVE-WEB] ${message}`, extra);
    else fn(`[LIVE-WEB] ${message}`);
  } catch {}
}

export function LivePhotoFullscreenOverlay({ assetId }: { assetId: string }) {
  const [phase, setPhase] = useState<Phase>('loading');
  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  const [showVideo, setShowVideo] = useState(true);
  const [awaitingGesture, setAwaitingGesture] = useState(false);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const currentAssetRef = useRef<string>(assetId);
  const blobUrlRef = useRef<string | null>(null);
  const triedLockedRef = useRef<boolean>(false);
  const triedBlobRef = useRef<boolean>(false);
  const startedRef = useRef<boolean>(false);
  const sourceKindRef = useRef<'blob' | 'direct' | 'locked_blob' | null>(null);
  const retryDirectRef = useRef<boolean>(false);
  const playbackStartAtMsRef = useRef<number>(0);

  useEffect(() => {
    currentAssetRef.current = assetId;
    liveWebLog('info', 'overlay mount/reset', { assetId });
    setPhase('loading');
    setVideoUrl(null);
    setShowVideo(true);
    setAwaitingGesture(false);
    triedLockedRef.current = false;
    triedBlobRef.current = false;
    startedRef.current = false;
    sourceKindRef.current = null;
    retryDirectRef.current = false;
    playbackStartAtMsRef.current = 0;

    if (blobUrlRef.current) {
      try { URL.revokeObjectURL(blobUrlRef.current); } catch {}
      blobUrlRef.current = null;
    }

    // Start with direct compat streaming on all browsers for fastest first frame.
    // Blob fallback is still available on playback errors.
    liveWebLog('info', 'overlay using direct compat live source', { assetId });
    sourceKindRef.current = 'direct';
    setVideoUrl(getLivePhotoVideoUrl(assetId, { preferCompat: true }));

    return () => {
      if (blobUrlRef.current) {
        try { URL.revokeObjectURL(blobUrlRef.current); } catch {}
        blobUrlRef.current = null;
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [assetId]);

  // Autoplay once when URL becomes available.
  useEffect(() => {
    if (!videoUrl || !showVideo) return;
    const v = videoRef.current;
    if (!v) return;

    startedRef.current = false;
    playbackStartAtMsRef.current = 0;
    let cancelled = false;
    let watchdog1: any = null;
    let watchdog2: any = null;

    const tryPlay = async (label: string) => {
      if (cancelled) return;
      try {
        if (!startedRef.current) {
          try { v.currentTime = 0; } catch {}
        }
        const p = v.play();
        if (p && typeof (p as any).then === 'function') await p;
        setAwaitingGesture(false);
      } catch (err) {
        liveWebLog('warn', 'autoplay attempt failed', {
          assetId,
          label,
          error: err instanceof Error ? err.message : String(err),
        });
        // Autoplay can still be blocked on some setups. Keep video visible and
        // offer an explicit user-gesture play button instead of hiding it.
        if (!cancelled) {
          setPhase('ended');
          setAwaitingGesture(true);
        }
      }
    };

    const onPlaying = () => {
      const ct = Number.isFinite(v.currentTime) ? v.currentTime : 0;
      const dur = Number.isFinite(v.duration) ? v.duration : 0;
      if (!playbackStartAtMsRef.current) playbackStartAtMsRef.current = Date.now();
      liveWebLog('info', 'video playing', { assetId, currentTime: ct, duration: dur });
      startedRef.current = true;
      setAwaitingGesture(false);
      setPhase('playing');
    };
    const onPlay = () => {
      if (!playbackStartAtMsRef.current) playbackStartAtMsRef.current = Date.now();
      setAwaitingGesture(false);
      setPhase('playing');
    };

    // Kick once now; once more when data is ready.
    tryPlay('init').catch(() => {});
    const onLoaded = () => { tryPlay('loaded').catch(() => {}); };
    v.addEventListener('loadeddata', onLoaded, { once: true });
    v.addEventListener('canplay', onLoaded, { once: true });
    v.addEventListener('play', onPlay);
    v.addEventListener('playing', onPlaying);

    // Watchdog: if we're still pinned at the first frame, retry play; then give up and show still.
    watchdog1 = setTimeout(() => {
      if (cancelled) return;
      try {
        if (!startedRef.current && v.readyState >= 2 && (v.currentTime || 0) < 0.01) {
          tryPlay('watchdog1').catch(() => {});
        }
      } catch {}
    }, 900);
    watchdog2 = setTimeout(() => {
      if (cancelled) return;
      try {
        if (!startedRef.current && v.readyState >= 2 && (v.currentTime || 0) < 0.01) {
          setPhase('error');
          setAwaitingGesture(true);
        }
      } catch {}
    }, 2400);

    return () => {
      cancelled = true;
      if (watchdog1) clearTimeout(watchdog1);
      if (watchdog2) clearTimeout(watchdog2);
      v.removeEventListener('play', onPlay);
      v.removeEventListener('playing', onPlaying);
    };
  }, [videoUrl, showVideo]);

  const canReplay = phase === 'ended' || phase === 'error';

  return (
    <>
      {/* Video overlay (plays once, then hides to reveal the still beneath) */}
      {showVideo && videoUrl && (
        <video
          ref={videoRef}
          className="absolute inset-0 w-full h-full object-contain z-30"
          src={videoUrl}
          muted
          playsInline
          preload="auto"
          controls={false}
          autoPlay
          onClick={(e) => e.stopPropagation()}
          onEnded={() => {
            const v = videoRef.current;
            const currentTime = Number.isFinite(v?.currentTime) ? (v?.currentTime || 0) : 0;
            const duration = Number.isFinite(v?.duration) ? (v?.duration || 0) : 0;
            const elapsedMs = playbackStartAtMsRef.current
              ? (Date.now() - playbackStartAtMsRef.current)
              : 0;
            // Chrome can report currentTime ~= duration on a broken fast-end.
            // So also treat very short wall-clock playback as abnormal.
            const endedTooEarlyByTime = duration > 1 && currentTime < Math.max(0.25, duration * 0.2);
            const endedTooEarlyByWallClock = duration > 1 && elapsedMs > 0 && elapsedMs < Math.min(1200, duration * 500);
            const endedTooEarly = endedTooEarlyByTime || endedTooEarlyByWallClock;
            liveWebLog('info', 'video ended event', {
              assetId,
              currentTime,
              duration,
              elapsedMs,
              sourceKind: sourceKindRef.current,
              endedTooEarlyByTime,
              endedTooEarlyByWallClock,
            });
            if (
              endedTooEarly &&
              sourceKindRef.current === 'blob' &&
              !retryDirectRef.current &&
              currentAssetRef.current === assetId
            ) {
              retryDirectRef.current = true;
              liveWebLog('warn', 'ended too early on blob source; retrying direct source', {
                assetId,
                currentTime,
                duration,
                elapsedMs,
              });
              sourceKindRef.current = 'direct';
              playbackStartAtMsRef.current = 0;
              setPhase('loading');
              setAwaitingGesture(false);
              setVideoUrl(getLivePhotoVideoUrl(assetId, { preferCompat: true }));
              setShowVideo(true);
              return;
            }
            liveWebLog('info', 'video ended', { assetId });
            setPhase('ended');
            setShowVideo(false);
          }}
          onError={() => {
            const mediaErrorCode = videoRef.current?.error?.code ?? null;
            liveWebLog('warn', 'video element error', {
              assetId,
              source: videoUrl || '',
              mediaErrorCode,
              readyState: videoRef.current?.readyState ?? null,
            });
            // If direct source fails, try unlocked blob source once.
            if (sourceKindRef.current === 'direct' && !triedBlobRef.current) {
              triedBlobRef.current = true;
              liveWebLog('warn', 'direct source failed; trying blob source', { assetId });
              setPhase('loading');
              setShowVideo(false);
              prepareLivePhotoVideoSource(assetId, { preferCompat: true }).then((url) => {
                if (!url || currentAssetRef.current !== assetId) {
                  if (url?.startsWith('blob:')) {
                    try { URL.revokeObjectURL(url); } catch {}
                  }
                  liveWebLog('warn', 'blob fallback returned empty/expired source', { assetId });
                  if (triedLockedRef.current) {
                    setPhase('error');
                    setShowVideo(false);
                    return;
                  }
                  triedLockedRef.current = true;
                  liveWebLog('info', 'trying locked live fallback', { assetId });
                  prepareLockedLivePhotoVideoSource(assetId).then((lockedUrl) => {
                    if (!lockedUrl || currentAssetRef.current !== assetId) {
                      if (lockedUrl?.startsWith('blob:')) {
                        try { URL.revokeObjectURL(lockedUrl); } catch {}
                      }
                      setPhase('error');
                      setShowVideo(false);
                      return;
                    }
                    if (blobUrlRef.current) {
                      try { URL.revokeObjectURL(blobUrlRef.current); } catch {}
                    }
                    blobUrlRef.current = lockedUrl.startsWith('blob:') ? lockedUrl : null;
                    sourceKindRef.current = lockedUrl.startsWith('blob:') ? 'locked_blob' : 'direct';
                    setVideoUrl(lockedUrl);
                    setShowVideo(true);
                  }).catch(() => {
                    setPhase('error');
                    setShowVideo(false);
                  });
                  return;
                }
                if (blobUrlRef.current) {
                  try { URL.revokeObjectURL(blobUrlRef.current); } catch {}
                }
                blobUrlRef.current = url.startsWith('blob:') ? url : null;
                sourceKindRef.current = url.startsWith('blob:') ? 'blob' : 'direct';
                liveWebLog('info', 'overlay switched to blob source after direct failure', { assetId });
                setVideoUrl(url);
                setShowVideo(true);
              }).catch(() => {
                setPhase('error');
                setShowVideo(false);
              });
              return;
            }
            // If /api/live is locked (401) or unplayable, try the locked decrypt path once.
            if (triedLockedRef.current) {
              liveWebLog('warn', 'locked fallback already tried; giving up', { assetId });
              setPhase('error');
              setShowVideo(false);
              return;
            }
            triedLockedRef.current = true;
            liveWebLog('info', 'trying locked live fallback', { assetId });
            setPhase('loading');
            setShowVideo(false);
            prepareLockedLivePhotoVideoSource(assetId).then((url) => {
              if (!url || currentAssetRef.current !== assetId) {
                if (url?.startsWith('blob:')) {
                  try { URL.revokeObjectURL(url); } catch {}
                }
                liveWebLog('warn', 'locked fallback returned empty/expired source', { assetId });
                setPhase('error');
                setShowVideo(false);
                return;
              }
              if (blobUrlRef.current) {
                try { URL.revokeObjectURL(blobUrlRef.current); } catch {}
              }
              liveWebLog('info', 'locked fallback source ready', { assetId, blob: url.startsWith('blob:') });
              blobUrlRef.current = url.startsWith('blob:') ? url : null;
              sourceKindRef.current = url.startsWith('blob:') ? 'locked_blob' : 'direct';
              setVideoUrl(url);
              setShowVideo(true);
            }).catch(() => {
              liveWebLog('error', 'locked fallback failed', { assetId });
              setPhase('error');
              setShowVideo(false);
            });
          }}
        />
      )}

      {awaitingGesture && showVideo && videoUrl && (
        <button
          className="absolute bottom-4 left-1/2 -translate-x-1/2 bg-black/60 hover:bg-black/80 text-white px-3 py-2 rounded-full flex items-center gap-2 z-40 pointer-events-auto"
          onClick={(e) => {
            e.stopPropagation();
            playbackStartAtMsRef.current = 0;
            const v = videoRef.current;
            if (!v) return;
            try {
              const p = v.play();
              if (p && typeof (p as any).catch === 'function') {
                (p as any).catch((err: unknown) => {
                  liveWebLog('warn', 'manual play failed', {
                    assetId,
                    error: err instanceof Error ? err.message : String(err),
                  });
                });
              }
              liveWebLog('info', 'manual play requested', { assetId });
            } catch {}
          }}
          aria-label="Play Live Photo"
          title="Play Live Photo"
        >
          <Play className="w-4 h-4" />
          <span className="text-sm">Play Live</span>
        </button>
      )}

      {/* Preparing overlay (keep subtle so the still can be seen/loaded underneath) */}
      {phase === 'loading' && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 bg-black/50 text-white text-xs px-3 py-1.5 rounded-full z-40 pointer-events-none">
          Preparing Live Video…
        </div>
      )}

      {/* Replay control after the first playback */}
      {canReplay && videoUrl && !showVideo && (
        <button
          className="absolute bottom-4 left-1/2 -translate-x-1/2 bg-black/60 hover:bg-black/80 text-white px-3 py-2 rounded-full flex items-center gap-2 z-40 pointer-events-auto"
          onClick={(e) => {
            e.stopPropagation();
            setShowVideo(true);
            setPhase('loading');
          }}
          aria-label="Replay Live Photo"
          title="Replay Live Photo"
        >
          <Play className="w-4 h-4" />
          <span className="text-sm">Replay Live</span>
        </button>
      )}
    </>
  );
}
