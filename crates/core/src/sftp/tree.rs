use std::collections::HashSet;
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
/// Rejects empty names, `.`, `/`, path separators, null bytes, and `..` to block path
/// traversal via malicious directory listings.
pub fn validate_remote_entry_name(name: &str) -> Result<(), SftpError> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name == "/"
        || name.contains('/')
        || name.contains('\0')
    {
        return Err(SftpError::InvalidRemotePath {
            path: name.to_string(),
        });
    }
    Ok(())
}

/// Validates a remote directory entry against the listing directory and server path.
///
/// Rejects malicious entry names and mismatches between the server-reported path and the
/// client-rebuilt path. Returns the client-built absolute remote path.
pub fn validated_remote_entry(
    listing_dir: &str,
    name: &str,
    server_path: &str,
) -> Result<String, SftpError> {
    validate_remote_entry_name(name)?;
    let rebuilt = join_remote_path(listing_dir, Path::new(name))?;
    let normalized_server = normalize_remote_path(server_path)?;
    if normalized_server != rebuilt {
        return Err(SftpError::InvalidRemotePath {
            path: server_path.to_string(),
        });
    }
    Ok(rebuilt)
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

fn invalid_local_path(path: &Path) -> SftpError {
    SftpError::InvalidRemotePath {
        path: path.display().to_string(),
    }
}

fn canonicalize_local_path(path: &Path) -> Result<PathBuf, SftpError> {
    std::fs::canonicalize(path).map_err(|_| invalid_local_path(path))
}

fn resolve_local_path_for_root_check(path: &Path) -> Result<PathBuf, SftpError> {
    if path.exists() {
        return canonicalize_local_path(path);
    }

    let file_name = path
        .file_name()
        .ok_or_else(|| invalid_local_path(path))?
        .to_os_string();

    let mut parent = path.parent().unwrap_or_else(|| Path::new("."));
    let mut pending_components: Vec<std::ffi::OsString> = Vec::new();

    while !parent.as_os_str().is_empty() && !parent.exists() {
        if let Some(name) = parent.file_name() {
            pending_components.push(name.to_os_string());
        }
        parent = parent.parent().unwrap_or_else(|| Path::new("."));
    }

    let canonical_parent = if parent.as_os_str().is_empty() {
        canonicalize_local_path(Path::new("."))?
    } else {
        canonicalize_local_path(parent)?
    };

    let mut resolved = canonical_parent;
    pending_components.reverse();
    for component in pending_components {
        resolved.push(component);
    }
    resolved.push(file_name);
    Ok(resolved)
}

fn ensure_canonical_path_within_root(
    canonical_root: &Path,
    canonical_path: &Path,
    display_path: &Path,
) -> Result<(), SftpError> {
    if canonical_path == canonical_root {
        return Ok(());
    }

    canonical_path
        .strip_prefix(canonical_root)
        .map_err(|_| invalid_local_path(display_path))?;
    Ok(())
}

/// Ensures `path` resolves under `root` after normalizing `.`, rejecting `..`, and resolving
/// symlinks via canonicalization.
pub fn ensure_local_path_within_root(root: &Path, path: &Path) -> Result<(), SftpError> {
    let normalized_root = normalize_local_path(root)?;
    let normalized_path = normalize_local_path(path)?;

    if normalized_path != normalized_root {
        normalized_path
            .strip_prefix(&normalized_root)
            .map_err(|_| invalid_local_path(path))?;
    }

    let canonical_root = canonicalize_local_path(root)?;
    let resolved_path = resolve_local_path_for_root_check(path)?;
    ensure_canonical_path_within_root(&canonical_root, &resolved_path, path)
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
    let mut visited = HashSet::<PathBuf>::new();

    while let Some(current) = pending.pop() {
        let canonical =
            tokio::fs::canonicalize(&current)
                .await
                .map_err(|err| SftpError::UploadFailed {
                    local: current.display().to_string(),
                    remote: String::new(),
                    message: err.to_string(),
                })?;
        if !visited.insert(canonical) {
            continue;
        }

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
    let mut pending = vec![(normalized_root.clone(), PathBuf::new())];
    let mut visited = HashSet::new();
    visited.insert(normalized_root);

    while let Some((current_remote, relative_prefix)) = pending.pop() {
        let entries = client.list_directory(&current_remote).await?;
        for entry in entries {
            let child_remote = validated_remote_entry(&current_remote, &entry.name, &entry.path)?;

            let relative_path = if relative_prefix.as_os_str().is_empty() {
                PathBuf::from(&entry.name)
            } else {
                relative_prefix.join(&entry.name)
            };

            if entry.is_directory {
                if visited.insert(child_remote.clone()) {
                    pending.push((child_remote, relative_path));
                }
            } else {
                files.push(RemoteFileEntry {
                    remote_path: child_remote,
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
        for name in ["", ".", "..", "/", "foo/bar", "a\u{0}b"] {
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
        let dir = tempdir().unwrap();
        let root = dir.path().join("download");
        fs::create_dir(&root).unwrap();
        let escaped = root.join("../secret.txt");
        let err = ensure_local_path_within_root(&root, &escaped).unwrap_err();
        assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
    }

    #[test]
    fn ensure_local_path_within_root_accepts_nested_paths() {
        // Given: a nested path under the root
        // When: ensure_local_path_within_root is called
        // Then: validation succeeds
        let dir = tempdir().unwrap();
        let root = dir.path().join("download");
        fs::create_dir_all(root.join("nested")).unwrap();
        let nested = root.join("nested/file.txt");
        assert!(ensure_local_path_within_root(&root, &nested).is_ok());
    }

    #[test]
    fn ensure_local_path_within_root_accepts_nonexistent_nested_paths() {
        // Given: a download destination that does not exist yet
        // When: ensure_local_path_within_root is called
        // Then: validation succeeds when the logical path stays under the root
        let dir = tempdir().unwrap();
        let root = dir.path().join("download");
        fs::create_dir(&root).unwrap();
        let nested = root.join("nested/new/file.txt");
        assert!(ensure_local_path_within_root(&root, &nested).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn ensure_local_path_within_root_rejects_symlink_escape() {
        // Given: a symlink under the root that points outside it
        // When: ensure_local_path_within_root is called
        // Then: InvalidRemotePath is returned
        let dir = tempdir().unwrap();
        let root = dir.path().join("download");
        fs::create_dir(&root).unwrap();
        let outside = tempdir().unwrap();
        fs::write(outside.path().join("secret.txt"), b"secret").unwrap();
        std::os::unix::fs::symlink(outside.path().join("secret.txt"), root.join("escape.txt"))
            .unwrap();

        let escaped = root.join("escape.txt");
        let err = ensure_local_path_within_root(&root, &escaped).unwrap_err();
        assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn ensure_local_path_within_root_rejects_symlink_directory_escape() {
        // Given: a directory symlink under the root that points outside it
        // When: ensure_local_path_within_root is called for a nested file path
        // Then: InvalidRemotePath is returned
        let dir = tempdir().unwrap();
        let root = dir.path().join("download");
        fs::create_dir(&root).unwrap();
        let outside = tempdir().unwrap();
        fs::write(outside.path().join("secret.txt"), b"secret").unwrap();
        std::os::unix::fs::symlink(outside.path(), root.join("link_dir")).unwrap();

        let escaped = root.join("link_dir/secret.txt");
        let err = ensure_local_path_within_root(&root, &escaped).unwrap_err();
        assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
    }

    #[test]
    fn validated_remote_entry_accepts_matching_paths() {
        // Given: a valid entry name and matching server path
        // When: validated_remote_entry is called
        // Then: the client-built path is returned
        assert_eq!(
            validated_remote_entry("/remote/dir", "file.txt", "/remote/dir/file.txt").unwrap(),
            "/remote/dir/file.txt"
        );
    }

    #[test]
    fn validated_remote_entry_rejects_mismatched_server_path() {
        // Given: a valid entry name but a mismatched server path
        // When: validated_remote_entry is called
        // Then: InvalidRemotePath is returned
        let err = validated_remote_entry("/remote/dir", "file.txt", "/etc/passwd").unwrap_err();
        assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
    }

    #[test]
    fn validated_remote_entry_rejects_malicious_names() {
        // Given: a malicious entry name
        // When: validated_remote_entry is called
        // Then: InvalidRemotePath is returned before path comparison
        let err = validated_remote_entry("/remote/dir", "..", "/remote/dir/..").unwrap_err();
        assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
    }

    #[test]
    fn validated_remote_entry_rejects_dot_entry() {
        // Given: a directory entry named "."
        // When: validated_remote_entry is called
        // Then: InvalidRemotePath is returned before path comparison
        let err = validated_remote_entry("/remote/dir", ".", "/remote/dir").unwrap_err();
        assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
    }

    #[test]
    fn remote_directory_visit_tracking_skips_already_seen_paths() {
        // Given: visited paths including a directory that would cycle back
        // When: the same insert logic as walk_remote_directory is applied
        // Then: already-seen paths are not enqueued again
        let mut visited = HashSet::from(["/remote/dir".to_string()]);
        let cycle_path = "/remote/dir".to_string();
        assert!(
            !visited.insert(cycle_path),
            "already-seen directory paths must not be re-enqueued"
        );

        let child_path = "/remote/dir/sub".to_string();
        assert!(
            visited.insert(child_path),
            "new directory paths must be enqueued once"
        );
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

    #[cfg(unix)]
    #[tokio::test]
    async fn walk_local_directory_with_options_avoids_symlink_cycle_to_parent() {
        // Given: a directory containing a symlink that points back to itself
        // When: follow_symlinks is enabled
        // Then: the cycle is detected and the walk terminates without duplicates
        let dir = tempdir().unwrap();
        let root = dir.path();
        fs::write(root.join("top.txt"), b"top").unwrap();
        std::os::unix::fs::symlink(root, root.join("link_dir")).unwrap();

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
        assert!(relatives.contains(&"top.txt".to_string()));
        assert!(!relatives.iter().any(|path| path.contains("link_dir")));
    }
}
