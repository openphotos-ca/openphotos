use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=DEVELOPER_DIR");
    println!("cargo:rerun-if-env-changed=SDKROOT");
    println!("cargo:rerun-if-env-changed=XCODE_SELECT_PATH");

    if std::env::var("CARGO_CFG_TARGET_VENDOR").as_deref() != Ok("apple") {
        return;
    }

    if let Some(dir) = active_macos_clang_rt_dir() {
        println!("cargo:rustc-link-search={}", dir.display());
    }
}

fn active_macos_clang_rt_dir() -> Option<PathBuf> {
    let clang = resolve_clang()?;
    let output = Command::new(clang)
        .arg("--print-search-dirs")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let libraries_dir = stdout
        .lines()
        .find_map(|line| line.strip_prefix("libraries: ="))?;
    let dir = PathBuf::from(libraries_dir).join("lib/darwin");
    dir.exists().then_some(dir)
}

fn resolve_clang() -> Option<PathBuf> {
    let output = Command::new("xcrun")
        .arg("--find")
        .arg("clang")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let path = String::from_utf8(output.stdout).ok()?;
    let trimmed = path.trim();
    (!trimmed.is_empty()).then(|| PathBuf::from(trimmed))
}
