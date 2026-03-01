use axum::{extract::State, Json};
use serde::Serialize;
use std::sync::Arc;

use crate::server::state::AppState;

#[derive(Serialize)]
pub struct CapabilitiesResponse {
    pub ee: bool,
    pub version: &'static str,
    pub features: Vec<&'static str>,
}

pub fn build_capabilities() -> CapabilitiesResponse {
    let features: Vec<&'static str> = {
        #[cfg(feature = "ee")]
        {
            crate::ee::capabilities::ee_features()
        }
        #[cfg(not(feature = "ee"))]
        {
            Vec::new()
        }
    };

    CapabilitiesResponse {
        ee: cfg!(feature = "ee"),
        version: env!("CARGO_PKG_VERSION"),
        features,
    }
}

pub async fn capabilities(State(_state): State<Arc<AppState>>) -> Json<CapabilitiesResponse> {
    Json(build_capabilities())
}
