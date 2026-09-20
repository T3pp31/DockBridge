//! Remote path helpers shared across the SFTP client and transfer manager.

use crate::error::SftpError;

use super::tree::normalize_remote_path;

/// Returns the parent directory of `remote_path`, or `None` for the root.
///
/// `"/"` and empty paths have no parent. `"/file.txt"` has parent `"/"`.
///
/// Single source of truth shared by the SFTP client and the transfer manager
/// (issue #321: previously duplicated in `sftp/client.rs` and
/// `transfer/manager.rs`).
pub fn parent_remote_path(remote_path: &str) -> Result<Option<String>, SftpError> {
    let normalized = normalize_remote_path(remote_path)?;
    if normalized == "/" {
        return Ok(None);
    }

    let trimmed = normalized.trim_end_matches('/');
    let Some((parent, _)) = trimmed.rsplit_once('/') else {
        return Ok(None);
    };
    Ok(Some(if parent.is_empty() {
        "/".to_string()
    } else {
        parent.to_string()
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parent_remote_path_returns_parent_directory() {
        assert_eq!(
            parent_remote_path("/remote/dir/file.txt")
                .unwrap()
                .as_deref(),
            Some("/remote/dir")
        );
        assert_eq!(
            parent_remote_path("/file.txt").unwrap().as_deref(),
            Some("/")
        );
        assert_eq!(parent_remote_path("/").unwrap(), None);
        assert_eq!(parent_remote_path("").unwrap(), None);
    }

    #[test]
    fn parent_remote_path_rejects_traversal() {
        assert!(parent_remote_path("/remote/../secret.txt").is_err());
    }
}
