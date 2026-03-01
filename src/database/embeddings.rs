use anyhow::Result;
use serde::{Deserialize, Serialize};
use tokio::task;
use tracing::{debug, instrument};

use super::DbPool;
use std::sync::Arc;

#[derive(Debug, Clone)]
enum Backend {
    Duck(DbPool),
    Pg(Arc<tokio_postgres::Client>),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub asset_id: String,
    pub distance: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhotoRecord {
    pub asset_id: String,
    pub image_width: i32,
    pub image_height: i32,
    pub content_type: String,
    pub created_at: String,
}

#[derive(Debug, Clone)]
pub struct PhotoData {
    // `smart_search.image_data` is optional and may be NULL (we no longer store full image bytes).
    // Callers that still use this should treat an empty Vec as "no embedded image data".
    pub image_data: Vec<u8>,
    pub content_type: String,
    pub image_width: i32,
    pub image_height: i32,
}

#[derive(Debug, Clone)]
pub struct EmbeddingStore {
    backend: Backend,
    embedding_dim: usize,
}

impl EmbeddingStore {
    pub fn new(conn: DbPool, embedding_dim: usize) -> Self {
        Self {
            backend: Backend::Duck(conn),
            embedding_dim,
        }
    }

    pub fn new_postgres(client: Arc<tokio_postgres::Client>, embedding_dim: usize) -> Self {
        Self {
            backend: Backend::Pg(client),
            embedding_dim,
        }
    }

    #[instrument(skip(self, embedding, image_data))]
    pub async fn upsert_image_embedding(
        &self,
        asset_id: String,
        embedding: Vec<f32>,
        // We intentionally avoid storing full image bytes in the DB to prevent unbounded DB growth
        // and expensive checkpoints. Thumbnails/previews are served from the filesystem endpoints.
        image_data: Option<Vec<u8>>,
        image_width: u32,
        image_height: u32,
        content_type: String,
        detected_objects: Option<Vec<String>>,
        scene_tags: Option<Vec<String>>,
    ) -> Result<()> {
        let embedding_dim = self.embedding_dim;
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                task::spawn_blocking(move || {
                    let conn = conn.lock();
                    let mut padded_embedding = embedding;
                    padded_embedding.resize(embedding_dim, 0.0);
                    let embedding_str = format!(
                        "[{}]",
                        padded_embedding
                            .iter()
                            .map(|f| f.to_string())
                            .collect::<Vec<_>>()
                            .join(",")
                    );
                    let mut search_tags = Vec::new();
                    if let Some(objects) = &detected_objects {
                        search_tags.extend(objects.clone());
                    }
                    if let Some(scenes) = &scene_tags {
                        search_tags.extend(scenes.clone());
                    }
                    let objects_str = detected_objects
                        .map(|objs| format!("['{}']", objs.join("','")));
                    let scenes_str = scene_tags
                        .map(|scenes| format!("['{}']", scenes.join("','")));
                    let search_str = if search_tags.is_empty() {
                        None
                    } else {
                        Some(format!("['{}']", search_tags.join("','")))
                    };
                    let query = format!(
                        "INSERT INTO smart_search (asset_id, embedding, image_data, image_width, image_height, content_type, detected_objects, scene_tags, search_tags)
                         VALUES (?, ?::FLOAT[{}], ?, ?, ?, ?, ?::TEXT[], ?::TEXT[], ?::TEXT[])
                         ON CONFLICT (asset_id)
                         DO UPDATE SET
                            embedding = EXCLUDED.embedding,
                            image_width = EXCLUDED.image_width,
                            image_height = EXCLUDED.image_height,
                            content_type = EXCLUDED.content_type,
                            detected_objects = EXCLUDED.detected_objects,
                            scene_tags = EXCLUDED.scene_tags,
                            search_tags = EXCLUDED.search_tags;",
                        embedding_dim
                    );
                    conn.execute(
                        &query,
                        duckdb::params![
                            asset_id,
                            embedding_str,
                            image_data,
                            image_width as i32,
                            image_height as i32,
                            content_type,
                            objects_str,
                            scenes_str,
                            search_str
                        ],
                    )?;
                    debug!("Upserted embedding for asset: {}", asset_id);
                    Ok::<_, anyhow::Error>(())
                })
                .await??;
            }
            Backend::Pg(pg) => {
                let client = pg.clone();
                // Pad embedding and format as pgvector literal
                let mut padded_embedding = embedding;
                padded_embedding.resize(embedding_dim, 0.0);
                let embedding_str = format!(
                    "[{}]",
                    padded_embedding
                        .iter()
                        .map(|f| f.to_string())
                        .collect::<Vec<_>>()
                        .join(",")
                );
                // Build arrays for detected/scenes/search
                let mut search_tags: Vec<String> = Vec::new();
                if let Some(ref objects) = detected_objects {
                    search_tags.extend(objects.clone());
                }
                if let Some(ref scenes) = scene_tags {
                    search_tags.extend(scenes.clone());
                }
                let det_vec = detected_objects.unwrap_or_default();
                let det_refs: Vec<&str> = det_vec.iter().map(|s| s.as_str()).collect();
                let scn_vec = scene_tags.unwrap_or_default();
                let scn_refs: Vec<&str> = scn_vec.iter().map(|s| s.as_str()).collect();
                let srch_refs: Vec<&str> = search_tags.iter().map(|s| s.as_str()).collect();
                client
                        .execute(
                            "INSERT INTO smart_search (asset_id, embedding, image_data, image_width, image_height, content_type, detected_objects, scene_tags, search_tags)
                             VALUES ($1, ($2::text)::vector(512), $3, $4, $5, $6, $7::text[], $8::text[], $9::text[])
                             ON CONFLICT (asset_id) DO UPDATE SET
                                embedding = EXCLUDED.embedding,
                                image_width = EXCLUDED.image_width,
                                image_height = EXCLUDED.image_height,
                                content_type = EXCLUDED.content_type,
                                detected_objects = EXCLUDED.detected_objects,
                                scene_tags = EXCLUDED.scene_tags,
                            search_tags = EXCLUDED.search_tags",
                        &[
                            &asset_id,
                            &embedding_str,
                            &image_data,
                            &(image_width as i32),
                            &(image_height as i32),
                            &content_type,
                            &det_refs,
                            &scn_refs,
                            &srch_refs,
                        ],
                    )
                    .await?;
                debug!("Upserted embedding for asset: {} (pg)", asset_id);
            }
        }

        Ok(())
    }

    #[instrument(skip(self, query_embedding))]
    pub async fn search_similar(
        &self,
        query_embedding: Vec<f32>,
        limit: usize,
    ) -> Result<Vec<SearchResult>> {
        let embedding_dim = self.embedding_dim;
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                let results = task::spawn_blocking(move || {
                    let conn = conn.lock();
                    let embedding_str = format!(
                        "[{}]",
                        query_embedding
                            .iter()
                            .map(|f| f.to_string())
                            .collect::<Vec<_>>()
                            .join(",")
                    );
                    let query = format!(
                        "SELECT asset_id,
                                (1.0 - array_cosine_similarity(embedding, ?::FLOAT[{}])) as distance
                         FROM smart_search
                         WHERE embedding IS NOT NULL
                         ORDER BY distance ASC
                         LIMIT ?",
                        embedding_dim
                    );
                    let mut stmt = conn.prepare(&query)?;
                    let results = stmt.query_map(duckdb::params![embedding_str, limit], |row| {
                        Ok(SearchResult {
                            asset_id: row.get(0)?,
                            distance: row.get(1)?,
                        })
                    })?;
                    let mut search_results = Vec::new();
                    for result in results {
                        search_results.push(result?);
                    }
                    debug!("Found {} similar assets", search_results.len());
                    Ok::<_, anyhow::Error>(search_results)
                })
                .await??;
                Ok(results)
            }
            Backend::Pg(pg) => {
                let client = pg.clone();
                let embedding_str = format!(
                    "[{}]",
                    query_embedding
                        .iter()
                        .map(|f| f.to_string())
                        .collect::<Vec<_>>()
                        .join(",")
                );
                let rows = client.query(
                    &format!("SELECT asset_id, (embedding <=> ($1::text)::vector({})) AS distance FROM smart_search WHERE embedding IS NOT NULL ORDER BY distance ASC LIMIT $2", embedding_dim),
                    &[&embedding_str, &(limit as i64)]
                ).await?;
                let results = rows
                    .into_iter()
                    .map(|r| SearchResult {
                        asset_id: r.get::<_, String>(0),
                        distance: r.get::<_, f64>(1) as f32,
                    })
                    .collect();
                Ok(results)
            }
        }
    }

    #[instrument(skip(self, embedding))]
    pub async fn cache_text_embedding(
        &self,
        query: String,
        model_name: String,
        language: Option<String>,
        embedding: Vec<f32>,
    ) -> Result<()> {
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                let embedding_dim = self.embedding_dim;
                let lang = language.unwrap_or_else(|| "en".to_string());
                task::spawn_blocking(move || {
                    let conn = conn.lock();
                    let embedding_str = format!(
                        "[{}]",
                        embedding
                            .iter()
                            .map(|f| f.to_string())
                            .collect::<Vec<_>>()
                            .join(",")
                    );
                    let query_sql = format!(
                        "INSERT INTO text_cache (query_text, model_name, language, embedding)
                         VALUES (?, ?, ?, ?::FLOAT[{}])
                         ON CONFLICT (query_text, model_name, language)
                         DO UPDATE SET embedding = EXCLUDED.embedding;",
                        embedding_dim
                    );
                    conn.execute(
                        &query_sql,
                        duckdb::params![query, model_name, lang, embedding_str],
                    )?;
                    Ok::<_, anyhow::Error>(())
                })
                .await??;
                Ok(())
            }
            Backend::Pg(_pg) => {
                // Optional: implement PG text_cache; for now, no-op
                Ok(())
            }
        }
    }

    #[instrument(skip(self))]
    pub async fn get_cached_text_embedding(
        &self,
        query: &str,
        model_name: &str,
        language: Option<&str>,
    ) -> Result<Option<Vec<f32>>> {
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                let embedding_dim = self.embedding_dim;
                let query = query.to_string();
                let model_name = model_name.to_string();
                let lang = language.unwrap_or("en").to_string();
                let result = task::spawn_blocking(move || {
                    let conn = conn.lock();
                    let mut stmt = conn.prepare(
                        "SELECT embedding FROM text_cache WHERE query_text = ? AND model_name = ? AND language = ?",
                    )?;
                    let mut rows = stmt.query_map(duckdb::params![query, model_name, lang], |row| {
                        match row.get::<_, String>(0) {
                            Ok(embedding_str) => {
                                let trimmed = embedding_str.trim_start_matches('[').trim_end_matches(']');
                                let floats: Vec<f32> = trimmed.split(',').filter_map(|s| s.trim().parse().ok()).collect();
                                if floats.len() == embedding_dim { Ok::<Vec<f32>, duckdb::Error>(floats) } else { Ok::<Vec<f32>, duckdb::Error>(Vec::new()) }
                            }
                            Err(_) => Ok::<Vec<f32>, duckdb::Error>(Vec::new()),
                        }
                    })?;
                    if let Some(row) = rows.next() {
                        let embedding = row?;
                        if embedding.is_empty() { Ok::<Option<Vec<f32>>, anyhow::Error>(None) } else { Ok(Some(embedding)) }
                    } else { Ok(None) }
                }).await??;
                Ok(result)
            }
            Backend::Pg(_pg) => Ok(None),
        }
    }

    #[instrument(skip(self))]
    pub async fn get_image_data(&self, asset_id: &str) -> Result<Option<(Vec<u8>, String)>> {
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                let id = asset_id.to_string();
                let result = task::spawn_blocking(move || {
                    let conn = conn.lock();
                    let mut stmt = conn.prepare(
                        "SELECT image_data, content_type FROM smart_search WHERE asset_id = ?",
                    )?;
                    let mut rows = stmt.query_map(duckdb::params![id], |row| {
                        let image_data: Option<Vec<u8>> = row.get(0).ok();
                        let content_type: Option<String> = row.get(1).ok();
                        Ok((image_data, content_type))
                    })?;
                    if let Some(row) = rows.next() {
                        let (bytes_opt, ct_opt) = row?;
                        if let (Some(bytes), Some(ct)) = (bytes_opt, ct_opt) {
                            if bytes.is_empty() {
                                Ok::<Option<(Vec<u8>, String)>, anyhow::Error>(None)
                            } else {
                                Ok(Some((bytes, ct)))
                            }
                        } else {
                            Ok(None)
                        }
                    } else {
                        Ok(None)
                    }
                })
                .await??;
                Ok(result)
            }
            Backend::Pg(pg) => {
                let client = pg.clone();
                let rows = client
                    .query(
                        "SELECT image_data, content_type FROM smart_search WHERE asset_id = $1",
                        &[&asset_id],
                    )
                    .await?;
                if let Some(r) = rows.into_iter().next() {
                    let bytes: Option<Vec<u8>> = r.get(0);
                    let ct: Option<String> = r.get(1);
                    if let (Some(b), Some(c)) = (bytes, ct) {
                        if b.is_empty() {
                            Ok(None)
                        } else {
                            Ok(Some((b, c)))
                        }
                    } else {
                        Ok(None)
                    }
                } else {
                    Ok(None)
                }
            }
        }
    }

    pub async fn delete_embedding(&self, asset_id: &str) -> Result<()> {
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                let id = asset_id.to_string();
                task::spawn_blocking(move || {
                    let conn = conn.lock();
                    conn.execute(
                        "DELETE FROM smart_search WHERE asset_id = ?",
                        duckdb::params![id],
                    )?;
                    Ok::<_, anyhow::Error>(())
                })
                .await??;
                Ok(())
            }
            Backend::Pg(pg) => {
                let client = pg.clone();
                client
                    .execute("DELETE FROM smart_search WHERE asset_id = $1", &[&asset_id])
                    .await?;
                Ok(())
            }
        }
    }

    #[instrument(skip(self, query_embedding))]
    pub async fn search_combined(
        &self,
        query_text: &str,
        query_embedding: Vec<f32>,
        limit: usize,
    ) -> Result<Vec<SearchResult>> {
        let embedding_dim = self.embedding_dim;
        let ql = query_text.to_lowercase();
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                let results = task::spawn_blocking(move || {
                    let conn = conn.lock();
                    let embedding_str = format!(
                        "[{}]",
                        query_embedding
                            .iter()
                            .map(|f| f.to_string())
                            .collect::<Vec<_>>()
                            .join(",")
                    );
                    let is_single_word = ql.split_whitespace().count() == 1;
                    let query = if is_single_word {
                        format!(
                            "WITH tag_search AS (
                                SELECT asset_id,
                                       0.0 as distance
                                FROM smart_search
                                WHERE search_tags IS NOT NULL
                                AND EXISTS (
                                    SELECT 1 FROM unnest(search_tags) as tag(value)
                                    WHERE LOWER(tag.value) LIKE '%' || ? || '%'
                                )
                            ),
                            semantic_search AS (
                                SELECT asset_id,
                                       (1.0 - array_cosine_similarity(embedding, ?::FLOAT[{}])) as distance
                                FROM smart_search
                                WHERE embedding IS NOT NULL
                                AND (SELECT COUNT(*) FROM tag_search) = 0  -- Only if no YOLO matches
                            ),
                            filtered_results AS (
                                SELECT asset_id, distance FROM tag_search
                                UNION ALL
                                SELECT asset_id, distance FROM semantic_search
                            )
                            SELECT asset_id, distance FROM filtered_results
                            WHERE distance < 0.8
                            ORDER BY distance ASC
                            LIMIT ?",
                            embedding_dim
                        )
                    } else {
                        format!(
                            "WITH tag_search AS (
                                SELECT asset_id,
                                       0.0 as distance
                                FROM smart_search
                                WHERE search_tags IS NOT NULL
                                AND EXISTS (
                                    SELECT 1 FROM unnest(search_tags) as tag(value)
                                    WHERE LOWER(tag.value) LIKE '%' || ? || '%'
                                )
                            ),
                            semantic_search AS (
                                SELECT asset_id,
                                       (1.0 - array_cosine_similarity(embedding, ?::FLOAT[{}])) as distance
                                FROM smart_search
                                WHERE embedding IS NOT NULL
                                AND asset_id NOT IN (SELECT asset_id FROM tag_search)
                            ),
                            filtered_results AS (
                                SELECT asset_id, distance FROM tag_search
                                UNION ALL
                                SELECT asset_id, distance FROM semantic_search
                            )
                            SELECT asset_id, distance FROM filtered_results
                            WHERE distance < 0.8
                            ORDER BY distance ASC
                            LIMIT ?",
                            embedding_dim
                        )
                    };
                    let mut stmt = conn.prepare(&query)?;
                    let results = stmt.query_map(duckdb::params![ql, embedding_str, limit], |row| {
                        Ok(SearchResult { asset_id: row.get(0)?, distance: row.get(1)? })
                    })?;
                    let mut search_results = Vec::new();
                    for result in results { search_results.push(result?); }
                    debug!("Found {} combined search results", search_results.len());
                    Ok::<_, anyhow::Error>(search_results)
                })
                .await??;
                Ok(results)
            }
            Backend::Pg(pg) => {
                let client = pg.clone();
                let embedding_str = format!(
                    "[{}]",
                    query_embedding
                        .iter()
                        .map(|f| f.to_string())
                        .collect::<Vec<_>>()
                        .join(",")
                );
                let is_single_word = ql.split_whitespace().count() == 1;
                let sql = if is_single_word {
                    format!(
                        "WITH tag_search AS (
                            SELECT asset_id, 0.0::float8 as distance
                            FROM smart_search
                            WHERE search_tags IS NOT NULL
                            AND EXISTS (
                                SELECT 1 FROM unnest(search_tags) as tag(value)
                                WHERE LOWER(tag.value) LIKE '%' || ($1)::text || '%'
                            )
                        ),
                        semantic_search AS (
                            SELECT asset_id, (embedding <=> ($2::text)::vector({})) as distance
                            FROM smart_search
                            WHERE embedding IS NOT NULL AND (SELECT COUNT(*) FROM tag_search) = 0
                        ),
                        filtered_results AS (
                            SELECT asset_id, distance FROM tag_search
                            UNION ALL
                            SELECT asset_id, distance FROM semantic_search
                        )
                        SELECT asset_id, distance FROM filtered_results WHERE distance < 0.8 ORDER BY distance ASC LIMIT $3",
                        embedding_dim
                    )
                } else {
                    format!(
                        "WITH tag_search AS (
                            SELECT asset_id, 0.0::float8 as distance
                            FROM smart_search
                            WHERE search_tags IS NOT NULL
                            AND EXISTS (
                                SELECT 1 FROM unnest(search_tags) as tag(value)
                                WHERE LOWER(tag.value) LIKE '%' || ($1)::text || '%'
                            )
                        ),
                        semantic_search AS (
                            SELECT asset_id, (embedding <=> ($2::text)::vector({})) as distance
                            FROM smart_search
                            WHERE embedding IS NOT NULL AND asset_id NOT IN (SELECT asset_id FROM tag_search)
                        ),
                        filtered_results AS (
                            SELECT asset_id, distance FROM tag_search
                            UNION ALL
                            SELECT asset_id, distance FROM semantic_search
                        )
                        SELECT asset_id, distance FROM filtered_results WHERE distance < 0.8 ORDER BY distance ASC LIMIT $3",
                        embedding_dim
                    )
                };
                let rows = client
                    .query(&sql, &[&ql, &embedding_str, &(limit as i64)])
                    .await?;
                let results = rows
                    .into_iter()
                    .map(|r| SearchResult {
                        asset_id: r.get::<_, String>(0),
                        distance: r.get::<_, f64>(1) as f32,
                    })
                    .collect();
                Ok(results)
            }
        }
    }

    #[instrument(skip(self))]
    pub async fn list_all_photos(&self) -> Result<Vec<PhotoRecord>> {
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                let results = task::spawn_blocking(move || {
                    let conn = conn.lock();
                    let sql = "SELECT asset_id, image_width, image_height, content_type, strftime('%Y-%m-%d %H:%M:%S', created_at) as created_at FROM smart_search ORDER BY created_at DESC";
                    let mut stmt = conn.prepare(sql)?;
                    let results = stmt.query_map([], |row| {
                        Ok(PhotoRecord { asset_id: row.get(0)?, image_width: row.get(1)?, image_height: row.get(2)?, content_type: row.get(3)?, created_at: row.get(4)? })
                    })?;
                    let mut photos = Vec::new();
                    for result in results { photos.push(result?); }
                    debug!("Found {} photos in database", photos.len());
                    Ok::<_, anyhow::Error>(photos)
                }).await??;
                Ok(results)
            }
            Backend::Pg(pg) => {
                let client = pg.clone();
                let rows = client.query("SELECT asset_id, image_width, image_height, content_type, to_char(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at FROM smart_search ORDER BY created_at DESC", &[]).await?;
                let photos = rows
                    .into_iter()
                    .map(|r| PhotoRecord {
                        asset_id: r.get::<_, String>(0),
                        image_width: r.get::<_, i32>(1),
                        image_height: r.get::<_, i32>(2),
                        content_type: r.get::<_, String>(3),
                        created_at: r.get::<_, String>(4),
                    })
                    .collect();
                Ok(photos)
            }
        }
    }

    #[instrument(skip(self))]
    pub async fn get_photo_data(&self, asset_id: &str) -> Result<Option<PhotoData>> {
        match &self.backend {
            Backend::Duck(conn) => {
                let conn = conn.clone();
                let id = asset_id.to_string();
                let result = task::spawn_blocking(move || {
                    let conn = conn.lock();
                    let sql = "SELECT image_data, content_type, image_width, image_height FROM smart_search WHERE asset_id = ?";
                    let mut stmt = conn.prepare(sql)?;
                    let mut results = stmt.query_map([id], |row| {
                        let bytes: Option<Vec<u8>> = row.get(0).ok();
                        Ok(PhotoData {
                            image_data: bytes.unwrap_or_default(),
                            content_type: row.get(1)?,
                            image_width: row.get(2)?,
                            image_height: row.get(3)?,
                        })
                    })?;
                    if let Some(result) = results.next() { Ok::<Option<PhotoData>, anyhow::Error>(Some(result?)) } else { Ok(None) }
                }).await??;
                Ok(result)
            }
            Backend::Pg(pg) => {
                let client = pg.clone();
                let rows = client.query("SELECT image_data, content_type, image_width, image_height FROM smart_search WHERE asset_id = $1", &[&asset_id]).await?;
                if let Some(r) = rows.into_iter().next() {
                    let bytes: Option<Vec<u8>> = r.get(0);
                    Ok(Some(PhotoData {
                        image_data: bytes.unwrap_or_default(),
                        content_type: r.get::<_, String>(1),
                        image_width: r.get::<_, i32>(2),
                        image_height: r.get::<_, i32>(3),
                    }))
                } else {
                    Ok(None)
                }
            }
        }
    }
}

/// Filter search results by score distribution to match Immich's behavior
/// This detects natural cutoff points where similarity drops significantly
fn filter_by_score_distribution(mut results: Vec<SearchResult>) -> Vec<SearchResult> {
    if results.len() <= 2 {
        return results;
    }

    // Results are already sorted by distance (ASC), so lower distances = more similar

    // Look for the biggest gap in distances
    let mut max_gap = 0.0_f32;
    let mut cutoff_index = results.len();

    for i in 0..(results.len() - 1) {
        let gap = results[i + 1].distance - results[i].distance;

        // Only consider this a significant gap if:
        // 1. The gap is substantial (> 0.03)
        // 2. We have at least 1 result before the gap
        // 3. This gap is the largest we've seen
        if gap > 0.03 && i >= 0 && gap > max_gap {
            max_gap = gap;
            cutoff_index = i + 1;
        }
    }

    // Additional heuristic: if the first result has distance > 0.8,
    // it's probably not very relevant, so return empty
    if results[0].distance > 0.8 {
        return vec![];
    }

    // Additional heuristic: keep results with distance < 0.75 (very similar)
    // and apply gap-based filtering for everything else
    let mut filtered = Vec::new();
    for (i, result) in results.iter().enumerate() {
        if result.distance < 0.75 || i < cutoff_index {
            filtered.push(result.clone());
        }
    }

    // Don't return more than 10 results even with filtering
    filtered.truncate(10);

    tracing::debug!(
        "Score distribution filtering: {} -> {} results, max_gap: {:.4}, cutoff_index: {}",
        results.len(),
        filtered.len(),
        max_gap,
        cutoff_index
    );

    filtered
}
