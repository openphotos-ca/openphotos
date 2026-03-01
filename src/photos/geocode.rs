use anyhow::Result;
use serde_json::Value;
use std::time::Duration;

use crate::database::multi_tenant::DbPool;
use tokio_postgres::Client as PgClient;

fn round_key(lat: f64, lon: f64, precision: u32) -> (String, f64, f64) {
    let f = 10f64.powi(precision as i32);
    let rl = (lat * f).round() / f;
    let rn = (lon * f).round() / f;
    (
        format!("{:.prec$}:{:.prec$}", rl, rn, prec = precision as usize),
        rl,
        rn,
    )
}

async fn nominatim_reverse(
    base: &str,
    lat: f64,
    lon: f64,
    timeout_ms: u64,
) -> Result<(
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
)> {
    let url = format!(
        "{}/reverse?lat={}&lon={}&format=jsonv2&addressdetails=1&zoom=10",
        base.trim_end_matches('/'),
        lat,
        lon
    );
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .user_agent("Albumbud/0.1 (reverse-geocode)")
        .build()?;
    let t0 = std::time::Instant::now();
    tracing::info!(
        target = "geocode",
        "[GEOCODE] HTTP start url={} timeout_ms={}",
        url,
        timeout_ms
    );
    let resp = client.get(&url).send().await?;
    let dt = t0.elapsed().as_millis() as u64;
    tracing::info!(
        target = "geocode",
        "[GEOCODE] HTTP done status={} ms={} url={}",
        resp.status().as_u16(),
        dt,
        url
    );
    if !resp.status().is_success() {
        return Ok((None, None, None, None));
    }
    let v: Value = resp.json().await.unwrap_or(Value::Null);
    let display = v
        .get("display_name")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string());
    let addr = v.get("address").cloned().unwrap_or(Value::Null);
    let city = addr
        .get("city")
        .or_else(|| addr.get("town"))
        .or_else(|| addr.get("village"))
        .or_else(|| addr.get("hamlet"))
        .and_then(|x| x.as_str())
        .map(|s| s.to_string());
    let province = addr
        .get("state")
        .or_else(|| addr.get("region"))
        .or_else(|| addr.get("state_district"))
        .and_then(|x| x.as_str())
        .map(|s| s.to_string());
    let country = addr
        .get("country")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string());
    Ok((display, city, province, country))
}

pub async fn reverse_geocode_cached(
    pool: &DbPool,
    lat: f64,
    lon: f64,
) -> Result<(
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
)> {
    let precision: u32 = std::env::var("GEOCODE_PRECISION")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(4);
    let (key, rlat, rlon) = round_key(lat, lon, precision);

    tracing::info!(
        target = "geocode",
        "[GEOCODE] request (duckdb) lat={} lon={}",
        lat,
        lon
    );
    // Try cache
    {
        let conn = pool.lock();
        if let Ok(mut stmt) = conn.prepare("SELECT location_name, city, province, country FROM geocode_cache WHERE key = ? LIMIT 1") {
            if let Ok(res) = stmt.query_row([&key], |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            }) {
                tracing::info!(target="geocode", "[GEOCODE] cache hit key={}", key);
                return Ok(res);
            }
        }
    }

    // Disabled?
    if std::env::var("GEOCODE_ENABLED")
        .map(|v| v == "0" || v.eq_ignore_ascii_case("false"))
        .unwrap_or(false)
    {
        tracing::info!(
            target = "geocode",
            "[GEOCODE] disabled via GEOCODE_ENABLED=0"
        );
        return Ok((None, None, None, None));
    }
    let base = std::env::var("NOMINATIM_URL")
        .unwrap_or_else(|_| "https://nominatim.openstreetmap.org".to_string());
    let timeout_ms: u64 = std::env::var("GEOCODE_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(5000);

    let t0 = std::time::Instant::now();
    let (location_name, city, province, country) = nominatim_reverse(&base, rlat, rlon, timeout_ms)
        .await
        .unwrap_or((None, None, None, None));
    let dt = t0.elapsed().as_millis() as u64;
    tracing::info!(
        target = "geocode",
        "[GEOCODE] fetched key={} ms={} base={} hit={} city={:?}",
        key,
        dt,
        base,
        location_name.is_some(),
        city
    );

    // Insert into cache
    {
        let conn = pool.lock();
        let _ = conn.execute(
            "INSERT OR REPLACE INTO geocode_cache (key, lat, lon, precision, location_name, city, province, country, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            duckdb::params![
                &key,
                rlat,
                rlon,
                precision as i32,
                &location_name,
                &city,
                &province,
                &country,
                chrono::Utc::now().timestamp()
            ],
        );
    }

    Ok((location_name, city, province, country))
}

pub async fn reverse_geocode_cached_pg(
    client: &PgClient,
    organization_id: i32,
    lat: f64,
    lon: f64,
) -> Result<(
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
)> {
    let precision: u32 = std::env::var("GEOCODE_PRECISION")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(4);
    let (key, rlat, rlon) = round_key(lat, lon, precision);

    tracing::info!(
        target = "geocode",
        "[GEOCODE] request (pg) org={} lat={} lon={}",
        organization_id,
        lat,
        lon
    );
    // Try cache in Postgres
    if let Ok(row_opt) = client
        .query_opt(
            "SELECT location_name, city, province, country FROM geocode_cache WHERE organization_id=$1 AND key=$2 LIMIT 1",
            &[&organization_id, &key],
        )
        .await
    {
        if let Some(row) = row_opt {
            tracing::info!(target="geocode", "[GEOCODE] cache hit org={} key={}", organization_id, key);
            let res: (Option<String>, Option<String>, Option<String>, Option<String>) = (
                row.get(0),
                row.get(1),
                row.get(2),
                row.get(3),
            );
            return Ok(res);
        }
    }

    if std::env::var("GEOCODE_ENABLED")
        .map(|v| v == "0" || v.eq_ignore_ascii_case("false"))
        .unwrap_or(false)
    {
        tracing::info!(
            target = "geocode",
            "[GEOCODE] disabled via GEOCODE_ENABLED=0"
        );
        return Ok((None, None, None, None));
    }
    let base = std::env::var("NOMINATIM_URL")
        .unwrap_or_else(|_| "https://nominatim.openstreetmap.org".to_string());
    let timeout_ms: u64 = std::env::var("GEOCODE_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(5000);

    let t0 = std::time::Instant::now();
    let (location_name, city, province, country) = nominatim_reverse(&base, rlat, rlon, timeout_ms)
        .await
        .unwrap_or((None, None, None, None));
    let dt = t0.elapsed().as_millis() as u64;
    tracing::info!(
        target = "geocode",
        "[GEOCODE] fetched (pg) org={} key={} ms={} base={} hit={} city={:?}",
        organization_id,
        key,
        dt,
        base,
        location_name.is_some(),
        city
    );

    // Upsert into cache
    let _ = client
        .execute(
            "INSERT INTO geocode_cache (organization_id, key, lat, lon, precision, location_name, city, province, country, updated_at) \
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) \
             ON CONFLICT (organization_id, key) DO UPDATE SET location_name=EXCLUDED.location_name, city=EXCLUDED.city, province=EXCLUDED.province, country=EXCLUDED.country, updated_at=EXCLUDED.updated_at",
            &[
                &organization_id,
                &key,
                &rlat,
                &rlon,
                &(precision as i32),
                &location_name,
                &city,
                &province,
                &country,
                &chrono::Utc::now().timestamp(),
            ],
        )
        .await;

    Ok((location_name, city, province, country))
}
