use std::env;
use std::path::PathBuf;
use std::process::Command;

const BUNDLED_FFMPEG_BIN: &str = "/opt/openphotos/bin/ffmpeg";
const BUNDLED_FFPROBE_BIN: &str = "/opt/openphotos/bin/ffprobe";

fn preferred_tool_path(env_var: &str, bundled_path: &str, fallback: &str) -> PathBuf {
    if let Some(value) = env::var_os(env_var).filter(|value| !value.is_empty()) {
        return PathBuf::from(value);
    }

    let bundled = PathBuf::from(bundled_path);
    if bundled.is_file() {
        return bundled;
    }

    PathBuf::from(fallback)
}

pub fn ffmpeg_path() -> PathBuf {
    preferred_tool_path("FFMPEG_BIN", BUNDLED_FFMPEG_BIN, "ffmpeg")
}

pub fn ffprobe_path() -> PathBuf {
    preferred_tool_path("FFPROBE_BIN", BUNDLED_FFPROBE_BIN, "ffprobe")
}

pub fn ffmpeg_command() -> Command {
    Command::new(ffmpeg_path())
}

pub fn ffprobe_command() -> Command {
    Command::new(ffprobe_path())
}
