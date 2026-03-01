'use client';

import React, { useState, useCallback, useMemo } from 'react';
import { logger } from '@/lib/logger';
import { FixedSizeGrid as Grid } from 'react-window';
import { useInView } from 'react-intersection-observer';
import { Play, Check } from 'lucide-react';
import { AuthenticatedImage } from '@/components/ui/AuthenticatedImage';

import { Photo } from '@/lib/types/photo';
import { photosApi } from '@/lib/api/photos';

interface PhotoGridProps {
  photos: Photo[];
  selectedPhotos: string[];
  onPhotoClick: (photo: Photo) => void;
  onPhotoSelect: (assetId: string, selected: boolean) => void;
  onLoadMore?: () => void;
  hasMore?: boolean;
  isLoading?: boolean;
  containerWidth: number;
  containerHeight: number;
}

interface PhotoCardProps {
  photo: Photo;
  isSelected: boolean;
  onPhotoClick: (photo: Photo) => void;
  onPhotoSelect: (assetId: string, selected: boolean) => void;
  width: number;
  height: number;
  showLockedBadge?: boolean;
}

function PhotoCard({ 
  photo, 
  isSelected, 
  onPhotoClick, 
  onPhotoSelect, 
  width, 
  height,
  showLockedBadge
}: PhotoCardProps) {
  const [isHovered, setIsHovered] = useState(false);
  const [imageError, setImageError] = useState(false);
  const [videoRef, setVideoRef] = useState<HTMLVideoElement | null>(null);

  const handleMouseEnter = useCallback(() => {
    setIsHovered(true);
    if (photo.is_live_photo && videoRef) {
      videoRef.currentTime = 0;
      videoRef.play().catch(() => {
        // Ignore play errors
      });
    }
  }, [photo.is_live_photo, videoRef]);

  const handleMouseLeave = useCallback(() => {
    setIsHovered(false);
    if (photo.is_live_photo && videoRef) {
      videoRef.pause();
      videoRef.currentTime = 0;
    }
  }, [photo.is_live_photo, videoRef]);

  // Ensure playback triggers when the <video> ref becomes available while hovered
  React.useEffect(() => {
    if (isHovered && photo.is_live_photo && videoRef) {
      videoRef.currentTime = 0;
      videoRef.play().catch(() => {});
    }
  }, [isHovered, photo.is_live_photo, videoRef]);

  const handleClick = (e: React.MouseEvent) => {
    if (e.ctrlKey || e.metaKey || e.shiftKey) {
      e.preventDefault();
      onPhotoSelect(photo.asset_id, !isSelected);
    } else {
      onPhotoClick(photo);
    }
  };

  const handleSelectClick = (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    onPhotoSelect(photo.asset_id, !isSelected);
  };

  const formatDuration = (ms?: number) => {
    if (!ms || ms <= 0) return '';
    const total = Math.floor(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (n: number) => n.toString().padStart(2, '0');
    if (h > 0) return `${h}:${pad(m)}:${pad(s)}`;
    return `${m}:${pad(s)}`;
  };

  if (imageError) {
    return (
      <div 
        className="photo-card bg-gray-200 flex items-center justify-center"
        style={{ width: width - 8, height: height - 8, margin: 4 }}
      >
        <span className="text-gray-400 text-sm">{photo.locked ? '🔒 Locked — Unlock to view' : 'Failed to load'}</span>
      </div>
    );
  }

  return (
    <div 
      className={`photo-card relative cursor-pointer ${isSelected ? 'photo-card-selected' : ''}`}
      style={{ width: width - 8, height: height - 8, margin: 4 }}
      onClick={handleClick}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      {/* Main image */}
      <AuthenticatedImage
        assetId={photo.asset_id}
        alt={photo.filename}
        title={photo.filename}
        className="absolute inset-0 w-full h-full object-cover"
        onError={() => setImageError(true)}
      />

      {/* Live photo video overlay */}
      {photo.is_live_photo && isHovered && !photo.locked && (
        <video
          ref={setVideoRef}
          className={`absolute inset-0 w-full h-full object-cover transition-opacity duration-200 ${
            isHovered ? 'opacity-100' : 'opacity-0'
          }`}
          muted
          loop
          playsInline
          autoPlay
          onLoadedData={() => {
            if (videoRef) {
              videoRef.play().catch(() => {});
            }
          }}
          preload="none"
          src={`/api/live/${encodeURIComponent(photo.asset_id)}`}
        />
      )}

      {/* Overlays */}
      <div className="absolute inset-0 bg-black bg-opacity-0 hover:bg-opacity-20 transition-all duration-200 pointer-events-none" />

      {/* Live photo indicator */}
      {photo.is_live_photo && (
        <div className="live-photo-indicator">
          <Play className="w-3 h-3" fill="white" />
        </div>
      )}

      {/* Video indicator */}
      {photo.is_video && (
        <>
          <div className="absolute top-2 left-2 bg-black bg-opacity-70 rounded-full p-1">
            <Play className="w-3 h-3 text-white" fill="white" />
          </div>
          <div className="absolute bottom-2 right-2 bg-black bg-opacity-70 text-white text-xs px-1.5 py-0.5 rounded">
            {formatDuration(photo.duration_ms)}
          </div>
        </>
      )}

      {/* Locked badge (when showing locked items) */}
      {showLockedBadge && photo.locked && (
        <div className="absolute bottom-2 right-2 bg-black bg-opacity-70 text-white text-xs px-1.5 py-0.5 rounded">
          🔒
        </div>
      )}

      {/* Screenshot indicator */}
      {photo.is_screenshot === 1 && (
        <div className="absolute top-2 left-2 bg-orange-500 text-white text-xs px-1 py-0.5 rounded">
          📱
        </div>
      )}

      {/* Selection checkbox */}
      <button
        className={`absolute top-2 right-2 w-6 h-6 rounded-full border-2 border-white flex items-center justify-center transition-all duration-200 ${
          isSelected
            ? 'bg-primary border-primary'
            : 'bg-black bg-opacity-30 hover:bg-opacity-50'
        } ${isHovered || isSelected ? 'opacity-100' : 'opacity-0'}`}
        onClick={handleSelectClick}
      >
        {isSelected && <Check className="w-4 h-4 text-white" />}
      </button>

      {/* Rating overlay (stars) – always mounted so local state persists */}
      <StarRatingOverlay assetId={photo.asset_id} initialRating={photo.rating} interactive={isHovered} />
    </div>
  );
}

function StarRatingOverlay({ assetId, initialRating, interactive }: { assetId: string; initialRating?: number | null; interactive?: boolean }) {
  const isUnrated = initialRating == null;
  const [editing, setEditing] = React.useState<boolean>(isUnrated);
  const [hoverN, setHoverN] = React.useState<number>(0);
  const [current, setCurrent] = React.useState<number | undefined>(initialRating == null ? undefined : initialRating);
  React.useEffect(()=>{ setCurrent(initialRating == null ? undefined : initialRating); }, [initialRating]);
  const solid = editing ? (hoverN || current || 0) : (current || 0);
  const onClick = async (n: number) => {
    try {
      setCurrent(n);
      await photosApi.updatePhotoRating(assetId, n);
      setEditing(false);
    } catch {
      // ignore
    }
  };
  const onClear = async () => {
    try {
      await photosApi.updatePhotoRating(assetId, null);
      setCurrent(undefined);
      setHoverN(0);
      setEditing(true); // stay editable so user can click a star immediately
    } catch {}
  };
  const onDouble = () => setEditing(true);
  const Star = ({ idx }: { idx: number }) => {
    const filled = solid >= idx;
    return (
      <button
        type="button"
        aria-label={`Rate ${idx} stars`}
        className={`w-5 h-5 inline-flex items-center justify-center ${canInteract ? 'cursor-pointer' : 'cursor-default'}`}
        onMouseEnter={() => { if (editing) setHoverN(idx); }}
        onFocus={() => { if (editing) setHoverN(idx); }}
        onMouseLeave={() => { if (editing) setHoverN(0); }}
        onClick={(e)=>{ e.stopPropagation(); if (canInteract && (editing || (current ?? 0) === 0)) onClick(idx); }}
        onDoubleClick={(e)=>{ e.stopPropagation(); onDouble(); }}
      >
        <span className={`${filled ? 'text-red-500' : 'text-red-500/60'}`} style={{fontSize: 18, lineHeight: 1}}>{filled ? '★' : '☆'}</span>
      </button>
    );
  };
  const canInteract = !!interactive;
  const visible = canInteract || ((current ?? 0) > 0);
  return (
    <div className={`absolute bottom-0 left-0 right-0 p-1 ${canInteract ? 'bg-black/40' : 'bg-transparent'} z-50 ${canInteract ? 'pointer-events-auto cursor-pointer' : 'pointer-events-none cursor-default'}`} title={assetId} onDoubleClick={(e)=>{ if (!canInteract) return; e.stopPropagation(); onDouble(); }}>
      <div className={`flex items-center justify-center gap-1 select-none ${visible ? '' : 'invisible'}`}>
        {[1,2,3,4,5].map(i => <Star key={i} idx={i} />)}
        {canInteract && (current != null && current > 0) ? (
          <button className="ml-2 px-1.5 py-0.5 text-xs rounded border border-border bg-background/60 hover:bg-background cursor-pointer" onClick={(e)=>{ e.stopPropagation(); onClear(); }} title="Clear rating">Clear</button>
        ) : null}
      </div>
    </div>
  );
}

export function PhotoGrid({
  photos,
  selectedPhotos,
  onPhotoClick,
  onPhotoSelect,
  onLoadMore,
  hasMore = false,
  isLoading = false,
  containerWidth,
  containerHeight,
}: PhotoGridProps) {
  const { ref: loadMoreRef, inView } = useInView({
    threshold: 0,
    triggerOnce: false,
  });

  const gridPhotos = useMemo(() => {
    return (photos || []).map((p: any, idx) => {
      if (!p || typeof p !== 'object') return null;
      const assetId = typeof p.asset_id === 'string' && p.asset_id.length > 0
        ? p.asset_id
        : (typeof p.id === 'number' ? String(p.id) : `invalid-${idx}`);
      return { ...p, asset_id: assetId } as Photo;
    }).filter(Boolean) as Photo[];
  }, [photos]);

  // Calculate grid dimensions
  const { columnCount, columnWidth, rowHeight } = useMemo(() => {
    const minPhotoSize = 150;
    const maxPhotoSize = 300;
    const gap = 8;
    
    // Responsive photo size based on container width
    let photoSize = Math.max(
      minPhotoSize,
      Math.min(
        maxPhotoSize,
        Math.floor((containerWidth - gap * 2) / Math.max(2, Math.floor(containerWidth / 200)))
      )
    );
    
    const cols = Math.floor((containerWidth + gap) / (photoSize + gap));
    const actualColumnWidth = Math.floor(containerWidth / cols);
    
    return {
      columnCount: cols,
      columnWidth: actualColumnWidth,
      rowHeight: actualColumnWidth, // Square photos
    };
  }, [containerWidth]);

  const rowCount = Math.ceil(gridPhotos.length / columnCount);

  React.useEffect(() => {
    try {
      const snapshot = {
        photosLen: photos.length,
        gridPhotosLen: gridPhotos.length,
        containerWidth,
        containerHeight,
        columnCount,
        columnWidth,
        rowHeight,
        rowCount,
        hasMore,
        isLoading,
      };
      console.log('[PHOTO_GRID_DEBUG] snapshot', snapshot);
      if (!Number.isFinite(columnCount) || columnCount < 1 || !Number.isFinite(containerHeight) || containerHeight < 1) {
        console.warn('[PHOTO_GRID_DEBUG] invalid grid sizing', snapshot);
      }
    } catch {}
  }, [photos.length, gridPhotos.length, containerWidth, containerHeight, columnCount, columnWidth, rowHeight, rowCount, hasMore, isLoading]);

  // Load more when scrolled near bottom
  React.useEffect(() => {
    if (inView && hasMore && !isLoading && onLoadMore) {
      onLoadMore();
    }
  }, [inView, hasMore, isLoading, onLoadMore]);

  const Cell = useCallback(({ columnIndex, rowIndex, style }: any) => {
    const photoIndex = rowIndex * columnCount + columnIndex;
    const photo = gridPhotos[photoIndex];

    if (!photo) {
      // Empty cell or loading indicator
      if (photoIndex === gridPhotos.length && hasMore) {
        return (
          <div style={style} ref={loadMoreRef}>
            <div 
              className="flex items-center justify-center bg-muted rounded-lg"
              style={{ 
                width: columnWidth - 8, 
                height: rowHeight - 8, 
                margin: 4 
              }}
            >
              {isLoading ? (
                <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
              ) : (
                <span className="text-gray-400 text-sm">Load more</span>
              )}
            </div>
          </div>
        );
      }
      return <div style={style} />;
    }

    const isSelected = selectedPhotos.includes(photo.asset_id);

    return (
      <div style={style}>
        <PhotoCard
          photo={photo}
          isSelected={isSelected}
          onPhotoClick={onPhotoClick}
          onPhotoSelect={onPhotoSelect}
          width={columnWidth}
          height={rowHeight}
          showLockedBadge={true}
        />
      </div>
    );
  }, [
    gridPhotos,
    selectedPhotos, 
    onPhotoClick, 
    onPhotoSelect, 
    columnCount, 
    columnWidth, 
    rowHeight, 
    hasMore, 
    isLoading, 
    loadMoreRef
  ]);

  logger.debug('PhotoGrid - photos count:', gridPhotos.length, 'isLoading:', isLoading);

  if (gridPhotos.length === 0 && !isLoading) {
    return (
      <div className="flex flex-col items-center justify-center h-64 text-gray-500">
        <div className="text-6xl mb-4">📷</div>
        <h3 className="text-lg font-medium mb-2">No photos found</h3>
        <p className="text-sm text-center max-w-md">
          Try adjusting your search terms or filters, or index some photos to get started.
        </p>
      </div>
    );
  }

  const invalidSizing =
    !Number.isFinite(columnCount) ||
    columnCount < 1 ||
    !Number.isFinite(columnWidth) ||
    columnWidth < 1 ||
    !Number.isFinite(containerWidth) ||
    containerWidth < 1 ||
    !Number.isFinite(containerHeight) ||
    containerHeight < 1;

  if (invalidSizing) {
    return (
      <div className="p-4 text-sm text-red-500">
        Grid sizing error (w={containerWidth}, h={containerHeight}, cols={columnCount}).
      </div>
    );
  }

  const isMobileLayout = containerWidth < 768;
  if (isMobileLayout) {
    const columns = containerWidth >= 520 ? 3 : 2;
    const gap = 8;
    const cell = Math.max(120, Math.floor((containerWidth - gap * (columns + 1)) / columns));
    return (
      <div className="px-2 pb-2">
        <div
          className="grid gap-2"
          style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
        >
          {gridPhotos.map((photo) => {
            const isSelected = selectedPhotos.includes(photo.asset_id);
            return (
              <PhotoCard
                key={photo.asset_id}
                photo={photo}
                isSelected={isSelected}
                onPhotoClick={onPhotoClick}
                onPhotoSelect={onPhotoSelect}
                width={cell}
                height={cell}
                showLockedBadge={true}
              />
            );
          })}
        </div>
        {hasMore && (
          <div ref={loadMoreRef} className="py-4 flex items-center justify-center">
            {isLoading ? (
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
            ) : (
              <span className="text-gray-400 text-sm">Load more</span>
            )}
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="photo-grid-container">
      <Grid
        columnCount={columnCount}
        columnWidth={columnWidth}
        height={containerHeight}
        rowCount={rowCount + (hasMore ? 1 : 0)} // Extra row for loading
        rowHeight={rowHeight}
        width={containerWidth}
        className="custom-scrollbar"
      >
        {Cell}
      </Grid>
    </div>
  );
}
