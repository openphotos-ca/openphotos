import { apiClient } from './client';

export interface FaceSettings {
  min_quality: number;
  min_confidence: number;
  min_size: number;
  yaw_max: number;
  yaw_hard_max: number;
  min_sharpness: number;
  sharpness_target: number;
}

export interface DuplicateSettings {
  max_distance: number;
  max_neighbors: number;
}

export const settingsApi = {
  async getFaceSettings(): Promise<FaceSettings> {
    return apiClient.get<FaceSettings>('/settings/face');
  },

  async updateFaceSettings(partial: Partial<FaceSettings>): Promise<void> {
    return apiClient.put('/settings/face', partial);
  },

  async getDuplicateSettings(): Promise<DuplicateSettings> {
    return apiClient.get<DuplicateSettings>('/settings/duplicates');
  },

  async updateDuplicateSettings(partial: Partial<DuplicateSettings>): Promise<{ message: string; max_distance: number; max_neighbors: number }>{
    return apiClient.put('/settings/duplicates', partial);
  },
};
