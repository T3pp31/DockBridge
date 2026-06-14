use std::path::{Component, Path, PathBuf};

use crate::error::SftpError;

use super::client::SftpClient;

/// A local file discovered during directory traversal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalFileEntry {
    pub local_path: PathBuf,
    pub relative_path: PathBuf,
}

/// A remote file discovered during directory traversal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteFileEntry {
    pub remote_path: String,
    pub relative_path: PathBuf,
}

fn reject_parent_dir_segment(path: &str) -> Result<(), SftpError> {
    if path.split('/').any(|segment| segment == "..") {
        return Err(SftpError::InvalidRemotePath {
            path: path.to_string(),
        });
    }
    Ok(())
}

/// Validates a single SFTP directory entry name from the server.
///
/// Rejects empty names, `/`, path separators, null bytes, and `..` to block path
/// traversal via malicious directory listings.
pub fn validate_remote_entry_name(name: &str) -> Result<(), SftpError> {
    if name.is_empty() || name == ".." || name == "/" || name.contains('/') || name.contains('\0') {
        return Err(SftpError::InvalidRemotePath {
            path: name.to_string(),
        });
    }
    Ok(())
}

fn normalize_local_path(path: &Path) -> Result<PathBuf, SftpError> {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(_) | Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(SftpError::InvalidRemotePath {
                    path: path.display().to_string(),
                });
            }
            Component::Normal(name) => normalized.push(name),
        }
    }
    Ok(normalized)
}

/// Ensures `path` resolves under `root` after normalizing `.` and rejecting `..`.
pub fn ensure_local_path_within_root(root: &Path, path: &Path) -> Result<(), SftpError> {
    let normalized_root = normalize_local_path(root)?;
    let normalized_path = normalize_local_path(path)?;

    if normalized_path == normalized_root {
        return Ok(());
    }

    normalized_path
        .strip_prefix(&normalized_root)
        .map_err(|_| SftpError::InvalidRemotePath {
            path: path.display().to_string(),
        })?;

    Ok(())
}

/// Joins a remote base path with a relative path using POSIX separators.
pub fn join_remote_path(base: &str, relative: &Path) -> Result<String, SftpError> {
    let mut result = normalize_remote_path(base)?;
    for component in relative.components() {
        match component {
            Component::Normal(name) => {
                let segment = name.to_string_lossy();
                if result == "/" {
                    result = format!("/{segment}");
                } else if result.ends_with('/') {
                    result.push_str(&segment);
                } else {
                    result.push('/');
                    result.push_str(&segment);
                }
            }
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(SftpError::InvalidRemotePath {
                    path: relative.display().to_string(),
                });
            }
            Component::RootDir | Component::Prefix(_) => {}
        }
    }
    Ok(result)
}

/// Normalizes a remote path to an absolute POSIX path.
pub fn normalize_remote_path(path: &str) -> Result<String, SftpError> {
    reject_parent_dir_segment(path)?;

    let mut value = path.replace("//", "/");
    if value.is_empty() {
        value = "/".to_string();
    }
    if !value.starts_with('/') {
        value = format!("/{value}");
    }
    Ok(value)
}

/// Options for [`walk_local_directory_with_options`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WalkLocalDirectoryOptions {
    /// When `true`, symlinks are followed during traversal. Defaults to `false` for security.
    pub follow_symlinks: bool,
}

/// Recursively walks a local directory and returns all files with relative paths.
///
/// Symlinks are not followed by default to avoid uploading unintended files outside the
/// selected directory tree.
pub async fn walk_local_directory(root: &Path) -> Result<Vec<LocalFileEntry>, SftpError> {
    walk_local_directory_with_options(root, WalkLocalDirectoryOptions::default()).await
}

/// Recursively walks a local directory with configurable symlink handling.
pub async fn walk_local_directory_with_options(
    root: &Path,
    options: WalkLocalDirectoryOptions,
) -> Result<Vec<LocalFileEntry>, SftpError> {
    let metadata = tokio::fs::metadata(root)
        .await
        .map_err(|err| SftpError::UploadFailed {
            local: root.display().to_string(),
            remote: String::new(),
            message: err.to_string(),
        })?;

    if metadata.is_file() {
        let file_name = root
            .file_name()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("file"));
        return Ok(vec![LocalFileEntry {
            local_path: root.to_path_buf(),
            relative_path: file_name,
        }]);
    }

    if !metadata.is_dir() {
        return Err(SftpError::UploadFailed {
            local: root.display().to_string(),
            remote: String::new(),
            message: "path is neither a file nor a directory".to_string(),
        });
    }

    let mut entries = Vec::new();
    let mut pending = vec![root.to_path_buf()];

    while let Some(current) = pending.pop() {
        let mut read_dir =
            tokio::fs::read_dir(&current)
                .await
                .map_err(|err| SftpError::UploadFailed {
                    local: current.display().to_string(),
                    remote: String::new(),
                    message: err.to_string(),
                })?;

        while let Some(entry) =
            read_dir
                .next_entry()
                .await
                .map_err(|err| SftpError::UploadFailed {
                    local: current.display().to_string(),
                    remote: String::new(),
                    message: err.to_string(),
                })?
        {
            let path = entry.path();
            let file_type = entry
                .file_type()
                .await
                .map_err(|err| SftpError::UploadFailed {
                    local: path.display().to_string(),
                    remote: String::new(),
                    message: err.to_string(),
                })?;

            if file_type.is_symlink() {
                if !options.follow_symlinks {
                    continue;
                }

                let target_metadata =
                    tokio::fs::metadata(&path)
                        .await
                        .map_err(|err| SftpError::UploadFailed {
                            local: path.display().to_string(),
                            remote: String::new(),
                            message: err.to_string(),
                        })?;

                if target_metadata.is_dir() {
                    pending.push(path);
                } else if target_metadata.is_file() {
                    let relative_path =
                        path.strip_prefix(root).map(PathBuf::from).map_err(|err| {
                            SftpError::UploadFailed {
                                local: path.display().to_string(),
                                remote: String::new(),
                                message: err.to_string(),
                            }
                        })?;
                    entries.push(LocalFileEntry {
                        local_path: path,
                        relative_path,
                    });
                }
                continue;
            }

            if file_type.is_dir() {
                pending.push(path);
            } else if file_type.is_file() {
                let relative_path = path.strip_prefix(root).map(PathBuf::from).map_err(|err| {
                    SftpError::UploadFailed {
                        local: path.display().to_string(),
                        remote: String::new(),
                        message: err.to_string(),
                    }
                })?;
                entries.push(LocalFileEntry {
                    local_path: path,
                    relative_path,
                });
            }
        }
    }

    Ok(entries)
}

/// Recursively walks a remote directory and returns all files with relative paths.
pub async fn walk_remote_directory<'a>(
    client: &SftpClient<'a>,
    root: &str,
) -> Result<Vec<RemoteFileEntry>, SftpError> {
    let normalized_root = normalize_remote_path(root)?;
    let _entries = client.list_directory(&normalized_root).await?;
    let mut files = Vec::new();
    let mut pending = vec![(normalized_root, PathBuf::new())];

    while let Some((current_remote, relative_prefix)) = pending.pop() {
        let entries = client.list_directory(&current_remote).await?;
        for entry in entries {
            validate_remote_entry_name(&entry.name)?;

            let relative_path = if relative_prefix.as_os_str().is_empty() {
                PathBuf::from(&entry.name)
            } else {
                relative_prefix.join(&entry.name)
            };

            let child_remote = join_remote_path(&current_remote, Path::new(&entry.name))?;

            if entry.is_directory {
                pending.push((child_remote, relative_path));
            } else {
                files.push(RemoteFileEntry {
                    remote_path: entry.path,
                    relative_path,
                });
            }
        }
    }

    Ok(files)
}

/// Returns `true` when `path` is a local directory.
pub async fn is_local_directory(path: &Path) -> Result<bool, SftpError> {
    let metadata = tokio::fs::metadata(path)
        .await
        .map_err(|err| SftpError::UploadFailed {
            local: path.display().to_string(),
            remote: String::new(),
            message: err.to_string(),
        })?;
    Ok(metadata.is_dir())
}

/// Returns the base name of a local path.
pub fn local_entry_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn validate_remote_entry_name_rejects_traversal_and_separators() {
        // Given: malicious or malformed SFTP entry names
        // When: validate_remote_entry_name is called
        // Then: InvalidRemotePath is returned
        for name in ["", "..", "/", "foo/bar", "a\u{0}b"] {
            let err = validate_remote_entry_name(name).unwrap_err();
            assert!(
                matches!(err, SftpError::InvalidRemotePath { .. }),
                "expected InvalidRemotePath for {name:?}"
            );
        }
    }

    #[test]
    fn validate_remote_entry_name_accepts_normal_names() {
        // Given: a normal file name
        // When: validate_remote_entry_name is called
        // Then: validation succeeds
        assert!(validate_remote_entry_name("file.txt").is_ok());
        assert!(validate_remote_entry_name(".hidden").is_ok());
    }

    #[test]
    fn ensure_local_path_within_root_rejects_escape() {
        // Given: a download root and a path that escapes it
        // When: ensure_local_path_within_root is called
        // Then: InvalidRemotePath is returned
        let root = Path::new("/tmp/download");
        let escaped = root.join("../secret.txt");
        let err = ensure_local_path_within_root(root, &escaped).unwrap_err();
        assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
    }

    #[test]
    fn ensure_local_path_within_root_accepts_nested_paths() {
        // Given: a nested path under the root
        // When: ensure_local_path_within_root is called
        // Then: validation succeeds
        let root = Path::new("/tmp/download");
        let nested = root.join("nested/file.txt");
        assert!(ensure_local_path_within_root(root, &nested).is_ok());
    }

    #[test]
    fn join_remote_path_appends_segments() {
        assert_eq!(
            join_remote_path("/remote/dir", Path::new("child/file.txt")).unwrap(),
            "/remote/dir/child/file.txt"
        );
    }

    #[test]
    fn join_remote_path_handles_root() {
        assert_eq!(
            join_remote_path("/", Path::new("file.txt")).unwrap(),
            "/file.txt"
        );
    }

    #[test]
    fn join_remote_path_rejects_parent_dir() {
        let err = join_remote_path("/remote/dir", Path::new("../secret")).unwrap_err();
        assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
    }

    #[test]
    fn normalize_remote_path_adds_leading_slash() {
        assert_eq!(normalize_remote_path("remote/dir").unwrap(), "/remote/dir");
        assert_eq!(normalize_remote_path("").unwrap(), "/");
    }

    #[test]
    fn normalize_remote_path_rejects_parent_dir_segments() {
        for path in ["/foo/../bar", "../secret", "foo/..", ".."] {
            let err = normalize_remote_path(path).unwrap_err();
            assert!(
                matches!(err, SftpError::InvalidRemotePath { .. }),
                "expected InvalidRemotePath for {path:?}"
            );
        }
    }

    #[test]
    fn normalize_remote_path_allows_non_traversal_dots() {
        assert_eq!(
            normalize_remote_path("/foo..bar/baz").unwrap(),
            "/foo..bar/baz"
        );
    }

    #[tokio::test]
    async fn walk_local_directory_collects_nested_files() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("nested")).unwrap();
        fs::write(root.join("top.txt"), b"a").unwrap();
        fs::write(root.join("nested/inner.txt"), b"b").unwrap();

        let entries = walk_local_directory(root).await.unwrap();
        let relatives: Vec<_> = entries
            .iter()
            .map(|entry| entry.relative_path.to_string_lossy().into_owned())
            .collect();

        assert_eq!(entries.len(), 2);
        assert!(relatives.contains(&"top.txt".to_string()));
        assert!(relatives.contains(&"nested/inner.txt".to_string()));
    }

    #[tokio::test]
    async fn walk_local_directory_single_file() {
        let dir = tempdir().unwrap();
        let file = dir.path().join("only.txt");
        fs::write(&file, b"x").unwrap();

        let entries = walk_local_directory(&file).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].relative_path, PathBuf::from("only.txt"));
    }

    #[tokio::test]
    async fn walk_local_directory_empty_directory() {
        let dir = tempdir().unwrap();
        let entries = walk_local_directory(dir.path()).await.unwrap();
        assert!(entries.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn walk_local_directory_skips_symlinks_by_default() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        let outside = tempdir().unwrap();
        fs::write(outside.path().join("secret.txt"), b"secret").unwrap();
        fs::write(root.join("normal.txt"), b"ok").unwrap();
        std::os::unix::fs::symlink(outside.path().join("secret.txt"), root.join("link.txt"))
            .unwrap();
        std::os::unix::fs::symlink(outside.path(), root.join("link_dir")).unwrap();

        let entries = walk_local_directory(root).await.unwrap();
        let relatives: Vec<_> = entries
            .iter()
            .map(|entry| entry.relative_path.to_string_lossy().into_owned())
            .collect();

        assert_eq!(entries.len(), 1);
        assert!(relatives.contains(&"normal.txt".to_string()));
        assert!(!relatives.iter().any(|path| path.contains("secret")));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn walk_local_directory_follows_symlinks_when_enabled() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        let outside = tempdir().unwrap();
        fs::write(outside.path().join("linked.txt"), b"linked").unwrap();
        std::os::unix::fs::symlink(outside.path().join("linked.txt"), root.join("link.txt"))
            .unwrap();

        let entries = walk_local_directory_with_options(
            root,
            WalkLocalDirectoryOptions {
                follow_symlinks: true,
            },
        )
        .await
        .unwrap();
        let relatives: Vec<_> = entries
            .iter()
            .map(|entry| entry.relative_path.to_string_lossy().into_owned())
            .collect();

        assert_eq!(entries.len(), 1);
        assert!(relatives.contains(&"link.txt".to_string()));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn walk_local_directory_follows_directory_symlinks_when_enabled() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        let outside = tempdir().unwrap();
        fs::write(outside.path().join("nested.txt"), b"nested").unwrap();
        std::os::unix::fs::symlink(outside.path(), root.join("link_dir")).unwrap();

        let entries = walk_local_directory_with_options(
            root,
            WalkLocalDirectoryOptions {
                follow_symlinks: true,
            },
        )
        .await
        .unwrap();
        let relatives: Vec<_> = entries
            .iter()
            .map(|entry| entry.relative_path.to_string_lossy().into_owned())
            .collect();

        assert_eq!(entries.len(), 1);
        assert!(relatives.contains(&"link_dir/nested.txt".to_string()));
    }
}
