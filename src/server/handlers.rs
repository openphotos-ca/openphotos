use axum::{
    extract::{Multipart, Path, State},
    http::{header, HeaderMap},
    response::{Html, IntoResponse},
    Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::{debug, instrument};

use crate::face_processing::{get_all_persons, get_photos_by_person};
use crate::server::state::AppState;
use crate::server::AppError;
use image::{DynamicImage, GenericImageView};
use std::collections::HashMap;
// use base64::Engine;
// pHash utility function (deprecated; asset_id now uses Base58(first16(HMAC-SHA256(user_id, file_bytes))))
// fn calculate_phash(image: &DynamicImage) -> Result<String, anyhow::Error> { /* deprecated */ }

// Match Python ML service request/response format
#[derive(Debug, Deserialize)]
pub struct PredictRequest {
    #[serde(rename = "clip")]
    pub search: Option<SearchConfig>,
}

#[derive(Debug, Deserialize)]
pub struct SearchConfig {
    pub visual: Option<ModelConfig>,
    pub textual: Option<ModelConfig>,
}

#[derive(Debug, Deserialize)]
pub struct ModelConfig {
    #[serde(rename = "modelName")]
    pub model_name: String,
    pub options: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
pub struct PredictResponse {
    #[serde(rename = "clip", skip_serializing_if = "Option::is_none")]
    pub search: Option<String>,
    #[serde(rename = "imageHeight", skip_serializing_if = "Option::is_none")]
    pub image_height: Option<u32>,
    #[serde(rename = "imageWidth", skip_serializing_if = "Option::is_none")]
    pub image_width: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub status: String,
    pub models: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub query: String,
    pub limit: Option<usize>,
    pub model: Option<String>,
    pub language: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub results: Vec<SearchResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_used: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fallback_used: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct SearchResult {
    pub asset_id: String,
    pub score: f32,
}

#[derive(Debug, Deserialize)]
pub struct IndexRequest {
    pub directory: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct IndexResponse {
    pub indexed_files: Vec<String>,
    pub total_files: usize,
    pub message: String,
}

#[instrument(skip(state))]
pub async fn health_check(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let models = state.list_models();

    Json(HealthResponse {
        status: "healthy".to_string(),
        models,
    })
}

#[instrument(skip(state, multipart))]
pub async fn predict(
    State(state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> Result<impl IntoResponse, AppError> {
    // TODO: This endpoint needs to be updated for multi-tenant architecture
    // For now, return a placeholder response since we don't have a global database anymore
    let _state = state;
    let _multipart = multipart;

    return Ok(Json(PredictResponse {
        search: Some("disabled".to_string()),
        image_height: None,
        image_width: None,
    }));

    /*
    let mut entries: Option<PredictRequest> = None;
    let mut image_data: Option<Vec<u8>> = None;
    let mut text_data: Option<String> = None;

    // Parse multipart form data
    while let Some(field) = multipart.next_field().await.map_err(|e| anyhow::anyhow!("Multipart error: {}", e))? {
        let name = field.name().unwrap_or("").to_string();

        match name.as_str() {
            "entries" => {
                let data = field.bytes().await.map_err(|e| anyhow::anyhow!("Field read error: {}", e))?;
                let json_str = String::from_utf8(data.to_vec())
                    .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in entries: {}", e))?;
                entries = Some(serde_json::from_str(&json_str).map_err(|e| anyhow::anyhow!("JSON parse error: {}", e))?);
                debug!("Parsed entries: {:?}", entries);
            }
            "image" => {
                image_data = Some(field.bytes().await.map_err(|e| anyhow::anyhow!("Image read error: {}", e))?.to_vec());
                debug!("Received image data: {} bytes", image_data.as_ref().unwrap().len());
            }
            "text" => {
                text_data = Some(field.text().await.map_err(|e| anyhow::anyhow!("Text read error: {}", e))?);
                debug!("Received text: {:?}", text_data);
            }
            _ => {
                debug!("Unknown field: {}", name);
            }
        }
    }

    let entries = entries.ok_or_else(|| anyhow::anyhow!("Missing entries field"))?;

    // Process based on request type
    if let Some(search_config) = entries.search {
        if let Some(visual_config) = search_config.visual {
            // Image encoding
            if let Some(image_bytes) = image_data {
                let image = image::load_from_memory(&image_bytes).map_err(|e| anyhow::anyhow!("Image load error: {}", e))?;

                let embedding = state.with_visual_encoder(Some(&visual_config.model_name), |encoder| {
                    encoder.encode_image(&image)
                }).ok_or_else(|| anyhow::anyhow!("Visual encoder not found: {}", visual_config.model_name))??;

                // Store in database
                // Note: In production, asset_id would come from the request
                // For now, generate a placeholder
                let asset_id = format!("temp_{}", uuid::Uuid::new_v4());

                // Detect content type from image data
                let content_type = detect_content_type(&image_bytes);

                state.embedding_store
                    .upsert_image_embedding(
                        asset_id,
                        embedding.clone(),
                        image_bytes,
                        image.width(),
                        image.height(),
                        content_type,
                        None, // detected_objects
                        None, // scene_tags
                    )
                    .await?;

                // Encode as base64 for response (matching Python service)
                let embedding_json = base64::encode(&bincode::serialize(&embedding).map_err(|e| anyhow::anyhow!("Serialize error: {}", e))?);

                return Ok(Json(PredictResponse {
                    search: Some(embedding_json),
                    image_height: Some(image.height()),
                    image_width: Some(image.width()),
                }));
            }
        } else if let Some(textual_config) = search_config.textual {
            // Text encoding
            if let Some(text) = text_data {
                // Extract language from options
                let language = textual_config.options
                    .as_ref()
                    .and_then(|o| o.get("language"))
                    .and_then(|l| l.as_str())
                    .map(|s| s.to_string());

                // Select model based on language if not explicitly specified
                let mut model_name = if textual_config.model_name == "auto" && language.is_some() {
                    state.select_model_for_language(language.as_deref())
                } else {
                    textual_config.model_name.clone()
                };

                debug!("Attempting to use model '{}' for language '{:?}'", model_name, language);

                // Try to encode with selected model, fallback to English if unavailable
                let embedding = match state.with_textual_encoder(Some(&model_name), |encoder| {
                    encoder.encode_text(&text)
                }) {
                    Some(Ok(embedding)) => embedding,
                    Some(Err(e)) => {
                        return Err(anyhow::anyhow!("Encoding failed: {}", e).into());
                    }
                    None if model_name != "ViT-B-32__openai" => {
                        // Fallback to English model if multilingual model not available
                        tracing::warn!(
                            "Model '{}' not available for language '{:?}', falling back to English model",
                            model_name, language
                        );
                        model_name = "ViT-B-32__openai".to_string();

                        state.with_textual_encoder(Some(&model_name), |encoder| {
                            encoder.encode_text(&text)
                        }).ok_or_else(|| anyhow::anyhow!("Fallback encoder '{}' not found", model_name))??
                    }
                    None => {
                        return Err(anyhow::anyhow!("Textual encoder not found: {}", model_name).into());
                    }
                };

                // Cache text embedding
                state.embedding_store
                    .cache_text_embedding(
                        text.clone(),
                        model_name,
                        language,
                        embedding.clone(),
                    )
                    .await?;

                // Encode as base64 for response
                let embedding_json = base64::encode(&bincode::serialize(&embedding).map_err(|e| anyhow::anyhow!("Serialize error: {}", e))?);

                return Ok(Json(PredictResponse {
                    search: Some(embedding_json),
                    image_height: None,
                    image_width: None,
                }));
            }
        }
    }
    */

    // Err(anyhow::anyhow!("Invalid request format").into())
}

/// Simple translation function for common search terms
/// Only translates non-English single words, passes sentence queries directly to CLIP
fn translate_if_needed(query: &str) -> (String, bool) {
    // Split query into words to check if it's a single term or sentence
    let words: Vec<&str> = query.split_whitespace().collect();

    // If it's a multi-word query (sentence), pass it directly to CLIP
    if words.len() > 1 {
        debug!(
            "Multi-word query '{}' - passing directly to CLIP for semantic understanding",
            query
        );
        return (query.to_string(), false);
    }

    // Check if single word contains non-ASCII characters (likely needs translation)
    let needs_translation = query.chars().any(|c| {
        let code = c as u32;
        // Chinese character ranges or other non-ASCII
        (0x4E00..=0x9FFF).contains(&code) ||  // CJK Unified Ideographs
        (0x3400..=0x4DBF).contains(&code) ||  // CJK Extension A
        !c.is_ascii()
    });

    if !needs_translation {
        debug!(
            "Single word query '{}' appears to be English, no translation needed",
            query
        );
        return (query.to_string(), false);
    }

    // Create translation mappings for common search terms
    let mut mappings = HashMap::new();
    mappings.insert("猫", "cat");
    mappings.insert("狗", "dog");
    mappings.insert("花", "flower");
    mappings.insert("虎", "tiger");
    mappings.insert("老虎", "tiger");
    mappings.insert("山", "mountain");
    mappings.insert("海滩", "beach");
    mappings.insert("沙滩", "beach");
    mappings.insert("海", "ocean");
    mappings.insert("树", "tree");
    mappings.insert("房子", "house");
    mappings.insert("建筑", "building");
    mappings.insert("汽车", "car");
    mappings.insert("食物", "food");
    mappings.insert("蛋糕", "cake");
    mappings.insert("天空", "sky");
    mappings.insert("人", "person");
    mappings.insert("鸟", "bird");

    let mut translated = query.to_string();

    // Apply translations
    for (foreign, english) in &mappings {
        translated = translated.replace(foreign, english);
    }

    // If we actually translated something, return the result
    if translated != query {
        debug!(
            "Applied built-in translation for single term: '{}' -> '{}'",
            query, translated
        );
        (translated, true)
    } else {
        debug!("No translation mapping found for single term: '{}'", query);
        // For unknown foreign terms, return original - OpenAI CLIP might still work
        (query.to_string(), false)
    }
}

#[instrument(skip(state))]
pub async fn search(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(query): Json<SearchQuery>,
) -> Result<impl IntoResponse, AppError> {
    // Extract token from Authorization or Cookie
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers.get(header::COOKIE).and_then(|v| {
                v.to_str().ok().and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
            })
        });
    let token = token_opt.ok_or_else(|| anyhow::anyhow!("Missing authorization token"))?;
    let user = state.auth_service.verify_token(&token).await?;

    // Create per-user embedding store
    let embedding_store = state.create_user_embedding_store(&user.user_id)?;

    // Encode text using default textual encoder
    let model_name = state.default_model.clone();
    let embedding = state
        .with_textual_encoder(Some(&model_name), |encoder| {
            encoder.encode_text(&query.query)
        })
        .ok_or_else(|| anyhow::anyhow!("Text encoder not available"))??;

    // Run combined search (vector + tags)
    let limit = query.limit.unwrap_or(10);
    let results = embedding_store
        .search_combined(&query.query, embedding, limit)
        .await?;

    let response = SearchResponse {
        results: results
            .into_iter()
            .map(|r| SearchResult {
                asset_id: r.asset_id,
                score: if r.distance == 0.0 {
                    1.0
                } else {
                    1.0 - r.distance
                },
            })
            .collect(),
        model_used: Some(model_name),
        fallback_used: None,
    };
    return Ok(Json(response));

    // Translate query if needed (for better semantic understanding with OpenAI CLIP)
    let (translated_query, translation_used) = translate_if_needed(&query.query);

    debug!(
        "Original query: '{}', Translated: '{}', Translation used: {}",
        query.query, translated_query, translation_used
    );

    // Use translated query for search
    let search_query = SearchQuery {
        query: translated_query,
        ..query // Keep other fields the same
    };

    // Check cache first
    // let cached = state.embedding_store
    //     .get_cached_text_embedding(
    //         &search_query.query,
    //         search_query.model.as_deref().unwrap_or(&state.default_model),
    //         search_query.language.as_deref(),
    //     )
    //     .await?;

    // let (embedding, model_used, fallback_used) = if let Some(cached_embedding) = cached {
    //     debug!("Using cached embedding for query: {}", search_query.query);
    //     let model_name = search_query.model.clone().unwrap_or_else(|| state.default_model.clone());
    //     (cached_embedding, model_name, false)
    // } else {
    //     // Select model based on language if no model specified
    /*
        let mut model_name = if search_query.model.is_none() {
            // Always use language-based selection, defaulting to 'en' if no language specified
            let lang = search_query.language.as_deref().unwrap_or("en");
            state.select_model_for_language(Some(lang))
        } else {
            search_query.model.clone().unwrap_or_else(|| state.default_model.clone())
        };

        debug!("Attempting to use model '{}' for language '{:?}'", model_name, search_query.language);

        let original_model = model_name.clone();
        let mut fallback_used = false;

        // Try to encode with selected model, fallback to English if unavailable
        let embedding = match state.with_textual_encoder(Some(&model_name), |encoder| {
            encoder.encode_text(&search_query.query)
        }) {
            Some(Ok(embedding)) => embedding,
            Some(Err(e)) => {
                tracing::error!("Error encoding with model '{}': {}", model_name, e);
                return Err(anyhow::anyhow!("Encoding failed: {}", e).into());
            }
            None if model_name != state.default_model && state.list_models().contains(&state.default_model) => {
                // Fallback to default model if selected model not available
                tracing::warn!(
                    "Model '{}' not available for language '{:?}', falling back to default model '{}'",
                    model_name, search_query.language, state.default_model
                );
                model_name = state.default_model.clone();
                fallback_used = true;

                state.with_textual_encoder(Some(&model_name), |encoder| {
                    encoder.encode_text(&search_query.query)
                }).ok_or_else(|| anyhow::anyhow!("Fallback encoder '{}' not found", model_name))??
            }
            None => {
                let lang = search_query.language.as_deref().unwrap_or("en");
                return Err(anyhow::anyhow!("No suitable text encoder found for language '{}' (model: {})", lang, model_name).into());
            }
        };

        // Cache for future use
        state.embedding_store
            .cache_text_embedding(
                search_query.query.clone(),
                model_name.clone(),
                search_query.language.clone(),
                embedding.clone(),
            )
            .await?;

        (embedding, model_name, fallback_used)
    };

    // Search using combined CLIP+YOLO approach
    let limit = query.limit.unwrap_or(10);
    let results = state.embedding_store
        .search_combined(&search_query.query, embedding, limit)
        .await?;

    let response = SearchResponse {
        results: results.into_iter()
            .map(|r| SearchResult {
                asset_id: r.asset_id,
                score: if r.distance == 0.0 {
                    // Perfect YOLO tag match - return high similarity score
                    1.0
                } else {
                    // Convert distance back to similarity (1 - distance)
                    // Since distance = (1 - cosine_similarity), similarity = (1 - distance)
                    1.0 - r.distance
                },
            })
            .collect(),
        model_used: Some(model_used),
        fallback_used: if fallback_used { Some(true) } else { None },
    };
    */

    // Ok(Json(response))
}

// removed: list_models, list_languages, legacy serve_image

// removed: scene category constants used only by legacy indexer

// removed: legacy index_photos and index_single_photo

/// Compute cosine similarity between two vectors
fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }

    let dot_product: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();

    if norm_a == 0.0 || norm_b == 0.0 {
        0.0
    } else {
        dot_product / (norm_a * norm_b)
    }
}

// Helper to detect image content type from raw bytes
fn detect_content_type(bytes: &[u8]) -> String {
    if bytes.len() >= 4 {
        match &bytes[0..4] {
            [0xFF, 0xD8, 0xFF, _] => "image/jpeg".to_string(),
            [0x89, 0x50, 0x4E, 0x47] => "image/png".to_string(),
            [0x47, 0x49, 0x46, _] => "image/gif".to_string(),
            [0x52, 0x49, 0x46, 0x46] if bytes.len() >= 12 && &bytes[8..12] == b"WEBP" => {
                "image/webp".to_string()
            }
            _ => "image/jpeg".to_string(), // Default fallback
        }
    } else {
        "image/jpeg".to_string()
    }
}

// removed: duplicate face endpoints and dev clustering

// Helper to decode base64 embeddings (for compatibility with existing system)
// removed: decode_embedding helper and UUID debug module

// removed: debug embedding endpoints
