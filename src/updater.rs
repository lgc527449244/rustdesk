use std::path::PathBuf;

// Retained for installation of an explicitly supplied update URL. This module
// does not check for releases or start a background updater.
pub fn get_download_file_from_url(url: &str) -> Option<PathBuf> {
    let filename = url.split('/').last()?;
    Some(std::env::temp_dir().join(filename))
}
