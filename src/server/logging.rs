pub fn app_log_level() -> String {
    std::env::var("APP_LOG_LEVEL")
        .unwrap_or_else(|_| "info".to_string())
        .to_lowercase()
}

pub fn info_enabled() -> bool {
    matches!(app_log_level().as_str(), "info" | "debug" | "trace")
}

pub fn debug_enabled() -> bool {
    matches!(app_log_level().as_str(), "debug" | "trace")
}
