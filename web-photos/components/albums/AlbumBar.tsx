'use client';

import React, { useMemo, useState } from 'react';
import type { Album, Photo } from '@/lib/types/photo';
import { X, Plus } from 'lucide-react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import AlbumPickerDialog from './AlbumPickerDialog';
import { useToast } from '@/hooks/use-toast';

export function AlbumBar({ photo }: { photo: Photo }) {
  const queryClient = useQueryClient();
  const photoId = photo.id;
  if (photoId == null) return null;
  // Removed bottom-right Browse button

  const { data: albums } = useQuery({ queryKey: ['albums'], queryFn: () => photosApi.getAlbums(), staleTime: 60_000 });
  const { data: assigned = [], refetch: refetchAssigned } = useQuery({
    queryKey: ['photoAlbums', photoId],
    queryFn: async () => {
      if (photoId == null) return [] as Album[];
      return photosApi.getPhotoAlbums(photoId);
    },
    enabled: photoId != null,
  });

  const assignedIds = useMemo(() => new Set((assigned || []).map(a => a.id)), [assigned]);

  const suggestions = useMemo(() => {
    const list = (albums || []).filter(a => !assignedIds.has(a.id));
    list.sort((a, b) => b.updated_at - a.updated_at);
    return list.slice(0, 10);
  }, [albums, assignedIds]);

  // Deterministic accent color from album id (golden angle)
  const albumColor = (id: number) => {
    const hue = Math.floor((id * 137.508) % 360);
    return {
      solid: `hsl(${hue}, 70%, 44%)`,
      border: `hsl(${hue}, 70%, 55%)`,
      hoverSoft: `hsla(${hue}, 70%, 20%, 0.35)`,
    };
  };

  const { toast } = useToast();

  const addMutation = useMutation({
    mutationFn: async (albumId: number) => {
      if (photoId == null) throw new Error('Missing photo id');
      await photosApi.addPhotoToAlbum(albumId, photoId);
      // Invalidate albums for recency and assigned list
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['albums'] }),
        queryClient.invalidateQueries({ queryKey: ['photoAlbums', photoId] }),
      ]);
    },
    onSuccess: (_data, albumId) => {
      const a = (albums || []).find(x => x.id === albumId);
      toast({ title: a ? `Added to ${a.name}` : 'Album added' });
    },
    onError: (err, albumId) => {
      const a = (albums || []).find(x => x.id === albumId);
      toast({ title: 'Failed to add to album', description: a?.name, variant: 'destructive' });
    },
  });
  const removeMutation = useMutation({
    mutationFn: async (albumId: number) => {
      if (photoId == null) throw new Error('Missing photo id');
      await photosApi.removePhotoFromAlbum(albumId, photoId);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['albums'] }),
        queryClient.invalidateQueries({ queryKey: ['photoAlbums', photoId] }),
      ]);
    },
    onSuccess: (_data, albumId) => {
      const a = (assigned || []).find(x => x.id === albumId);
      toast({ title: a ? `Removed from ${a.name}` : 'Album removed' });
    },
    onError: (err, albumId) => {
      const a = (assigned || []).find(x => x.id === albumId);
      toast({ title: 'Failed to remove from album', description: a?.name, variant: 'destructive' });
    },
  });

  const onAdd = (albumId: number) => {
    // optimistic
    const album = (albums || []).find(a => a.id === albumId);
    if (album) {
      queryClient.setQueryData<Album[]>(['photoAlbums', photoId], (prev) => {
        const existing = prev || [];
        if (existing.find(a => a.id === albumId)) return existing;
        return [album, ...existing];
      });
    }
    addMutation.mutate(albumId);
  };

  const onRemove = (albumId: number) => {
    queryClient.setQueryData<Album[]>(['photoAlbums', photoId], (prev) => (prev || []).filter(a => a.id !== albumId));
    removeMutation.mutate(albumId);
  };

  return (
    <div className="absolute bottom-1 left-0 right-0 z-[65] px-3 pb-1 pt-1 select-none" onClick={(e) => e.stopPropagation()}>
      <div className="rounded-lg bg-gradient-to-t from-black/70 to-black/30 p-1.5 backdrop-blur">
        {/* Assigned row removed per request (avoid green chip at bottom-left) */}
        {/* Suggestions/Browse row removed per request */}
      </div>

      {/* AlbumPickerDialog removed with Browse button */}
    </div>
  );
}

export default AlbumBar;
