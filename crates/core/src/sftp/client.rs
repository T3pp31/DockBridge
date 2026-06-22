use std::path::{Path, PathBuf};

use rand::TryRng;
use russh_sftp::client::error::Error as SftpClientError;
use russh_sftp::client::fs::File as RemoteFileHandle;
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::OpenFlags;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::config::{clamp_transfer_chunk_size, DEFAULT_TRANSFER_CHUNK_SIZE_BYTES};
use crate::error::SftpError;
use crate::ssh::session::SshSession;
use crate::transfer::TransferOverwritePolicy;

use super::tree::{
    ensure_local_path_within_root, is_local_directory, join_remote_path, local_entry_name,
    normalize_remote_path, validated_remote_entry, walk_local_directory, walk_remote_directory,
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
        let path = normalize_remote_path(path)?;
        let mut read_dir =
            self.sftp()
                .read_dir(&path)
                .await
                .map_err(|err| SftpError::ListFailed {
                    path: path.to_string(),
                    message: err.to_string(),
                })?;

        let mut files = Vec::new();
        for entry in read_dir.by_ref() {
            let name = entry.file_name();
            let validated_path = validated_remote_entry(&path, &name, &entry.path())?;
            let metadata = entry.metadata();
            files.push(RemoteFile {
                name: name.clone(),
                path: validated_path,
                is_directory: metadata.is_dir(),
                size: metadata.size.unwrap_or(0),
            });
        }

        files.sort_by(|left, right| left.name.cmp(&right.name));
        Ok(files)
    }

    /// Returns the size of a remote file in bytes.
    pub async fn remote_file_size(&self, remote_path: &str) -> Result<u64, SftpError> {
        let remote_path = normalize_remote_path(remote_path)?;
        let metadata =
            self.sftp()
                .metadata(&remote_path)
                .await
                .map_err(|err| SftpError::DownloadFailed {
                    remote: remote_path.clone(),
                    local: String::new(),
                    message: err.to_string(),
                })?;
        Ok(metadata.size.unwrap_or(0))
    }

    /// Uploads a local file to a remote path.
    pub async fn upload(&self, local_path: &Path, remote_path: &str) -> Result<(), SftpError> {
        self.upload_cancellable(
            local_path,
            remote_path,
            default_chunk_size(),
            TransferOverwritePolicy::default(),
            || false,
            |_| {},
        )
        .await
    }

    /// Uploads a local file in chunks, checking `is_cancelled` before each chunk.
    pub async fn upload_cancellable(
        &self,
        local_path: &Path,
        remote_path: &str,
        chunk_size: usize,
        overwrite_policy: TransferOverwritePolicy,
        is_cancelled: impl Fn() -> bool + Send,
        mut on_progress: impl FnMut(u64) + Send,
    ) -> Result<(), SftpError> {
        let remote_path = normalize_remote_path(remote_path)?;
        let local = local_path.display().to_string();
        let remote = remote_path.clone();
        let chunk_size = clamp_transfer_chunk_size(chunk_size);
        let parent = parent_remote_path(&remote_path)?.unwrap_or_else(|| "/".to_string());

        let mut local_file =
            tokio::fs::File::open(local_path)
                .await
                .map_err(|err| SftpError::UploadFailed {
                    local: local.clone(),
                    remote: remote.clone(),
                    message: err.to_string(),
                })?;

        let mut partial =
            PartialRemoteTransfer::begin(self, &parent, &local, &remote, overwrite_policy).await?;

        let mut buffer = vec![0_u8; chunk_size];
        let mut transferred = 0_u64;
        loop {
            if is_cancelled() {
                partial.abort(true).await?;
                return Err(SftpError::Cancelled);
            }

            let bytes_read = match local_file.read(&mut buffer).await {
                Ok(bytes_read) => bytes_read,
                Err(err) => {
                    let _ = partial.abort(false).await;
                    return Err(SftpError::UploadFailed {
                        local: local.clone(),
                        remote: remote.clone(),
                        message: err.to_string(),
                    });
                }
            };
            if bytes_read == 0 {
                break;
            }

            if let Err(err) = partial
                .remote_file_mut()
                .write_all(&buffer[..bytes_read])
                .await
            {
                let _ = partial.abort(false).await;
                return Err(SftpError::UploadFailed {
                    local: local.clone(),
                    remote: remote.clone(),
                    message: err.to_string(),
                });
            }
            transferred += bytes_read as u64;
            on_progress(transferred);
        }

        if is_cancelled() {
            partial.abort(true).await?;
            return Err(SftpError::Cancelled);
        }

        if let Err(err) = partial.shutdown().await {
            let _ = partial.abort(false).await;
            return Err(err);
        }

        if is_cancelled() {
            partial.abort(true).await?;
            return Err(SftpError::Cancelled);
        }

        partial.finalize_rename(&remote_path).await
    }

    /// Downloads a remote file to a local path.
    pub async fn download(&self, remote_path: &str, local_path: &Path) -> Result<(), SftpError> {
        self.download_cancellable(
            remote_path,
            local_path,
            default_chunk_size(),
            TransferOverwritePolicy::default(),
            || false,
            |_| {},
        )
        .await
    }

    /// Downloads a remote file in chunks, checking `is_cancelled` before each chunk.
    pub async fn download_cancellable(
        &self,
        remote_path: &str,
        local_path: &Path,
        chunk_size: usize,
        overwrite_policy: TransferOverwritePolicy,
        is_cancelled: impl Fn() -> bool + Send,
        mut on_progress: impl FnMut(u64) + Send,
    ) -> Result<(), SftpError> {
        let remote_path = normalize_remote_path(remote_path)?;
        let remote = remote_path.clone();
        let local = local_path.display().to_string();
        let chunk_size = clamp_transfer_chunk_size(chunk_size);

        if let Some(parent) = local_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|err| SftpError::DownloadFailed {
                    remote: remote.clone(),
                    local: local.clone(),
                    message: err.to_string(),
                })?;
        }

        let mut remote_file =
            self.sftp()
                .open(&remote_path)
                .await
                .map_err(|err| SftpError::DownloadFailed {
                    remote: remote.clone(),
                    local: local.clone(),
                    message: err.to_string(),
                })?;

        let local_parent = local_path.parent().unwrap_or_else(|| Path::new("."));
        let mut partial =
            PartialLocalTransfer::begin(local_parent, &remote, &local, overwrite_policy).await?;

        let mut buffer = vec![0_u8; chunk_size];
        let mut transferred = 0_u64;
        loop {
            if is_cancelled() {
                partial.abort(true, &mut remote_file).await?;
                return Err(SftpError::Cancelled);
            }

            let bytes_read = match remote_file.read(&mut buffer).await {
                Ok(bytes_read) => bytes_read,
                Err(err) => {
                    let _ = partial.abort(false, &mut remote_file).await;
                    return Err(SftpError::DownloadFailed {
                        remote: remote.clone(),
                        local: local.clone(),
                        message: err.to_string(),
                    });
                }
            };
            if bytes_read == 0 {
                break;
            }

            if let Err(err) = partial
                .local_file_mut()
                .write_all(&buffer[..bytes_read])
                .await
            {
                let _ = partial.abort(false, &mut remote_file).await;
                return Err(SftpError::DownloadFailed {
                    remote: remote.clone(),
                    local: local.clone(),
                    message: err.to_string(),
                });
            }
            transferred += bytes_read as u64;
            on_progress(transferred);
        }

        if is_cancelled() {
            partial.abort(true, &mut remote_file).await?;
            return Err(SftpError::Cancelled);
        }

        if let Err(err) = partial.flush().await {
            let _ = partial.abort(false, &mut remote_file).await;
            return Err(err);
        }

        if is_cancelled() {
            partial.abort(true, &mut remote_file).await?;
            return Err(SftpError::Cancelled);
        }

        partial.finalize_rename(local_path, &mut remote_file).await
    }

    /// Deletes a remote file.
    pub async fn delete(&self, remote_path: &str) -> Result<(), SftpError> {
        let remote_path = normalize_remote_path(remote_path)?;
        self.sftp()
            .remove_file(&remote_path)
            .await
            .map_err(|err| SftpError::DeleteFailed {
                path: remote_path,
                message: err.to_string(),
            })
    }

    /// Renames a remote file or directory.
    pub async fn rename(&self, from: &str, to: &str) -> Result<(), SftpError> {
        let from = normalize_remote_path(from)?;
        let to = normalize_remote_path(to)?;
        self.sftp()
            .rename(&from, &to)
            .await
            .map_err(|err| SftpError::RenameFailed {
                from,
                to,
                message: err.to_string(),
            })
    }

    /// Creates a remote directory.
    pub async fn create_directory(&self, remote_path: &str) -> Result<(), SftpError> {
        let remote_path = normalize_remote_path(remote_path)?;
        self.sftp()
            .create_dir(&remote_path)
            .await
            .map_err(|err| SftpError::MkdirFailed {
                path: remote_path,
                message: err.to_string(),
            })
    }

    /// Creates a remote directory and any missing parent directories.
    pub async fn create_directory_all(&self, remote_path: &str) -> Result<(), SftpError> {
        let normalized = normalize_remote_path(remote_path)?;
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
            current = join_remote_path(&current, Path::new(segment))?;
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
            let remote_root = join_remote_path(remote_directory, Path::new(&directory_name))?;
            self.create_directory_all(&remote_root).await?;

            let files = walk_local_directory(local_path).await?;
            for entry in files {
                let remote_path = join_remote_path(&remote_root, &entry.relative_path)?;
                if let Some(parent) = parent_remote_path(&remote_path)? {
                    self.create_directory_all(&parent).await?;
                }
                self.upload(&entry.local_path, &remote_path).await?;
            }
            return Ok(());
        }

        let remote_path =
            join_remote_path(remote_directory, Path::new(&local_entry_name(local_path)))?;
        if let Some(parent) = parent_remote_path(&remote_path)? {
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
        let normalized = normalize_remote_path(remote_path)?;
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
                    ensure_local_path_within_root(&local_root, &local_path)?;
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

fn default_chunk_size() -> usize {
    DEFAULT_TRANSFER_CHUNK_SIZE_BYTES
}

const PARTIAL_SUFFIX_BYTES: usize = 16;
const MAX_PARTIAL_CREATE_ATTEMPTS: usize = 5;

fn random_partial_suffix() -> String {
    let mut bytes = [0_u8; PARTIAL_SUFFIX_BYTES];
    rand::rng()
        .try_fill_bytes(&mut bytes)
        .expect("failed to generate random partial suffix");
    bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

fn partial_file_name(suffix: &str) -> String {
    format!(".dockbridge-{suffix}.partial")
}

#[cfg(test)]
fn partial_remote_path_for_suffix(remote_path: &str, suffix: &str) -> Result<String, SftpError> {
    let parent = parent_remote_path(remote_path)?.unwrap_or_else(|| "/".to_string());
    join_remote_path(&parent, Path::new(&partial_file_name(suffix)))
}

fn partial_local_path_for_suffix(parent: &Path, suffix: &str) -> PathBuf {
    parent.join(partial_file_name(suffix))
}

struct PartialRemoteTransfer<'a> {
    client: &'a SftpClient<'a>,
    partial_path: String,
    remote_file: Option<RemoteFileHandle>,
    committed: bool,
    local: String,
    remote: String,
    overwrite_policy: TransferOverwritePolicy,
}

impl<'a> PartialRemoteTransfer<'a> {
    async fn begin(
        client: &'a SftpClient<'a>,
        parent: &str,
        local: &str,
        remote: &str,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<Self, SftpError> {
        let (partial_path, remote_file) =
            create_exclusive_remote_partial(client, parent, local, remote).await?;
        Ok(Self {
            client,
            partial_path,
            remote_file: Some(remote_file),
            committed: false,
            local: local.to_string(),
            remote: remote.to_string(),
            overwrite_policy,
        })
    }

    fn remote_file_mut(&mut self) -> &mut RemoteFileHandle {
        self.remote_file
            .as_mut()
            .expect("partial remote file handle must exist before commit")
    }

    async fn shutdown(&mut self) -> Result<(), SftpError> {
        if let Some(mut remote_file) = self.remote_file.take() {
            remote_file
                .shutdown()
                .await
                .map_err(|err| SftpError::UploadFailed {
                    local: self.local.clone(),
                    remote: self.remote.clone(),
                    message: err.to_string(),
                })?;
        }
        Ok(())
    }

    async fn finalize_rename(mut self, final_path: &str) -> Result<(), SftpError> {
        if let Err(err) = prepare_remote_finalize_destination(
            self.client,
            final_path,
            self.overwrite_policy,
            &self.local,
            &self.remote,
        )
        .await
        {
            self.abort(true).await?;
            return Err(err);
        }

        match self.client.rename(&self.partial_path, final_path).await {
            Ok(()) => {
                self.committed = true;
                Ok(())
            }
            Err(err) => {
                self.abort(true).await?;
                Err(err)
            }
        }
    }

    async fn abort(mut self, strict: bool) -> Result<(), SftpError> {
        if self.committed {
            return Ok(());
        }

        if let Some(mut remote_file) = self.remote_file.take() {
            if let Err(err) = remote_file.shutdown().await {
                tracing::warn!(
                    partial_remote_path = %self.partial_path,
                    error = %err,
                    "failed to close partial remote file during cleanup"
                );
            }
        }

        match self.client.delete(&self.partial_path).await {
            Ok(()) => Ok(()),
            Err(err) if !strict => {
                tracing::warn!(
                    partial_remote_path = %self.partial_path,
                    error = %err,
                    "failed to delete partial remote file after transfer error"
                );
                Ok(())
            }
            Err(err) => Err(SftpError::CleanupFailed {
                path: self.partial_path,
                message: err.to_string(),
            }),
        }
    }
}

struct PartialLocalTransfer {
    partial_path: PathBuf,
    local_file: Option<tokio::fs::File>,
    committed: bool,
    remote: String,
    local: String,
    overwrite_policy: TransferOverwritePolicy,
}

impl PartialLocalTransfer {
    async fn begin(
        parent: &Path,
        remote: &str,
        local: &str,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<Self, SftpError> {
        let (partial_path, local_file) = create_exclusive_local_partial(parent).await?;
        Ok(Self {
            partial_path,
            local_file: Some(local_file),
            committed: false,
            remote: remote.to_string(),
            local: local.to_string(),
            overwrite_policy,
        })
    }

    fn local_file_mut(&mut self) -> &mut tokio::fs::File {
        self.local_file
            .as_mut()
            .expect("partial local file handle must exist before commit")
    }

    async fn flush(&mut self) -> Result<(), SftpError> {
        self.local_file_mut()
            .flush()
            .await
            .map_err(|err| SftpError::DownloadFailed {
                remote: self.remote.clone(),
                local: self.local.clone(),
                message: err.to_string(),
            })
    }

    async fn finalize_rename(
        mut self,
        final_path: &Path,
        remote_file: &mut RemoteFileHandle,
    ) -> Result<(), SftpError> {
        self.local_file.take();

        if let Err(err) = prepare_local_finalize_destination(
            final_path,
            self.overwrite_policy,
            &self.remote,
            &self.local,
        )
        .await
        {
            self.abort(true, remote_file).await?;
            return Err(err);
        }

        match tokio::fs::rename(&self.partial_path, final_path).await {
            Ok(()) => {
                self.committed = true;
                Ok(())
            }
            Err(err) => {
                let remote = self.remote.clone();
                let local = self.local.clone();
                self.abort(true, remote_file).await?;
                Err(SftpError::DownloadFailed {
                    remote,
                    local,
                    message: err.to_string(),
                })
            }
        }
    }

    async fn abort(
        mut self,
        strict: bool,
        remote_file: &mut RemoteFileHandle,
    ) -> Result<(), SftpError> {
        if self.committed {
            return Ok(());
        }

        self.local_file.take();

        if let Err(err) = remote_file.shutdown().await {
            tracing::warn!(
                local = %self.partial_path.display(),
                error = %err,
                "failed to close remote file during download cleanup"
            );
        }

        match tokio::fs::remove_file(&self.partial_path).await {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) if !strict => {
                tracing::warn!(
                    local = %self.partial_path.display(),
                    error = %err,
                    "failed to delete partial local file after transfer error"
                );
                Ok(())
            }
            Err(err) => Err(SftpError::CleanupFailed {
                path: self.partial_path.display().to_string(),
                message: err.to_string(),
            }),
        }
    }
}

async fn create_exclusive_remote_partial(
    client: &SftpClient<'_>,
    parent: &str,
    local: &str,
    remote: &str,
) -> Result<(String, RemoteFileHandle), SftpError> {
    for _ in 0..MAX_PARTIAL_CREATE_ATTEMPTS {
        let suffix = random_partial_suffix();
        let partial_path = join_remote_path(parent, Path::new(&partial_file_name(&suffix)))?;
        match client
            .sftp()
            .open_with_flags(
                &partial_path,
                OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
            )
            .await
        {
            Ok(remote_file) => return Ok((partial_path, remote_file)),
            Err(err) if is_remote_file_exists_error(&err) => continue,
            Err(err) => {
                return Err(SftpError::UploadFailed {
                    local: local.to_string(),
                    remote: remote.to_string(),
                    message: err.to_string(),
                });
            }
        }
    }

    Err(SftpError::UploadFailed {
        local: local.to_string(),
        remote: remote.to_string(),
        message: format!(
            "failed to create exclusive partial file after {MAX_PARTIAL_CREATE_ATTEMPTS} attempts"
        ),
    })
}

async fn create_exclusive_local_partial(
    parent: &Path,
) -> Result<(PathBuf, tokio::fs::File), SftpError> {
    for _ in 0..MAX_PARTIAL_CREATE_ATTEMPTS {
        let suffix = random_partial_suffix();
        let partial_path = partial_local_path_for_suffix(parent, &suffix);
        match open_exclusive_local_file(&partial_path).await {
            Ok(file) => return Ok((partial_path, file)),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => {
                return Err(SftpError::DownloadFailed {
                    remote: String::new(),
                    local: parent.display().to_string(),
                    message: err.to_string(),
                });
            }
        }
    }

    Err(SftpError::DownloadFailed {
        remote: String::new(),
        local: parent.display().to_string(),
        message: format!(
            "failed to create exclusive partial file after {MAX_PARTIAL_CREATE_ATTEMPTS} attempts"
        ),
    })
}

async fn open_exclusive_local_file(path: &Path) -> std::io::Result<tokio::fs::File> {
    let mut options = tokio::fs::OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path).await
}

async fn prepare_remote_finalize_destination(
    client: &SftpClient<'_>,
    final_path: &str,
    overwrite_policy: TransferOverwritePolicy,
    local: &str,
    remote: &str,
) -> Result<(), SftpError> {
    let exists = remote_path_exists(client, final_path).await?;
    if !exists {
        return Ok(());
    }

    match overwrite_policy {
        TransferOverwritePolicy::FailIfExists => Err(SftpError::UploadFailed {
            local: local.to_string(),
            remote: remote.to_string(),
            message: TransferOverwritePolicy::destination_exists_message(final_path),
        }),
        TransferOverwritePolicy::Replace => client.delete(final_path).await,
    }
}

async fn prepare_local_finalize_destination(
    final_path: &Path,
    overwrite_policy: TransferOverwritePolicy,
    remote: &str,
    local: &str,
) -> Result<(), SftpError> {
    match tokio::fs::symlink_metadata(final_path).await {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(SftpError::DownloadFailed {
            remote: remote.to_string(),
            local: local.to_string(),
            message: format!(
                "destination '{}' is a symlink and cannot be replaced safely",
                final_path.display()
            ),
        }),
        Ok(_) => match overwrite_policy {
            TransferOverwritePolicy::FailIfExists => Err(SftpError::DownloadFailed {
                remote: remote.to_string(),
                local: local.to_string(),
                message: TransferOverwritePolicy::destination_exists_message(
                    &final_path.display().to_string(),
                ),
            }),
            TransferOverwritePolicy::Replace => Ok(()),
        },
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(SftpError::DownloadFailed {
            remote: remote.to_string(),
            local: local.to_string(),
            message: err.to_string(),
        }),
    }
}

async fn remote_path_exists(client: &SftpClient<'_>, path: &str) -> Result<bool, SftpError> {
    match client.sftp().metadata(path).await {
        Ok(_) => Ok(true),
        Err(err) if is_remote_no_such_file_error(&err) => Ok(false),
        Err(err) => Err(SftpError::UploadFailed {
            local: String::new(),
            remote: path.to_string(),
            message: err.to_string(),
        }),
    }
}

fn is_remote_file_exists_error(err: &SftpClientError) -> bool {
    match err {
        SftpClientError::Status(status) => {
            let message = status.error_message.to_lowercase();
            message.contains("file exists") || message.contains("already exists")
        }
        SftpClientError::IO(message) => {
            let message = message.to_lowercase();
            message.contains("file exists") || message.contains("already exists")
        }
        _ => false,
    }
}

fn is_remote_no_such_file_error(err: &SftpClientError) -> bool {
    match err {
        SftpClientError::Status(status) => {
            let message = status.error_message.to_lowercase();
            message.contains("no such file") || message.contains("not found")
        }
        SftpClientError::IO(message) => {
            let message = message.to_lowercase();
            message.contains("no such file") || message.contains("not found")
        }
        _ => false,
    }
}

fn is_mkdir_already_exists_message(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.contains("already exists") || lower.contains("file exists") || lower.contains("failure")
}

fn parent_remote_path(remote_path: &str) -> Result<Option<String>, SftpError> {
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
#[allow(dead_code)]
impl<'a> SftpClient<'a> {
    async fn open_remote_for_test(&self, path: &str) -> Result<RemoteFileHandle, SftpError> {
        let path = normalize_remote_path(path)?;
        self.sftp()
            .open(&path)
            .await
            .map_err(|err| SftpError::DownloadFailed {
                remote: path.clone(),
                local: String::new(),
                message: err.to_string(),
            })
    }
}

#[cfg(test)]
mod tests {
    use std::io::ErrorKind;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    use super::{
        create_exclusive_local_partial, is_mkdir_already_exists_message, normalize_remote_path,
        open_exclusive_local_file, parent_remote_path, partial_file_name,
        partial_local_path_for_suffix, partial_remote_path_for_suffix,
        prepare_local_finalize_destination, random_partial_suffix,
        SftpClient,
    };
    use crate::error::SftpError;
    use crate::sftp::test_server::{list_partial_paths, TestSftpServer};
    use crate::transfer::TransferOverwritePolicy;

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
    }

    #[test]
    fn mkdir_already_exists_messages_are_recognized() {
        assert!(is_mkdir_already_exists_message("Failure"));
        assert!(is_mkdir_already_exists_message("File already exists"));
        assert!(is_mkdir_already_exists_message("file exists"));
        assert!(!is_mkdir_already_exists_message("Permission denied"));
        assert!(!is_mkdir_already_exists_message("No such file"));
    }

    #[test]
    fn random_partial_suffix_is_32_hex_chars() {
        let suffix = random_partial_suffix();
        assert_eq!(suffix.len(), 32);
        assert!(suffix.chars().all(|ch| ch.is_ascii_hexdigit()));
    }

    #[test]
    fn partial_remote_path_uses_parent_directory_and_suffix() {
        let partial = partial_remote_path_for_suffix("/a/b.txt", "abc123").unwrap();
        assert_eq!(partial, "/a/.dockbridge-abc123.partial");
    }

    #[test]
    fn partial_local_path_uses_parent_directory_and_suffix() {
        let partial = partial_local_path_for_suffix(std::path::Path::new("/tmp/a"), "abc123");
        assert_eq!(
            partial,
            std::path::Path::new("/tmp/a/.dockbridge-abc123.partial")
        );
    }

    #[test]
    fn partial_file_name_uses_expected_prefix_and_suffix() {
        assert_eq!(
            partial_file_name("deadbeef"),
            ".dockbridge-deadbeef.partial"
        );
    }

    #[tokio::test]
    async fn create_exclusive_local_partial_rejects_existing_file() {
        let temp_dir = tempfile::tempdir().unwrap();
        let parent = temp_dir.path();

        let (partial_path, _file) = create_exclusive_local_partial(parent).await.unwrap();

        let duplicate_err = open_exclusive_local_file(&partial_path).await.unwrap_err();
        assert_eq!(duplicate_err.kind(), ErrorKind::AlreadyExists);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn open_exclusive_local_file_rejects_symlink_path() {
        let temp_dir = tempfile::tempdir().unwrap();
        let target = temp_dir.path().join("target.txt");
        std::fs::write(&target, b"secret").unwrap();
        let link = temp_dir.path().join(".dockbridge-link.partial");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let err = open_exclusive_local_file(&link).await.unwrap_err();
        assert_eq!(err.kind(), ErrorKind::AlreadyExists);
    }

    #[tokio::test]
    async fn finalize_local_destination_rejects_existing_file_when_policy_is_fail_if_exists() {
        let temp_dir = tempfile::tempdir().unwrap();
        let destination = temp_dir.path().join("final.txt");
        std::fs::write(&destination, b"existing").unwrap();

        let err = prepare_local_finalize_destination(
            &destination,
            TransferOverwritePolicy::FailIfExists,
            "/remote/file.txt",
            destination.display().to_string().as_str(),
        )
        .await
        .unwrap_err();

        match err {
            crate::error::SftpError::DownloadFailed { message, .. } => {
                assert!(message.contains("already exists and overwrite is disabled"));
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[tokio::test]
    async fn finalize_local_destination_allows_replace_when_file_exists() {
        let temp_dir = tempfile::tempdir().unwrap();
        let destination = temp_dir.path().join("final.txt");
        std::fs::write(&destination, b"existing").unwrap();

        prepare_local_finalize_destination(
            &destination,
            TransferOverwritePolicy::Replace,
            "/remote/file.txt",
            destination.display().to_string().as_str(),
        )
        .await
        .expect("replace policy should allow existing destination");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn finalize_local_destination_rejects_symlink_destination() {
        let temp_dir = tempfile::tempdir().unwrap();
        let target = temp_dir.path().join("target.txt");
        std::fs::write(&target, b"secret").unwrap();
        let link = temp_dir.path().join("final.txt");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let err = prepare_local_finalize_destination(
            &link,
            TransferOverwritePolicy::Replace,
            "/remote/file.txt",
            link.display().to_string().as_str(),
        )
        .await
        .unwrap_err();

        match err {
            crate::error::SftpError::DownloadFailed { message, .. } => {
                assert!(message.contains("symlink"));
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn client_path_normalization_rejects_parent_segments() {
        for path in ["/foo/../etc", "../secret"] {
            let err = normalize_remote_path(path).unwrap_err();
            assert!(
                matches!(err, crate::error::SftpError::InvalidRemotePath { .. }),
                "expected InvalidRemotePath for {path:?}"
            );
        }
    }

    #[test]
    fn upload_download_boundary_normalizes_relative_paths() {
        assert_eq!(
            normalize_remote_path("remote/dir/file.txt").unwrap(),
            "/remote/dir/file.txt"
        );
        assert_eq!(
            normalize_remote_path("/already/absolute").unwrap(),
            "/already/absolute"
        );
    }

    #[test]
    fn partial_remote_path_rejects_traversal_before_upload() {
        let err = partial_remote_path_for_suffix("/remote/../secret.txt", "abc123").unwrap_err();
        assert!(matches!(
            err,
            crate::error::SftpError::InvalidRemotePath { .. }
        ));
    }

    #[tokio::test]
    async fn upload_cancel_before_rename_leaves_no_remote_final_file() {
        // Given: a local file and a test SFTP server
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let payload = b"upload cancel before rename payload";
        let local_path = local_dir.path().join("file.txt");
        tokio::fs::write(&local_path, payload).await.unwrap();
        let total_bytes = payload.len() as u64;

        // When: all bytes are transferred and cancel is requested before rename
        let cancel = Arc::new(AtomicBool::new(false));
        let cancel_flag = Arc::clone(&cancel);
        let err = client
            .upload_cancellable(
                &local_path,
                "/upload/file.txt",
                16,
                move || cancel_flag.load(Ordering::Relaxed),
                {
                    let cancel_flag = Arc::clone(&cancel);
                    move |transferred| {
                        if transferred >= total_bytes {
                            cancel_flag.store(true, Ordering::Relaxed);
                        }
                    }
                },
            )
            .await
            .unwrap_err();

        // Then: transfer is cancelled and no final or partial remote file remains
        assert!(matches!(err, SftpError::Cancelled));
        assert!(
            !server.remote_file_exists("/upload/file.txt"),
            "final remote file must not exist after cancel-before-rename"
        );
        assert!(
            server.remote_partial_paths().is_empty(),
            "partial remote files must be cleaned up: {:?}",
            server.remote_partial_paths()
        );
    }

    #[tokio::test]
    async fn download_cancel_before_rename_leaves_no_local_final_file() {
        // Given: a remote file on the test SFTP server
        let server = TestSftpServer::start().await;
        let payload = b"download cancel before rename payload";
        server
            .write_remote_file("/download/file.txt", payload)
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("file.txt");
        let total_bytes = payload.len() as u64;

        // When: all bytes are transferred and cancel is requested before rename
        let cancel = Arc::new(AtomicBool::new(false));
        let cancel_flag = Arc::clone(&cancel);
        let err = client
            .download_cancellable(
                "/download/file.txt",
                &local_path,
                16,
                move || cancel_flag.load(Ordering::Relaxed),
                {
                    let cancel_flag = Arc::clone(&cancel);
                    move |transferred| {
                        if transferred >= total_bytes {
                            cancel_flag.store(true, Ordering::Relaxed);
                        }
                    }
                },
            )
            .await
            .unwrap_err();

        // Then: transfer is cancelled and no final or partial local file remains
        assert!(matches!(err, SftpError::Cancelled));
        assert!(
            !local_path.exists(),
            "final local file must not exist after cancel-before-rename"
        );
        assert!(
            list_partial_paths(local_dir.path()).is_empty(),
            "partial local files must be cleaned up: {:?}",
            list_partial_paths(local_dir.path())
        );
    }
}
