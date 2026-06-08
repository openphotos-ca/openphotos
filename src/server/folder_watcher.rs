use crate::server::auth_handlers::{
    folder_index_media_kind, index_watched_path_for_user, AlbumIndexOptions,
};
use crate::server::state::AppState;
use anyhow::Result;
use notify::event::{ModifyKind, RenameMode};
use notify::{recommended_watcher, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const DEFAULT_DEBOUNCE_MS: u64 = 1_500;
const STABILITY_CHECKS: usize = 10;
const STABILITY_DELAY_MS: u64 = 500;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WatchConfig {
    user_id: String,
    root: PathBuf,
    canonical_root: PathBuf,
    album_opts: AlbumIndexOptions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WatchAction {
    Index,
    Remove,
}

#[derive(Debug, Clone)]
pub(crate) struct PendingWork {
    user_id: String,
    root: PathBuf,
    path: PathBuf,
    album_opts: AlbumIndexOptions,
    action: WatchAction,
    ready_at: Instant,
}

#[derive(Debug, Clone, Hash, PartialEq, Eq)]
struct WorkKey {
    user_id: String,
    path: PathBuf,
}

pub fn spawn_folder_watcher(state: Arc<AppState>) {
    if !folder_watch_enabled() {
        tracing::info!("[FOLDER_WATCH] disabled by FOLDER_WATCH_ENABLED");
        return;
    }

    let debounce = folder_watch_debounce();
    tokio::spawn(async move {
        if let Err(e) = run_folder_watcher(state, debounce).await {
            tracing::warn!("[FOLDER_WATCH] stopped: {}", e);
        }
    });
}

fn folder_watch_enabled() -> bool {
    std::env::var("FOLDER_WATCH_ENABLED")
        .ok()
        .map(|s| !matches!(s.trim().to_ascii_lowercase().as_str(), "0" | "false" | "no"))
        .unwrap_or(true)
}

fn folder_watch_debounce() -> Duration {
    let ms = std::env::var("FOLDER_WATCH_DEBOUNCE_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(DEFAULT_DEBOUNCE_MS);
    Duration::from_millis(ms)
}

async fn run_folder_watcher(state: Arc<AppState>, debounce: Duration) -> Result<()> {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel::<notify::Result<Event>>();
    let mut reload_rx = state.subscribe_folder_watch_reloads();
    let mut pending: HashMap<WorkKey, PendingWork> = HashMap::new();
    let mut configs = load_watch_configs(&state).await?;
    let mut watcher = build_watcher(&configs, event_tx.clone());
    enqueue_startup_scans(&configs, &mut pending, Duration::ZERO);

    let mut tick = tokio::time::interval(Duration::from_millis(500));
    loop {
        tokio::select! {
            Some(event) = event_rx.recv() => {
                match event {
                    Ok(event) => enqueue_event_work(&configs, event, &mut pending, debounce),
                    Err(e) => tracing::warn!("[FOLDER_WATCH] notify error: {}", e),
                }
            }
            reload = reload_rx.recv() => {
                if reload.is_err() {
                    reload_rx = state.subscribe_folder_watch_reloads();
                }
                match load_watch_configs(&state).await {
                    Ok(next) => {
                        configs = next;
                        watcher = build_watcher(&configs, event_tx.clone());
                        enqueue_startup_scans(&configs, &mut pending, debounce);
                    }
                    Err(e) => tracing::warn!("[FOLDER_WATCH] reload failed: {}", e),
                }
            }
            _ = tick.tick() => {
                let ready = drain_ready_work(&mut pending, Instant::now());
                for work in ready {
                    process_work_item(&state, work).await;
                }
                let _keep_watcher_alive = watcher.as_ref().map(|_| ());
            }
        }
    }
}

fn build_watcher(
    configs: &[WatchConfig],
    event_tx: mpsc::UnboundedSender<notify::Result<Event>>,
) -> Option<RecommendedWatcher> {
    let roots = unique_existing_roots(configs);
    if roots.is_empty() {
        tracing::info!("[FOLDER_WATCH] no configured folders to watch");
        return None;
    }

    let mut watcher = match recommended_watcher(move |event| {
        let _ = event_tx.send(event);
    }) {
        Ok(watcher) => watcher,
        Err(e) => {
            tracing::warn!("[FOLDER_WATCH] failed to create watcher: {}", e);
            return None;
        }
    };

    let mut watched = 0usize;
    for root in roots {
        match watcher.watch(&root, RecursiveMode::Recursive) {
            Ok(()) => watched += 1,
            Err(e) => tracing::warn!("[FOLDER_WATCH] failed to watch {}: {}", root.display(), e),
        }
    }
    tracing::info!("[FOLDER_WATCH] watching {} indexed folders", watched);
    Some(watcher)
}

fn unique_existing_roots(configs: &[WatchConfig]) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut roots = Vec::new();
    for config in configs {
        if seen.insert(config.canonical_root.clone()) {
            roots.push(config.canonical_root.clone());
        }
    }
    roots
}

async fn load_watch_configs(state: &AppState) -> Result<Vec<WatchConfig>> {
    let mut configs = Vec::new();
    let rows = if let Some(pg) = &state.pg_client {
        let rows = pg
            .query(
                "SELECT user_id, COALESCE(folders,''), index_parent_album_id,
                        COALESCE(index_preserve_tree_path,FALSE)
                 FROM users
                 WHERE status='active'",
                &[],
            )
            .await?;
        rows.into_iter()
            .map(|row| {
                (
                    row.get::<_, String>(0),
                    row.get::<_, String>(1),
                    row.get::<_, Option<i32>>(2),
                    row.get::<_, bool>(3),
                )
            })
            .collect::<Vec<_>>()
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        let mut rows_out = Vec::new();
        let mut stmt = conn.prepare(
            "SELECT user_id, COALESCE(folders,''), index_parent_album_id,
                    COALESCE(index_preserve_tree_path,FALSE)
             FROM users
             WHERE status='active'",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<i32>>(2)?,
                row.get::<_, bool>(3)?,
            ))
        })?;
        for row in rows.flatten() {
            rows_out.push(row);
        }
        rows_out
    };

    let library_root = state
        .library_root
        .canonicalize()
        .unwrap_or_else(|_| state.library_root.clone());
    for (user_id, folders, album_parent_id, preserve_tree_path) in rows {
        let album_opts = AlbumIndexOptions {
            album_parent_id,
            preserve_tree_path,
        };
        for root in parse_folders(&folders) {
            if !root.is_dir() {
                tracing::warn!(
                    "[FOLDER_WATCH] skipping unavailable folder for user {}: {}",
                    user_id,
                    root.display()
                );
                continue;
            }
            let canonical_root = root.canonicalize().unwrap_or_else(|_| root.clone());
            if canonical_root.starts_with(&library_root) {
                tracing::warn!(
                    "[FOLDER_WATCH] skipping internal library folder: {}",
                    root.display()
                );
                continue;
            }
            configs.push(WatchConfig {
                user_id: user_id.clone(),
                root,
                canonical_root,
                album_opts: album_opts.clone(),
            });
        }
    }
    Ok(configs)
}

pub(crate) fn parse_folders(raw: &str) -> Vec<PathBuf> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .collect()
}

fn enqueue_startup_scans(
    configs: &[WatchConfig],
    pending: &mut HashMap<WorkKey, PendingWork>,
    debounce: Duration,
) {
    for config in configs {
        enqueue_work(
            pending,
            PendingWork {
                user_id: config.user_id.clone(),
                root: config.root.clone(),
                path: config.root.clone(),
                album_opts: config.album_opts.clone(),
                action: WatchAction::Index,
                ready_at: Instant::now() + debounce,
            },
        );
    }
}

fn enqueue_event_work(
    configs: &[WatchConfig],
    event: Event,
    pending: &mut HashMap<WorkKey, PendingWork>,
    debounce: Duration,
) {
    if matches!(
        event.kind,
        EventKind::Modify(ModifyKind::Name(RenameMode::Both))
    ) && event.paths.len() >= 2
    {
        enqueue_paths(
            configs,
            &event.paths[..1],
            pending,
            debounce,
            WatchAction::Remove,
        );
        enqueue_paths(
            configs,
            &event.paths[1..],
            pending,
            debounce,
            WatchAction::Index,
        );
        return;
    }

    let action = event_action(&event);
    enqueue_paths(configs, &event.paths, pending, debounce, action);
}

fn event_action(event: &Event) -> WatchAction {
    match event.kind {
        EventKind::Remove(_) => WatchAction::Remove,
        EventKind::Create(_) => WatchAction::Index,
        EventKind::Modify(ModifyKind::Name(RenameMode::From)) => WatchAction::Remove,
        EventKind::Modify(_) => WatchAction::Index,
        _ => {
            if event.paths.iter().any(|path| path.exists()) {
                WatchAction::Index
            } else {
                WatchAction::Remove
            }
        }
    }
}

fn enqueue_paths(
    configs: &[WatchConfig],
    paths: &[PathBuf],
    pending: &mut HashMap<WorkKey, PendingWork>,
    debounce: Duration,
    action: WatchAction,
) {
    for path in paths {
        for (config, db_path) in matching_configs(configs, path) {
            enqueue_work(
                pending,
                PendingWork {
                    user_id: config.user_id.clone(),
                    root: config.root.clone(),
                    path: db_path,
                    album_opts: config.album_opts.clone(),
                    action,
                    ready_at: Instant::now() + debounce,
                },
            );
        }
    }
}

fn enqueue_work(pending: &mut HashMap<WorkKey, PendingWork>, work: PendingWork) {
    let key = WorkKey {
        user_id: work.user_id.clone(),
        path: work.path.clone(),
    };
    pending.insert(key, work);
}

fn drain_ready_work(pending: &mut HashMap<WorkKey, PendingWork>, now: Instant) -> Vec<PendingWork> {
    let ready_keys = pending
        .iter()
        .filter_map(|(key, work)| {
            if work.ready_at <= now {
                Some(key.clone())
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    ready_keys
        .into_iter()
        .filter_map(|key| pending.remove(&key))
        .collect()
}

fn matching_configs<'a>(
    configs: &'a [WatchConfig],
    event_path: &Path,
) -> Vec<(&'a WatchConfig, PathBuf)> {
    configs
        .iter()
        .filter_map(|config| path_for_config(config, event_path).map(|p| (config, p)))
        .collect()
}

fn path_for_config(config: &WatchConfig, event_path: &Path) -> Option<PathBuf> {
    if event_path.starts_with(&config.root) {
        return Some(event_path.to_path_buf());
    }

    if event_path.starts_with(&config.canonical_root) {
        if let Ok(relative) = event_path.strip_prefix(&config.canonical_root) {
            return Some(config.root.join(relative));
        }
    }

    if let Ok(canonical_path) = event_path.canonicalize() {
        if canonical_path.starts_with(&config.canonical_root) {
            if let Ok(relative) = canonical_path.strip_prefix(&config.canonical_root) {
                return Some(config.root.join(relative));
            }
        }
    }

    None
}

async fn process_work_item(state: &Arc<AppState>, work: PendingWork) {
    match work.action {
        WatchAction::Index => {
            if !work.path.exists() {
                if let Err(e) = soft_delete_removed_path(state, &work.user_id, &work.path).await {
                    tracing::warn!(
                        "[FOLDER_WATCH] delete for missing path failed {}: {}",
                        work.path.display(),
                        e
                    );
                }
                return;
            }
            if work.path.is_file() && folder_index_media_kind(&work.path).is_none() {
                return;
            }
            if work.path.is_file() {
                wait_for_stable_file(&work.path).await;
            }
            match index_watched_path_for_user(
                state,
                &work.user_id,
                &work.root,
                &work.path,
                work.album_opts.clone(),
            )
            .await
            {
                Ok(indexed) if indexed > 0 => tracing::info!(
                    "[FOLDER_WATCH] indexed {} item(s) for user {} from {}",
                    indexed,
                    work.user_id,
                    work.path.display()
                ),
                Ok(_) => {}
                Err(e) => tracing::warn!(
                    "[FOLDER_WATCH] indexing failed for user {} path {}: {}",
                    work.user_id,
                    work.path.display(),
                    e
                ),
            }
        }
        WatchAction::Remove => {
            if let Err(e) = soft_delete_removed_path(state, &work.user_id, &work.path).await {
                tracing::warn!(
                    "[FOLDER_WATCH] delete failed for user {} path {}: {}",
                    work.user_id,
                    work.path.display(),
                    e
                );
            }
        }
    }
}

async fn wait_for_stable_file(path: &Path) {
    let mut last = file_signature(path);
    for _ in 0..STABILITY_CHECKS {
        tokio::time::sleep(Duration::from_millis(STABILITY_DELAY_MS)).await;
        let current = file_signature(path);
        if current.is_some() && current == last {
            return;
        }
        last = current;
    }
}

fn file_signature(path: &Path) -> Option<(u64, Option<std::time::SystemTime>)> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() {
        return None;
    }
    Some((meta.len(), meta.modified().ok()))
}

async fn soft_delete_removed_path(
    state: &Arc<AppState>,
    user_id: &str,
    removed_path: &Path,
) -> Result<usize> {
    let org_id = state.org_id_for_user(user_id);
    let path = removed_path.to_string_lossy().to_string();
    let prefix = path_prefix_with_separator(removed_path);
    let now = chrono::Utc::now().timestamp();

    let asset_ids = if let Some(pg) = &state.pg_client {
        let rows = pg
            .query(
                "SELECT asset_id FROM photos
                 WHERE organization_id=$1 AND user_id=$2
                   AND COALESCE(delete_time,0)=0
                   AND (path=$3 OR substr(path, 1, length($4))=$4)",
                &[&org_id, &user_id, &path, &prefix],
            )
            .await?;
        let ids = rows
            .into_iter()
            .map(|row| row.get::<_, String>(0))
            .collect::<Vec<_>>();
        if !ids.is_empty() {
            pg.execute(
                "UPDATE photos
                 SET delete_time=$1, favorites=0, delete_origin='folder_watch', search_indexed_at=$1
                 WHERE organization_id=$2 AND user_id=$3
                   AND COALESCE(delete_time,0)=0
                   AND (path=$4 OR substr(path, 1, length($5))=$5)",
                &[&now, &org_id, &user_id, &path, &prefix],
            )
            .await?;
        }
        ids
    } else {
        let data_db = state.get_user_data_database(user_id)?;
        let ids = {
            let conn = data_db.lock();
            let mut ids = Vec::new();
            if let Ok(mut stmt) = conn.prepare(
                "SELECT asset_id FROM photos
                 WHERE organization_id = ? AND user_id = ?
                   AND COALESCE(delete_time,0) = 0
                   AND (path = ? OR substr(path, 1, length(?)) = ?)",
            ) {
                if let Ok(rows) = stmt.query_map(
                    duckdb::params![org_id, user_id, &path, &prefix, &prefix],
                    |row| row.get::<_, String>(0),
                ) {
                    for row in rows.flatten() {
                        ids.push(row);
                    }
                }
            }
            ids
        };
        if !ids.is_empty() {
            let conn = data_db.lock();
            conn.execute(
                "UPDATE photos
                 SET delete_time = ?, favorites = 0, delete_origin = 'folder_watch', search_indexed_at = ?
                 WHERE organization_id = ? AND user_id = ?
                   AND COALESCE(delete_time,0) = 0
                   AND (path = ? OR substr(path, 1, length(?)) = ?)",
                duckdb::params![now, now, org_id, user_id, &path, &prefix, &prefix],
            )?;
        }
        ids
    };

    for asset_id in &asset_ids {
        if let Err(e) = crate::server::text_search::delete_single_asset(state, user_id, asset_id) {
            tracing::warn!("[FOLDER_WATCH] text delete failed for {}: {}", asset_id, e);
        }
    }
    if !asset_ids.is_empty() {
        tracing::info!(
            "[FOLDER_WATCH] soft-deleted {} item(s) for user {} under {}",
            asset_ids.len(),
            user_id,
            removed_path.display()
        );
    }
    Ok(asset_ids.len())
}

pub(crate) fn path_prefix_with_separator(path: &Path) -> String {
    let mut prefix = path.to_string_lossy().to_string();
    if !prefix.ends_with(std::path::MAIN_SEPARATOR) {
        prefix.push(std::path::MAIN_SEPARATOR);
    }
    prefix
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config(root: PathBuf) -> WatchConfig {
        WatchConfig {
            user_id: "user-a".to_string(),
            canonical_root: root.clone(),
            root,
            album_opts: AlbumIndexOptions {
                album_parent_id: None,
                preserve_tree_path: false,
            },
        }
    }

    #[test]
    fn parse_folders_trims_empty_entries() {
        let folders = parse_folders(" /photos/a, ,/photos/b ,, ");
        assert_eq!(
            folders,
            vec![PathBuf::from("/photos/a"), PathBuf::from("/photos/b")]
        );
    }

    #[test]
    fn media_kind_matches_folder_indexer_extensions() {
        assert!(folder_index_media_kind(Path::new("a.jpg")).is_some());
        assert!(folder_index_media_kind(Path::new("a.HEIC")).is_some());
        assert!(folder_index_media_kind(Path::new("a.mov")).is_some());
        assert!(folder_index_media_kind(Path::new("a.txt")).is_none());
    }

    #[test]
    fn coalescing_keeps_last_action_for_path() {
        let mut pending = HashMap::new();
        let root = PathBuf::from("/photos");
        let first = PendingWork {
            user_id: "user-a".to_string(),
            root: root.clone(),
            path: root.join("a.jpg"),
            album_opts: AlbumIndexOptions {
                album_parent_id: None,
                preserve_tree_path: false,
            },
            action: WatchAction::Remove,
            ready_at: Instant::now(),
        };
        let mut second = first.clone();
        second.action = WatchAction::Index;

        enqueue_work(&mut pending, first);
        enqueue_work(&mut pending, second);

        let work = pending.values().next().expect("one item");
        assert_eq!(pending.len(), 1);
        assert_eq!(work.action, WatchAction::Index);
    }

    #[test]
    fn matching_config_maps_child_path() {
        let root = PathBuf::from("/photos");
        let configs = vec![test_config(root.clone())];
        let matches = matching_configs(&configs, &root.join("nested/a.jpg"));

        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].1, root.join("nested/a.jpg"));
    }

    #[test]
    fn delete_prefix_has_separator() {
        assert_eq!(
            path_prefix_with_separator(Path::new("/photos/a")),
            format!("/photos/a{}", std::path::MAIN_SEPARATOR)
        );
    }

    #[test]
    fn delete_predicate_matches_exact_path_and_descendants_only() {
        let conn = duckdb::Connection::open_in_memory().expect("open db");
        conn.execute(
            "CREATE TABLE photos (
                organization_id INTEGER,
                user_id TEXT,
                asset_id TEXT,
                path TEXT,
                delete_time INTEGER,
                delete_origin TEXT
            )",
            [],
        )
        .expect("create photos");
        for (asset_id, path) in [
            ("exact", "/photos/folder"),
            ("child", "/photos/folder/a.jpg"),
            ("nested", "/photos/folder/nested/b.jpg"),
            ("sibling_prefix", "/photos/folderish/c.jpg"),
            ("parent", "/photos"),
        ] {
            conn.execute(
                "INSERT INTO photos VALUES (1, 'user-a', ?, ?, 0, NULL)",
                duckdb::params![asset_id, path],
            )
            .expect("insert photo");
        }

        let removed = Path::new("/photos/folder");
        let path = removed.to_string_lossy().to_string();
        let prefix = path_prefix_with_separator(removed);
        conn.execute(
            "UPDATE photos
             SET delete_time = 123, delete_origin = 'folder_watch'
             WHERE organization_id = ? AND user_id = ?
               AND COALESCE(delete_time,0) = 0
               AND (path = ? OR substr(path, 1, length(?)) = ?)",
            duckdb::params![1, "user-a", &path, &prefix, &prefix],
        )
        .expect("update deleted rows");

        let mut stmt = conn
            .prepare("SELECT asset_id FROM photos WHERE delete_origin = 'folder_watch' ORDER BY asset_id")
            .expect("prepare select");
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .expect("query rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect rows");

        assert_eq!(rows, vec!["child", "exact", "nested"]);
    }
}
