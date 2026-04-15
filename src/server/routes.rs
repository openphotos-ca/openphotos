use axum::routing::get_service;
use axum::{
    extract::DefaultBodyLimit,
    routing::{any, delete, get, post, put},
    Router,
};
use std::sync::Arc;
use tower_http::services::{ServeDir, ServeFile};

#[cfg(feature = "ee")]
use crate::ee::auth_ee;
#[cfg(feature = "ee")]
use crate::ee::public_links;
#[cfg(feature = "ee")]
use crate::ee::settings as ee_settings;
#[cfg(feature = "ee")]
use crate::ee::shares;
#[cfg(feature = "ee")]
use crate::ee::team_handlers;
use crate::server::auth_handlers::{
    change_password, get_face_settings, get_trash_settings, get_user_folders, login, logout, me,
    oauth_github_callback, oauth_github_url, oauth_google_callback, oauth_google_url, register,
    reindex_active, reindex_stream, reindex_user_photos, update_face_settings,
    update_trash_settings, update_user_folders,
};
use crate::server::capabilities as server_capabilities;
use crate::server::crypto_envelope;
use crate::server::face_handlers::{
    assign_face, filter_photos_by_person, get_face_thumbnail, get_faces, get_faces_for_asset,
};
use crate::server::handlers::health_check;
use crate::server::photo_routes::{
    add_photos_to_album, create_album, create_live_album, delete_album, freeze_live_album,
    get_albums_for_photo, get_filter_metadata, get_photo, list_albums, list_deleted_backups,
    list_media, list_photos, match_deleted_backups, media_counts, merge_albums, purge_all_trash,
    purge_photos, remove_photos_from_album, restore_photos, serve_face_thumbnail,
    serve_image as photo_serve_image, serve_thumbnail, update_album as update_album_route,
    update_album_json, update_live_album_json,
};
use crate::server::similar_routes::{
    similar_groups, similar_neighbors, similar_video_groups, similar_video_neighbors,
};
use crate::server::state::AppState;
use crate::server::text_search::{reindex_text, text_search};
use crate::server::updates::{check_server_update, get_server_update_status};
use crate::server::upload_handlers::upload_multipart;

#[cfg(feature = "ee")]
async fn ee_share_trace_mw(
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> impl axum::response::IntoResponse {
    use std::time::Instant;
    let path = req.uri().path().to_string();
    let method = req.method().clone();
    let trace_this = path.starts_with("/api/ee/shares");
    let start = Instant::now();
    if trace_this {
        tracing::info!(target = "share", "[EE-TRACE] START {} {}", method, path);
    }
    let resp = next.run(req).await;
    if trace_this {
        let elapsed = start.elapsed().as_millis();
        let status = resp.status().as_u16();
        tracing::info!(
            target = "share",
            "[EE-TRACE] END   {} {} -> {} in {}ms",
            method,
            path,
            status,
            elapsed
        );
    }
    resp
}

pub fn create_router(state: Arc<AppState>) -> Router {
    #[cfg(feature = "ee")]
    tracing::info!("🔥 EE FEATURE IS ENABLED - Registering EE routes");

    #[cfg(not(feature = "ee"))]
    tracing::warn!("❌ EE FEATURE IS DISABLED - EE routes will NOT be registered");

    let static_dir = ServeDir::new("web-photos/out")
        .not_found_service(ServeFile::new("web-photos/out/index.html"));

    // Build router
    let tus_router = Router::new()
        .route("/files", any(crate::server::tus_proxy::tus_proxy))
        .route("/files/", any(crate::server::tus_proxy::tus_proxy))
        .route("/files/*path", any(crate::server::tus_proxy::tus_proxy))
        // Disable default body limit for TUS routes (chunks may be large)
        .layer(DefaultBodyLimit::disable());

    // Multipart upload router (disable body limit)
    let upload_router = Router::new()
        .route("/api/upload", post(upload_multipart))
        .layer(DefaultBodyLimit::disable());

    let app_base = Router::new()
        // Serve product home (Next.js static export)
        .route(
            "/",
            get_service(ServeFile::new("web-photos/out/index.html")),
        )
        // Health check endpoint
        .route("/ping", get(health_check))
        .route("/health", get(health_check))
        .route("/api/capabilities", get(server_capabilities::capabilities))
        // Authentication endpoints
        .route("/api/auth/register", post(register))
        .route("/api/auth/login", post(login))
        .route("/api/auth/password/change", post(change_password))
        .route("/api/auth/logout", post(logout))
        .route(
            "/api/auth/refresh",
            post(crate::server::auth_handlers::refresh),
        )
        .route("/api/auth/me", get(me))
        .route("/api/auth/oauth/google", get(oauth_google_url))
        .route(
            "/api/auth/oauth/google/callback",
            get(oauth_google_callback),
        )
        .route("/api/auth/oauth/github", get(oauth_github_url))
        .route(
            "/api/auth/oauth/github/callback",
            get(oauth_github_callback),
        )
        .route("/api/server/update-status", get(get_server_update_status))
        .route("/api/server/update/check", post(check_server_update));

    #[cfg(feature = "ee")]
    let app_base = app_base
        .route("/api/auth/login/start", post(auth_ee::login_start))
        .route("/api/auth/login/finish", post(auth_ee::login_finish))
        // EE: sharing
        .route("/api/ee/share-targets", get(shares::list_share_targets))
        .route("/api/ee/shares", get(shares::list_shares))
        .route("/api/ee/shares", post(shares::create_share))
        .route("/api/ee/shares/outgoing", get(shares::list_outgoing))
        .route("/api/ee/shares/received", get(shares::list_received))
        .route("/api/ee/shares/:id/recipients", post(shares::add_recipients))
        .route("/api/ee/shares/:id/recipients/:rid", delete(shares::remove_recipient))
        .route("/api/ee/shares/:id", get(shares::get_share).delete(shares::revoke_share))
        .route(
            "/api/ee/shares/:id",
            axum::routing::patch(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                id: axum::extract::Path<String>,
                body: axum::Json<crate::ee::shares::UpdateShareRequest>,
            | async move {
                shares::update_share(state, id, headers, body).await
            })
        )
        // Share-scoped assets (wrap in closures to satisfy Handler bounds on axum 0.7)
        .route(
            "/api/ee/shares/:id/assets",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                q: axum::extract::Query<crate::ee::shares::PageQuery>,
            | async move {
                shares::list_share_assets(state, id, headers, q).await
            }),
        )
        .route(
            "/api/ee/shares/:id/assets/:asset_id",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                headers: axum::http::HeaderMap,
            | async move {
                shares::get_share_asset(state, path, headers).await
            }),
        )
        .route(
            "/api/ee/shares/:id/assets/:asset_id/thumbnail",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                headers: axum::http::HeaderMap,
            | async move {
                shares::serve_share_thumbnail(state, path, headers).await
            }),
        )
        .route(
            "/api/ee/shares/:id/assets/:asset_id/image",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                request: axum::extract::Request,
            | async move {
                shares::serve_share_image(state, path, request).await
            }),
        )
        // Share-scoped faces
        .route(
            "/api/ee/shares/:id/faces",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                q: axum::extract::Query<crate::ee::shares::FacesQuery>,
            | async move {
                shares::list_share_faces(state, id, headers, q).await
            }),
        )
        .route(
            "/api/ee/shares/:id/faces/:person_id/assets",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                headers: axum::http::HeaderMap,
            | async move {
                shares::list_share_face_assets(state, path, headers).await
            }),
        )
        .route(
            "/api/ee/shares/:id/faces/:person_id/thumbnail",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                headers: axum::http::HeaderMap,
            | async move {
                shares::serve_share_face_thumbnail(state, path, headers).await
            }),
        )
        // Share-scoped comments
        .route(
            "/api/ee/shares/:id/comments",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                query: axum::extract::Query<crate::ee::shares::ShareCommentsListQuery>,
            | async move {
                shares::share_comments_list(state, id, headers, query).await
            }),
        )
        .route(
            "/api/ee/shares/:id/comments",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                payload: axum::Json<crate::ee::shares::ShareCommentCreate>,
            | async move {
                shares::share_comments_create(state, id, headers, payload).await
            }),
        )
        .route("/api/ee/shares/:id/comments/:cid", delete(|
            state: axum::extract::State<Arc<AppState>>,
            path: axum::extract::Path<(String, String)>,
            headers: axum::http::HeaderMap,
            query: axum::extract::Query<std::collections::HashMap<String, String>>,
        | async move { shares::share_comments_delete(state, path, headers, query).await }))
        .route(
            "/api/ee/shares/:id/comments/latest-by-assets",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                payload: axum::Json<crate::ee::shares::LatestByAssetsRequest>,
            | async move {
                shares::share_comments_latest_by_assets(state, id, headers, payload).await
            }),
        )
        // Share-scoped likes
        .route(
            "/api/ee/shares/:id/likes/toggle",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                payload: axum::Json<crate::ee::shares::LikesToggleRequest>,
            | async move {
                shares::share_likes_toggle(state, id, headers, payload).await
            }),
        )
        .route(
            "/api/ee/shares/:id/likes/counts-by-assets",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                payload: axum::Json<crate::ee::shares::LikeCountsByAssetsRequest>,
            | async move {
                shares::share_likes_counts_by_assets(state, id, headers, payload).await
            }),
        )
        // Share-scoped import into recipient library
        .route(
            "/api/ee/shares/:id/import",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                axum::Json(payload): axum::Json<crate::ee::shares::ImportRequest>,
            | async move {
                shares::import_share_assets(state, id, headers, axum::Json(payload)).await
            }),
        )
        // EE: E2EE identity and share wrap APIs
        .route(
            "/api/ee/e2ee/identity/pubkey",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                body: axum::Json<crate::ee::shares::PubKeyBody>,
            | async move {
                shares::set_identity_pubkey(state, headers, body).await
            }),
        )
        .route(
            "/api/ee/e2ee/identity/pubkey/:user_id",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                user_id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
            | async move {
                shares::get_identity_pubkey(state, user_id, headers).await
            }),
        )
        .route(
            "/api/ee/shares/:id/e2ee/recipient-envelopes",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                body: axum::Json<crate::ee::shares::RecipientEnvBatch>,
            | async move {
                shares::upsert_share_recipient_envelopes(state, headers, id, body).await
            }),
        )
        .route(
            "/api/ee/shares/:id/e2ee/my-smk-envelope",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
            | async move {
                shares::get_my_share_smk_envelope(state, headers, id).await
            }),
        )
        .route(
            "/api/ee/shares/:id/e2ee/dek-wraps/batch",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                body: axum::Json<crate::ee::shares::DekWrapBatch>,
            | async move {
                shares::upsert_share_dek_wraps_batch(state, headers, id, body).await
            }),
        )
        .route(
            "/api/ee/shares/:id/e2ee/wraps",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                headers: axum::http::HeaderMap,
                query: axum::extract::Query<crate::ee::shares::WrapsQuery>,
            | async move {
                shares::get_share_dek_wraps(state, headers, id, query).await
            }),
        )
        // EE: public links (no login required, but require key (+ optional PIN) per request)
        .route("/api/ee/public-links", get(public_links::list_public_links))
        .route(
            "/api/ee/public-links",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                payload: axum::Json<crate::ee::public_links::CreatePublicLinkRequest>,
            | async move {
                public_links::create_public_link(state, headers, payload).await
            }),
        )
        .route(
            "/api/ee/public/:id/meta",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                q: axum::extract::Query<crate::ee::public_links::MetaQuery>,
                headers: axum::http::HeaderMap,
            | async move {
                public_links::public_meta(state, id, q, headers).await
            }),
        )
        .route(
            "/api/ee/public/:id/cover",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                query: axum::extract::Query<crate::ee::public_links::MetaQuery>,
            | async move {
                public_links::public_cover(state, id, query).await
            }),
        )
        .route("/api/ee/public/:id/assets", get(public_links::public_assets))
        .route(
            "/api/ee/public/:id/stats",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                path: axum::extract::Path<String>,
                query: axum::extract::Query<crate::ee::public_links::MetaQuery>,
            | async move {
                public_links::public_stats(state, headers, path, query).await
            }),
        )
        .route("/api/ee/public/:id/assets/pending", get(public_links::public_pending_assets))
        .route(
            "/api/ee/public/:id/assets/:asset_id/meta",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                query: axum::extract::Query<crate::ee::public_links::MetaQuery>,
            | async move {
                public_links::public_asset_meta(state, path, query).await
            }),
        )
        .route(
            "/api/ee/public/:id/assets/:asset_id/thumbnail",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                query: axum::extract::Query<crate::ee::public_links::MetaQuery>,
            | async move {
                public_links::public_thumbnail(state, path, query).await
            }),
        )
        .route(
            "/api/ee/public/:id/assets/:asset_id/image",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                query: axum::extract::Query<crate::ee::public_links::MetaQuery>,
                request: axum::extract::Request,
            | async move {
                public_links::public_image(state, path, query, request).await
            }),
        )
        // Public comments & likes (require key + optional PIN)
        .route("/api/ee/public/:id/comments", get(public_links::public_comments_list))
        .route("/api/ee/public/:id/comments", post(public_links::public_comments_create))
        .route(
            "/api/ee/public/:id/comments/:cid",
            delete(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<(String, String)>,
                query: axum::extract::Query<std::collections::HashMap<String, String>>,
                headers: axum::http::HeaderMap,
            | async move {
                public_links::public_comments_delete(state, path, query, headers).await
            })
        )
        .route("/api/ee/public/:id/comments/latest-by-assets", post(public_links::public_comments_latest_by_assets))
        .route("/api/ee/public/:id/likes/toggle", post(public_links::public_likes_toggle))
        .route("/api/ee/public/:id/likes/counts-by-assets", post(public_links::public_likes_counts_by_assets))
        .route("/api/ee/public/:id/moderate", post(public_links::public_moderate))
        // EE: E2EE public link helpers (SMK envelope + DEK wraps)
        .route(
            "/api/ee/public-links/:id/e2ee/smk-envelope",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                id: axum::extract::Path<String>,
                body: axum::Json<crate::ee::public_links::SmkEnvelopeBody>,
            | async move {
                public_links::save_public_smk_envelope(state, headers, id, body).await
            }),
        )
        .route(
            "/api/ee/public/:id/e2ee/smk-envelope",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                query: axum::extract::Query<crate::ee::public_links::MetaQuery>,
            | async move {
                public_links::get_public_smk_envelope(state, id, query).await
            }),
        )
        .route(
            "/api/ee/public-links/:id/e2ee/dek-wraps/batch",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                id: axum::extract::Path<String>,
                body: axum::Json<crate::ee::public_links::DekWrapBatch>,
            | async move {
                public_links::upsert_public_dek_wraps_batch(state, headers, id, body).await
            }),
        )
        .route(
            "/api/ee/public/:id/e2ee/wraps",
            get(|
                state: axum::extract::State<Arc<AppState>>,
                id: axum::extract::Path<String>,
                query: axum::extract::Query<crate::ee::public_links::WrapsQuery>,
            | async move {
                public_links::get_public_dek_wraps(state, id, query).await
            }),
        )
        .route(
            "/api/ee/public-links/:id",
            axum::routing::patch(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                id: axum::extract::Path<String>,
                body: axum::Json<crate::ee::public_links::UpdatePublicLinkRequest>,
            | async move {
                public_links::update_public_link(state, headers, id, body).await
            })
        )
        .route(
            "/api/ee/public-links/:id/rotate-key",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                id: axum::extract::Path<String>,
            | async move {
                public_links::rotate_public_link_key(state, headers, id).await
            })
        )
        .route(
            "/api/ee/public-links/:id",
            delete(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                id: axum::extract::Path<String>,
            | async move {
                public_links::revoke_public_link(state, headers, id).await
            })
        )
        // EE: org settings
        .route("/api/ee/settings/public-link-prefix", get(ee_settings::get_public_link_prefix))
        .route("/api/ee/settings/public-link-prefix", put(ee_settings::set_public_link_prefix))
        .route("/api/team/users", get(team_handlers::list_team_users))
        .route("/api/team/users", post(team_handlers::create_team_user))
        .route("/api/team/users/:id", axum::routing::patch(team_handlers::update_team_user))
        .route("/api/team/users/:id", delete(team_handlers::delete_team_user))
        .route("/api/team/users/:id/reset-password", post(team_handlers::reset_password))
        .route("/api/team/groups", get(team_handlers::list_groups))
        .route("/api/team/groups", post(team_handlers::create_group))
        .route("/api/team/groups/:id", axum::routing::patch(team_handlers::update_group))
        .route("/api/team/groups/:id", delete(team_handlers::delete_group))
        .route("/api/team/groups/:id/users", post(team_handlers::modify_group_users))
        .route("/api/team/groups/:id/users", get(team_handlers::list_group_users))
        .route("/api/team/org", get(team_handlers::org_info))
        .route("/api/team/org", axum::routing::patch(team_handlers::org_update));

    // Add lightweight tracing middleware for EE share routes
    #[cfg(feature = "ee")]
    let app_base = app_base.layer(axum::middleware::from_fn(ee_share_trace_mw));

    #[cfg(not(feature = "ee"))]
    let app_base = app_base;

    // APIs and the rest
    let app = app_base
        .route("/api/crypto/envelope", get(crypto_envelope::get_envelope))
        .route("/api/crypto/envelope", post(crypto_envelope::post_envelope))
        .route("/api/settings/folders", get(get_user_folders))
        .route("/api/settings/folders", put(update_user_folders))
        .route("/api/settings/face", get(get_face_settings))
        .route("/api/settings/face", put(update_face_settings))
        .route("/api/settings/trash", get(crate::server::auth_handlers::get_trash_settings))
        .route("/api/settings/trash", put(crate::server::auth_handlers::update_trash_settings))
        .route("/api/settings/security", get(crate::server::auth_handlers::get_security_settings))
        .route("/api/settings/security", put(crate::server::auth_handlers::update_security_settings))
        .route("/api/photos", get(list_photos))
        .route("/api/photos/state", get(crate::server::photo_routes::get_photo_state))
        .route("/api/photos/:id/rating", put(crate::server::photo_routes::update_photo_rating))
        .route("/api/photos/by-ids", post(crate::server::photo_routes::get_photos_by_asset_ids))
        .route("/api/photos/exists", post(crate::server::photo_routes::photos_exist))
        .route("/api/photos/deleted-backups", get(list_deleted_backups))
        .route("/api/photos/deleted-backups/match", post(match_deleted_backups))
        .route("/api/media", get(list_media))
        .route("/api/media/counts", get(media_counts))
        .route("/api/buckets/years", get(crate::server::photo_routes::bucket_years))
        .route("/api/buckets/quarters", get(crate::server::photo_routes::bucket_quarters))
        .route("/api/photos/:id", get(get_photo))
        .route("/api/photos/:asset_id/favorite", put(crate::server::photo_routes::set_favorite))
        .route("/api/photos/reindex", post(reindex_user_photos))
        .route("/api/reindex/stream", get(reindex_stream))
        .route("/api/reindex/active", get(reindex_active))
        .route("/api/reindex/stop", post(crate::server::auth_handlers::reindex_stop))
        // Explicit HEAD support helps media elements that probe before ranged GETs.
        .route("/api/images/:asset_id", get(photo_serve_image).head(photo_serve_image))
        .route("/api/thumbnails/:asset_id", get(serve_thumbnail))
        .route("/api/live/:asset_id", get(crate::server::photo_routes::serve_live_video))
        .route(
            "/api/live-locked/:asset_id",
            get(crate::server::photo_routes::serve_locked_live_video),
        )
        .route("/api/photos/:asset_id/lock", post(crate::server::photo_routes::lock_photo))
        .route("/api/photos/:asset_id/metadata", put(crate::server::photo_routes::update_photo_metadata))
        .route("/api/images/faces/:person_id", get(serve_face_thumbnail))
        .route("/api/debug/photos-count", get(crate::server::photo_routes::debug_photos_count))
        .route(
            "/api/debug/photo/:asset_id",
            get(crate::server::photo_routes::debug_photo_row),
        )
        .route("/api/debug/locked-sample", get(crate::server::photo_routes::debug_locked_sample))
        .route("/api/photos/:asset_id/refresh-metadata", post(crate::server::photo_routes::refresh_photo_metadata))
        .route("/api/photos/delete", post(crate::server::photo_routes::delete_photos))
        .route("/api/photos/restore", post(crate::server::photo_routes::restore_photos))
        .route("/api/photos/purge", post(crate::server::photo_routes::purge_photos))
        .route("/api/photos/purge-all", post(crate::server::photo_routes::purge_all_trash))
        .route("/api/admin/repair/live-photos", post(crate::server::photo_routes::repair_live_photos))
        .route(
            "/api/admin/purge-smart-search-image-data",
            post(crate::server::photo_routes::purge_smart_search_image_data),
        )
        .route("/api/similar/groups", get(similar_groups))
        .route("/api/similar/:asset_id", get(similar_neighbors))
        .route("/api/video/similar/groups", get(similar_video_groups))
        .route("/api/video/similar/:asset_id", get(similar_video_neighbors))
        .route("/api/albums", get(list_albums))
        .route("/api/albums", post(create_album))
        .route(
            "/api/albums/merge",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                payload: axum::Json<crate::server::photo_routes::MergeAlbumsRequest>,
            | async move {
                crate::server::photo_routes::merge_albums(state, headers, payload).await
            }),
        )
        .route("/api/albums/live", post(create_live_album))
        .route("/api/albums/live/update", post(update_live_album_json))
        .route(
            "/api/albums/update",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                headers: axum::http::HeaderMap,
                payload: axum::Json<crate::server::photo_routes::UpdateAlbumJson>,
            | async move {
                crate::server::photo_routes::update_album_json(state, headers, payload).await
            }),
        )
        // .route("/api/albums/:id", put(update_album_route))
        .route("/api/albums/:id", delete(delete_album))
        .route("/api/albums/:id/photos", post(add_photos_to_album))
        .route("/api/albums/:id/photos", delete(remove_photos_from_album))
        .route(
            "/api/albums/:id/freeze",
            post(|
                state: axum::extract::State<Arc<AppState>>,
                path: axum::extract::Path<i32>,
                headers: axum::http::HeaderMap,
                payload: axum::Json<crate::server::photo_routes::FreezeAlbumJson>,
            | async move {
                crate::server::photo_routes::freeze_live_album(state, path, headers, payload).await
            }),
        )
        // Allow POST-based removal for clients that cannot send DELETE with JSON body
        .route("/api/albums/:id/photos/remove", post(remove_photos_from_album))

        // Photo-album membership
        .route("/api/photos/:id/albums", get(get_albums_for_photo))


        // Face endpoints (using mock data for now)
        .route("/api/faces", get(get_faces))
        .route("/api/faces/merge", post(crate::server::face_handlers::merge_faces))
        .route("/api/faces/delete", post(crate::server::face_handlers::delete_persons))
        .route("/api/faces/:person_id", put(crate::server::face_handlers::update_person))
        .route("/api/faces/:face_id/assign", put(assign_face))
        .route("/api/faces/filter", post(filter_photos_by_person))
        .route("/api/face-thumbnail", get(get_face_thumbnail))
        .route("/api/photos/:asset_id/persons", get(crate::server::face_handlers::get_persons_for_asset))
        .route("/api/photos/:asset_id/assign-person", post(crate::server::face_handlers::assign_person_to_photo))
        .route("/api/photos/:asset_id/faces", get(get_faces_for_asset))

        // Filter endpoints
        .route("/api/filters/metadata", get(get_filter_metadata))

        // Search endpoint
        .route("/api/search", post(text_search))
        .route("/api/search/reindex", post(reindex_text))
        .route("/api/search/sync", post(crate::server::text_search::sync_text))
        .route("/api/search/stats", get(crate::server::text_search::stats_text))

        // Rustus webhooks (pre-create, post-finish)
        .route(
            "/api/upload/hooks",
            post(crate::server::upload_hooks::handle_rustus_hook),
        )
        // Upload events stream (SSE)
        .route(
            "/api/uploads/stream",
            get(crate::server::upload_hooks::uploads_stream),
        )
        .route(
            "/api/uploads/ingested",
            post(crate::server::upload_hooks::uploads_ingested),
        )

        // Set body limit to 64MB for image uploads
        .layer(DefaultBodyLimit::max(64 * 1024 * 1024))
        // Mount TUS reverse proxy (no body limit)
        .merge(tus_router)
        .merge(upload_router);

    let app = app
        .with_state(state)
        .fallback_service(get_service(static_dir));

    app
}
