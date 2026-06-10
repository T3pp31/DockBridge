use std::path::Path;

use russh_sftp::client::SftpSession;
use tokio::io::AsyncWriteExt;

use crate::error::SftpError;
use crate::ssh::session::SshSession;

use super::tree::{
    is_local_directory, join_remote_path, local_entry_name, normalize_remote_path,
    walk_local_directory, walk_remote_directory,
};

/// Metadata for a remote file or directory entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteFile {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub size: u64,
}

/// High-level SFTP client built on top of an SSH session.
pub struct SftpClient<'a> {
    session: &'a SshSession,
}

impl<'a> SftpClient<'a> {
    /// Creates a new SFTP client for the given SSH session.
    pub fn new(session: &'a SshSession) -> Self {
        Self { session }
    }

    fn sftp(&self) -> &SftpSession {
        self.session.sftp()
    }

    /// Resolves a relative remote path to an absolute path.
    pub async fn canonicalize_path(&self, path: &str) -> Result<String, SftpError> {
        self.sftp()
            .canonicalize(path)
            .await
            .map_err(|err| SftpError::CanonicalizeFailed {
                path: path.to_string(),
                message: err.to_string(),
            })
    }

    /// Returns the SFTP session's initial working directory (typically the user's home).
    pub async fn initial_directory(&self) -> Result<String, SftpError> {
        self.canonicalize_path(".").await
    }

    /// Verifies that the SFTP session is still responsive.
    pub async fn check_alive(&self) -> Result<(), SftpError> {
        self.canonicalize_path(".").await.map(|_| ())
    }

    /// Lists entries in a remote directory.
    pub async fn list_directory(&self, path: &str) -> Result<Vec<RemoteFile>, SftpError> {
        let mut read_dir =
            self.sftp()
                .read_dir(path)
                .await
                .map_err(|err| SftpError::ListFailed {
                    path: path.to_string(),
                    message: err.to_string(),
                })?;

        let mut files = Vec::new();
        for entry in read_dir.by_ref() {
            let name = entry.file_name();
            let metadata = entry.metadata();
            files.push(RemoteFile {
                name: name.clone(),
                path: entry.path(),
                is_directory: metadata.is_dir(),
                size: metadata.size.unwrap_or(0),
            });
        }

        files.sort_by(|left, right| left.name.cmp(&right.name));
        Ok(files)
    }

    /// Uploads a local file to a remote path.
    pub async fn upload(&self, local_path: &Path, remote_path: &str) -> Result<(), SftpError> {
        let data = tokio::fs::read(local_path)
            .await
            .map_err(|err| SftpError::UploadFailed {
                local: local_path.display().to_string(),
                remote: remote_path.to_string(),
                message: err.to_string(),
            })?;

        let mut remote_file =
            self.sftp()
                .create(remote_path)
                .await
                .map_err(|err| SftpError::UploadFailed {
                    local: local_path.display().to_string(),
                    remote: remote_path.to_string(),
                    message: err.to_string(),
                })?;

        remote_file
            .write_all(&data)
            .await
            .map_err(|err| SftpError::UploadFailed {
                local: local_path.display().to_string(),
                remote: remote_path.to_string(),
                message: err.to_string(),
            })?;

        Ok(())
    }

    /// Downloads a remote file to a local path.
    pub async fn download(&self, remote_path: &str, local_path: &Path) -> Result<(), SftpError> {
        let data =
            self.sftp()
                .read(remote_path)
                .await
                .map_err(|err| SftpError::DownloadFailed {
                    remote: remote_path.to_string(),
                    local: local_path.display().to_string(),
                    message: err.to_string(),
                })?;

        if let Some(parent) = local_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|err| SftpError::DownloadFailed {
                    remote: remote_path.to_string(),
                    local: local_path.display().to_string(),
                    message: err.to_string(),
                })?;
        }

        tokio::fs::write(local_path, data)
            .await
            .map_err(|err| SftpError::DownloadFailed {
                remote: remote_path.to_string(),
                local: local_path.display().to_string(),
                message: err.to_string(),
            })
    }

    /// Deletes a remote file.
    pub async fn delete(&self, remote_path: &str) -> Result<(), SftpError> {
        self.sftp()
            .remove_file(remote_path)
            .await
            .map_err(|err| SftpError::DeleteFailed {
                path: remote_path.to_string(),
                message: err.to_string(),
            })
    }

    /// Renames a remote file or directory.
    pub async fn rename(&self, from: &str, to: &str) -> Result<(), SftpError> {
        self.sftp()
            .rename(from, to)
            .await
            .map_err(|err| SftpError::RenameFailed {
                from: from.to_string(),
                to: to.to_string(),
                message: err.to_string(),
            })
    }

    /// Creates a remote directory.
    pub async fn create_directory(&self, remote_path: &str) -> Result<(), SftpError> {
        self.sftp()
            .create_dir(remote_path)
            .await
            .map_err(|err| SftpError::MkdirFailed {
                path: remote_path.to_string(),
                message: err.to_string(),
            })
    }

    /// Creates a remote directory and any missing parent directories.
    pub async fn create_directory_all(&self, remote_path: &str) -> Result<(), SftpError> {
        let normalized = normalize_remote_path(remote_path);
        if normalized == "/" {
            return Ok(());
        }

        let trimmed = normalized.trim_start_matches('/');
        if trimmed.is_empty() {
            return Ok(());
        }

        let mut current = String::from("/");
        for segment in trimmed.split('/') {
            if segment.is_empty() {
                continue;
            }
            current = join_remote_path(&current, Path::new(segment));
            if let Err(SftpError::MkdirFailed { path, message }) =
                self.create_directory(&current).await
            {
                if is_mkdir_already_exists_message(&message) {
                    continue;
                }
                return Err(SftpError::MkdirFailed { path, message });
            }
        }

        Ok(())
    }

    /// Uploads a local file or directory tree into a remote directory.
    pub async fn upload_entry(
        &self,
        local_path: &Path,
        remote_directory: &str,
    ) -> Result<(), SftpError> {
        if is_local_directory(local_path).await? {
            let directory_name = local_entry_name(local_path);
            let remote_root = join_remote_path(remote_directory, Path::new(&directory_name));
            self.create_directory_all(&remote_root).await?;

            let files = walk_local_directory(local_path).await?;
            for entry in files {
                let remote_path = join_remote_path(&remote_root, &entry.relative_path);
                if let Some(parent) = parent_remote_path(&remote_path) {
                    self.create_directory_all(&parent).await?;
                }
                self.upload(&entry.local_path, &remote_path).await?;
            }
            return Ok(());
        }

        let remote_path =
            join_remote_path(remote_directory, Path::new(&local_entry_name(local_path)));
        if let Some(parent) = parent_remote_path(&remote_path) {
            self.create_directory_all(&parent).await?;
        }
        self.upload(local_path, &remote_path).await
    }

    /// Downloads a remote file or directory tree into a local directory.
    pub async fn download_entry(
        &self,
        remote_path: &str,
        local_directory: &Path,
    ) -> Result<(), SftpError> {
        let normalized = normalize_remote_path(remote_path);
        match self.list_directory(&normalized).await {
            Ok(entries) => {
                let directory_name = normalized
                    .trim_end_matches('/')
                    .rsplit('/')
                    .next()
                    .filter(|name| !name.is_empty())
                    .unwrap_or("download");
                let local_root = local_directory.join(directory_name);
                tokio::fs::create_dir_all(&local_root)
                    .await
                    .map_err(|err| SftpError::DownloadFailed {
                        remote: normalized.clone(),
                        local: local_root.display().to_string(),
                        message: err.to_string(),
                    })?;

                if entries.is_empty() {
                    return Ok(());
                }

                let files = walk_remote_directory(self, &normalized).await?;
                for entry in files {
                    let local_path = local_root.join(&entry.relative_path);
                    if let Some(parent) = local_path.parent() {
                        tokio::fs::create_dir_all(parent).await.map_err(|err| {
                            SftpError::DownloadFailed {
                                remote: entry.remote_path.clone(),
                                local: local_path.display().to_string(),
                                message: err.to_string(),
                            }
                        })?;
                    }
                    self.download(&entry.remote_path, &local_path).await?;
                }
                Ok(())
            }
            Err(_) => {
                let file_name = normalized
                    .rsplit('/')
                    .next()
                    .filter(|name| !name.is_empty())
                    .unwrap_or("download");
                let local_path = local_directory.join(file_name);
                self.download(&normalized, &local_path).await
            }
        }
    }
}

fn is_mkdir_already_exists_message(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.contains("already exists") || lower.contains("file exists") || lower.contains("failure")
}

fn parent_remote_path(remote_path: &str) -> Option<String> {
    let normalized = normalize_remote_path(remote_path);
    if normalized == "/" {
        return None;
    }

    let trimmed = normalized.trim_end_matches('/');
    let parent = trimmed.rsplit_once('/')?.0;
    if parent.is_empty() {
        Some("/".to_string())
    } else {
        Some(parent.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{is_mkdir_already_exists_message, parent_remote_path};

    #[test]
    fn parent_remote_path_returns_parent_directory() {
        assert_eq!(
            parent_remote_path("/remote/dir/file.txt").as_deref(),
            Some("/remote/dir")
        );
        assert_eq!(parent_remote_path("/file.txt").as_deref(), Some("/"));
        assert_eq!(parent_remote_path("/"), None);
    }

    #[test]
    fn mkdir_already_exists_messages_are_recognized() {
        assert!(is_mkdir_already_exists_message("Failure"));
        assert!(is_mkdir_already_exists_message("File already exists"));
        assert!(is_mkdir_already_exists_message("file exists"));
        assert!(!is_mkdir_already_exists_message("Permission denied"));
        assert!(!is_mkdir_already_exists_message("No such file"));
    }
}
