'use client';

import { useEffect, useRef, useState } from 'react';
import { Play } from 'lucide-react';

import { getLivePhotoVideoUrl, prepareLockedLivePhotoVideoSource } from '@/lib/livePhoto';

type Phase = 'loading' | 'playing' | 'ended' | 'error';

export function LivePhotoFullscreenOverlay({ assetId }: { assetId: string }) {
  const [phase, setPhase] = useState<Phase>('loading');
  const [videoUrl, setVideoUrl] = useState<string | null>(null);
  const [showVideo, setShowVideo] = useState(true);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const currentAssetRef = useRef<string>(assetId);
  const blobUrlRef = useRef<string | null>(null);
  const triedLockedRef = useRef<boolean>(false);
  const startedRef = useRef<boolean>(false);

  useEffect(() => {
    currentAssetRef.current = assetId;
    setPhase('loading');
    setVideoUrl(getLivePhotoVideoUrl(assetId));
    setShowVideo(true);
    triedLockedRef.current = false;
    startedRef.current = false;

    if (blobUrlRef.current) {
      try { URL.revokeObjectURL(blobUrlRef.current); } catch {}
      blobUrlRef.current = null;
    }

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
      } catch {
        // Autoplay may be blocked; fall back to still.
        if (!cancelled) {
          setPhase('ended');
          setShowVideo(false);
        }
      }
    };

    const onPlaying = () => {
      startedRef.current = true;
      setPhase('playing');
    };
    const onPlay = () => { setPhase('playing'); };

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
          setShowVideo(false);
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
            setPhase('ended');
            setShowVideo(false);
          }}
          onError={() => {
            // If /api/live is locked (401) or unplayable, try the locked decrypt path once.
            if (triedLockedRef.current) {
              setPhase('error');
              setShowVideo(false);
              return;
            }
            triedLockedRef.current = true;
            setPhase('loading');
            setShowVideo(false);
            prepareLockedLivePhotoVideoSource(assetId).then((url) => {
              if (!url || currentAssetRef.current !== assetId) {
                if (url?.startsWith('blob:')) {
                  try { URL.revokeObjectURL(url); } catch {}
                }
                setPhase('error');
                setShowVideo(false);
                return;
              }
              if (blobUrlRef.current) {
                try { URL.revokeObjectURL(blobUrlRef.current); } catch {}
              }
              blobUrlRef.current = url.startsWith('blob:') ? url : null;
              setVideoUrl(url);
              setShowVideo(true);
            }).catch(() => {
              setPhase('error');
              setShowVideo(false);
            });
          }}
        />
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
