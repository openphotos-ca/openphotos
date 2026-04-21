import { apiClient } from './client';
import { logger } from '@/lib/logger';
import { 
  Photo, 
  PhotoListQuery, 
  PhotoListResponse, 
  Album, 
  CreateAlbumRequest, 
  UpdateAlbumRequest,
  CreateLiveAlbumRequest,
  Face,
  UpdateFaceRequest,
  AssetFace,
  FilterMetadata,
  SearchResponse
} from '@/lib/types/photo';

export const photosApi = {
  // Photos
  async getPhotos(params?: PhotoListQuery): Promise<PhotoListResponse> {
    return apiClient.get<PhotoListResponse>('/photos', params);
  },

  async getMediaCounts(params?: Partial<PhotoListQuery>): Promise<{ all: number; photos: number; videos: number; locked: number; locked_photos?: number; locked_videos?: number; total_size_bytes?: number; trash?: number }> {
    return apiClient.get('/media/counts', params as Record<string, any>);
  },

  async getPhoto(id: number): Promise<Photo> {
    return apiClient.get<Photo>(`/photos/${id}`);
  },

  async refreshPhotoMetadata(assetId: string): Promise<{
    asset_id: string;
    updated: boolean;
    camera_make?: string;
    camera_model?: string;
    iso?: number;
    aperture?: number;
    shutter_speed?: string;
    focal_length?: number;
    created_at?: number;
    latitude?: number;
    longitude?: number;
    altitude?: number;
  }> {
    // Triggers server-side EXIF re-parse and writes back to DB
    return apiClient.post(`/photos/${encodeURIComponent(assetId)}/refresh-metadata`, {});
  },

  async reindexPhotos(directory?: string): Promise<any> {
    return apiClient.post('/photos/reindex', { directory });
  },

  // Albums
  async getAlbums(): Promise<Album[]> {
    logger.debug('[API photosApi] getAlbums');
    const res = await apiClient.get<Album[]>('/albums');
    logger.debug('[API photosApi] getAlbums result', { count: res?.length });
    return res;
  },

  async getPhotoAlbums(photoId: number): Promise<Album[]> {
    return apiClient.get<Album[]>(`/photos/${photoId}/albums`);
  },

  async createAlbum(data: CreateAlbumRequest): Promise<Album> {
    logger.info('[API photosApi] createAlbum', data);
    const res = await apiClient.post<Album>('/albums', data);
    logger.debug('[API photosApi] createAlbum result', { id: (res as any)?.id, name: (res as any)?.name });
    return res;
  },

  async updateAlbum(id: number, data: UpdateAlbumRequest): Promise<Album> {
    logger.info('[API photosApi] updateAlbum', { id, ...data });
    // Server does not expose PUT /albums/:id; directly use POST /albums/update
    const res = await apiClient.post<Album>(`/albums/update`, { id, ...data });
    logger.debug('[API photosApi] updateAlbum POST ok', { id: (res as any)?.id, position: (res as any)?.position, parent_id: (res as any)?.parent_id });
    return res;
  },

  async deleteAlbum(id: number): Promise<void> {
    logger.info('[API photosApi] deleteAlbum', { id });
    const res = await apiClient.delete<void>(`/albums/${id}`);
    logger.debug('[API photosApi] deleteAlbum done', { id });
    return res;
  },

  async createLiveAlbum(data: CreateLiveAlbumRequest): Promise<Album> {
    logger.info('[API photosApi] createLiveAlbum', { name: data.name });
    const res = await apiClient.post<Album>('/albums/live', data);
    logger.debug('[API photosApi] createLiveAlbum result', { id: (res as any)?.id, name: (res as any)?.name });
    return res;
  },

  async updateLiveAlbum(id: number, data: { name?: string; description?: string; parent_id?: number; position?: number; criteria?: PhotoListQuery }): Promise<Album> {
    logger.info('[API photosApi] updateLiveAlbum', { id, ...data });
    const res = await apiClient.post<Album>('/albums/live/update', { id, ...data });
    logger.debug('[API photosApi] updateLiveAlbum result', { id: (res as any)?.id });
    return res;
  },

  async freezeAlbum(id: number, name?: string): Promise<Album> {
    logger.info('[API photosApi] freezeAlbum', { id, name });
    const res = await apiClient.post<Album>(`/albums/${id}/freeze`, { name });
    logger.debug('[API photosApi] freezeAlbum created', { id: (res as any)?.id, name: (res as any)?.name });
    return res;
  },

  async mergeAlbums(params: { source_album_id: number; target_album_id: number; delete_source?: boolean; dry_run?: boolean }): Promise<{ added_count: number; skipped_count: number; total_in_target: number; deleted_source: boolean }> {
    logger.info('[API photosApi] mergeAlbums', params);
    return apiClient.post(`/albums/merge`, params as any);
  },

  async addPhotosToAlbum(albumId: number, photoIds: number[]): Promise<{ message?: string; added?: number }> {
    return apiClient.post(`/albums/${albumId}/photos`, { photo_ids: photoIds });
  },

  async removePhotosFromAlbum(albumId: number, photoIds: number[]): Promise<void> {
    // Use POST convenience route that accepts JSON to remove
    return apiClient.post(`/albums/${albumId}/photos/remove`, { photo_ids: photoIds });
  },

  async addPhotoToAlbum(albumId: number, photoId: number): Promise<{ message?: string; added?: number }> {
    return this.addPhotosToAlbum(albumId, [photoId]);
  },

  async removePhotoFromAlbum(albumId: number, photoId: number): Promise<void> {
    return this.removePhotosFromAlbum(albumId, [photoId]);
  },

  // Faces
  async getFaces(): Promise<Face[]> {
    return apiClient.get<Face[]>('/faces');
  },

  async getFace(id: number): Promise<Face> {
    return apiClient.get<Face>(`/faces/${id}`);
  },

  async updateFace(id: number, data: UpdateFaceRequest): Promise<Face> {
    return apiClient.put<Face>(`/faces/${id}`, data);
  },

  async updatePerson(personId: string, data: { display_name?: string; birth_date?: string }): Promise<any> {
    return apiClient.put(`/faces/${encodeURIComponent(personId)}`, data);
  },

  async getPersonsForAsset(assetId: string): Promise<Array<{ person_id: string; display_name?: string; birth_date?: string }>> {
    return apiClient.get(`/photos/${encodeURIComponent(assetId)}/persons`);
  },

  async getFacePhotos(id: number): Promise<any[]> {
    return apiClient.get<any[]>(`/faces/${id}/photos`);
  },

  // Faces within a specific asset
  async getPhotoFaces(assetId: string): Promise<AssetFace[]> {
    return apiClient.get<AssetFace[]>(`/photos/${encodeURIComponent(assetId)}/faces`);
  },

  async assignFace(faceId: string, personId: string | null): Promise<{ face_id: string; person_id: string | null; updated_face_count?: number }> {
    return apiClient.put(`/faces/${encodeURIComponent(faceId)}/assign`, { person_id: personId });
  },

  // Manual association of a person to a photo (independent of detections)
  async addPersonToPhoto(assetId: string, personId: string): Promise<{ asset_id: string; person_id: string; added: boolean; face_count?: number }> {
    return apiClient.post(`/photos/${encodeURIComponent(assetId)}/assign-person`, { person_id: personId });
  },
  // remove API omitted for now; can be added later for Undo

  async mergeFaces(targetPersonId: string, sourcePersonIds: string[]): Promise<any> {
    return apiClient.post('/faces/merge', {
      target_person_id: targetPersonId,
      source_person_ids: sourcePersonIds,
    });
  },

  async deletePersons(personIds: string[]): Promise<{ deleted: number }> {
    return apiClient.post('/faces/delete', { person_ids: personIds });
  },

  async searchByFace(personId: string): Promise<any> {
    return apiClient.get(`/faces/search/${personId}`);
  },

  async filterPhotosByPerson(personId: string): Promise<{ items: Array<{ asset_id: string; is_video?: boolean; duration_ms?: number; filename?: string }> }> {
    return apiClient.post('/faces/filter', { person_id: personId });
  },

  // Search
  async search(query: string, limit: number = 10): Promise<SearchResponse> {
    // Use API client to include auth headers and /api/search route
    return apiClient.post('/search', {
      query,
      limit
    });
  },

  // Text search (Tantivy-backed)
  async textSearch(params: { q: string; page?: number; limit?: number; media?: 'photos'|'videos'|'all'; locked?: boolean; date_from?: number; date_to?: number; engine?: 'auto'|'text'|'semantic' }): Promise<{ items: { asset_id: string; score: number }[]; total: number; page: number; has_more: boolean; mode?: 'text'|'clip' }> {
    return apiClient.post('/search', params);
  },

  async getPhotosByAssetIds(assetIds: string[], includeLocked: boolean = false): Promise<Photo[]> {
    return apiClient.post('/photos/by-ids', { asset_ids: assetIds, include_locked: includeLocked });
  },

  // Filter metadata
  async getFilterMetadata(): Promise<FilterMetadata> {
    return apiClient.get<FilterMetadata>('/filters/metadata');
  },

  // Image URLs
  getImageUrl(assetId: string): string {
    // Always use same-origin API path; server handles both filename and base64 IDs
    return apiClient.getImageUrl(assetId);
  },

  getThumbnailUrl(assetId: string): string {
    return apiClient.getThumbnailUrl(assetId);
  },

  // Helper to detect base64-encoded asset IDs from CLIP service
  isBase64AssetId(assetId: string): boolean {
    // pHash values are 16-character hexadecimal strings, base64 IDs are longer and contain = padding
    // pHash example: "ffffe76700f0f070" (16 chars, only hex)
    // Base64 example: "VGhpcyBpcyBhIHRlc3Q=" (longer, contains =)
    return assetId.length > 16 && assetId.includes('=') && /^[A-Za-z0-9+/=]+$/.test(assetId);
  },

  getFaceThumbnailUrl(personId: string): string {
    return apiClient.getFaceThumbnailUrl(personId);
  },

  // Favorites
  async setFavorite(assetId: string, favorite: boolean): Promise<{ asset_id: string; favorites: number }> {
    return apiClient.put(`/photos/${encodeURIComponent(assetId)}/favorite`, { favorite });
  },

  async deletePhotos(assetIds: string[]): Promise<{ requested: number; deleted: number }> {
    return apiClient.post('/photos/delete', { asset_ids: assetIds });
  },

  async restorePhotos(assetIds: string[]): Promise<{ requested: number; restored: number }> {
    return apiClient.post('/photos/restore', { asset_ids: assetIds });
  },

  async purgePhotos(assetIds: string[]): Promise<{ requested: number; purged: number }> {
    return apiClient.post('/photos/purge', { asset_ids: assetIds });
  },

  async clearTrash(): Promise<{ purged: number }> {
    return apiClient.post('/photos/purge-all', {});
  },

  async getTrashSettings(): Promise<{ auto_purge_days: number }> {
    return apiClient.get('/settings/trash');
  },

  async updateTrashSettings(days: number): Promise<{ auto_purge_days: number }> {
    return apiClient.put('/settings/trash', { auto_purge_days: days });
  },

  // PIN status (E2EE local gating)
  async getPinStatus(): Promise<{ is_set: boolean; verified: boolean; verified_until?: number }> {
    // The legacy server PIN API was removed. This now reflects local E2EE state:
    // - is_set: true if an envelope exists (server or IndexedDB)
    // - verified: true if UMK is present in memory (unlocked session)
    try {
      const { useE2EEStore } = await import('@/lib/stores/e2ee');
      const st = useE2EEStore.getState();
      if (!st.envelope) {
        try { await st.loadEnvelope(); } catch {}
      }
      const hasEnvelope = !!useE2EEStore.getState().envelope;
      const hasUMK = !!useE2EEStore.getState().umk;
      return { is_set: hasEnvelope, verified: hasUMK } as any;
    } catch {
      return { is_set: false, verified: false } as any;
    }
  },
  // The following legacy PIN mutation endpoints are deprecated in favor of client-side
  // envelope wrap/unwrap via the E2EE worker. They are intentionally not implemented.
  async setPin(_pin: string): Promise<{ ok: boolean; verified_until?: number }> {
    throw new Error('setPin is deprecated; use client-side E2EE wrap flow');
  },
  async verifyPin(_pin: string): Promise<{ ok: boolean; verified_until?: number }> {
    throw new Error('verifyPin is deprecated; use client-side E2EE unlock flow');
  },
  async changePin(_oldPin: string, _newPin: string): Promise<{ ok: boolean; verified_until?: number }> {
    throw new Error('changePin is deprecated; use client-side E2EE re-wrap flow');
  },

  // Lock photo (one-way)
  async lockPhoto(assetId: string): Promise<{ ok: boolean; asset_id: string }> {
    return apiClient.post(`/photos/${encodeURIComponent(assetId)}/lock`, {});
  },

  // Update caption/description
  async updatePhotoMetadata(assetId: string, data: { caption?: string; description?: string }): Promise<{ ok: boolean }> {
    return apiClient.put(`/photos/${encodeURIComponent(assetId)}/metadata`, data);
  },

  // Rating (0 clears to NULL)
  async updatePhotoRating(assetId: string, rating: number | null): Promise<{ ok: boolean; rating?: number|null }> {
    const body: any = { rating: typeof rating === 'number' ? rating : null };
    return apiClient.put(`/photos/${encodeURIComponent(assetId)}/rating`, body);
  },
};
