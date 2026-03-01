# Web API and URL Spec (Home Redesign)

This doc defines the shareable URL schema and backend API contracts to power the redesigned homepage. It favors clear, cacheable GETs and deterministic paging. Paths are rooted at `/api` (served by the Rust backend). Items marked Proposed are new endpoints to add; others already exist.

## Defaults and Behavior
- Default chip: Favorites (heart filled, accent color).
- Default URL: `/?favorite=1&media=all&sort=newest`.
- Selection mode clears on any change to query, album/favorite, filters, sort, or media.
- Slideshow includes photos and videos by default, respects current filters/sort.

## URL Query Schema (source of truth)
- `q` string: free-text (semantic + metadata search).
- `favorite` `1` | omit: Favorites chip on/off (mutually exclusive with `album`).
- `album` string: user album id (mutually exclusive with `favorite`).
- `faces` csv: list of detected face/person IDs.
- `faces` csv: list of detected face/person IDs.
- `facesMode` `all|any` (default `all`): whether all selected faces must be present (AND) or any of them (OR).
- `media` `all|photo|video` (default `all`).
- `type` csv: `screenshot,live` flags.
- `sort` `newest|oldest|largest|random` (default `newest`).
- `seed` int: required when `sort=random` for stable order across pages.
- `start`, `end` ISO 8601: taken_at time range.
- `country`, `region`, `city` strings: location cascade.
- `cursor` string: opaque pagination cursor; `pageSize` int (default 100).

The URL fully reproduces state; localStorage may remember last `sort` and `media` only.

## Types (frontend reference)
```ts
export type MediaType = 'photo' | 'video';

export type MediaItem = {
  id: string;                 // backend id or stable asset_id
  type: MediaType;            // photo or video
  width?: number;
  height?: number;
  duration?: number;          // seconds for videos
  size: number;               // bytes
  takenAt?: string;           // ISO; fallback to indexedAt when absent
  indexedAt: string;          // ISO index time
  thumbUrl: string;           // small square
  previewUrl?: string;        // larger preview
  favorite?: boolean;
  albumIds: string[];
  faceIds: string[];
  location?: { country?: string; region?: string; city?: string };
};

export type Counts = { all: number; photos: number; videos: number };

export type QueryState = {
  q?: string;
  favorite?: '1';
  album?: string;
  faces?: string[];
  media?: 'all' | 'photo' | 'video';
  type?: ('screenshot' | 'live')[];
  sort?: 'newest' | 'oldest' | 'largest' | 'random';
  seed?: number;
  start?: string; end?: string;
  country?: string; region?: string; city?: string;
  cursor?: string; pageSize?: number;
};
```

## Endpoints

### List Media — Proposed
GET `/api/media`

Query: accepts all parameters from QueryState. For `media=photo|video` the backend filters by type. Sorting:
- `newest|oldest` by `taken_at` (fallback `indexed_at`).
- `largest` by file size.
- `random` requires `seed`; ordering must remain stable across pages for same `seed`.

Response:
```json
{
  "items": [
    {
      "id": "a1b2",
      "type": "photo",
      "width": 3024,
      "height": 4032,
      "size": 2748390,
      "takenAt": "2023-11-01T12:34:56Z",
      "indexedAt": "2024-09-01T08:00:00Z",
      "thumbUrl": "/api/thumbnails/a1b2",
      "previewUrl": "/api/images/a1b2",
      "favorite": true,
      "albumIds": ["fav"],
      "faceIds": ["p_42"],
      "location": {"country": "CN", "region": "ZJ", "city": "Hangzhou"}
    }
  ],
  "nextCursor": "opaque-token",
  "total": 500
}
```

Notes:
- Until `/api/media` exists, the UI may continue using `/api/photos` and map query params where possible.

### List Photos — Current
GET `/api/photos`

Current query (subset): `page`, `limit`, `sort_by`, `sort_order`, `filter_city`, `filter_country`, `filter_date_from`, `filter_date_to`, `filter_screenshot`, `filter_live_photo`, `filter_faces[]`, `album_id`.

Response shape (current):
```json
{
  "photos": [ { "asset_id": "...", "is_video": false, "favorites": 1, ... } ],
  "total": 500, "page": 1, "limit": 100, "has_more": true
}
```

Bridging plan: extend this endpoint or add `/api/media` to support Favorites, random sorting with seed, unified counts, and cursor pagination.

### Counts — Proposed
GET `/api/media/counts`

Query: same filters as `/api/media` except `media`.

Response:
```json
{ "all": 500, "photos": 450, "videos": 50 }
```

Used for the segmented control: `All (n) | Photos (n) | Videos (n)`.

### Albums — Current
GET `/api/albums`

Response:
```json
[
  { "id": "1", "name": "Trip", "total": 120, "coverThumbUrl": "/api/thumbnails/a1" }
]
```

UI rules:
- Chips order: `[♥ Favorites] [All] [Album …]`.
- State mapping:
  - Favorites → `favorite=1`, clear `album`.
  - All → clear `favorite` and `album`.
  - Album → `album=<id>`, clear `favorite`.

### Faces Facet — Proposed
GET `/api/facets/faces`

Query: current filters except `faces` (avoid self-filtering). Supports `q`, `favorite|album`, time, location, type.

Response:
```json
[
  { "id": "p_42", "label": "Alice", "count": 133, "thumbUrl": "/api/face-thumbnail?personId=p_42" }
]
```

### Locations Facet — Proposed
GET `/api/facets/locations`

Query: current filters except `country/region/city`.

Response:
```json
[
  {
    "country": "CN",
    "regions": [
      { "region": "ZJ", "cities": [ { "city": "Hangzhou", "count": 92 } ] }
    ]
  }
]
```

### Search — Current
POST `/api/search`

Body:
```json
{ "query": "baby in bathtub", "limit": 50, "model": "ViT-B-32__openai" }
```

Response:
```json
{ "results": [ { "asset_id": "a1b2", "score": 0.72 } ], "model_used": "ViT-B-32__openai" }
```

Combine with `/api/media` by providing `q` to retrieve the actual items with filters and sort applied.

### Media Delivery — Current
- Image full/preview: `GET /api/images/:asset_id`
- Thumbnail: `GET /api/thumbnails/:asset_id`
- Live video: `GET /api/live/:asset_id`
- Face thumbnail: `GET /api/face-thumbnail?personId=:id`

## Examples

1) Default Favorites page with newest first:
```
GET /api/media?favorite=1&sort=newest&pageSize=100
```

2) User album (id=12), photos only, random stable order for seed 42:
```
GET /api/media?album=12&media=photo&sort=random&seed=42&pageSize=120
```

3) Faces + time + location filters with counts:
```
GET /api/media?favorite=1&faces=p_42,p_99&start=2024-01-01T00:00:00Z&end=2024-12-31T23:59:59Z&country=CN&region=ZJ&city=Hangzhou
GET /api/media/counts?favorite=1&faces=p_42,p_99&start=2024-01-01T00:00:00Z&end=2024-12-31T23:59:59Z&country=CN&region=ZJ&city=Hangzhou
```

## Implementation Notes
- Deterministic paging: prefer cursor pagination. For random order, include the `seed` value in the cursor to preserve stability.
- Sorting indices: add indexes on `taken_at`, `size`, `media_type`, `album_id`, `(country,region,city)`, and face join tables.
- Favorites: treated as a boolean filter; does not create a synthetic album.

## Acceptance
- Same URL recreates the same view, including Random with identical `seed`.
- Counts match the filtered result set for `All/Photos/Videos`.
- Switching chips (Favorites/All/Album) updates grid and counts; selection clears.
