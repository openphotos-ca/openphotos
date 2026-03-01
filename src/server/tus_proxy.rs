use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, Uri};
use axum::response::Response;
use http_body_util::BodyExt as _;
use hyper::{Request as HyperRequest, Response as HyperResponse};
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

pub async fn tus_proxy(
    State(_state): State<Arc<AppState>>,
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
    let upstream_str = format!("{}{}", RUSTUS_ORIGIN.as_str(), path_and_query);
    let upstream_uri: Uri = upstream_str
        .parse()
        .map_err(|_| (StatusCode::BAD_GATEWAY, "invalid upstream uri".to_string()))?;

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

    Ok(resp)
}
