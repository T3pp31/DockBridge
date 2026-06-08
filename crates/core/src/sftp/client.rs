use std::path::Path;

use russh_sftp::client::SftpSession;
use tokio::io::AsyncWriteExt;

use crate::error::SftpError;
use crate::ssh::session::SshSession;

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
}
