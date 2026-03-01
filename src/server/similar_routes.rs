use anyhow::anyhow;
use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderMap},
    response::IntoResponse,
    Json,
};
use duckdb::OptionalExt;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::auth::types::User;
use crate::server::state::AppState;
use crate::server::AppError;

#[derive(Debug, Deserialize)]
pub struct GroupsQuery {
    pub threshold: Option<u8>,
    pub min_group_size: Option<usize>,
    pub limit: Option<usize>,
    pub cursor: Option<usize>,
}

#[derive(Debug, Serialize, Clone)]
pub struct GroupItem {
    pub representative: String,
    pub count: usize,
    pub members: Vec<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct SimpleMeta {
    pub mime_type: Option<String>,
    pub size: i64,
    pub created_at: i64,
}

#[derive(Debug, Serialize)]
pub struct GroupsResponse {
    pub total_groups: usize,
    pub groups: Vec<GroupItem>,
    pub next_cursor: Option<usize>,
    /// Minimal metadata for assets present in the page's groups
    pub metadata: HashMap<String, SimpleMeta>,
}

#[derive(Debug, Serialize)]
pub struct NeighborItem {
    pub asset_id: String,
    pub distance: u32,
}

#[derive(Debug, Serialize)]
pub struct NeighborsResponse {
    pub asset_id: String,
    pub threshold: u8,
    pub neighbors: Vec<NeighborItem>,
}

#[derive(Debug, Serialize)]
pub struct VideoNeighborItem {
    pub asset_id: String,
    pub hits: u32,
    pub compared: u32,
    pub hit_ratio: f32,
    pub median_distance: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct VideoNeighborsResponse {
    pub asset_id: String,
    pub neighbors: Vec<VideoNeighborItem>,
}

// Extract user from headers (Authorization or auth-token cookie)
async fn extract_user(state: &AppState, headers: &HeaderMap) -> Result<User, AppError> {
    if let Some(token) = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    {
        let user = state.auth_service.verify_token(token).await?;
        return Ok(user);
    }
    if let Some(cookie_hdr) = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()) {
        for part in cookie_hdr.split(';') {
            let trimmed = part.trim();
            if let Some(val) = trimmed.strip_prefix("auth-token=") {
                let user = state.auth_service.verify_token(val).await?;
                return Ok(user);
            }
        }
    }
    Err(AppError(anyhow::anyhow!("Missing authorization token")))
}

#[tracing::instrument(skip(state, headers), fields(endpoint = "/api/similar/groups"))]
pub async fn similar_groups(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<GroupsQuery>,
) -> Result<impl IntoResponse, AppError> {
    let user = extract_user(&state, &headers).await?;
    let user_id = user.user_id.clone();
    let org_id = user.organization_id;
    let t_req = q.threshold.unwrap_or(state.phash_t_max);
    let t = t_req.min(state.phash_t_max);
    let min_group = q.min_group_size.unwrap_or(2);
    let limit = q.limit.unwrap_or(50).min(200);
    let cursor = q.cursor.unwrap_or(0);

    tracing::info!(
        "[PHASH] Groups request user={} t_req={} t_clamped={} min_group={} limit={} cursor={}",
        user_id,
        t_req,
        t,
        min_group,
        limit,
        cursor
    );
    let idx = state.get_or_build_similar_index(&user_id)?;
    let idx_guard = idx.read();
    let groups = idx_guard.groups(t, min_group);
    tracing::info!(
        "[PHASH] Groups response user={} hashes={} groups_found={}",
        user_id,
        idx_guard.len(),
        groups.len()
    );
    let total = groups.len();
    let end = (cursor + limit).min(total);
    let page = if cursor >= total {
        vec![]
    } else {
        groups[cursor..end].to_vec()
    };
    let resp_groups: Vec<GroupItem> = page
        .into_iter()
        .map(|mut g| {
            g.sort();
            let representative = g.first().cloned().unwrap_or_default();
            let count = g.len();
            GroupItem {
                representative,
                count,
                members: g,
            }
        })
        .collect();
    let next = if end < total { Some(end) } else { None };

    // Collect asset_ids in this page and fetch minimal metadata in one query
    let mut ids: HashSet<String> = HashSet::new();
    for g in &resp_groups {
        ids.insert(g.representative.clone());
        for a in &g.members {
            ids.insert(a.clone());
        }
    }
    let mut metadata: HashMap<String, SimpleMeta> = HashMap::new();
    if !ids.is_empty() {
        let pool = state.get_user_data_database(&user_id)?;
        let conn = pool.lock();
        let inlist = ids
            .iter()
            .map(|s| format!("'{}'", s.replace("'", "''")))
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "SELECT asset_id, mime_type, size, created_at FROM photos WHERE organization_id = {} AND asset_id IN ({})",
            org_id, inlist
        );
        if let Ok(mut stmt) = conn.prepare(&sql) {
            let rows = stmt.query_map([], |row| {
                let aid: String = row.get(0)?;
                let mt: Option<String> = row.get(1)?;
                let size: i64 = row.get(2)?;
                let created_at: i64 = row.get(3)?;
                Ok((aid, mt, size, created_at))
            })?;
            for r in rows {
                if let Ok((aid, mt, size, created_at)) = r {
                    metadata.insert(
                        aid,
                        SimpleMeta {
                            mime_type: mt,
                            size,
                            created_at,
                        },
                    );
                }
            }
        }
    }

    Ok(Json(GroupsResponse {
        total_groups: total,
        groups: resp_groups,
        next_cursor: next,
        metadata,
    }))
}

#[tracing::instrument(skip(state, headers), fields(endpoint = "/api/similar/:asset_id"))]
pub async fn similar_neighbors(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
    Query(q): Query<GroupsQuery>,
) -> Result<impl IntoResponse, AppError> {
    let user = extract_user(&state, &headers).await?;
    let user_id = user.user_id.clone();
    let t_req = q.threshold.unwrap_or(state.phash_t_max);
    let t = t_req.min(state.phash_t_max);
    let idx = state.get_or_build_similar_index(&user_id)?;
    // Lookup phash for the given asset
    let pool = state.get_user_data_database(&user_id)?;
    let conn = pool.lock();
    let phash_hex: Option<String> = conn
        .query_row(
            "SELECT phash_hex FROM photo_hashes WHERE organization_id = ? AND asset_id = ?",
            duckdb::params![user.organization_id, &asset_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .unwrap_or(None);
    drop(conn);
    let Some(hex) = phash_hex else {
        return Ok(Json(NeighborsResponse {
            asset_id,
            threshold: t,
            neighbors: vec![],
        }));
    };
    let Some(ph) = crate::photos::phash::phash_from_hex(&hex) else {
        return Ok(Json(NeighborsResponse {
            asset_id,
            threshold: t,
            neighbors: vec![],
        }));
    };
    let idx_guard = idx.read();
    let nbs = idx_guard.neighbors(ph, t, Some(&asset_id));
    tracing::info!(
        "[PHASH] Neighbors request user={} asset_id={} t_req={} t_clamped={} hashes={} neighbors_found={}",
        user_id,
        asset_id,
        t_req,
        t,
        idx_guard.len(),
        nbs.len()
    );
    let resp: Vec<NeighborItem> = nbs
        .into_iter()
        .map(|(a, d)| NeighborItem {
            asset_id: a,
            distance: d,
        })
        .collect();
    Ok(Json(NeighborsResponse {
        asset_id,
        threshold: t,
        neighbors: resp,
    }))
}

#[tracing::instrument(
    skip(state, headers),
    fields(endpoint = "/api/video/similar/:asset_id")
)]
pub async fn similar_video_neighbors(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
) -> Result<impl IntoResponse, AppError> {
    use duckdb::OptionalExt;
    let user = extract_user(&state, &headers).await?;
    let user_id = user.user_id.clone();
    let org_id = user.organization_id;
    // If video similarity is disabled, return empty neighbors immediately (after auth)
    if state.video_similarity_mode == crate::server::state::VideoSimilarityMode::Off {
        return Ok(Json(VideoNeighborsResponse {
            asset_id,
            neighbors: vec![],
        }));
    }
    let target_id_for_resp = asset_id.clone();

    // Verify target is a video and load its samples
    let pool = state.get_user_data_database(&user_id)?;
    let conn = pool.lock();
    let is_video: bool = conn
        .query_row(
            "SELECT is_video FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1",
            duckdb::params![org_id, &asset_id],
            |row| row.get::<_, bool>(0),
        )
        .optional()
        .unwrap_or(Some(false))
        .unwrap_or(false);
    if !is_video {
        // If not a video, return empty result to avoid mixing semantics with images
        return Ok(Json(VideoNeighborsResponse {
            asset_id: target_id_for_resp,
            neighbors: vec![],
        }));
    }

    let mut stmt = conn.prepare("SELECT sample_idx, phash_hex FROM video_phash_samples WHERE organization_id = ? AND asset_id = ? ORDER BY sample_idx")?;
    let rows = stmt.query_map(duckdb::params![org_id, &asset_id], |row| {
        let idx: i16 = row.get(0)?;
        let hex: String = row.get(1)?;
        Ok((idx as i32, hex))
    })?;
    let mut target: Vec<(i32, u64)> = Vec::new();
    for r in rows {
        if let Ok((i, hex)) = r {
            if let Some(ph) = crate::photos::phash::phash_from_hex(&hex) {
                target.push((i, ph));
            }
        }
    }
    drop(stmt);
    if target.is_empty() {
        return Ok(Json(VideoNeighborsResponse {
            asset_id: target_id_for_resp,
            neighbors: vec![],
        }));
    }

    // Candidate retrieval: any asset sharing one of the hashes (fast path)
    // Build IN list safely by preparing a dynamic statement
    let ph_hexes: Vec<String> = target
        .iter()
        .map(|(_, h)| crate::photos::phash::phash_to_hex(*h))
        .collect();
    let mut placeholders = Vec::new();
    for _ in 0..ph_hexes.len() {
        placeholders.push("?".to_string());
    }
    let sql = format!(
        "SELECT DISTINCT asset_id FROM video_phash_samples WHERE organization_id = ? AND phash_hex IN ({}) AND asset_id <> ?",
        placeholders.join(",")
    );
    let mut params: Vec<Box<dyn duckdb::ToSql>> = Vec::new();
    params.push(Box::new(org_id));
    for hex in &ph_hexes {
        params.push(Box::new(hex.as_str()));
    }
    // push target id as owned String to avoid borrow issues
    params.push(Box::new(asset_id.clone()));
    let mut stmt2 = conn.prepare(&sql)?;
    let mut cand_ids: Vec<String> = Vec::new();
    let results = stmt2.query_map(
        duckdb::params_from_iter(params.iter().map(|b| &**b)),
        |row| row.get::<_, String>(0),
    )?;
    for r in results {
        if let Ok(id) = r {
            cand_ids.push(id);
        }
    }
    drop(stmt2);

    // Load candidate samples and verify
    let h_max = state.video_phash_hamming_max as u32;
    let mut neighbors: Vec<VideoNeighborItem> = Vec::new();
    for cid in cand_ids {
        let mut s = conn.prepare("SELECT sample_idx, phash_hex FROM video_phash_samples WHERE organization_id = ? AND asset_id = ? ORDER BY sample_idx")?;
        let rows = s.query_map(duckdb::params![org_id, &cid], |row| {
            let idx: i16 = row.get(0)?;
            let hex: String = row.get(1)?;
            Ok((idx as i32, hex))
        })?;
        let mut cand: Vec<(i32, u64)> = Vec::new();
        for r in rows {
            if let Ok((i, hex)) = r {
                if let Some(ph) = crate::photos::phash::phash_from_hex(&hex) {
                    cand.push((i, ph));
                }
            }
        }
        drop(s);
        if cand.is_empty() {
            continue;
        }

        // Verify with ±1 index tolerance
        let mut distances: Vec<u32> = Vec::new();
        for (i, h) in &target {
            // search for i-1, i, i+1
            let mut best: Option<u32> = None;
            for j in [i - 1, *i, i + 1] {
                if let Some(&(_, ch)) = cand.iter().find(|(k, _)| *k == j) {
                    let d = crate::photos::phash::hamming_distance(*h, ch);
                    best = Some(best.map_or(d, |b| b.min(d)));
                }
            }
            if let Some(bd) = best {
                distances.push(bd);
            }
        }
        let compared = distances.len() as u32;
        if compared == 0 {
            continue;
        }
        let hits = distances.iter().filter(|&&d| d <= h_max).count() as u32;
        let hit_ratio = if compared > 0 {
            hits as f32 / compared as f32
        } else {
            0.0
        };
        let median_distance = {
            let mut v = distances.clone();
            v.sort_unstable();
            let n = v.len();
            if n == 0 {
                None
            } else {
                Some(v[n / 2])
            }
        };

        // Acceptance per stage rules
        let accept = if compared <= 3 {
            hits >= 2 && median_distance.unwrap_or(u32::MAX) <= 8
        } else if compared <= 5 {
            hits >= 3 && hit_ratio >= 0.60
        } else if compared <= 7 {
            hits >= 4 && hit_ratio >= 0.57
        } else {
            // 8..=9
            hits >= 5 && hit_ratio >= 0.55
        };

        if accept {
            neighbors.push(VideoNeighborItem {
                asset_id: cid,
                hits,
                compared,
                hit_ratio,
                median_distance,
            });
        }
    }

    // Sort by descending hit_ratio, then by hits desc
    neighbors.sort_by(|a, b| {
        b.hit_ratio
            .partial_cmp(&a.hit_ratio)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.hits.cmp(&a.hits))
    });

    Ok(Json(VideoNeighborsResponse {
        asset_id: target_id_for_resp,
        neighbors,
    }))
}

#[tracing::instrument(skip(state, headers), fields(endpoint = "/api/video/similar/groups"))]
pub async fn similar_video_groups(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<GroupsQuery>,
) -> Result<impl IntoResponse, AppError> {
    use std::collections::{HashMap, HashSet};
    let user = extract_user(&state, &headers).await?;
    let user_id = user.user_id.clone();
    // If video similarity is disabled, return empty groups immediately (after auth)
    if state.video_similarity_mode == crate::server::state::VideoSimilarityMode::Off {
        return Ok(Json(GroupsResponse {
            total_groups: 0,
            groups: vec![],
            next_cursor: None,
            metadata: HashMap::new(),
        }));
    }
    let min_group = q.min_group_size.unwrap_or(2);
    let limit = q.limit.unwrap_or(50).min(200);
    let cursor = q.cursor.unwrap_or(0);

    // Load all video samples for user
    let pool = state.get_user_data_database(&user_id)?;
    let conn = pool.lock();

    // Map: asset_id -> Vec<(idx, hash)>
    let mut samples_by_asset: HashMap<String, Vec<(i32, u64)>> = HashMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT v.asset_id, v.sample_idx, v.phash_hex
             FROM video_phash_samples v
             JOIN photos p ON p.asset_id = v.asset_id
             WHERE p.is_video = TRUE
             ORDER BY v.asset_id, v.sample_idx",
        )?;
        let rows = stmt.query_map([], |row| {
            let aid: String = row.get(0)?;
            let idx: i16 = row.get(1)?;
            let hex: String = row.get(2)?;
            Ok((aid, idx as i32, hex))
        })?;
        for r in rows {
            if let Ok((aid, idx, hex)) = r {
                if let Some(h) = crate::photos::phash::phash_from_hex(&hex) {
                    samples_by_asset.entry(aid).or_default().push((idx, h));
                }
            }
        }
    }
    if samples_by_asset.is_empty() {
        return Ok(Json(GroupsResponse {
            total_groups: 0,
            groups: vec![],
            next_cursor: None,
            metadata: HashMap::new(),
        }));
    }

    // Invert index: phash_hex -> asset_ids (string hex form for equality buckets)
    let mut by_hex: HashMap<String, Vec<String>> = HashMap::new();
    for (aid, vecs) in &samples_by_asset {
        for &(_, h) in vecs {
            let hex = crate::photos::phash::phash_to_hex(h);
            by_hex.entry(hex).or_default().push(aid.clone());
        }
    }

    // Union-Find structure
    let mut parent: HashMap<String, String> = HashMap::new();
    for aid in samples_by_asset.keys() {
        parent.insert(aid.clone(), aid.clone());
    }
    fn find_root(parent: &HashMap<String, String>, x: &str) -> String {
        let mut xcur = x.to_string();
        loop {
            let p = parent.get(&xcur).cloned().unwrap_or_else(|| xcur.clone());
            if p == xcur {
                break;
            }
            xcur = p;
        }
        xcur
    }
    let mut union = |a: &str, b: &str| {
        let ra = find_root(&parent, a);
        let rb = find_root(&parent, b);
        if ra != rb {
            parent.insert(ra, rb);
        }
    };

    // Verification helper
    let verify_pair =
        |a: &[(i32, u64)], b: &[(i32, u64)], h_max: u32| -> (u32, u32, f32, Option<u32>, bool) {
            let mut distances: Vec<u32> = Vec::new();
            for (i, h) in a {
                let mut best: Option<u32> = None;
                for j in [*i - 1, *i, *i + 1] {
                    if let Some(&(_, ch)) = b.iter().find(|(k, _)| *k == j) {
                        let d = crate::photos::phash::hamming_distance(*h, ch);
                        best = Some(best.map_or(d, |b| b.min(d)));
                    }
                }
                if let Some(bd) = best {
                    distances.push(bd);
                }
            }
            let compared = distances.len() as u32;
            let hits = distances.iter().filter(|&&d| d <= h_max).count() as u32;
            let hit_ratio = if compared > 0 {
                hits as f32 / compared as f32
            } else {
                0.0
            };
            let median_distance = if distances.is_empty() {
                None
            } else {
                let mut v = distances.clone();
                v.sort_unstable();
                Some(v[v.len() / 2])
            };
            let accept = if compared <= 3 {
                hits >= 2 && median_distance.unwrap_or(u32::MAX) <= 8
            } else if compared <= 5 {
                hits >= 3 && hit_ratio >= 0.60
            } else if compared <= 7 {
                hits >= 4 && hit_ratio >= 0.57
            } else {
                hits >= 5 && hit_ratio >= 0.55
            };
            (hits, compared, hit_ratio, median_distance, accept)
        };

    let h_max = state.video_phash_hamming_max as u32;
    let mut visited_pairs: HashSet<(String, String)> = HashSet::new();
    for (aid, avec) in &samples_by_asset {
        // fast candidate set via shared hash buckets
        let mut cands: HashSet<String> = HashSet::new();
        for &(_, h) in avec {
            let hex = crate::photos::phash::phash_to_hex(h);
            if let Some(list) = by_hex.get(&hex) {
                for cid in list {
                    if cid != aid {
                        cands.insert(cid.clone());
                    }
                }
            }
        }
        for cid in cands {
            let key = if aid < &cid {
                (aid.clone(), cid.clone())
            } else {
                (cid.clone(), aid.clone())
            };
            if visited_pairs.contains(&key) {
                continue;
            }
            visited_pairs.insert(key.clone());
            let bvec = match samples_by_asset.get(&cid) {
                Some(v) => v,
                None => continue,
            };
            let (_hits, compared, _ratio, _med, accept) = verify_pair(avec, bvec, h_max);
            if accept && compared > 0 {
                union(aid, &cid);
            }
        }
    }

    // Collect groups
    let mut groups_map: HashMap<String, Vec<String>> = HashMap::new();
    for aid in samples_by_asset.keys() {
        let root = find_root(&parent, aid);
        groups_map.entry(root).or_default().push(aid.clone());
    }
    let mut groups: Vec<GroupItem> = groups_map
        .into_iter()
        .map(|(_root, mut members)| {
            members.sort();
            let representative = members.first().cloned().unwrap_or_default();
            let count = members.len();
            GroupItem {
                representative,
                count,
                members,
            }
        })
        .filter(|g| g.count >= min_group)
        .collect();

    // Sort by size desc, then representative id asc for stability
    groups.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then_with(|| a.representative.cmp(&b.representative))
    });

    let total = groups.len();
    let end = (cursor + limit).min(total);
    let page = if cursor >= total {
        vec![]
    } else {
        groups[cursor..end].to_vec()
    };
    let next = if end < total { Some(end) } else { None };
    Ok(Json(GroupsResponse {
        total_groups: total,
        groups: page,
        next_cursor: next,
        metadata: HashMap::new(),
    }))
}
