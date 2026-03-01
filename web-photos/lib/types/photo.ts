export interface Photo {
  id?: number;
  asset_id: string;
  path: string;
  filename: string;
  mime_type?: string;
  created_at: number;
  modified_at: number;
  size: number;
  width?: number;
  height?: number;
  orientation?: number;
  favorites: number;
  locked?: boolean;
  delete_time?: number;
  is_video: boolean;
  is_live_photo: boolean;
  live_video_path?: string;
  is_screenshot: number;
  camera_make?: string;
  camera_model?: string;
  iso?: number;
  aperture?: number;
  shutter_speed?: string;
  focal_length?: number;
  rating?: number; // 1..5 or undefined for unrated
  latitude?: number;
  longitude?: number;
  altitude?: number;
  location_name?: string;
  city?: string;
  province?: string;
  country?: string;
  caption?: string;
  description?: string;
  duration_ms?: number;
  poster_time_ms?: number;
}

export interface PhotoListQuery {
  q?: string;
  page?: number;
  limit?: number;
  total_hint?: number;
  sort_by?: string;
  sort_order?: 'ASC' | 'DESC';
  sort_random_seed?: number;
  filter_city?: string;
  filter_country?: string;
  filter_date_from?: number;
  filter_date_to?: number;
  filter_screenshot?: boolean;
  filter_live_photo?: boolean;
  // New filters for redesigned homepage state
  filter_favorite?: boolean; // true => favorites only
  filter_is_video?: boolean; // true => videos only, false => photos only
  filter_faces?: string[];
  filter_faces_mode?: 'any' | 'all';
  // Ratings
  filter_rating_min?: number; // 1..5
  album_id?: number;
  album_ids?: string; // CSV of album ids for multi-select
  album_subtree?: boolean;
  include_locked?: boolean;
  filter_locked_only?: boolean;
  include_trashed?: boolean;
  filter_trashed_only?: boolean;
}

export interface PhotoListResponse {
  photos: Photo[];
  total: number;
  page: number;
  limit: number;
  has_more: boolean;
}

export interface Album {
  id: number;
  name: string;
  description?: string;
  parent_id?: number;
  position?: number;
  cover_photo_id?: number;
  cover_asset_id?: string;
  photo_count: number;
  created_at: number;
  updated_at: number;
  depth?: number;
  is_live?: boolean;
  rating_min?: number;
}

export interface CreateAlbumRequest {
  name: string;
  description?: string;
  parent_id?: number;
}

export interface CreateLiveAlbumRequest {
  name: string;
  description?: string;
  parent_id?: number;
  criteria: PhotoListQuery;
}

export interface UpdateAlbumRequest {
  name?: string;
  description?: string;
  cover_photo_id?: number;
  parent_id?: number;
  position?: number;
}

export interface Face {
  id: number;
  person_id: string;
  name?: string;
  birth_date?: string;
  thumbnail_path?: string;
  photo_count: number;
  avg_age?: number;
  first_seen_date?: number;
  last_seen_date?: number;
}

export interface UpdateFaceRequest {
  name?: string;
  birth_date?: string;
}

export interface AssetFace {
  face_id: string;
  bbox: [number, number, number, number];
  confidence: number;
  person_id?: string | null;
  thumbnail?: string | null; // data URL
}

export interface FilterMetadata {
  cities: string[];
  countries: string[];
  date_range?: {
    min: number;
    max: number;
  };
  faces: Array<{
    person_id: string;
    name?: string;
    photo_count: number;
  }>;
  cameras: string[];
}

export interface SearchResult {
  asset_id: string;
  score: number;
}

export interface SearchResponse {
  results: SearchResult[];
  model_used?: string;
  fallback_used?: boolean;
}

// New text search types (Tantivy-backed)
export interface TextSearchHit { asset_id: string; score: number }
export interface TextSearchResponse { items: TextSearchHit[]; total: number; page: number; has_more: boolean }

export type SortOption = 'created_at' | 'modified_at' | 'size' | 'filename' | 'last_indexed' | 'random';
export type SortOrder = 'ASC' | 'DESC';

export interface FilterState {
  dateRange?: [Date, Date];
  cities: string[];
  countries: string[];
  faces: string[];
  showScreenshots: boolean;
  showLivePhotos: boolean;
  cameras: string[];
}

// Optional seed for random sorting, used when sort_by === 'random'
export interface RandomSortQuery {
  sort_random_seed?: number;
}
