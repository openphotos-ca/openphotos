import { apiClient } from './client';
import { logger } from '@/lib/logger';

export interface SimilarGroup {
  representative: string;
  count: number;
  members: string[];
}

export interface AssetMeta {
  mime_type?: string;
  size?: number;
  created_at?: number;
}

export interface GroupsResponse {
  total_groups: number;
  groups: SimilarGroup[];
  next_cursor?: number;
  metadata?: Record<string, AssetMeta>;
}

export interface NeighborsResponse {
  asset_id: string;
  threshold: number;
  neighbors: Array<{ asset_id: string; distance: number }>;
}

export const similarApi = {
  async getGroups(params?: { threshold?: number; min_group_size?: number; limit?: number; cursor?: number }): Promise<GroupsResponse> {
    logger.debug('[SIMILAR API] getGroups', params);
    return apiClient.get('/similar/groups', params as any);
  },
  async getVideoGroups(params?: { min_group_size?: number; limit?: number; cursor?: number }): Promise<GroupsResponse> {
    logger.debug('[SIMILAR API] getVideoGroups', params);
    return apiClient.get('/video/similar/groups', params as any);
  },
  async getNeighbors(assetId: string, params?: { threshold?: number }): Promise<NeighborsResponse> {
    logger.debug('[SIMILAR API] getNeighbors', { assetId, ...(params||{}) });
    return apiClient.get(`/similar/${encodeURIComponent(assetId)}`, params as any);
  }
};
