use axum::{
    extract::State,
    http::{header, HeaderMap},
    Json,
};
use chrono::{DateTime, Utc};
use rand::Rng;
use reqwest::{header as reqwest_header, Client, Url};
use semver::Version;
use serde::{Deserialize, Serialize};
use std::{
    fmt,
    str::FromStr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::Notify;

use crate::{
    auth::types::User,
    server::{demo_policy::ensure_not_demo_mutation, state::AppState, AppError},
};

const CURRENT_SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_UPDATE_URL: &str =
    "https://api.github.com/repos/openphotos-ca/openphotos/releases/latest";
const DEFAULT_UPDATE_CHANNEL: &str = "stable";
const DEFAULT_UPDATE_INTERVAL_HOURS: u64 = 6;
const DEFAULT_RELEASES_PAGE_URL: &str = "https://github.com/openphotos-ca/openphotos/releases";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum InstallMode {
    Docker,
    LinuxUniversal,
    MacosPkg,
    WindowsNsis,
    Unknown,
}

impl InstallMode {
    pub fn platform_name(&self) -> Option<&'static str> {
        match self {
            Self::Docker => Some("docker"),
            Self::LinuxUniversal => Some("linux"),
            Self::MacosPkg => Some("macos"),
            Self::WindowsNsis => Some("windows"),
            Self::Unknown => None,
        }
    }

    pub fn supports_guided_install(&self) -> bool {
        !matches!(self, Self::Unknown)
    }

    fn requires_release_artifact(&self) -> bool {
        matches!(
            self,
            Self::LinuxUniversal | Self::MacosPkg | Self::WindowsNsis
        )
    }
}

impl fmt::Display for InstallMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let value = match self {
            Self::Docker => "docker",
            Self::LinuxUniversal => "linux-universal",
            Self::MacosPkg => "macos-pkg",
            Self::WindowsNsis => "windows-nsis",
            Self::Unknown => "unknown",
        };
        f.write_str(value)
    }
}

impl FromStr for InstallMode {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let normalized = value.trim().to_ascii_lowercase();
        match normalized.as_str() {
            "docker" => Ok(Self::Docker),
            "linux-universal" | "linux-deb" => Ok(Self::LinuxUniversal),
            "macos-pkg" => Ok(Self::MacosPkg),
            "windows-nsis" => Ok(Self::WindowsNsis),
            "unknown" | "" => Ok(Self::Unknown),
            _ => Err(anyhow::anyhow!("unsupported install mode '{value}'")),
        }
    }
}

#[derive(Debug, Clone)]
struct UpdateConfig {
    enabled: bool,
    url: String,
    interval: Duration,
    install_mode: InstallMode,
    install_arch: String,
}

impl UpdateConfig {
    fn from_env() -> Self {
        let install_mode = InstallMode::from_str(
            &std::env::var("OPENPHOTOS_INSTALL_MODE")
                .ok()
                .unwrap_or_else(|| "unknown".to_string()),
        )
        .unwrap_or(InstallMode::Unknown);
        let install_arch =
            normalize_install_arch(std::env::var("OPENPHOTOS_INSTALL_ARCH").ok(), &install_mode);
        let enabled = parse_bool_env("OPENPHOTOS_UPDATE_ENABLED", true);
        warn_if_deprecated_update_channel_set();
        let url = std::env::var("OPENPHOTOS_UPDATE_URL")
            .ok()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| DEFAULT_UPDATE_URL.to_string());
        let interval_hours = std::env::var("OPENPHOTOS_UPDATE_CHECK_INTERVAL_HOURS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|v| *v >= 1)
            .unwrap_or(DEFAULT_UPDATE_INTERVAL_HOURS);

        Self {
            enabled,
            url,
            interval: Duration::from_secs(interval_hours * 3600),
            install_mode,
            install_arch,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SelectedUpdateArtifact {
    pub platform: String,
    pub arch: String,
    pub url: String,
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UpdateStatusKind {
    Disabled,
    NeverChecked,
    Ok,
    CheckFailed,
    UnsupportedInstallMode,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ServerUpdateStatus {
    pub current_version: String,
    pub latest_version: Option<String>,
    pub available: bool,
    pub channel: String,
    pub checked_at: Option<DateTime<Utc>>,
    pub status: UpdateStatusKind,
    pub install_mode: InstallMode,
    pub install_arch: String,
    pub install_supported: bool,
    pub release_notes_url: Option<String>,
    pub artifact: Option<SelectedUpdateArtifact>,
    pub install_command: Option<String>,
    pub manual_steps: Vec<String>,
    pub last_error: Option<String>,
}

impl ServerUpdateStatus {
    fn new(config: &UpdateConfig) -> Self {
        Self {
            current_version: CURRENT_SERVER_VERSION.to_string(),
            latest_version: None,
            available: false,
            channel: DEFAULT_UPDATE_CHANNEL.to_string(),
            checked_at: None,
            status: if config.enabled {
                UpdateStatusKind::NeverChecked
            } else {
                UpdateStatusKind::Disabled
            },
            install_mode: config.install_mode.clone(),
            install_arch: config.install_arch.clone(),
            install_supported: config.install_mode.supports_guided_install(),
            release_notes_url: None,
            artifact: None,
            install_command: None,
            manual_steps: Vec::new(),
            last_error: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
struct GitHubReleaseAsset {
    name: String,
    browser_download_url: String,
}

#[derive(Debug, Clone, Deserialize)]
struct GitHubLatestRelease {
    tag_name: String,
    #[serde(default)]
    html_url: Option<String>,
    #[serde(default)]
    assets: Vec<GitHubReleaseAsset>,
}

pub struct UpdateService {
    config: UpdateConfig,
    client: Client,
    status: parking_lot::RwLock<ServerUpdateStatus>,
    check_in_progress: AtomicBool,
    check_complete: Notify,
}

impl UpdateService {
    pub fn new() -> Self {
        let config = UpdateConfig::from_env();
        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .user_agent(format!("openphotos/{CURRENT_SERVER_VERSION}"))
            .build()
            .expect("update HTTP client");

        Self {
            status: parking_lot::RwLock::new(ServerUpdateStatus::new(&config)),
            config,
            client,
            check_in_progress: AtomicBool::new(false),
            check_complete: Notify::new(),
        }
    }

    pub fn spawn_background_checks(service: Arc<Self>) {
        if !service.config.enabled {
            return;
        }

        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(5)).await;
            service.check_now().await;

            loop {
                tokio::time::sleep(jittered_interval(service.config.interval)).await;
                service.check_now().await;
            }
        });
    }

    pub fn status_snapshot(&self) -> ServerUpdateStatus {
        self.status.read().clone()
    }

    pub async fn check_now(&self) -> ServerUpdateStatus {
        if !self.config.enabled {
            return self.status_snapshot();
        }

        if self
            .check_in_progress
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            self.check_complete.notified().await;
            return self.status_snapshot();
        }

        let next_status = match self.perform_check().await {
            Ok(status) => status,
            Err(err) => {
                tracing::warn!(
                    update_url = %self.config.url,
                    error = %err,
                    "server update check failed"
                );
                self.failure_status(err)
            }
        };
        *self.status.write() = next_status.clone();

        self.check_in_progress.store(false, Ordering::SeqCst);
        self.check_complete.notify_waiters();
        next_status
    }

    async fn perform_check(&self) -> anyhow::Result<ServerUpdateStatus> {
        let release = self.fetch_latest_release().await?;
        build_status_from_release(&self.config, &release)
    }

    async fn fetch_latest_release(&self) -> anyhow::Result<GitHubLatestRelease> {
        let response = self
            .client
            .get(&self.config.url)
            .header(reqwest_header::CACHE_CONTROL, "no-cache")
            .header(reqwest_header::PRAGMA, "no-cache")
            .header(reqwest_header::ACCEPT, "application/vnd.github+json")
            .send()
            .await?;
        let status = response.status();
        let body = response.bytes().await?;
        if !status.is_success() {
            return Err(update_endpoint_error(
                &self.config.url,
                status,
                body.as_ref(),
            ));
        }

        let release: GitHubLatestRelease = serde_json::from_slice(&body)
            .map_err(|err| anyhow::anyhow!("invalid GitHub release JSON: {err}"))?;
        if release.tag_name.trim().is_empty() {
            return Err(anyhow::anyhow!("GitHub release tag_name is empty"));
        }

        Ok(release)
    }

    fn failure_status(&self, err: anyhow::Error) -> ServerUpdateStatus {
        let mut status = self.status_snapshot();
        status.checked_at = Some(Utc::now());
        status.status = UpdateStatusKind::CheckFailed;
        status.last_error = Some(err.to_string());
        status
    }
}

fn build_status_from_release(
    config: &UpdateConfig,
    release: &GitHubLatestRelease,
) -> anyhow::Result<ServerUpdateStatus> {
    let current_version = Version::parse(CURRENT_SERVER_VERSION)
        .map_err(|err| anyhow::anyhow!("invalid current server version: {err}"))?;
    let latest_version_string = normalize_release_version(&release.tag_name)?;
    let latest_version = Version::parse(&latest_version_string)
        .map_err(|err| anyhow::anyhow!("invalid GitHub release version: {err}"))?;
    let available = latest_version > current_version;
    let selected_asset = if available && config.install_mode.requires_release_artifact() {
        select_release_asset(config, &latest_version_string, &release.assets)
    } else {
        None
    };

    let install_supported = if available {
        !config.install_mode.requires_release_artifact() || selected_asset.is_some()
    } else {
        config.install_mode.supports_guided_install()
    };

    let status = if available && !install_supported {
        UpdateStatusKind::UnsupportedInstallMode
    } else {
        UpdateStatusKind::Ok
    };

    let public_artifact = selected_asset.map(|asset| SelectedUpdateArtifact {
        platform: config
            .install_mode
            .platform_name()
            .unwrap_or("unknown")
            .to_string(),
        arch: artifact_display_arch(config),
        url: asset.browser_download_url.clone(),
        sha256: None,
    });
    let install_command = selected_asset.and_then(|asset| {
        build_install_command(
            &config.install_mode,
            &asset.browser_download_url,
            &latest_version_string,
        )
    });
    let manual_steps = if available {
        build_manual_steps(&config.install_mode, selected_asset)
    } else {
        Vec::new()
    };

    Ok(ServerUpdateStatus {
        current_version: CURRENT_SERVER_VERSION.to_string(),
        latest_version: Some(latest_version_string),
        available,
        channel: DEFAULT_UPDATE_CHANNEL.to_string(),
        checked_at: Some(Utc::now()),
        status,
        install_mode: config.install_mode.clone(),
        install_arch: config.install_arch.clone(),
        install_supported,
        release_notes_url: Some(
            release
                .html_url
                .clone()
                .filter(|url| !url.trim().is_empty())
                .unwrap_or_else(|| DEFAULT_RELEASES_PAGE_URL.to_string()),
        ),
        artifact: public_artifact,
        install_command,
        manual_steps,
        last_error: None,
    })
}

fn select_release_asset<'a>(
    config: &UpdateConfig,
    version: &str,
    assets: &'a [GitHubReleaseAsset],
) -> Option<&'a GitHubReleaseAsset> {
    let expected_names =
        expected_asset_filenames(&config.install_mode, &config.install_arch, version);
    if expected_names.is_empty() {
        return None;
    }

    assets.iter().find(|asset| {
        expected_names
            .iter()
            .any(|expected| asset.name.eq_ignore_ascii_case(expected))
    })
}

fn expected_asset_filenames(install_mode: &InstallMode, arch: &str, version: &str) -> Vec<String> {
    match install_mode {
        InstallMode::Docker => Vec::new(),
        InstallMode::LinuxUniversal => vec![
            format!("openphotos-linux-installer-{arch}.sh"),
            format!("openphotos-linux-online_{version}_{arch}.tar.gz"),
            format!("openphotos-linux_{version}_{arch}.tar.gz"),
        ],
        InstallMode::MacosPkg => {
            if matches!(arch, "x64" | "arm64" | "universal") {
                vec![format!("openphotos-macos-{version}.pkg")]
            } else {
                Vec::new()
            }
        }
        InstallMode::WindowsNsis => {
            if arch.eq_ignore_ascii_case("x64") {
                vec![format!("openphotos-windows-{version}-x64-setup.exe")]
            } else {
                Vec::new()
            }
        }
        InstallMode::Unknown => Vec::new(),
    }
}

fn artifact_display_arch(config: &UpdateConfig) -> String {
    match config.install_mode {
        InstallMode::MacosPkg => "universal".to_string(),
        _ => config.install_arch.clone(),
    }
}

fn update_endpoint_error(url: &str, status: reqwest::StatusCode, body: &[u8]) -> anyhow::Error {
    let message = extract_github_error_message(body);
    match status {
        reqwest::StatusCode::NOT_FOUND => anyhow::anyhow!(
            "GitHub latest release endpoint not found at {}{}",
            url,
            format_optional_message(message.as_deref())
        ),
        reqwest::StatusCode::FORBIDDEN | reqwest::StatusCode::TOO_MANY_REQUESTS => {
            anyhow::anyhow!(
                "GitHub releases API rate limit or access error at {}{}",
                url,
                format_optional_message(message.as_deref())
            )
        }
        _ => anyhow::anyhow!(
            "update endpoint {} returned {}{}",
            url,
            status.as_u16(),
            format_optional_message(message.as_deref())
        ),
    }
}

fn extract_github_error_message(body: &[u8]) -> Option<String> {
    if body.is_empty() {
        return None;
    }

    #[derive(Deserialize)]
    struct GitHubErrorBody {
        message: Option<String>,
    }

    if let Ok(parsed) = serde_json::from_slice::<GitHubErrorBody>(body) {
        if let Some(message) = parsed.message {
            let trimmed = message.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }

    let text = String::from_utf8_lossy(body);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn format_optional_message(message: Option<&str>) -> String {
    message
        .filter(|value| !value.trim().is_empty())
        .map(|value| format!(": {value}"))
        .unwrap_or_default()
}

fn normalize_release_version(tag_name: &str) -> anyhow::Result<String> {
    let trimmed = tag_name.trim();
    let normalized = trimmed.strip_prefix('v').unwrap_or(trimmed).trim();
    if normalized.is_empty() {
        return Err(anyhow::anyhow!("GitHub release tag_name is empty"));
    }
    Version::parse(normalized)
        .map_err(|err| anyhow::anyhow!("invalid GitHub release tag_name '{}': {err}", tag_name))?;
    Ok(normalized.to_string())
}

fn warn_if_deprecated_update_channel_set() {
    if let Ok(value) = std::env::var("OPENPHOTOS_UPDATE_CHANNEL") {
        if !value.trim().is_empty() {
            tracing::warn!(
                "OPENPHOTOS_UPDATE_CHANNEL is deprecated and ignored; server updates always use '{}' releases",
                DEFAULT_UPDATE_CHANNEL
            );
        }
    }
}

fn build_install_command(install_mode: &InstallMode, url: &str, version: &str) -> Option<String> {
    let filename = install_filename_for_url(url);
    match install_mode {
        InstallMode::LinuxUniversal => Some(format!(
            "curl -fsSL https://raw.githubusercontent.com/openphotos-ca/openphotos/refs/heads/main/scripts/install_linux.sh | sudo env \"PATH=$PATH\" bash -s -- --version v{version}"
        )),
        InstallMode::MacosPkg => Some(format!(
            "curl -fsSL \"{url}\" -o /tmp/{filename} && sudo installer -pkg /tmp/{filename} -target /"
        )),
        InstallMode::Docker | InstallMode::WindowsNsis | InstallMode::Unknown => None,
    }
}

fn build_manual_steps(
    install_mode: &InstallMode,
    artifact: Option<&GitHubReleaseAsset>,
) -> Vec<String> {
    match (install_mode, artifact) {
        (InstallMode::Docker, _) => vec![
            "Pull the updated container image on the Docker host: docker compose pull".to_string(),
            "Recreate OpenPhotos with the new image: docker compose up -d".to_string(),
            "Confirm the container reports healthy and the server responds on /ping."
                .to_string(),
        ],
        (InstallMode::LinuxUniversal, Some(_)) => vec![
            "Run the install command on the server host with sudo.".to_string(),
            "Wait for the universal Linux installer to finish updating OpenPhotos.".to_string(),
            "Confirm the systemd services restart cleanly.".to_string(),
        ],
        (InstallMode::MacosPkg, Some(_)) => vec![
            "Run the install command on the server host with sudo.".to_string(),
            "Wait for the macOS installer to finish updating OpenPhotos.".to_string(),
            "Confirm the LaunchDaemons restart the OpenPhotos services.".to_string(),
        ],
        (InstallMode::WindowsNsis, Some(artifact)) => vec![
            format!("Download the installer from {}.", artifact.browser_download_url),
            "Run the installer on the Windows server host as Administrator.".to_string(),
            "Confirm the OpenPhotos Windows services restart cleanly.".to_string(),
        ],
        _ => vec![
            "A new server version is available, but this install mode does not support guided instructions.".to_string(),
            "Use the release notes and installer downloads to update the server manually.".to_string(),
        ],
    }
}

fn install_filename_for_url(url: &str) -> String {
    Url::parse(url)
        .ok()
        .and_then(|parsed| {
            parsed
                .path_segments()
                .and_then(|segments| segments.filter(|segment| !segment.is_empty()).last())
                .map(|segment| segment.to_string())
        })
        .filter(|segment| !segment.trim().is_empty())
        .unwrap_or_else(|| "openphotos-update".to_string())
}

fn jittered_interval(base: Duration) -> Duration {
    let factor = rand::thread_rng().gen_range(0.9_f64..=1.1_f64);
    let seconds = (base.as_secs_f64() * factor).round() as u64;
    Duration::from_secs(seconds.max(1))
}

fn parse_bool_env(key: &str, default: bool) -> bool {
    std::env::var(key)
        .ok()
        .and_then(|value| match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Some(true),
            "0" | "false" | "no" | "off" => Some(false),
            _ => None,
        })
        .unwrap_or(default)
}

fn normalize_install_arch(raw: Option<String>, mode: &InstallMode) -> String {
    let normalized = raw
        .unwrap_or_else(|| std::env::consts::ARCH.to_string())
        .trim()
        .to_ascii_lowercase();
    match mode {
        InstallMode::Docker | InstallMode::LinuxUniversal => match normalized.as_str() {
            "x86_64" | "x64" | "amd64" => "amd64".to_string(),
            "aarch64" | "arm64" => "arm64".to_string(),
            other => other.to_string(),
        },
        InstallMode::MacosPkg | InstallMode::WindowsNsis => match normalized.as_str() {
            "x86_64" | "amd64" | "x64" => "x64".to_string(),
            "aarch64" | "arm64" => "arm64".to_string(),
            "universal" => "universal".to_string(),
            other => other.to_string(),
        },
        InstallMode::Unknown => normalized,
    }
}

async fn current_user(headers: &HeaderMap, state: &AppState) -> Result<User, AppError> {
    if let Some(token) = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    {
        return state
            .auth_service
            .verify_token(token)
            .await
            .map_err(AppError);
    }

    if let Some(cookie_hdr) = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()) {
        for part in cookie_hdr.split(';') {
            if let Some(token) = part.trim().strip_prefix("auth-token=") {
                return state
                    .auth_service
                    .verify_token(token)
                    .await
                    .map_err(AppError);
            }
        }
    }

    Err(AppError(anyhow::anyhow!("Missing authorization token")))
}

fn require_admin(role: &str) -> Result<(), AppError> {
    if matches!(role, "owner" | "admin") {
        Ok(())
    } else {
        Err(AppError(anyhow::anyhow!(
            "forbidden: admin access required"
        )))
    }
}

pub async fn get_server_update_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<ServerUpdateStatus>, AppError> {
    let user = current_user(&headers, &state).await?;
    require_admin(&user.role)?;
    Ok(Json(state.update_service.status_snapshot()))
}

pub async fn check_server_update(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<ServerUpdateStatus>, AppError> {
    let user = current_user(&headers, &state).await?;
    require_admin(&user.role)?;
    ensure_not_demo_mutation(&state, &user.user_id, "POST /api/server/update/check").await?;
    Ok(Json(state.update_service.check_now().await))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{routing::get, Router};
    use tokio::net::TcpListener;

    fn github_release(tag_name: &str, assets: &[(&str, &str)]) -> GitHubLatestRelease {
        GitHubLatestRelease {
            tag_name: tag_name.to_string(),
            html_url: Some(format!(
                "https://github.com/openphotos-ca/openphotos/releases/tag/{}",
                tag_name
            )),
            assets: assets
                .iter()
                .map(|(name, url)| GitHubReleaseAsset {
                    name: (*name).to_string(),
                    browser_download_url: (*url).to_string(),
                })
                .collect(),
        }
    }

    fn linux_config() -> UpdateConfig {
        UpdateConfig {
            enabled: true,
            url: DEFAULT_UPDATE_URL.to_string(),
            interval: Duration::from_secs(3600),
            install_mode: InstallMode::LinuxUniversal,
            install_arch: "amd64".to_string(),
        }
    }

    fn docker_config() -> UpdateConfig {
        UpdateConfig {
            enabled: true,
            url: DEFAULT_UPDATE_URL.to_string(),
            interval: Duration::from_secs(3600),
            install_mode: InstallMode::Docker,
            install_arch: "amd64".to_string(),
        }
    }

    #[test]
    fn parses_release_version_from_v_prefixed_tag() {
        assert_eq!(normalize_release_version("v0.4.1").unwrap(), "0.4.1");
        assert_eq!(normalize_release_version("0.4.1").unwrap(), "0.4.1");
    }

    #[test]
    fn rejects_invalid_release_tag_name() {
        let err = normalize_release_version("release-0.4.1").unwrap_err();
        assert!(err.to_string().contains("invalid GitHub release tag_name"));
    }

    #[test]
    fn selects_matching_asset_from_release_assets() {
        let release = github_release(
            "v0.4.1",
            &[(
                "openphotos-linux-installer-amd64.sh",
                "https://github.com/openphotos-ca/openphotos/releases/download/v0.4.1/openphotos-linux-installer-amd64.sh",
            )],
        );

        let selected =
            select_release_asset(&linux_config(), "0.4.1", &release.assets).expect("asset");
        assert_eq!(selected.name, "openphotos-linux-installer-amd64.sh");
    }

    #[test]
    fn builds_update_status_from_github_release() {
        let release = github_release(
            "v99.0.0",
            &[(
                "openphotos-linux-installer-amd64.sh",
                "https://github.com/openphotos-ca/openphotos/releases/download/v99.0.0/openphotos-linux-installer-amd64.sh",
            )],
        );

        let status = build_status_from_release(&linux_config(), &release).unwrap();
        assert!(status.available);
        assert_eq!(status.latest_version.as_deref(), Some("99.0.0"));
        assert_eq!(
            status.release_notes_url.as_deref(),
            release.html_url.as_deref()
        );
        assert_eq!(
            status.artifact.as_ref().map(|artifact| artifact.url.as_str()),
            Some("https://github.com/openphotos-ca/openphotos/releases/download/v99.0.0/openphotos-linux-installer-amd64.sh")
        );
        assert_eq!(
            status.install_command.as_deref(),
            Some("curl -fsSL https://raw.githubusercontent.com/openphotos-ca/openphotos/refs/heads/main/scripts/install_linux.sh | sudo env \"PATH=$PATH\" bash -s -- --version v99.0.0")
        );
        assert_eq!(
            status
                .artifact
                .as_ref()
                .and_then(|artifact| artifact.sha256.as_deref()),
            None
        );
    }

    #[test]
    fn marks_unsupported_when_update_has_no_matching_asset() {
        let release = github_release(
            "v99.0.0",
            &[(
                "openphotos-windows-99.0.0-x64-setup.exe",
                "https://github.com/openphotos-ca/openphotos/releases/download/v99.0.0/openphotos-windows-99.0.0-x64-setup.exe",
            )],
        );
        let config = UpdateConfig {
            enabled: true,
            url: DEFAULT_UPDATE_URL.to_string(),
            interval: Duration::from_secs(3600),
            install_mode: InstallMode::MacosPkg,
            install_arch: "arm64".to_string(),
        };

        let status = build_status_from_release(&config, &release).unwrap();
        assert!(status.available);
        assert_eq!(status.status, UpdateStatusKind::UnsupportedInstallMode);
        assert!(!status.install_supported);
        assert!(status.artifact.is_none());
    }

    #[test]
    fn docker_updates_use_manual_steps_without_release_asset() {
        let release = github_release("v99.0.0", &[]);

        let status = build_status_from_release(&docker_config(), &release).unwrap();
        assert!(status.available);
        assert_eq!(status.status, UpdateStatusKind::Ok);
        assert!(status.install_supported);
        assert!(status.artifact.is_none());
        assert!(status.install_command.is_none());
        assert_eq!(status.install_mode, InstallMode::Docker);
        assert_eq!(status.install_arch, "amd64");
        assert_eq!(status.manual_steps.len(), 3);
        assert!(status.manual_steps[0].contains("docker compose pull"));
        assert!(status.manual_steps[1].contains("docker compose up -d"));
    }

    #[test]
    fn normalizes_docker_arch_to_amd64_and_arm64() {
        assert_eq!(
            normalize_install_arch(Some("x86_64".to_string()), &InstallMode::Docker),
            "amd64"
        );
        assert_eq!(
            normalize_install_arch(Some("aarch64".to_string()), &InstallMode::Docker),
            "arm64"
        );
    }

    #[test]
    fn keeps_previous_update_payload_when_check_fails() {
        let service = UpdateService {
            config: linux_config(),
            client: Client::builder().build().unwrap(),
            status: parking_lot::RwLock::new(ServerUpdateStatus {
                current_version: CURRENT_SERVER_VERSION.to_string(),
                latest_version: Some("0.4.1".to_string()),
                available: true,
                channel: DEFAULT_UPDATE_CHANNEL.to_string(),
                checked_at: Some(Utc::now()),
                status: UpdateStatusKind::Ok,
                install_mode: InstallMode::LinuxUniversal,
                install_arch: "amd64".to_string(),
                install_supported: true,
                release_notes_url: Some("https://example.com/release".to_string()),
                artifact: Some(SelectedUpdateArtifact {
                    platform: "linux".to_string(),
                    arch: "amd64".to_string(),
                    url: "https://example.com/openphotos-linux-installer-amd64.sh".to_string(),
                    sha256: None,
                }),
                install_command: Some("curl ...".to_string()),
                manual_steps: vec!["step".to_string()],
                last_error: None,
            }),
            check_in_progress: AtomicBool::new(false),
            check_complete: Notify::new(),
        };

        let failed = service.failure_status(anyhow::anyhow!("network failed"));
        assert_eq!(failed.latest_version.as_deref(), Some("0.4.1"));
        assert_eq!(failed.status, UpdateStatusKind::CheckFailed);
        assert_eq!(failed.last_error.as_deref(), Some("network failed"));
    }

    #[test]
    fn require_admin_allows_owner_and_admin_only() {
        assert!(require_admin("owner").is_ok());
        assert!(require_admin("admin").is_ok());
        assert!(require_admin("regular").is_err());
    }

    #[test]
    fn formats_rate_limit_error_from_github_api() {
        let err = update_endpoint_error(
            DEFAULT_UPDATE_URL,
            reqwest::StatusCode::FORBIDDEN,
            br#"{"message":"API rate limit exceeded"}"#,
        );
        assert!(err.to_string().contains("rate limit"));
        assert!(err.to_string().contains("API rate limit exceeded"));
    }

    #[tokio::test]
    async fn fetch_latest_release_parses_github_payload() {
        let body = serde_json::json!({
            "tag_name": "v0.4.1",
            "html_url": "https://github.com/openphotos-ca/openphotos/releases/tag/v0.4.1",
            "assets": [
                {
                    "name": "openphotos-linux-installer-amd64.sh",
                    "browser_download_url": "https://github.com/openphotos-ca/openphotos/releases/download/v0.4.1/openphotos-linux-installer-amd64.sh"
                }
            ]
        });

        let router = Router::new().route(
            "/repos/openphotos-ca/openphotos/releases/latest",
            get(move || {
                let body = body.clone();
                async move { Json(body) }
            }),
        );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });

        let service = UpdateService {
            config: UpdateConfig {
                enabled: true,
                url: format!("http://{addr}/repos/openphotos-ca/openphotos/releases/latest"),
                interval: Duration::from_secs(3600),
                install_mode: InstallMode::LinuxUniversal,
                install_arch: "amd64".to_string(),
            },
            client: Client::builder().build().unwrap(),
            status: parking_lot::RwLock::new(ServerUpdateStatus::new(&UpdateConfig {
                enabled: true,
                url: format!("http://{addr}/repos/openphotos-ca/openphotos/releases/latest"),
                interval: Duration::from_secs(3600),
                install_mode: InstallMode::LinuxUniversal,
                install_arch: "amd64".to_string(),
            })),
            check_in_progress: AtomicBool::new(false),
            check_complete: Notify::new(),
        };

        let release = service.fetch_latest_release().await.unwrap();
        assert_eq!(release.tag_name, "v0.4.1");
        assert_eq!(release.assets.len(), 1);

        server.abort();
    }
}
