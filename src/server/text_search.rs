use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{anyhow, Result};
use axum::{extract::State, http::HeaderMap, Json};
use serde::{Deserialize, Serialize};
use std::fs;
use tantivy::collector::Count;
use tantivy::collector::TopDocs;
use tantivy::doc;
use tantivy::query::{BooleanQuery, Occur, QueryParser};
use tantivy::schema::{
    Field, IndexRecordOption, Schema, SchemaBuilder, TextFieldIndexing, TextOptions, FAST, INDEXED,
    STORED, TEXT,
};
use tantivy::{Document as _, Index, IndexReader, IndexWriter};

use crate::auth::types::User;
use crate::server::state::AppState;
use crate::server::AppError;

#[derive(Debug, Deserialize)]
pub struct TextSearchRequest {
    pub q: String,
    pub page: Option<usize>,
    pub limit: Option<usize>,
    #[serde(default)]
    pub media: Option<String>, // "photos" | "videos" | "all"
    #[serde(default)]
    pub locked: Option<bool>,
    #[serde(default)]
    pub date_from: Option<i64>,
    #[serde(default)]
    pub date_to: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct TextSearchHit {
    pub asset_id: String,
    pub score: f32,
}

#[derive(Debug, Serialize)]
pub struct TextSearchResponse {
    pub items: Vec<TextSearchHit>,
    pub total: usize,
    pub page: usize,
    pub has_more: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>, // "text" | "clip" (auto-fallback indicator)
}

#[derive(Clone)]
struct Fields {
    asset_id: Field,
    filename: Field,
    caption: Field,
    description: Field,
    ocr_text: Field,
    comments_json: Field,
    comments_text: Field,
    created_at: Field,
    is_video: Field,
    locked: Field,
}

fn text_with_positions(stored: bool) -> TextOptions {
    let mut indexing = TextFieldIndexing::default();
    indexing = indexing.set_tokenizer("default");
    indexing = indexing.set_index_option(IndexRecordOption::WithFreqsAndPositions);
    let mut opts = TextOptions::default();
    opts = opts.set_indexing_options(indexing);
    if stored {
        opts = opts.set_stored();
    }
    opts
}

fn build_schema() -> (Schema, Fields) {
    let mut builder = SchemaBuilder::default();
    let mut asset_opts = TextOptions::default();
    let mut idx = TextFieldIndexing::default();
    idx = idx.set_tokenizer("default");
    idx = idx.set_index_option(IndexRecordOption::Basic);
    asset_opts = asset_opts.set_indexing_options(idx).set_stored();
    let asset_id = builder.add_text_field("asset_id", asset_opts);
    let filename = builder.add_text_field("filename", text_with_positions(false));
    let caption = builder.add_text_field("caption", text_with_positions(true));
    let description = builder.add_text_field("description", text_with_positions(true));
    let ocr_text = builder.add_text_field("ocr_text", text_with_positions(true));
    let comments_json = builder.add_json_field(
        "comments_json",
        tantivy::schema::JsonObjectOptions::default()
            .set_stored()
            .set_indexing_options(
                tantivy::schema::TextFieldIndexing::default()
                    .set_tokenizer("default")
                    .set_index_option(IndexRecordOption::WithFreqsAndPositions),
            ),
    );
    let comments_text = builder.add_text_field("comments_text", text_with_positions(true));
    // For filtering and range queries, these fields must be INDEXED, not only FAST
    let created_at = builder.add_i64_field("created_at", FAST | INDEXED);
    let is_video = builder.add_bool_field("is_video", FAST | INDEXED);
    let locked = builder.add_bool_field("locked", FAST | INDEXED);

    let schema = builder.build();
    (
        schema,
        Fields {
            asset_id,
            filename,
            caption,
            description,
            ocr_text,
            comments_json,
            comments_text,
            created_at,
            is_video,
            locked,
        },
    )
}

// Tokenizer registration is optional; default tokenizer is used.

fn user_index_dir(state: &AppState, user_id: &str) -> PathBuf {
    let root = state.user_data_path(user_id);
    root.join("search_index")
}

fn open_or_create_index_for_user(state: &AppState, user_id: &str) -> Result<(Index, Fields)> {
    let dir = user_index_dir(state, user_id);
    std::fs::create_dir_all(&dir)?;
    let (target_schema, _target_fields) = build_schema();

    // Try to open existing index and validate critical fields
    match Index::open_in_dir(&dir) {
        Ok(idx) => {
            let s = idx.schema();
            let mut need_recreate = false;
            // Ensure critical fields have expected options
            match s.get_field("asset_id") {
                Ok(f) => {
                    let stored = s.get_field_entry(f).is_stored();
                    if !stored {
                        need_recreate = true;
                    }
                }
                Err(_) => need_recreate = true,
            }
            // created_at must be indexed for RangeQuery
            if let Ok(f) = s.get_field("created_at") {
                if !s.get_field_entry(f).is_indexed() {
                    need_recreate = true;
                }
            } else {
                need_recreate = true;
            }
            // is_video must be indexed for TermQuery filters
            if let Ok(f) = s.get_field("is_video") {
                if !s.get_field_entry(f).is_indexed() {
                    need_recreate = true;
                }
            } else {
                need_recreate = true;
            }
            // locked must be indexed for TermQuery filters
            if let Ok(f) = s.get_field("locked") {
                if !s.get_field_entry(f).is_indexed() {
                    need_recreate = true;
                }
            } else {
                need_recreate = true;
            }
            // Ensure caption/description fields exist (new)
            if s.get_field("caption").is_err() {
                need_recreate = true;
            }
            if s.get_field("description").is_err() {
                need_recreate = true;
            }
            if !need_recreate {
                // We can keep and reuse this index
                let field =
                    |name: &str| -> Result<Field> { s.get_field(name).map_err(|e| anyhow!(e)) };
                let fields = Fields {
                    asset_id: field("asset_id")?,
                    filename: field("filename")?,
                    caption: field("caption")?,
                    description: field("description")?,
                    ocr_text: field("ocr_text")?,
                    comments_json: field("comments_json")?,
                    comments_text: field("comments_text")?,
                    created_at: field("created_at")?,
                    is_video: field("is_video")?,
                    locked: field("locked")?,
                };
                return Ok((idx, fields));
            }

            // Existing index but schema mismatch: recreate and reset watermark
            tracing::warn!(
                target = "search",
                "[SEARCH] Recreating index for user {} due to schema mismatch; triggering full sync",
                user_id
            );
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir)?;
            let index = Index::create_in_dir(&dir, target_schema.clone())?;
            if let Some(pg) = &state.pg_client {
                // Reset watermark in Postgres for this user's org (fire-and-forget to avoid blocking reactor)
                let pg = pg.clone();
                let uid = user_id.to_string();
                let org_id = state.org_id_for_user(user_id);
                tokio::spawn(async move {
                    let _ = pg
                        .execute(
                            "UPDATE photos SET search_indexed_at=NULL WHERE organization_id=$1 AND user_id=$2",
                            &[&org_id, &uid],
                        )
                        .await;
                });
            } else if let Ok(db) = state.get_user_data_database(user_id) {
                let conn = db.lock();
                let _ = conn.execute("UPDATE photos SET search_indexed_at = NULL", []);
            }
            let s = index.schema();
            let field = |name: &str| -> Result<Field> { s.get_field(name).map_err(|e| anyhow!(e)) };
            let fields = Fields {
                asset_id: field("asset_id")?,
                filename: field("filename")?,
                caption: field("caption")?,
                description: field("description")?,
                ocr_text: field("ocr_text")?,
                comments_json: field("comments_json")?,
                comments_text: field("comments_text")?,
                created_at: field("created_at")?,
                is_video: field("is_video")?,
                locked: field("locked")?,
            };
            Ok((index, fields))
        }
        Err(_e) => {
            // Fresh directory (no prior index): create without warning
            tracing::info!(
                target = "search",
                "[SEARCH] Creating text index for user {} (fresh)",
                user_id
            );
            let index = Index::create_in_dir(&dir, target_schema.clone())?;
            let s = index.schema();
            let field = |name: &str| -> Result<Field> { s.get_field(name).map_err(|e| anyhow!(e)) };
            let fields = Fields {
                asset_id: field("asset_id")?,
                filename: field("filename")?,
                caption: field("caption")?,
                description: field("description")?,
                ocr_text: field("ocr_text")?,
                comments_json: field("comments_json")?,
                comments_text: field("comments_text")?,
                created_at: field("created_at")?,
                is_video: field("is_video")?,
                locked: field("locked")?,
            };
            Ok((index, fields))
        }
    }
}

// Very simple flattener: collect all string leaves; join by space.
fn flatten_json_text(raw: &str) -> String {
    let mut out = Vec::new();
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(raw) {
        fn walk(v: &serde_json::Value, out: &mut Vec<String>) {
            match v {
                serde_json::Value::String(s) => out.push(s.clone()),
                serde_json::Value::Array(arr) => {
                    for it in arr {
                        walk(it, out);
                    }
                }
                serde_json::Value::Object(map) => {
                    for (_, it) in map {
                        walk(it, out);
                    }
                }
                _ => {}
            }
        }
        walk(&val, &mut out);
    }
    out.join(" ")
}

async fn get_user_from_headers(
    headers: &HeaderMap,
    auth: &crate::auth::AuthService,
) -> Result<User> {
    // Try Bearer token
    if let Some(token) = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    {
        return Ok(auth.verify_token(token).await?);
    }
    // Fallback cookie
    if let Some(cookie_hdr) = headers
        .get(axum::http::header::COOKIE)
        .and_then(|v| v.to_str().ok())
    {
        for part in cookie_hdr.split(';') {
            let trimmed = part.trim();
            if let Some(val) = trimmed.strip_prefix("auth-token=") {
                return Ok(auth.verify_token(val).await?);
            }
        }
    }
    Err(anyhow!("Missing authorization token"))
}

#[derive(Debug, Deserialize)]
pub struct ReindexRequest {
    pub mode: Option<String>,
}

pub async fn reindex_text(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(_req): Json<ReindexRequest>,
) -> Result<Json<serde_json::Value>, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let dir = user_index_dir(&state, &user.user_id);
    let (index, fields) =
        open_or_create_index_for_user(&state, &user.user_id).map_err(|e| AppError(anyhow!(e)))?;
    let mut writer = index
        .writer::<tantivy::TantivyDocument>(50_000_000)
        .map_err(|e| AppError(anyhow!(e)))?; // ~50MB

    // Fetch source rows
    let mut count: usize = 0;
    let rows_iter: Vec<(
        String,
        String,
        String,
        String,
        String,
        String,
        i64,
        bool,
        bool,
    )> = if let Some(pg) = &state.pg_client {
        let sql = r#"
            SELECT p.asset_id, COALESCE(p.filename,''), COALESCE(p.caption,''), COALESCE(p.description,''),
                   COALESCE((SELECT string_agg(body, ' ') FROM photo_comments pc WHERE pc.organization_id=p.organization_id AND pc.asset_id=p.asset_id), '') AS comments_text_agg,
                   COALESCE(p.ocr_text,''), p.created_at, p.is_video, COALESCE(p.locked, FALSE)
            FROM photos p
            WHERE p.organization_id = $1 AND COALESCE(p.locked, FALSE) = FALSE
            ORDER BY p.created_at DESC
        "#;
        let rows = pg
            .query(sql, &[&user.organization_id])
            .await
            .map_err(|e| AppError(anyhow!(e)))?;
        rows.into_iter()
            .map(|r| {
                (
                    r.get::<_, String>(0),
                    r.get::<_, String>(1),
                    r.get::<_, String>(2),
                    r.get::<_, String>(3),
                    r.get::<_, String>(4),
                    r.get::<_, String>(5),
                    r.get::<_, i64>(6),
                    r.get::<_, bool>(7),
                    r.get::<_, bool>(8),
                )
            })
            .collect()
    } else {
        let db = state.get_user_data_database(&user.user_id)?;
        let conn = db.lock();
        let mut stmt = conn
            .prepare(
                "SELECT p.asset_id, p.filename, COALESCE(p.caption,''), COALESCE(p.description,''),
                        COALESCE((SELECT string_agg(body, ' ')
                                  FROM photo_comments pc
                                  WHERE pc.organization_id = p.organization_id AND pc.asset_id = p.asset_id), '') AS comments_text_agg,
                        COALESCE(p.ocr_text,''), p.created_at, p.is_video, p.locked
                 FROM photos p
                 WHERE p.organization_id = ? AND p.locked = 0
                 ORDER BY p.created_at DESC",
            )
            .map_err(|e| AppError(anyhow!(e)))?;
        let rows = stmt
            .query_map(duckdb::params![user.organization_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1).unwrap_or_default(),
                    row.get::<_, String>(2).unwrap_or_default(),
                    row.get::<_, String>(3).unwrap_or_default(),
                    row.get::<_, String>(4).unwrap_or_default(),
                    row.get::<_, String>(5).unwrap_or_default(),
                    row.get::<_, i64>(6).unwrap_or(0),
                    row.get::<_, bool>(7).unwrap_or(false),
                    row.get::<_, bool>(8).unwrap_or(false),
                ))
            })
            .map_err(|e| AppError(anyhow!(e)))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| AppError(anyhow!(e)))?
    };

    let now = chrono::Utc::now().timestamp();
    // Update watermark progressively
    for r in rows_iter {
        let (
            asset_id,
            filename,
            caption,
            description,
            comments_text,
            ocr_text,
            created_at,
            is_video,
            locked,
        ) = r;
        let mut doc = tantivy::TantivyDocument::default();
        doc.add_text(fields.asset_id, asset_id.clone());
        doc.add_text(fields.filename, filename);
        doc.add_text(fields.caption, caption);
        if !description.is_empty() {
            doc.add_text(fields.description, description);
        }
        if !comments_text.is_empty() {
            doc.add_text(fields.comments_text, comments_text);
        }
        if !ocr_text.is_empty() {
            doc.add_text(fields.ocr_text, ocr_text);
        }
        doc.add_i64(fields.created_at, created_at);
        doc.add_bool(fields.is_video, is_video);
        doc.add_bool(fields.locked, locked);
        // Intentionally skip storing comments_json if invalid; comments_text already captures searchable text
        writer.add_document(doc).map_err(|e| AppError(anyhow!(e)))?;
        count += 1;
        if let Some(pg) = &state.pg_client {
            let _ = pg
                .execute(
                    "UPDATE photos SET search_indexed_at=$1 WHERE organization_id=$2 AND asset_id=$3",
                    &[&now, &user.organization_id, &asset_id],
                )
                .await;
        } else {
            let db = state.get_user_data_database(&user.user_id)?;
            let conn = db.lock();
            let _ = conn.execute(
                "UPDATE photos SET search_indexed_at = ? WHERE organization_id = ? AND asset_id = ?",
                duckdb::params![now, user.organization_id, &asset_id],
            );
        }
        if count % 10_000 == 0 {
            writer.commit().map_err(|e| AppError(anyhow!(e)))?;
        }
    }
    writer.commit().map_err(|e| AppError(anyhow!(e)))?;
    Ok(Json(
        serde_json::json!({"indexed": count, "dir": dir.display().to_string()}),
    ))
}

#[derive(Debug, Deserialize)]
pub struct SyncRequest {
    pub limit: Option<usize>,
}

pub fn sync_user(state: &AppState, user_id: &str, limit: usize) -> Result<usize> {
    let (index, fields) = open_or_create_index_for_user(state, user_id)?;
    let org_id_for_user = state.org_id_for_user(user_id);
    let mut writer = index.writer::<tantivy::TantivyDocument>(20_000_000)?;
    let limit = limit.min(20_000).max(1);
    let rows: Vec<(
        String,
        String,
        String,
        String,
        String,
        String,
        i64,
        bool,
        bool,
    )> = if let Some(pg) = &state.pg_client {
        // Resolve org via helper
        let org_id: i32 = org_id_for_user;
        let sql = r#"
            SELECT p.asset_id, COALESCE(p.filename,''), COALESCE(p.caption,''), COALESCE(p.description,''),
                   COALESCE((SELECT string_agg(body, ' ') FROM photo_comments pc WHERE pc.organization_id = p.organization_id AND pc.asset_id = p.asset_id), '') AS comments_text_agg,
                   COALESCE(p.ocr_text,''), p.created_at, p.is_video, COALESCE(p.locked,FALSE)
            FROM photos p
            WHERE p.organization_id=$1 AND (p.search_indexed_at IS NULL OR p.modified_at > COALESCE(p.search_indexed_at,0)) AND COALESCE(p.locked,FALSE)=FALSE
            ORDER BY p.modified_at DESC
            LIMIT $2
        "#;
        let rows = futures::executor::block_on(pg.query(sql, &[&org_id, &(limit as i64)]))
            .unwrap_or_default();
        rows.into_iter()
            .map(|r| {
                (
                    r.get::<_, String>(0),
                    r.get::<_, String>(1),
                    r.get::<_, String>(2),
                    r.get::<_, String>(3),
                    r.get::<_, String>(4),
                    r.get::<_, String>(5),
                    r.get::<_, i64>(6),
                    r.get::<_, bool>(7),
                    r.get::<_, bool>(8),
                )
            })
            .collect()
    } else {
        let db = state.get_user_data_database(user_id)?;
        let conn = db.lock();
        let mut stmt = conn.prepare(&format!(
            "SELECT p.asset_id, p.filename, COALESCE(p.caption,''), COALESCE(p.description,''),
                     COALESCE((SELECT string_agg(body, ' ') FROM photo_comments pc WHERE pc.asset_id = p.asset_id), '') AS comments_text_agg,
                     COALESCE(p.ocr_text,''), p.created_at, p.is_video, p.locked
             FROM photos p
             WHERE (search_indexed_at IS NULL OR modified_at > COALESCE(search_indexed_at, 0)) AND p.locked = 0
             ORDER BY modified_at DESC
             LIMIT {}",
            limit
        ))?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1).unwrap_or_default(),
                row.get::<_, String>(2).unwrap_or_default(),
                row.get::<_, String>(3).unwrap_or_default(),
                row.get::<_, String>(4).unwrap_or_default(),
                row.get::<_, String>(5).unwrap_or_default(),
                row.get::<_, i64>(6).unwrap_or(0),
                row.get::<_, bool>(7).unwrap_or(false),
                row.get::<_, bool>(8).unwrap_or(false),
            ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    let now = chrono::Utc::now().timestamp();
    let mut count = 0usize;
    for r in rows {
        let (
            asset_id,
            filename,
            caption,
            description,
            comments_text,
            ocr_text,
            created_at,
            is_video,
            locked,
        ) = r;
        let mut doc = tantivy::TantivyDocument::default();
        doc.add_text(fields.asset_id, asset_id.clone());
        doc.add_text(fields.filename, filename);
        doc.add_text(fields.caption, caption);
        if !description.is_empty() {
            doc.add_text(fields.description, description);
        }
        if !comments_text.is_empty() {
            doc.add_text(fields.comments_text, comments_text);
        }
        if !ocr_text.is_empty() {
            doc.add_text(fields.ocr_text, ocr_text);
        }
        doc.add_i64(fields.created_at, created_at);
        doc.add_bool(fields.is_video, is_video);
        doc.add_bool(fields.locked, locked);
        // Skip comments_json storage when unknown/invalid
        writer.add_document(doc)?;
        count += 1;
        if let Some(pg) = &state.pg_client {
            let _ = futures::executor::block_on(pg.execute(
                "UPDATE photos SET search_indexed_at=$1 WHERE asset_id=$2",
                &[&now, &asset_id],
            ));
        } else {
            let db = state.get_user_data_database(user_id)?;
            let conn = db.lock();
            let _ = conn.execute(
                "UPDATE photos SET search_indexed_at = ? WHERE asset_id = ?",
                duckdb::params![now, &asset_id],
            );
        }
    }
    writer.commit()?;
    Ok(count)
}

pub async fn sync_text(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<SyncRequest>,
) -> Result<Json<serde_json::Value>, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let updated = sync_user(&state, &user.user_id, req.limit.unwrap_or(5000)).map_err(AppError)?;
    Ok(Json(serde_json::json!({"updated": updated})))
}

// ------ Internal helpers to be called from other handlers ------

pub fn reindex_single_asset(state: &AppState, user_id: &str, asset_id: &str) -> Result<()> {
    let (index, fields) = open_or_create_index_for_user(state, user_id)?;
    // Tantivy requires a minimum writer memory per thread (~15MB). Use 20MB here for safety.
    let mut writer = index.writer::<tantivy::TantivyDocument>(20_000_000)?;
    // Resolve org once outside any DB locks
    let org_id: i32 = state.org_id_for_user(user_id);
    // Fetch row
    if let Some(pg) = &state.pg_client {
        // Resolve org id
        let org_id: i32 = futures::executor::block_on(pg.query_one(
            "SELECT organization_id FROM users WHERE user_id=$1 LIMIT 1",
            &[&user_id],
        ))
        .ok()
        .map(|r| r.get::<_, i32>(0))
        .unwrap_or(1);
        if let Ok(row) = futures::executor::block_on(pg.query_one(
            "SELECT p.asset_id, COALESCE(p.filename,''), COALESCE(p.caption,''), COALESCE(p.description,''),
                    COALESCE((SELECT string_agg(body, ' ') FROM photo_comments pc WHERE pc.organization_id = p.organization_id AND pc.asset_id = p.asset_id), '') AS comments_text_agg,
                    COALESCE(p.ocr_text,''), p.created_at, p.is_video, COALESCE(p.locked,FALSE) FROM photos p WHERE p.organization_id = $1 AND p.asset_id = $2 LIMIT 1",
            &[&org_id, &asset_id],
        )) {
            let (
                asset_id_v,
                filename,
                caption,
                description,
                comments_text,
                ocr_text,
                created_at,
                is_video,
                locked,
            ) = (
                row.get::<_, String>(0),
                row.get::<_, String>(1),
                row.get::<_, String>(2),
                row.get::<_, String>(3),
                row.get::<_, String>(4),
                row.get::<_, String>(5),
                row.get::<_, i64>(6),
                row.get::<_, bool>(7),
                row.get::<_, bool>(8),
            );
            writer.delete_term(tantivy::Term::from_field_text(fields.asset_id, &asset_id_v));
            if !locked {
                let mut doc = tantivy::TantivyDocument::default();
                doc.add_text(fields.asset_id, asset_id_v.clone());
                doc.add_text(fields.filename, filename);
                doc.add_text(fields.caption, caption);
                if !description.is_empty() { doc.add_text(fields.description, description); }
                if !comments_text.is_empty() { doc.add_text(fields.comments_text, comments_text); }
                if !ocr_text.is_empty() { doc.add_text(fields.ocr_text, ocr_text); }
                doc.add_i64(fields.created_at, created_at);
                doc.add_bool(fields.is_video, is_video);
                doc.add_bool(fields.locked, locked);
                writer.add_document(doc)?;
            }
            writer.commit()?;
            let now = chrono::Utc::now().timestamp();
            let _ = futures::executor::block_on(pg.execute(
                "UPDATE photos SET search_indexed_at=$1 WHERE organization_id=$2 AND asset_id=$3",
                &[&now, &org_id, &asset_id],
            ));
        }
        return Ok(());
    }
    let db = state.get_user_data_database(user_id)?;
    let conn = db.lock();
    let mut stmt = conn.prepare(
        "SELECT p.asset_id, p.filename, COALESCE(p.caption,''), COALESCE(p.description,''),
                 COALESCE((SELECT string_agg(body, ' ')
                           FROM photo_comments pc
                           WHERE pc.organization_id = p.organization_id AND pc.asset_id = p.asset_id), '') AS comments_text_agg,
                 COALESCE(p.ocr_text,''), p.created_at, p.is_video, p.locked FROM photos p WHERE p.organization_id = ? AND p.asset_id = ? LIMIT 1",
    )?;
    if let Ok(row) = stmt.query_row(duckdb::params![org_id, asset_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1).unwrap_or_default(),
            row.get::<_, String>(2).unwrap_or_default(),
            row.get::<_, String>(3).unwrap_or_default(),
            row.get::<_, String>(4).unwrap_or_default(),
            row.get::<_, String>(5).unwrap_or_default(),
            row.get::<_, i64>(6).unwrap_or(0),
            row.get::<_, bool>(7).unwrap_or(false),
            row.get::<_, bool>(8).unwrap_or(false),
        ))
    }) {
        let (
            asset_id_v,
            filename,
            caption,
            description,
            comments_text,
            ocr_text,
            created_at,
            is_video,
            locked,
        ) = row;
        // Always remove any existing doc first
        writer.delete_term(tantivy::Term::from_field_text(fields.asset_id, &asset_id_v));
        if !locked {
            // Only index unlocked assets
            let mut doc = tantivy::TantivyDocument::default();
            doc.add_text(fields.asset_id, asset_id_v.clone());
            doc.add_text(fields.filename, filename);
            doc.add_text(fields.caption, caption);
            if !description.is_empty() {
                doc.add_text(fields.description, description);
            }
            if !comments_text.is_empty() {
                doc.add_text(fields.comments_text, comments_text);
            }
            if !ocr_text.is_empty() {
                doc.add_text(fields.ocr_text, ocr_text);
            }
            doc.add_i64(fields.created_at, created_at);
            doc.add_bool(fields.is_video, is_video);
            doc.add_bool(fields.locked, locked);
            writer.add_document(doc)?;
        }
        writer.commit()?;
        // mark indexed
        let now = chrono::Utc::now().timestamp();
        let _ = conn.execute(
            "UPDATE photos SET search_indexed_at = ? WHERE organization_id = ? AND asset_id = ?",
            duckdb::params![now, org_id, asset_id],
        );
    }
    Ok(())
}

pub fn delete_single_asset(state: &AppState, user_id: &str, asset_id: &str) -> Result<()> {
    let (index, fields) = open_or_create_index_for_user(state, user_id)?;
    // Keep consistent with the min requirement as well
    let mut writer = index.writer::<tantivy::TantivyDocument>(20_000_000)?;
    writer.delete_term(tantivy::Term::from_field_text(fields.asset_id, asset_id));
    writer.commit()?;
    Ok(())
}

#[derive(Debug, Serialize)]
pub struct SearchStats {
    pub docs: usize,
    pub index_path: String,
    pub size_bytes: u64,
}

pub async fn stats_text(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<SearchStats>, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let (index, _fields) =
        open_or_create_index_for_user(&state, &user.user_id).map_err(|e| AppError(anyhow!(e)))?;
    let reader = index.reader().map_err(|e| AppError(anyhow!(e)))?;
    let searcher = reader.searcher();
    // If index is empty (e.g., after schema migration), kick off an async sync.
    if let Ok(doc_count) = searcher.search(&tantivy::query::AllQuery, &Count) {
        if doc_count == 0 {
            let st = Arc::clone(&state);
            let uid = user.user_id.clone();
            tokio::spawn(async move {
                let _ = tokio::task::spawn_blocking(move || {
                    let _ = sync_user(&st, &uid, 50_000);
                })
                .await;
            });
        }
    }
    // If index is empty (e.g., after schema migration), kick off an async sync.
    if let Ok(doc_count) = searcher.search(&tantivy::query::AllQuery, &Count) {
        if doc_count == 0 {
            let st = Arc::clone(&state);
            let uid = user.user_id.clone();
            tokio::spawn(async move {
                let _ = tokio::task::spawn_blocking(move || {
                    let _ = sync_user(&st, &uid, 50_000);
                })
                .await;
            });
        }
    }
    let docs = searcher
        .search(&tantivy::query::AllQuery, &Count)
        .map_err(|e| AppError(anyhow!(e)))?;
    let mut size = 0u64;
    let dir = user_index_dir(&state, &user.user_id);
    if let Ok(entries) = fs::read_dir(&dir) {
        for e in entries.flatten() {
            if let Ok(md) = e.metadata() {
                if md.is_file() {
                    size += md.len();
                }
            }
        }
    }
    Ok(Json(SearchStats {
        docs,
        index_path: dir.display().to_string(),
        size_bytes: size,
    }))
}

pub async fn text_search(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<TextSearchResponse>, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let (index, fields) =
        open_or_create_index_for_user(&state, &user.user_id).map_err(|e| AppError(anyhow!(e)))?;
    let reader = index.reader().map_err(|e| AppError(anyhow!(e)))?;
    let searcher = reader.searcher();

    // If the index is empty (e.g., just recreated), kick off a background sync for this user
    if let Ok(doc_count) = searcher.search(&tantivy::query::AllQuery, &Count) {
        if doc_count == 0 {
            let st = Arc::clone(&state);
            let uid = user.user_id.clone();
            tokio::spawn(async move {
                let _ = tokio::task::spawn_blocking(move || {
                    let _ = super::text_search::sync_user(&st, &uid, 50_000);
                })
                .await;
            });
        }
    }
    // Backward-compat: accept { query, limit } and map to our fields
    let q = payload
        .get("q")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            payload
                .get("query")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
        .unwrap_or_default();
    let engine = payload
        .get("engine")
        .and_then(|v| v.as_str())
        .unwrap_or("auto"); // auto|text|semantic
    let page = payload
        .get("page")
        .and_then(|v| v.as_u64())
        .map(|v| v as usize)
        .unwrap_or(1)
        .max(1);
    let limit = payload
        .get("limit")
        .and_then(|v| v.as_u64())
        .map(|v| v as usize)
        .unwrap_or(50)
        .min(200);
    let media = payload
        .get("media")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    // Exclude locked by default. Only when locked=true do we lift the filter (though locked docs are not indexed).
    let locked_flag = payload
        .get("locked")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let date_from = payload.get("date_from").and_then(|v| v.as_i64());
    let date_to = payload.get("date_to").and_then(|v| v.as_i64());

    // Build the multi-field parser with boosts (exclude raw JSON field from parser to avoid edge-case parsing issues)
    let mut parser = QueryParser::for_index(
        &index,
        vec![
            fields.comments_text,
            fields.ocr_text,
            fields.caption,
            fields.description,
            fields.filename,
        ],
    );
    parser.set_conjunction_by_default();
    let query = parser.parse_query(&q).map_err(|e| AppError(anyhow!(e)))?;

    // Filters
    let mut filters: Vec<(Occur, Box<dyn tantivy::query::Query>)> = Vec::new();
    if let Some(media) = &media {
        match media.as_str() {
            "photos" => filters.push((
                Occur::Must,
                Box::new(tantivy::query::TermQuery::new(
                    tantivy::Term::from_field_bool(fields.is_video, false),
                    IndexRecordOption::Basic,
                )),
            )),
            "videos" => filters.push((
                Occur::Must,
                Box::new(tantivy::query::TermQuery::new(
                    tantivy::Term::from_field_bool(fields.is_video, true),
                    IndexRecordOption::Basic,
                )),
            )),
            _ => {}
        }
    }
    if !locked_flag {
        // Default: show only unlocked items
        filters.push((
            Occur::Must,
            Box::new(tantivy::query::TermQuery::new(
                tantivy::Term::from_field_bool(fields.locked, false),
                IndexRecordOption::Basic,
            )),
        ));
    }
    // Range queries require a field name (String) and a Range<i64>
    let created_field_name = index.schema().get_field_name(fields.created_at).to_string();
    match (date_from, date_to) {
        (Some(f), Some(t)) => {
            let end = t.saturating_add(1);
            filters.push((
                Occur::Must,
                Box::new(tantivy::query::RangeQuery::new_i64(
                    created_field_name.clone(),
                    f..end,
                )),
            ));
        }
        (Some(f), None) => {
            filters.push((
                Occur::Must,
                Box::new(tantivy::query::RangeQuery::new_i64(
                    created_field_name.clone(),
                    f..i64::MAX,
                )),
            ));
        }
        (None, Some(t)) => {
            let end = t.saturating_add(1);
            filters.push((
                Occur::Must,
                Box::new(tantivy::query::RangeQuery::new_i64(
                    created_field_name.clone(),
                    i64::MIN..end,
                )),
            ));
        }
        _ => {}
    }

    let combined: Box<dyn tantivy::query::Query> = if filters.is_empty() {
        query
    } else {
        let mut clauses = vec![(Occur::Must, query)];
        clauses.extend(filters);
        Box::new(BooleanQuery::new(clauses))
    };

    let topn = page * limit;
    let mut items_all: Vec<TextSearchHit> = Vec::new();
    let mut mode = Some("text".to_string());

    // Run text engine unless explicitly semantic
    if engine != "semantic" {
        let top_docs = searcher
            .search(&combined, &TopDocs::with_limit(topn))
            .map_err(|e| AppError(anyhow!(e)))?;
        for (score, addr) in top_docs.into_iter() {
            let retrieved: tantivy::TantivyDocument =
                searcher.doc(addr).map_err(|e| AppError(anyhow!(e)))?;
            // Tantivy 0.22 stores field values as OwnedValue; extract text safely
            let asset_vals = retrieved
                .get_first(fields.asset_id)
                .map(|v| match v {
                    tantivy::schema::OwnedValue::Str(s) => s.clone(),
                    tantivy::schema::OwnedValue::PreTokStr(pt) => pt.text.clone(),
                    tantivy::schema::OwnedValue::Array(arr) => {
                        // Pick first string-like element if present
                        arr.iter()
                            .find_map(|it| match it {
                                tantivy::schema::OwnedValue::Str(s) => Some(s.clone()),
                                tantivy::schema::OwnedValue::PreTokStr(pt) => Some(pt.text.clone()),
                                _ => None,
                            })
                            .unwrap_or_default()
                    }
                    _ => String::new(),
                })
                .unwrap_or_default();
            items_all.push(TextSearchHit {
                asset_id: asset_vals,
                score,
            });
        }
    }
    if !items_all.is_empty() {
        let sample: Vec<&str> = items_all
            .iter()
            .take(5)
            .map(|h| h.asset_id.as_str())
            .collect();
        tracing::info!(
            target = "search",
            "[SEARCH] q='{}' hits={} sample={:?}",
            q,
            items_all.len(),
            sample
        );
    } else {
        tracing::info!(target = "search", "[SEARCH] q='{}' text-hits=0", q);
        // Fallback to CLIP semantic search when text search has no results and engine is auto
        if !q.is_empty() && engine == "auto" {
            // Build user embedding store and encode query
            let store = state
                .create_user_embedding_store(&user.user_id)
                .map_err(|e| AppError(anyhow!(e)))?;
            let model_name = state.default_model.clone();
            if let Some(enc) =
                state.with_textual_encoder(Some(&model_name), |encoder| encoder.encode_text(&q))
            {
                let embedding = enc.map_err(|e| AppError(anyhow!(e)))?;
                match store.search_combined(&q, embedding, topn).await {
                    Ok(vecs) => {
                        if !vecs.is_empty() {
                            mode = Some("clip".to_string());
                            items_all = vecs
                                .into_iter()
                                .map(|r| TextSearchHit {
                                    asset_id: r.asset_id,
                                    score: (1.0 - r.distance).max(0.0),
                                })
                                .collect();
                            let sample: Vec<&str> = items_all
                                .iter()
                                .take(5)
                                .map(|h| h.asset_id.as_str())
                                .collect();
                            tracing::info!(
                                target = "search",
                                "[SEARCH] q='{}' clip-fallback hits={} sample={:?}",
                                q,
                                items_all.len(),
                                sample
                            );
                        }
                    }
                    Err(e) => {
                        tracing::error!(target = "search", "[SEARCH] CLIP fallback error: {}", e);
                    }
                }
            } else {
                tracing::warn!(
                    target = "search",
                    "[SEARCH] No textual encoder available for model '{}'; skipping CLIP fallback",
                    model_name
                );
            }
        }
    }

    // If engine is semantic: run CLIP only
    if engine == "semantic" {
        let store = state
            .create_user_embedding_store(&user.user_id)
            .map_err(|e| AppError(anyhow!(e)))?;
        let model_name = state.default_model.clone();
        if let Some(enc) =
            state.with_textual_encoder(Some(&model_name), |encoder| encoder.encode_text(&q))
        {
            let embedding = enc.map_err(|e| AppError(anyhow!(e)))?;
            match store.search_combined(&q, embedding, topn).await {
                Ok(vecs) => {
                    mode = Some("clip".to_string());
                    items_all = vecs
                        .into_iter()
                        .map(|r| TextSearchHit {
                            asset_id: r.asset_id,
                            score: (1.0 - r.distance).max(0.0),
                        })
                        .collect();
                    if !items_all.is_empty() {
                        let sample: Vec<&str> = items_all
                            .iter()
                            .take(5)
                            .map(|h| h.asset_id.as_str())
                            .collect();
                        tracing::info!(
                            target = "search",
                            "[SEARCH] q='{}' semantic hits={} sample={:?}",
                            q,
                            items_all.len(),
                            sample
                        );
                    }
                }
                Err(e) => {
                    tracing::error!(target = "search", "[SEARCH] semantic error: {}", e);
                }
            }
        }
    }
    let start = (page - 1) * limit;
    let items = items_all
        .into_iter()
        .skip(start)
        .take(limit)
        .collect::<Vec<_>>();
    let total = start + items.len();
    let has_more = items.len() == limit; // approximation
    Ok(Json(TextSearchResponse {
        items,
        total,
        page,
        has_more,
        mode,
    }))
}
