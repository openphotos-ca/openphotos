use anyhow::{anyhow, Result};
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

/// Get all image files from a directory
pub fn get_image_files<P: AsRef<Path>>(dir: P) -> Result<Vec<PathBuf>> {
    let dir = dir.as_ref();

    if !dir.exists() {
        return Err(anyhow!("Directory does not exist: {:?}", dir));
    }

    let mut image_files = Vec::new();
    let supported_extensions = ["jpg", "jpeg", "png", "bmp", "tiff", "webp"];

    for entry in WalkDir::new(dir)
        .follow_links(true)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();

        if path.is_file() {
            if let Some(extension) = path.extension() {
                let ext_str = extension.to_string_lossy().to_lowercase();
                if supported_extensions.contains(&ext_str.as_str()) {
                    image_files.push(path.to_path_buf());
                }
            }
        }
    }

    // Sort for consistent processing order
    image_files.sort();

    Ok(image_files)
}

/// Create directory if it doesn't exist
pub fn ensure_directory_exists<P: AsRef<Path>>(path: P) -> Result<()> {
    let path = path.as_ref();
    if !path.exists() {
        std::fs::create_dir_all(path)?;
    }
    Ok(())
}

/// Generate a safe filename from input
pub fn sanitize_filename(filename: &str) -> String {
    filename
        .chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.' => c,
            _ => '_',
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;
    use tempfile::TempDir;

    #[test]
    fn test_get_image_files() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let temp_path = temp_dir.path();

        // Create test files
        File::create(temp_path.join("image1.jpg"))?;
        File::create(temp_path.join("image2.PNG"))?;
        File::create(temp_path.join("document.txt"))?;
        File::create(temp_path.join("image3.jpeg"))?;

        let image_files = get_image_files(temp_path)?;

        assert_eq!(image_files.len(), 3);
        assert!(image_files
            .iter()
            .any(|p| p.file_name().unwrap() == "image1.jpg"));
        assert!(image_files
            .iter()
            .any(|p| p.file_name().unwrap() == "image2.PNG"));
        assert!(image_files
            .iter()
            .any(|p| p.file_name().unwrap() == "image3.jpeg"));

        Ok(())
    }

    #[test]
    fn test_sanitize_filename() {
        assert_eq!(sanitize_filename("hello world.jpg"), "hello_world.jpg");
        assert_eq!(sanitize_filename("test@#$%.png"), "test____.png");
        assert_eq!(
            sanitize_filename("normal_file-123.jpeg"),
            "normal_file-123.jpeg"
        );
    }
}
