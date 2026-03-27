use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue, Method, StatusCode, Uri};
use axum::response::Response;
use http_body_util::BodyExt as _;
use hyper::Response as HyperResponse;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use once_cell::sync::Lazy;
use std::convert::TryFrom;
use std::sync::Arc;

use crate::server::state::AppState;

// Upstream Rustus endpoint (default loopback). Override for containerized / multi-process setups.
// Example: RUSTUS_ORIGIN=http://rustus:1081
static RUSTUS_ORIGIN: Lazy<String> = Lazy::new(|| {
    std::env::var("RUSTUS_ORIGIN").unwrap_or_else(|_| "http://127.0.0.1:1081".to_string())
});

#[derive(Debug, Clone, PartialEq, Eq)]
struct PatchIngressFraming {
    content_length: Option<String>,
    transfer_encoding: Option<String>,
}

fn normalize_buffered_patch_headers(
    headers: &mut HeaderMap,
    body_len: usize,
) -> Result<PatchIngressFraming, (StatusCode, String)> {
    let framing = PatchIngressFraming {
        content_length: headers
            .get(header::CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok())
            .map(ToOwned::to_owned),
        transfer_encoding: headers
            .get(header::TRANSFER_ENCODING)
            .and_then(|v| v.to_str().ok())
            .map(ToOwned::to_owned),
    };

    let content_length = HeaderValue::from_str(&body_len.to_string()).map_err(|_| {
        (
            StatusCode::BAD_GATEWAY,
            "failed to normalize tus patch content-length".to_string(),
        )
    })?;
    headers.insert(header::CONTENT_LENGTH, content_length);
    headers.remove(header::TRANSFER_ENCODING);

    Ok(framing)
}

fn bearer_token_from_headers(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|token| !token.is_empty())
}

fn cookie_token_from_headers(headers: &HeaderMap) -> Option<&str> {
    let cookie_hdr = headers.get(header::COOKIE)?.to_str().ok()?;
    for part in cookie_hdr.split(';') {
        let trimmed = part.trim();
        if let Some(val) = trimmed.strip_prefix("auth-token=") {
            let val = val.trim();
            if !val.is_empty() {
                return Some(val);
            }
        }
    }
    None
}

async fn auth_user_id_from_headers(headers: &HeaderMap, state: &Arc<AppState>) -> Option<String> {
    let token =
        bearer_token_from_headers(headers).or_else(|| cookie_token_from_headers(headers))?;
    state
        .auth_service
        .verify_token(token)
        .await
        .ok()
        .map(|user| user.user_id)
}

fn upload_id_from_tus_path(path: &str) -> Option<String> {
    let path = path.split('?').next().unwrap_or(path).trim_end_matches('/');
    let (_, upload_id) = path.rsplit_once("/files/")?;
    if upload_id.is_empty() || upload_id.contains('/') {
        None
    } else {
        Some(upload_id.to_string())
    }
}

fn upload_id_from_location(location: &str) -> Option<String> {
    let path = location
        .split_once("://")
        .and_then(|(_, rest)| rest.split_once('/').map(|(_, path)| format!("/{}", path)))
        .unwrap_or_else(|| location.to_string());
    upload_id_from_tus_path(&path)
}

fn remember_tus_upload_owner(
    state: &Arc<AppState>,
    method: &Method,
    request_path: &str,
    location_header: Option<&HeaderValue>,
    auth_user_id: Option<&str>,
) {
    let Some(user_id) = auth_user_id else {
        return;
    };

    let upload_id = upload_id_from_tus_path(request_path).or_else(|| {
        location_header
            .and_then(|loc| loc.to_str().ok())
            .and_then(upload_id_from_location)
    });

    if let Some(upload_id) = upload_id {
        state.remember_tus_upload_owner(&upload_id, user_id);
        tracing::debug!(
            target = "upload",
            "[TUS_PROXY] Remembered upload owner upload_id={} user_id={} method={} path={}",
            upload_id,
            user_id,
            method.as_str(),
            request_path
        );
    }
}

pub async fn tus_proxy(
    State(state): State<Arc<AppState>>,
    method: Method,
    uri: Uri,
    mut headers: HeaderMap,
    body: Body,
) -> Result<Response, (StatusCode, String)> {
    // Log Upload-Metadata header (helps verify client sent caption/description)
    if let Some(h) = headers.get("Upload-Metadata") {
        if let Ok(s) = h.to_str() {
            tracing::info!(target = "upload", "[TUS] Incoming Upload-Metadata: {}", s);
            // Best-effort decode of selected keys (caption/description/favorite/created_at)
            // Format per TUS spec: comma-separated list of `key base64value` pairs
            let mut decoded: Vec<(String, String)> = Vec::new();
            for part in s.split(',') {
                let kv = part.trim();
                if kv.is_empty() {
                    continue;
                }
                let mut it = kv.split_whitespace();
                if let (Some(k), Some(vb64)) = (it.next(), it.next()) {
                    let key = k.trim().to_string();
                    if matches!(
                        key.as_str(),
                        "caption" | "description" | "favorite" | "created_at"
                    ) {
                        let val = base64::decode(vb64)
                            .ok()
                            .and_then(|v| String::from_utf8(v).ok())
                            .unwrap_or_else(|| "<non-utf8>".to_string());
                        let shown = if val.len() > 200 {
                            format!("{}…", &val[..200])
                        } else {
                            val
                        };
                        decoded.push((key, shown));
                    }
                }
            }
            if !decoded.is_empty() {
                let summary = decoded
                    .into_iter()
                    .map(|(k, v)| format!("{}='{}'", k, v))
                    .collect::<Vec<_>>()
                    .join(" ");
                tracing::info!(
                    target = "upload",
                    "[TUS] Decoded metadata preview: {}",
                    summary
                );
            }
        } else {
            tracing::info!(
                target = "upload",
                "[TUS] Incoming Upload-Metadata present but not valid UTF-8"
            );
        }
    }
    // Build upstream URL by preserving path and query
    let path_and_query = uri.path_and_query().map(|pq| pq.as_str()).unwrap_or("/");
    let request_path = uri.path().to_string();
    let auth_user_id = auth_user_id_from_headers(&headers, &state).await;
    if let Some(upload_id) = upload_id_from_tus_path(&request_path) {
        if let Some(user_id) = auth_user_id.as_deref() {
            state.remember_tus_upload_owner(&upload_id, user_id);
        }
    }
    let upstream_str = format!("{}{}", RUSTUS_ORIGIN.as_str(), path_and_query);
    let body = if method == Method::PATCH {
        // Cloudflare Tunnel defaults to chunked origin requests on HTTP/1.1.
        // Rustus handles fixed-length PATCH bodies more reliably, so we normalize
        // the request here before proxying upstream.
        let buffered = body
            .collect()
            .await
            .map_err(|e| {
                (
                    StatusCode::BAD_REQUEST,
                    format!("failed to buffer tus patch: {}", e),
                )
            })?
            .to_bytes();
        let buffered_len = buffered.len();
        let framing = normalize_buffered_patch_headers(&mut headers, buffered_len)?;
        if framing.transfer_encoding.is_some() || framing.content_length.is_none() {
            tracing::warn!(
                target = "upload",
                "[TUS_PROXY] Normalized PATCH framing content_length={} transfer_encoding={} buffered_bytes={}",
                framing.content_length.as_deref().unwrap_or("<none>"),
                framing.transfer_encoding.as_deref().unwrap_or("<none>"),
                buffered_len
            );
        } else {
            tracing::debug!(
                target = "upload",
                "[TUS_PROXY] Buffered PATCH with fixed content_length={} buffered_bytes={}",
                framing.content_length.as_deref().unwrap_or("<none>"),
                buffered_len
            );
        }
        Body::from(buffered)
    } else {
        body
    };

    // Use hyper client to stream bodies
    // Build hyper client that can stream request/response bodies
    let connector = HttpConnector::new();
    let client: Client<_, Body> = Client::builder(TokioExecutor::new()).build(connector);

    // Prepare streaming request to upstream
    let mut req_builder = hyper::Request::builder()
        .method(method.clone())
        .uri(upstream_str.clone());

    // Clean hop-by-hop headers
    for h in [
        "connection",
        "proxy-connection",
        "keep-alive",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ] {
        headers.remove(h);
    }

    // Set X-Forwarded-Proto/Host based on incoming
    let xf_proto = if let Some(h) = headers.get("x-forwarded-proto") {
        h.clone()
    } else {
        HeaderValue::from_static("http")
    };
    if let Some(host) = headers.get("host").cloned() {
        req_builder = req_builder
            .header("x-forwarded-proto", xf_proto)
            .header("x-forwarded-host", host);
    }
    // Build hyper request with the incoming streaming body
    let mut req = req_builder.body(body).map_err(|_| {
        (
            StatusCode::BAD_GATEWAY,
            "failed to build upstream request".into(),
        )
    })?;

    // Copy headers (excluding host)
    {
        let req_headers = req.headers_mut();
        for (k, v) in headers.iter() {
            if k.as_str().eq_ignore_ascii_case("host") {
                continue;
            }
            req_headers.append(k.clone(), v.clone());
        }
    }

    // Send upstream (streaming)
    let upstream_resp: HyperResponse<hyper::body::Incoming> = client
        .request(req)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("upstream error: {}", e)))?;

    // Build Axum response (streaming body)
    let (parts, incoming_body) = upstream_resp.into_parts();
    let stream = incoming_body.into_data_stream();
    let mut resp = Response::from_parts(parts, Body::from_stream(stream));
    if let Some(loc) = resp.headers().get("location").cloned() {
        remember_tus_upload_owner(
            &state,
            &method,
            &request_path,
            Some(&loc),
            auth_user_id.as_deref(),
        );
        if let Ok(loc_str) = loc.to_str() {
            // Compute external origin from incoming Host/X-Forwarded-Proto we preserved above
            let scheme = headers
                .get("x-forwarded-proto")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("http");
            let host = headers
                .get("host")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if loc_str.starts_with(RUSTUS_ORIGIN.as_str()) && !host.is_empty() {
                let path = &loc_str[RUSTUS_ORIGIN.len()..];
                let new_loc = format!("{}://{}{}", scheme, host, path);
                if let Ok(hv) = HeaderValue::try_from(new_loc) {
                    let headers_mut = resp.headers_mut();
                    headers_mut.insert("location", hv);
                }
            }
        }
    }
    if !resp.headers().contains_key("location") {
        remember_tus_upload_owner(
            &state,
            &method,
            &request_path,
            None,
            auth_user_id.as_deref(),
        );
    }

    Ok(resp)
}

#[cfg(test)]
mod tests {
    use super::{
        normalize_buffered_patch_headers, upload_id_from_location, upload_id_from_tus_path,
    };
    use axum::http::{header, HeaderMap, HeaderValue};

    #[test]
    fn normalize_buffered_patch_headers_replaces_chunked_with_content_length() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::TRANSFER_ENCODING,
            HeaderValue::from_static("chunked"),
        );

        let framing =
            normalize_buffered_patch_headers(&mut headers, 42).expect("header normalization");

        assert_eq!(framing.content_length, None);
        assert_eq!(framing.transfer_encoding.as_deref(), Some("chunked"));
        assert_eq!(
            headers
                .get(header::CONTENT_LENGTH)
                .and_then(|v| v.to_str().ok()),
            Some("42")
        );
        assert!(headers.get(header::TRANSFER_ENCODING).is_none());
    }

    #[test]
    fn normalize_buffered_patch_headers_overwrites_existing_content_length() {
        let mut headers = HeaderMap::new();
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from_static("999"));

        let framing =
            normalize_buffered_patch_headers(&mut headers, 29).expect("header normalization");

        assert_eq!(framing.content_length.as_deref(), Some("999"));
        assert_eq!(framing.transfer_encoding, None);
        assert_eq!(
            headers
                .get(header::CONTENT_LENGTH)
                .and_then(|v| v.to_str().ok()),
            Some("29")
        );
    }

    #[test]
    fn normalize_buffered_patch_headers_accepts_zero_length() {
        let mut headers = HeaderMap::new();

        let framing =
            normalize_buffered_patch_headers(&mut headers, 0).expect("header normalization");

        assert_eq!(framing.content_length, None);
        assert_eq!(framing.transfer_encoding, None);
        assert_eq!(
            headers
                .get(header::CONTENT_LENGTH)
                .and_then(|v| v.to_str().ok()),
            Some("0")
        );
    }

    #[test]
    fn upload_id_from_tus_path_extracts_single_segment_id() {
        assert_eq!(
            upload_id_from_tus_path("/files/93eb1eb4-0af8-41df-aad2-4702389f43bf"),
            Some("93eb1eb4-0af8-41df-aad2-4702389f43bf".to_string())
        );
        assert_eq!(
            upload_id_from_tus_path("/files/93eb1eb4-0af8-41df-aad2-4702389f43bf?foo=bar"),
            Some("93eb1eb4-0af8-41df-aad2-4702389f43bf".to_string())
        );
        assert_eq!(upload_id_from_tus_path("/files"), None);
        assert_eq!(upload_id_from_tus_path("/files/parent/child"), None);
    }

    #[test]
    fn upload_id_from_location_supports_absolute_and_relative_urls() {
        let expected = Some("93eb1eb4-0af8-41df-aad2-4702389f43bf".to_string());
        assert_eq!(
            upload_id_from_location(
                "https://photos.example.com/files/93eb1eb4-0af8-41df-aad2-4702389f43bf"
            ),
            expected
        );
        assert_eq!(
            upload_id_from_location("/files/93eb1eb4-0af8-41df-aad2-4702389f43bf"),
            Some("93eb1eb4-0af8-41df-aad2-4702389f43bf".to_string())
        );
    }
}
