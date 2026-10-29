use std::collections::HashSet;
#[cfg(any(target_os = "linux", target_os = "macos"))]
use std::ffi::CString;
#[cfg(any(target_os = "linux", target_os = "macos"))]
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;
use std::{future::Future, io};

use rand::TryRng;
use russh_sftp::client::error::Error as SftpClientError;
use russh_sftp::client::fs::File as RemoteFileHandle;
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::{FileAttributes, OpenFlags};
use tokio::io::{AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::config::{
    clamp_transfer_chunk_size, clamp_transfer_download_pipeline_depth, DirectoryWalkLimits,
    DEFAULT_TRANSFER_CHUNK_SIZE_BYTES, DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH,
};
use crate::error::{RemoteStatusCode, SftpError};
use crate::ssh::connection_health::is_connection_lost_message;
use crate::ssh::session::SshSession;
use crate::transfer::TransferOverwritePolicy;

use super::path::parent_remote_path;
use super::tree::{
    ensure_local_path_within_root, is_local_directory, join_remote_path, local_directories,
    local_entry_name, normalize_remote_path, remote_directories, validated_remote_entry,
    walk_local_directory_with_options, walk_remote_directory_with_limits, RemoteFileEntry,
    WalkLocalDirectoryOptions,
};

/// Metadata for a remote file or directory entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteFile {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub modified_at_secs: Option<u64>,
    /// POSIX permission bits (e.g. `0o755`) when the server reports them.
    pub permissions: Option<u32>,
    /// Numeric owner id when reported by the server.
    pub uid: Option<u32>,
    /// Numeric group id when reported by the server.
    pub gid: Option<u32>,
    /// Resolved symlink target for a single-entry `lstat`; `None` for listings
    /// (resolving every link would require one extra round-trip per entry).
    pub symlink_target: Option<String>,
    /// Whether the symlink target resolves to a directory (only meaningful
    /// when `symlink_target` is set).
    pub symlink_target_is_dir: Option<bool>,
}

/// High-level SFTP client built on top of an SSH session.
pub struct SftpClient<'a> {
    session: &'a SshSession,
    directory_walk_limits: DirectoryWalkLimits,
    /// Per-request timeout applied to upload WRITE acks and shutdown when the
    /// underlying session timeout is unavailable. Tests can shorten it.
    upload_request_timeout: Duration,
}

impl<'a> SftpClient<'a> {
    /// Creates a new SFTP client for the given SSH session.
    pub fn new(session: &'a SshSession) -> Self {
        Self {
            session,
            directory_walk_limits: DirectoryWalkLimits::default(),
            upload_request_timeout: UPLOAD_REQUEST_TIMEOUT,
        }
    }

    /// Sets resource limits applied during recursive directory walks.
    pub fn with_directory_walk_limits(mut self, limits: DirectoryWalkLimits) -> Self {
        self.directory_walk_limits = limits;
        self
    }

    /// Overrides the per-request timeout applied to upload WRITE acks and
    /// shutdown. Primarily for tests that inject a hung server.
    #[cfg(test)]
    pub(crate) fn with_upload_request_timeout(mut self, timeout: Duration) -> Self {
        self.upload_request_timeout = timeout;
        self
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

    /// Returns whether the remote path refers to a directory.
    pub(crate) async fn remote_is_directory(&self, path: &str) -> Result<bool, SftpError> {
        let path = normalize_remote_path(path)?;
        let metadata = self
            .sftp()
            .metadata(&path)
            .await
            .map_err(|err| SftpError::ListFailed {
                path: path.clone(),
                message: err.to_string(),
            })?;
        Ok(metadata.file_type().is_dir())
    }

    /// Reports whether `path` exists remotely and, when it does, whether it is
    /// a directory.
    ///
    /// Returns `Ok(None)` when the path does not exist (`SSH_FX_NO_SUCH_FILE`);
    /// `Ok(Some(true))` for a directory; `Ok(Some(false))` for a regular file
    /// / symlink / other type. Any other stat failure is surfaced as an error.
    pub async fn remote_path_kind(&self, path: &str) -> Result<Option<bool>, SftpError> {
        let path = normalize_remote_path(path)?;
        match self.sftp().metadata(&path).await {
            Ok(metadata) => Ok(Some(metadata.file_type().is_dir())),
            Err(err) if is_remote_no_such_file_error(&err) => Ok(None),
            Err(err) => Err(SftpError::ListFailed {
                path: path.clone(),
                message: err.to_string(),
            }),
        }
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
            let file_type = metadata.file_type();
            files.push(RemoteFile {
                name: name.clone(),
                path: validated_path,
                is_directory: file_type.is_dir(),
                is_symlink: file_type.is_symlink(),
                size: metadata.size.unwrap_or(0),
                modified_at_secs: metadata.mtime.map(|mtime| mtime as u64),
                permissions: metadata.permissions.map(|mode| mode & 0o7777),
                uid: metadata.uid,
                gid: metadata.gid,
                symlink_target: None,
                symlink_target_is_dir: None,
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
                .map_err(|err| SftpError::StatFailed {
                    path: remote_path.clone(),
                    message: err.to_string(),
                })?;
        Ok(metadata.size.unwrap_or(0))
    }

    /// Returns metadata for a single remote path.
    ///
    /// When `follow_symlinks` is `false`, symlinks are reported as symlinks and
    /// their target is resolved via `read_link` (when available). When `true`,
    /// the target entry's metadata is returned instead.
    pub async fn stat(
        &self,
        remote_path: &str,
        follow_symlinks: bool,
    ) -> Result<RemoteFile, SftpError> {
        let path = normalize_remote_path(remote_path)?;
        let metadata = if follow_symlinks {
            self.sftp()
                .metadata(&path)
                .await
                .map_err(|err| SftpError::StatFailed {
                    path: path.clone(),
                    message: err.to_string(),
                })?
        } else {
            self.sftp()
                .symlink_metadata(&path)
                .await
                .map_err(|err| SftpError::StatFailed {
                    path: path.clone(),
                    message: err.to_string(),
                })?
        };
        let file_type = metadata.file_type();
        let name = path
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .filter(|n| !n.is_empty())
            .unwrap_or(path.as_str())
            .to_string();

        let mut symlink_target = None;
        let mut symlink_target_is_dir = None;
        if file_type.is_symlink() {
            if let Ok(target) = self.sftp().read_link(&path).await {
                symlink_target = Some(target.clone());
                // A relative READLINK target refers to the link's parent
                // directory, not the session's current directory; join it with
                // the parent before stat'ing so symlink_target_is_dir is correct.
                let link_parent = path
                    .rsplit_once('/')
                    .map(|(parent, _)| parent)
                    .filter(|parent| !parent.is_empty())
                    .unwrap_or("/");
                let target_path = if target.starts_with('/') {
                    target.clone()
                } else {
                    format!("{}/{}", link_parent.trim_end_matches('/'), target)
                };
                symlink_target_is_dir = self
                    .sftp()
                    .metadata(&target_path)
                    .await
                    .ok()
                    .map(|target_meta| target_meta.file_type().is_dir());
            }
        }

        Ok(RemoteFile {
            name,
            path,
            is_directory: file_type.is_dir(),
            is_symlink: file_type.is_symlink(),
            size: metadata.size.unwrap_or(0),
            modified_at_secs: metadata.mtime.map(|mtime| mtime as u64),
            permissions: metadata.permissions.map(|mode| mode & 0o7777),
            uid: metadata.uid,
            gid: metadata.gid,
            symlink_target,
            symlink_target_is_dir,
        })
    }

    /// Resolves the target of a remote symlink (SFTP READLINK).
    pub async fn read_link(&self, remote_path: &str) -> Result<String, SftpError> {
        let path = normalize_remote_path(remote_path)?;
        self.sftp()
            .read_link(&path)
            .await
            .map_err(|err| SftpError::StatFailed {
                path: path.clone(),
                message: err.to_string(),
            })
    }

    /// Sets POSIX permission mode bits (e.g. `0o755`) on a remote entry.
    pub async fn set_permissions(&self, remote_path: &str, mode: u32) -> Result<(), SftpError> {
        let path = normalize_remote_path(remote_path)?;
        let mut attrs = FileAttributes::empty();
        attrs.permissions = Some(mode);
        self.sftp().set_metadata(&path, attrs).await.map_err(|err| {
            SftpError::Other(anyhow::anyhow!(
                "failed to set permissions on '{path}': {err}"
            ))
        })
    }

    /// Applies the supplied SFTP attributes to a remote entry via SETSTAT.
    pub async fn set_metadata(
        &self,
        remote_path: &str,
        attrs: FileAttributes,
    ) -> Result<(), SftpError> {
        let path = normalize_remote_path(remote_path)?;
        self.sftp().set_metadata(&path, attrs).await.map_err(|err| {
            SftpError::Other(anyhow::anyhow!("failed to set metadata on '{path}': {err}"))
        })
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

        // `metadata` follows symlinks, matching `File::open`: when a symlink is
        // uploaded, preserve the metadata of the file whose bytes are read.
        let local_metadata = match tokio::fs::metadata(local_path).await {
            Ok(metadata) => Some(metadata),
            Err(err) => {
                tracing::warn!(
                    local = %local_path.display(),
                    error = %err,
                    "failed to read source metadata before upload"
                );
                None
            }
        };

        // Reuse a leftover deterministic partial from a previous attempt so an
        // interrupted upload continues instead of restarting from zero
        // (issue #313). Cancellation deletes its partial, so cancelled tasks
        // never resume.
        let local_size = local_metadata.as_ref().map(|metadata| metadata.len());
        let resume_offset = match local_size {
            Some(size) => {
                self.find_resumable_upload_offset(size, &parent, &local, &remote)
                    .await?
            }
            None => None,
        };
        let mut partial = match resume_offset {
            Some(offset) => {
                let partial_path = join_remote_path(
                    &parent,
                    Path::new(&partial_file_name(&resume_partial_suffix(&local, &remote))),
                )?;
                use tokio::io::AsyncSeekExt;
                local_file
                    .seek(std::io::SeekFrom::Start(offset))
                    .await
                    .map_err(|err| SftpError::UploadFailed {
                        local: local.clone(),
                        remote: remote.clone(),
                        message: format!("failed to seek source file for resume: {err}"),
                    })?;
                match PartialRemoteTransfer::begin_resume(
                    self,
                    partial_path,
                    offset,
                    &local,
                    &remote,
                    overwrite_policy,
                )
                .await?
                {
                    Some(partial) => partial,
                    None => {
                        local_file
                            .seek(std::io::SeekFrom::Start(0))
                            .await
                            .map_err(|err| SftpError::UploadFailed {
                                local: local.clone(),
                                remote: remote.clone(),
                                message: format!("failed to seek source file to start: {err}"),
                            })?;
                        PartialRemoteTransfer::begin(
                            self,
                            &parent,
                            &local,
                            &remote,
                            overwrite_policy,
                        )
                        .await?
                    }
                }
            }
            None => {
                PartialRemoteTransfer::begin(self, &parent, &local, &remote, overwrite_policy)
                    .await?
            }
        };
        let base_offset = if partial.keep_on_error {
            resume_offset.unwrap_or(0)
        } else {
            0
        };

        upload_from_reader(
            &mut local_file,
            &mut partial,
            chunk_size,
            &is_cancelled,
            &mut |progress| on_progress(base_offset + progress),
            &local,
            &remote,
        )
        .await?;

        if is_cancelled() {
            partial.abort(true).await?;
            return Err(SftpError::Cancelled);
        }

        partial.finalize_rename(&remote_path, local_metadata).await
    }

    /// Returns the byte offset to continue a previous attempt from, when a
    /// leftover partial for this `(local, remote)` pair exists, is a strict
    /// prefix of the source file, AND all its bytes match the current local
    /// content (issue #313, #750). `Ok(None)` starts from scratch.
    ///
    /// A partial that is empty, at least as large as the source, or missing is
    /// not a resumable state: the transfer either never started or the source
    /// changed underneath it, and both are safest to redo from zero.
    async fn find_resumable_upload_offset(
        &self,
        local_size: u64,
        parent: &str,
        local: &str,
        remote: &str,
    ) -> Result<Option<u64>, SftpError> {
        let partial_path = join_remote_path(
            parent,
            Path::new(&partial_file_name(&resume_partial_suffix(local, remote))),
        )?;
        let Ok(metadata) = self.sftp().metadata(&partial_path).await else {
            return Ok(None);
        };
        let Some(size) = metadata.size else {
            return Ok(None);
        };
        if size == 0 || size >= local_size {
            return Ok(None);
        }
        // Verify through independent handles so a rejected partial cannot
        // advance the source handle used by the actual upload.
        let Ok(mut partial_file) = self.sftp().open(&partial_path).await else {
            return Ok(None);
        };
        let Ok(mut verification_file) = tokio::fs::File::open(local).await else {
            return Ok(None);
        };
        let mut partial_prefix = vec![0u8; RESUME_VERIFICATION_BYTES as usize];
        let mut local_prefix = vec![0u8; RESUME_VERIFICATION_BYTES as usize];
        let mut remaining = size;
        use tokio::io::AsyncReadExt;
        while remaining > 0 {
            let verify_len = remaining.min(RESUME_VERIFICATION_BYTES) as usize;
            if partial_file
                .read_exact(&mut partial_prefix[..verify_len])
                .await
                .is_err()
                || verification_file
                    .read_exact(&mut local_prefix[..verify_len])
                    .await
                    .is_err()
                || partial_prefix[..verify_len] != local_prefix[..verify_len]
            {
                drop(partial_file);
                let _ = self.delete(&partial_path).await;
                return Ok(None);
            }
            remaining -= verify_len as u64;
        }
        Ok(Some(size))
    }

    /// Downloads a remote file to a local path.
    pub async fn download(&self, remote_path: &str, local_path: &Path) -> Result<(), SftpError> {
        self.download_cancellable(
            remote_path,
            local_path,
            default_chunk_size(),
            DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH,
            TransferOverwritePolicy::default(),
            || false,
            |_| {},
        )
        .await
    }

    /// Downloads a remote file using concurrent pipelined READ requests,
    /// checking `is_cancelled` between chunks.
    ///
    /// `pipeline_depth` is the caller's preferred concurrency. Actual in-flight
    /// READs are scaled with [`pipeline_depth_for_chunk_budget`] so peak memory
    /// stays near `pipeline_depth × chunk_size` (the library sizes each READ
    /// from the SFTP packet ceiling, typically ~256 KiB).
    ///
    /// Progress callbacks report bytes successfully written to the local
    /// partial file (not speculative in-flight READ payloads).
    #[allow(clippy::too_many_arguments)]
    pub async fn download_cancellable(
        &self,
        remote_path: &str,
        local_path: &Path,
        chunk_size: usize,
        pipeline_depth: usize,
        overwrite_policy: TransferOverwritePolicy,
        is_cancelled: impl Fn() -> bool + Send,
        mut on_progress: impl FnMut(u64) + Send,
    ) -> Result<(), SftpError> {
        let remote_path = normalize_remote_path(remote_path)?;
        let remote = remote_path.clone();
        let local = local_path.display().to_string();
        let pipeline_depth = pipeline_depth_for_chunk_budget(pipeline_depth, chunk_size);

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
        // Read metadata from the same handle as the content, even if another
        // process replaces the remote pathname after open.
        let remote_metadata = match remote_file.metadata().await {
            Ok(metadata) => Some(metadata),
            Err(err) => {
                tracing::warn!(
                    remote = %remote_path,
                    error = %err,
                    "failed to read source metadata before download"
                );
                None
            }
        };
        let mut partial = {
            // Reuse a leftover deterministic local partial from a previous
            // attempt so an interrupted download continues instead of
            // restarting from zero (issue #313).
            let remote_size = remote_metadata.as_ref().and_then(|metadata| metadata.size);
            let resume_offset = match remote_size {
                Some(size) => {
                    let offset = tokio::select! {
                        biased;
                        () = cancel_watch(&is_cancelled) => return Err(SftpError::Cancelled),
                        offset = find_resumable_download_offset(&mut remote_file, local_parent, size, &local, &remote) => offset,
                    };
                    if is_cancelled() {
                        return Err(SftpError::Cancelled);
                    }
                    offset
                }
                None => None,
            };
            // Verification consumes this handle. Explicitly position both
            // the successful resume and restart paths before copying bytes.
            use tokio::io::AsyncSeekExt;
            remote_file
                .seek(std::io::SeekFrom::Start(resume_offset.unwrap_or(0)))
                .await
                .map_err(|err| SftpError::DownloadFailed {
                    remote: remote.clone(),
                    local: local.clone(),
                    message: format!("failed to seek remote file to the download offset: {err}"),
                })?;
            match resume_offset {
                Some(_) => {
                    PartialLocalTransfer::begin_resume(
                        local_parent,
                        &remote,
                        &local,
                        overwrite_policy,
                        remote_metadata,
                    )
                    .await?
                }
                None => {
                    PartialLocalTransfer::begin(
                        local_parent,
                        &remote,
                        &local,
                        overwrite_policy,
                        remote_metadata,
                    )
                    .await?
                }
            }
        };

        let writer_file =
            partial
                .clone_file_for_write()
                .await
                .map_err(|err| SftpError::DownloadFailed {
                    remote: remote.clone(),
                    local: local.clone(),
                    message: err.to_string(),
                })?;

        let mut writer =
            PipelinableTransferWriter::new(writer_file, &is_cancelled, &mut on_progress);
        let result =
            download_pipelined_to_writer(&mut remote_file, &mut writer, pipeline_depth).await;

        // Drop the writer (and its cloned file handle / any pending write)
        // before rename or abort so cleanup does not race with an open clone.
        drop(writer);

        if let Err(err) = result {
            // Best-effort remote close + local partial delete. `abort(false)`
            // never fails hard on remote shutdown (already closed handles are
            // logged and ignored) so cleanup of the local partial can proceed.
            // A cleanup failure must not mask the original transfer error
            // (issue #792); record it and keep the original `err` as primary.
            let cleanup_err = match partial.abort(false, &mut remote_file).await {
                Ok(note) => note,
                Err(e) => Some(e),
            };
            return Err(match err {
                DownloadFlowError::Cancelled => SftpError::Cancelled,
                DownloadFlowError::Write(message) => SftpError::DownloadFailed {
                    remote: remote.clone(),
                    local: local.clone(),
                    message: append_cleanup_context(message, cleanup_err),
                },
            });
        }

        if is_cancelled() {
            if let Err(err) = partial.abort(true, &mut remote_file).await {
                tracing::warn!(
                    remote = %remote,
                    local = %local,
                    error = %err,
                    "failed to clean up the local partial after cancellation"
                );
            }
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

    /// Deletes a remote entry, optionally recursing into directories.
    ///
    /// Symlinks are removed as links (their targets are never followed).
    /// When `recursive` is `false`, a non-empty directory fails with
    /// [`SftpError::DirectoryNotEmpty`]. When `recursive` is `true`, children
    /// are removed depth-first (files first, directories last), respecting the
    /// configured [`DirectoryWalkLimits`] (depth / file count / byte budget).
    ///
    /// Returns the total number of entries removed. On a limit or I/O error the
    /// previously removed entries stay removed, but the count is not returned;
    /// callers that need partial counts should scan before deleting.
    pub async fn delete_entry(
        &self,
        remote_path: &str,
        recursive: bool,
    ) -> Result<usize, SftpError> {
        let remote_path = normalize_remote_path(remote_path)?;
        if remote_path == "/" {
            return Err(SftpError::InvalidRemotePath { path: remote_path });
        }

        // Recursive post-order deletion without async recursion: keep a stack
        // of directories whose children still need visiting. Each child is
        // classified via symlink_metadata (lstat), so symlinks are deleted as
        // links and never descended.
        // Owned paths so the stack keeps references valid while we await.
        enum Task {
            VisitDir(String, u32),
            RemoveDir(String),
        }

        let mut count = 0usize;
        let mut deleted_files = 0u64;
        let mut deleted_bytes = 0u64;
        let mut stack = vec![Task::VisitDir(remote_path, 0)];

        while let Some(task) = stack.pop() {
            match task {
                Task::VisitDir(path, depth) => {
                    let path = path.as_str();
                    if depth > self.directory_walk_limits.max_depth {
                        return Err(SftpError::DirectoryWalkLimitExceeded {
                            limit: "max_depth".to_string(),
                            value: depth as u64,
                            path: path.to_string(),
                        });
                    }

                    let metadata = self.sftp().symlink_metadata(path).await.map_err(|err| {
                        SftpError::DeleteFailed {
                            path: path.to_string(),
                            message: err.to_string(),
                        }
                    })?;
                    let file_type = metadata.file_type();

                    // Files, symlinks and special files: remove directly.
                    if !file_type.is_dir() {
                        if deleted_files >= self.directory_walk_limits.max_files {
                            return Err(SftpError::DirectoryWalkLimitExceeded {
                                limit: "max_files".to_string(),
                                value: deleted_files,
                                path: path.to_string(),
                            });
                        }
                        let size = metadata.size.unwrap_or(0);
                        if deleted_bytes.saturating_add(size)
                            > self.directory_walk_limits.max_total_bytes
                        {
                            return Err(SftpError::DirectoryWalkLimitExceeded {
                                limit: "max_total_bytes".to_string(),
                                value: deleted_bytes.saturating_add(size),
                                path: path.to_string(),
                            });
                        }
                        self.sftp().remove_file(path).await.map_err(|err| {
                            SftpError::DeleteFailed {
                                path: path.to_string(),
                                message: err.to_string(),
                            }
                        })?;
                        count += 1;
                        deleted_files += 1;
                        deleted_bytes += size;
                        continue;
                    }

                    if !recursive {
                        let entries = self.list_directory(path).await?;
                        if !entries.is_empty() {
                            return Err(SftpError::DirectoryNotEmpty {
                                path: path.to_string(),
                            });
                        }
                        self.sftp().remove_dir(path).await.map_err(|err| {
                            SftpError::DeleteFailed {
                                path: path.to_string(),
                                message: err.to_string(),
                            }
                        })?;
                        count += 1;
                        continue;
                    }

                    let entries = self.list_directory(path).await?;
                    // First remove this dir after its children are removed.
                    stack.push(Task::RemoveDir(path.to_string()));
                    for entry in entries {
                        stack.push(Task::VisitDir(entry.path, depth + 1));
                    }
                }
                Task::RemoveDir(path) => {
                    let path = path.as_str();
                    self.sftp()
                        .remove_dir(path)
                        .await
                        .map_err(|err| SftpError::DeleteFailed {
                            path: path.to_string(),
                            message: err.to_string(),
                        })?;
                    count += 1;
                }
            }
        }

        Ok(count)
    }

    /// Renames a remote file or directory, replacing an existing destination
    /// atomically when the server supports `posix-rename@openssh.com`.
    /// Servers without the extension fall back to a plain SSH_FXP_RENAME
    /// (POSIX-style servers replace the destination; OpenSSH-style ones
    /// refuse and surface the server error).
    pub async fn rename(&self, from: &str, to: &str) -> Result<(), SftpError> {
        let from = normalize_remote_path(from)?;
        let to = normalize_remote_path(to)?;
        let replaced =
            self.sftp()
                .posix_rename(&from, &to)
                .await
                .map_err(|err| SftpError::RenameFailed {
                    from: from.clone(),
                    to: to.clone(),
                    message: err.to_string(),
                })?;
        if replaced {
            return Ok(());
        }
        self.sftp()
            .rename(&from, &to)
            .await
            .map_err(|err| SftpError::RenameFailed {
                from,
                to,
                message: err.to_string(),
            })
    }

    /// Renames `from` to `to`, atomically replacing an existing destination
    /// via the `posix-rename@openssh.com` extension. Returns `Ok(false)` when
    /// the server does not advertise the extension.
    pub async fn posix_rename(&self, from: &str, to: &str) -> Result<bool, SftpError> {
        let from = normalize_remote_path(from)?;
        let to = normalize_remote_path(to)?;
        self.sftp()
            .posix_rename(&from, &to)
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
        self.create_directory_all_cached(remote_path, &mut None)
            .await
    }

    /// Creates a remote directory (and missing parents), skipping segments
    /// already present in `created_cache` (a cache of paths known to exist).
    ///
    /// Starts from the given path's parent chain (not from "/"), so repeated
    /// calls for many files under the same root cost O(depth) per call instead
    /// of O(depth × segments) round trips from "/".
    pub async fn create_directory_all_cached(
        &self,
        remote_path: &str,
        created_cache: &mut Option<HashSet<String>>,
    ) -> Result<(), SftpError> {
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
            let next = join_remote_path(&current, Path::new(segment))?;

            if let Some(created) = created_cache.as_ref() {
                if created.contains(&next) {
                    current = next;
                    continue;
                }
            }

            if let Err(SftpError::MkdirFailed { path, message }) =
                self.create_directory(&next).await
            {
                // A generic SSH_FX_FAILURE may mean anything (permission denied,
                // disk full, etc.). Only treat it as "already exists" when the
                // path can be stat'd and is actually a directory.
                match self.sftp().metadata(&next).await {
                    Ok(metadata) if metadata.file_type().is_dir() => {}
                    Ok(_) | Err(_) => {
                        return Err(SftpError::MkdirFailed { path, message });
                    }
                }
            }
            if let Some(created) = created_cache.as_mut() {
                created.insert(next.clone());
            }
            current = next;
        }

        Ok(())
    }

    /// Uploads a local file or directory tree into a remote directory.
    pub async fn upload_entry(
        &self,
        local_path: &Path,
        remote_directory: &str,
    ) -> Result<(), SftpError> {
        let mut created = None;
        self.upload_entries(local_path, remote_directory, &mut created, &mut |_| {})
            .await
    }

    /// Uploads a local file or directory tree into a remote directory,
    /// creating directories once (cached) and reporting each completed file
    /// through `on_file_completed` (remote path per file).
    pub(crate) async fn upload_entries(
        &self,
        local_path: &Path,
        remote_directory: &str,
        created: &mut Option<HashSet<String>>,
        on_file_completed: &mut (dyn FnMut(&str) + Send),
    ) -> Result<(), SftpError> {
        if is_local_directory(local_path).await? {
            let directory_name = local_entry_name(local_path);
            let remote_root = join_remote_path(remote_directory, Path::new(&directory_name))?;
            // Create the whole remote directory tree exactly once (parents
            // first), including EMPTY directories, before uploading any files
            // — no per-file `create_directory_all` from "/" (issue #312).
            if created.is_none() {
                *created = Some(HashSet::new());
            }
            self.create_directory_all_cached(&remote_root, created)
                .await?;
            for relative_dir in local_directories(
                local_path,
                WalkLocalDirectoryOptions {
                    limits: self.directory_walk_limits,
                    ..Default::default()
                },
            )
            .await?
            {
                let remote_dir = join_remote_path(&remote_root, &relative_dir)?;
                self.create_directory_all_cached(&remote_dir, created)
                    .await?;
            }

            let result = walk_local_directory_with_options(
                local_path,
                WalkLocalDirectoryOptions {
                    limits: self.directory_walk_limits,
                    ..Default::default()
                },
            )
            .await?;
            for entry in result.files {
                let remote_path = join_remote_path(&remote_root, &entry.relative_path)?;
                self.upload(&entry.local_path, &remote_path).await?;
                on_file_completed(&remote_path);
            }
            if !result.skipped.is_empty() {
                tracing::warn!(
                    skipped = ?result.skipped,
                    "local directory walk skipped unreadable entries"
                );
            }
            return Ok(());
        }

        let remote_path =
            join_remote_path(remote_directory, Path::new(&local_entry_name(local_path)))?;
        if let Some(parent) = parent_remote_path(&remote_path)? {
            self.create_directory_all_cached(&parent, created).await?;
        }
        self.upload(local_path, &remote_path).await?;
        on_file_completed(&remote_path);
        Ok(())
    }

    /// Downloads a remote file or directory tree into a local directory,
    /// creating local directories once per batch. Mirrors empty directories.
    ///
    /// Reports each remote entry via `on_entry` before its transfer runs so
    /// the caller (e.g. the transfer manager) can enqueue a Pending task.
    pub async fn download_entries<F>(
        &self,
        remote_path: &str,
        local_directory: &Path,
        mut on_entry: F,
    ) -> Result<(), SftpError>
    where
        F: FnMut(RemoteFileEntry) + Send,
    {
        let normalized = normalize_remote_path(remote_path)?;
        if self.remote_is_directory(&normalized).await? {
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

            // Mirror the remote directory structure once (parents first),
            // including EMPTY directories, before downloading any files.
            let mut created_dirs = HashSet::new();
            created_dirs.insert(local_root.clone());
            for relative_dir in
                remote_directories(self, &normalized, self.directory_walk_limits).await?
            {
                let local_dir = local_root.join(&relative_dir);
                ensure_local_path_within_root(&local_root, &local_dir).await?;
                tokio::fs::create_dir_all(&local_dir).await.map_err(|err| {
                    SftpError::DownloadFailed {
                        remote: normalized.clone(),
                        local: local_dir.display().to_string(),
                        message: err.to_string(),
                    }
                })?;
                created_dirs.insert(local_dir);
            }

            let result =
                walk_remote_directory_with_limits(self, &normalized, self.directory_walk_limits)
                    .await?;

            for entry in result.files {
                let local_path = local_root.join(&entry.relative_path);
                ensure_local_path_within_root(&local_root, &local_path).await?;
                if let Some(parent) = local_path.parent() {
                    let mut ancestor = parent.to_path_buf();
                    while !created_dirs.contains(&ancestor) {
                        created_dirs.insert(ancestor.clone());
                        tokio::fs::create_dir_all(&ancestor).await.map_err(|err| {
                            SftpError::DownloadFailed {
                                remote: entry.remote_path.clone(),
                                local: ancestor.display().to_string(),
                                message: err.to_string(),
                            }
                        })?;
                        // Stop at the filesystem root ("/"); parent() is None
                        // there, and treating it as an empty PathBuf would
                        // otherwise call create_dir_all("") forever.
                        match ancestor.parent() {
                            Some(next) if !next.as_os_str().is_empty() => {
                                ancestor = next.to_path_buf()
                            }
                            _ => break,
                        }
                    }
                }

                on_entry(RemoteFileEntry {
                    remote_path: entry.remote_path.clone(),
                    relative_path: entry.relative_path.clone(),
                });
                self.download(&entry.remote_path, &local_path).await?;
            }
            if !result.skipped.is_empty() {
                tracing::warn!(
                    skipped = ?result.skipped,
                    "remote directory walk skipped unreadable entries"
                );
            }
            Ok(())
        } else {
            let file_name = normalized
                .rsplit('/')
                .next()
                .filter(|name| !name.is_empty())
                .unwrap_or("download");
            let local_path = local_directory.join(file_name);
            on_entry(RemoteFileEntry {
                remote_path: normalized.clone(),
                relative_path: PathBuf::from(&file_name),
            });
            self.download(&normalized, &local_path).await
        }
    }

    /// Downloads a remote file or directory tree into a local directory
    /// (legacy wrapper delegating to [`Self::download_entries`]).
    pub async fn download_entry(
        &self,
        remote_path: &str,
        local_directory: &Path,
    ) -> Result<(), SftpError> {
        self.download_entries(remote_path, local_directory, |_| {})
            .await
    }
}

fn default_chunk_size() -> usize {
    DEFAULT_TRANSFER_CHUNK_SIZE_BYTES
}

fn append_cleanup_context(original: impl Into<String>, cleanup: Option<SftpError>) -> String {
    let original = original.into();
    match cleanup {
        Some(cleanup) => format!("{original} (partial cleanup failed: {cleanup})"),
        None => original,
    }
}

async fn upload_from_reader(
    reader: &mut (impl AsyncReadExt + Unpin),
    partial: &mut PartialRemoteTransfer<'_>,
    chunk_size: usize,
    is_cancelled: &impl Fn() -> bool,
    on_progress: &mut impl FnMut(u64),
    local: &str,
    remote: &str,
) -> Result<(), SftpError> {
    let mut buffer = vec![0_u8; chunk_size];
    let mut transferred = 0_u64;
    let mut reported = 0_u64;
    // `File::write_all` queues at most `depth` packets. Subtracting the
    // maximum possible queued bytes gives a conservative lower bound for
    // acknowledged bytes without relying on unexposed ACK-ring internals.
    let max_unacknowledged = (partial.client.session.upload_pipeline_depth() as u64)
        .saturating_mul(DEFAULT_TRANSFER_CHUNK_SIZE_BYTES as u64);
    loop {
        if is_cancelled() {
            partial.abort(true).await?;
            return Err(SftpError::Cancelled);
        }

        let bytes_read = match reader.read(&mut buffer).await {
            Ok(bytes_read) => bytes_read,
            Err(err) => {
                let cleanup_err = partial.abort(false).await?;
                return Err(SftpError::UploadFailed {
                    local: local.to_string(),
                    remote: remote.to_string(),
                    message: append_cleanup_context(err.to_string(), cleanup_err),
                });
            }
        };
        if bytes_read == 0 {
            break;
        }

        // `File::write_all` uses the SFTP session's configured write-ACK ring,
        // so successive chunks are pipelined up to
        // `transfer_upload_pipeline_depth`. Keep the timeout/cancellation race
        // around every chunk to preserve the existing stalled-server behavior.
        enum WriteFailure {
            Timeout,
            Io(io::Error),
        }
        let request_timeout = partial.client_timeout();
        let write_outcome = tokio::time::timeout(
            request_timeout,
            partial.remote_file_mut()?.write_all(&buffer[..bytes_read]),
        );
        tokio::pin!(write_outcome);

        let result = tokio::select! {
            biased;
            () = cancel_watch(is_cancelled) => {
                let _ = partial.abort(false).await;
                return Err(SftpError::Cancelled);
            }
            timed_write = &mut write_outcome => match timed_write {
                Ok(write_result) => write_result.map_err(WriteFailure::Io),
                Err(_) => Err(WriteFailure::Timeout),
            },
        };
        // A cancellation racing the request timeout must still be classified
        // as Cancelled (issue #654).
        if is_cancelled() {
            let _ = partial.abort(false).await;
            return Err(SftpError::Cancelled);
        }
        if let Err(failure) = result {
            match failure {
                WriteFailure::Timeout => {
                    // The server may still have applied some of the in-flight
                    // bytes: keep the partial so a later attempt can resume
                    // instead of restarting (issue #313).
                    partial.mark_keep_on_error();
                    let _ = partial.abort(false).await;
                    return Err(SftpError::UploadFailed {
                        local: local.to_string(),
                        remote: remote.to_string(),
                        message: format!(
                            "timed out after {request_timeout:?} waiting for the server to acknowledge a remote write"
                        ),
                    });
                }
                WriteFailure::Io(err) => {
                    let cleanup_err = partial.abort(false).await?;
                    return Err(SftpError::UploadFailed {
                        local: local.to_string(),
                        remote: remote.to_string(),
                        message: append_cleanup_context(err.to_string(), cleanup_err),
                    });
                }
            }
        }
        transferred += bytes_read as u64;
        let acknowledged = transferred.saturating_sub(max_unacknowledged);
        if acknowledged > reported {
            reported = acknowledged;
            on_progress(reported);
        }
    }

    if is_cancelled() {
        partial.abort(true).await?;
        return Err(SftpError::Cancelled);
    }

    let shutdown_result = {
        let mut shutdown = Box::pin(partial.shutdown());
        tokio::select! {
            result = &mut shutdown => Some(result),
            () = cancel_watch(is_cancelled) => None,
        }
    };
    let Some(shutdown_result) = shutdown_result else {
        let _ = partial.abort(false).await;
        return Err(SftpError::Cancelled);
    };
    if let Err(err) = shutdown_result {
        let cleanup_err = partial.abort(false).await?;
        return Err(SftpError::UploadFailed {
            local: local.to_string(),
            remote: remote.to_string(),
            message: append_cleanup_context(err.to_string(), cleanup_err),
        });
    }

    // `shutdown` drains every pending WRITE ACK, so the full byte count is
    // exact here. Avoid a duplicate callback when the lower bound caught up.
    if transferred > reported {
        on_progress(transferred);
    }

    Ok(())
}

/// Awaits the transfer's cancellation flag becoming set. Used with
/// [`tokio::select!`] so blocked pipelined SFTP writes can be interrupted
/// promptly (issue #306).
async fn cancel_watch(is_cancelled: &impl Fn() -> bool) {
    loop {
        if is_cancelled() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Error returned when a pipelined download flow fails.
#[derive(Debug)]
enum DownloadFlowError {
    /// The transfer was cancelled by the caller.
    Cancelled,
    /// Writing the downloaded bytes failed locally.
    Write(String),
}

impl DownloadFlowError {
    /// Wraps a local write `io::Error` as `ErrorKind::Other` so cancellation
    /// (tracked on the writer flag, not by kind) cannot be confused with it.
    fn err_from_io(err: io::Error) -> io::Error {
        io::Error::other(DownloadFlowError::Write(err.to_string()).to_string())
    }
}

impl std::fmt::Display for DownloadFlowError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DownloadFlowError::Cancelled => f.write_str("transfer was cancelled"),
            DownloadFlowError::Write(message) => f.write_str(message),
        }
    }
}

/// Bounds a single `write_all` call. macOS caps a single file write below
/// 2 GiB (EINVAL) and other platforms behave differently, so oversized
/// buffers are split into sub-buffer pieces.
const MAX_WRITE_SIZE: usize = 8 * 1024 * 1024; // 8 MiB

/// Result of an in-flight local write: always returns the file handle so the
/// writer can restore it even when the write fails (avoids FD leaks).
type PendingWriteOutput = (tokio::fs::File, io::Result<()>);

/// Scales `pipeline_depth` so peak buffered memory stays near
/// `pipeline_depth × chunk_size`.
///
/// The SFTP crate sizes each READ issued by `read_to_writer_pipelined` from
/// the SFTP packet ceiling (~[`DEFAULT_TRANSFER_CHUNK_SIZE_BYTES`]), not from
/// `chunk_size`. Reducing depth when the caller asks for smaller chunks
/// preserves the intended memory budget.
fn pipeline_depth_for_chunk_budget(pipeline_depth: usize, chunk_size: usize) -> usize {
    let depth = clamp_transfer_download_pipeline_depth(pipeline_depth);
    let chunk = clamp_transfer_chunk_size(chunk_size).max(1);
    let budget = depth.saturating_mul(chunk);
    let assumed_read = DEFAULT_TRANSFER_CHUNK_SIZE_BYTES.max(1);
    let adjusted = (budget / assumed_read).max(1);
    clamp_transfer_download_pipeline_depth(adjusted.min(depth))
}

/// Adapter that presents a cloned local partial file handle as an
/// `AsyncWrite` sink while forwarding progress callbacks and cancellation
/// checks on every written chunk. Used to bridge `read_to_writer_pipelined`
/// (which streams into an `AsyncWrite`) with DockBridge's
/// progress/cancellation plumbing.
///
/// The file handle is taken from the struct while a chunk write is pending
/// and returned once the write completes (success or failure), so the
/// in-flight future does not borrow from the struct itself. `cancelled` is
/// set when this writer rejects a write due to cancellation; the download
/// helper classifies the resulting error from that flag (the SFTP crate
/// collapses `io::Error` into a string-only `Error::IO`, so kinds are not
/// preserved across the boundary).
struct PipelinableTransferWriter<'a, F>
where
    F: Fn() -> bool + Send + 'a,
{
    file: Option<tokio::fs::File>,
    write_pos: u64,
    is_cancelled: &'a F,
    on_progress: &'a mut (dyn FnMut(u64) + Send),
    transferred: u64,
    pending_write: Option<Pin<Box<dyn Future<Output = PendingWriteOutput> + Send + 'a>>>,
    /// Byte length of the in-flight `pending_write`, so `poll_flush` can
    /// advance `write_pos` / progress if it completes the write.
    pending_len: Option<usize>,
    /// Set when this writer surfaces a cancellation error.
    cancelled: bool,
    #[cfg(test)]
    fail_next_write: bool,
}

impl<'a, F> PipelinableTransferWriter<'a, F>
where
    F: Fn() -> bool + Send + 'a,
{
    fn new(
        file: tokio::fs::File,
        is_cancelled: &'a F,
        on_progress: &'a mut (dyn FnMut(u64) + Send),
    ) -> Self {
        Self {
            file: Some(file),
            write_pos: 0,
            is_cancelled,
            on_progress,
            transferred: 0,
            pending_write: None,
            pending_len: None,
            cancelled: false,
            #[cfg(test)]
            fail_next_write: false,
        }
    }

    #[cfg(test)]
    fn with_fail_next_write(mut self) -> Self {
        self.fail_next_write = true;
        self
    }

    fn record_successful_write(&mut self, len: usize) {
        self.write_pos += len as u64;
        self.transferred += len as u64;
        let transferred = self.transferred;
        (self.on_progress)(transferred);
    }

    fn start_pending_write(&mut self, buf: &[u8]) -> Result<(), io::Error> {
        // `file` is guaranteed to be present by the `AsyncWrite` contract:
        // `poll_write` only calls this when idle, and every completed poll
        // restores the handle via `poll_pending`. Still, tolerate a missing
        // handle as an I/O error instead of panicking on an index invariant.
        let mut file = self.file.take().ok_or_else(|| {
            io::Error::other(
                DownloadFlowError::Write(
                    "partial file handle missing before local write".to_string(),
                )
                .to_string(),
            )
        })?;
        let offset = self.write_pos;
        let data = buf.to_vec();
        self.pending_len = Some(buf.len());
        self.pending_write = Some(Box::pin(async move {
            use tokio::io::{AsyncSeekExt, AsyncWriteExt};
            let result = async {
                file.seek(io::SeekFrom::Start(offset)).await?;
                // Split oversized buffers: a single write above ~2 GiB fails on
                // macOS (EINVAL). Pipelined reads stay ≤ ~256 KiB in practice.
                let mut remaining = data.as_slice();
                while !remaining.is_empty() {
                    let n = remaining.len().min(MAX_WRITE_SIZE);
                    file.write_all(&remaining[..n]).await?;
                    remaining = &remaining[n..];
                }
                Ok(())
            }
            .await;
            // Always return the handle so the writer can restore it on error.
            (file, result)
        }));
        Ok(())
    }

    fn poll_pending(
        self: &mut Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<usize, io::Error>> {
        let Some(pending_write) = self.pending_write.as_mut() else {
            return Poll::Ready(Err(io::Error::other(
                DownloadFlowError::Write("pending write not set".to_string()).to_string(),
            )));
        };
        match pending_write.as_mut().poll(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready((file, Ok(()))) => {
                let len = self.pending_len.take().unwrap_or(0);
                self.file = Some(file);
                self.pending_write = None;
                self.record_successful_write(len);
                Poll::Ready(Ok(len))
            }
            Poll::Ready((file, Err(err))) => {
                self.file = Some(file);
                self.pending_write = None;
                self.pending_len = None;
                Poll::Ready(Err(DownloadFlowError::err_from_io(err)))
            }
        }
    }

    /// Marks this writer as cancelled and rejects a *new* write buffer.
    ///
    /// Call only when idle (`pending_write` is `None`). `poll_write` always
    /// drains an in-flight write before calling this, so progress already
    /// reflects bytes on disk. This method never touches `pending_write`.
    fn reject_cancelled(&mut self) -> Poll<Result<usize, io::Error>> {
        self.cancelled = true;
        Poll::Ready(Err(io::Error::other(
            DownloadFlowError::Cancelled.to_string(),
        )))
    }
}

impl<'a, F> AsyncWrite for PipelinableTransferWriter<'a, F>
where
    F: Fn() -> bool + Send + 'a,
{
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        // Drain any in-flight write first. While Pending, we never reach the
        // cancel branch below, so cancel cannot race with a live pending_write.
        if self.pending_write.is_some() {
            // Contract guard: `poll_pending` reports the *pending* buffer's
            // length. A future caller that abandons a `write_all` mid-buffer
            // would get a mismatched count (silent byte loss), so refuse it
            // explicitly instead (issue #321).
            if let Some(expected) = self.pending_len {
                if buf.len() != expected {
                    return Poll::Ready(Err(io::Error::other(format!(
                        "writer returned {} bytes for a {} byte buffer; a pending write was not fully consumed",
                        expected,
                        buf.len()
                    ))));
                }
            }
            return self.poll_pending(cx);
        }

        // Idle: reject new buffers when cancelled (progress already up to date).
        if (self.is_cancelled)() {
            return self.reject_cancelled();
        }

        #[cfg(test)]
        if self.fail_next_write {
            self.fail_next_write = false;
            return Poll::Ready(Err(io::Error::other(
                DownloadFlowError::Write("simulated local write failure".to_string()).to_string(),
            )));
        }

        if let Err(err) = self.start_pending_write(buf) {
            return Poll::Ready(Err(err));
        }
        self.poll_pending(cx)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        if self.pending_write.is_none() {
            return Poll::Ready(Ok(()));
        }
        match self.poll_pending(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(Ok(_)) => Poll::Ready(Ok(())),
            Poll::Ready(Err(err)) => Poll::Ready(Err(err)),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        self.poll_flush(cx)
    }
}

/// Streams the remote file into `writer` using up to `pipeline_depth`
/// concurrent SFTP READ requests (pipelined reads hide per-request
/// round-trip latency). Errors are classified into cancellation vs. write
/// failures for the caller to translate.
async fn download_pipelined_to_writer<'a, F>(
    remote_file: &mut RemoteFileHandle,
    writer: &mut PipelinableTransferWriter<'a, F>,
    pipeline_depth: usize,
) -> Result<(), DownloadFlowError>
where
    F: Fn() -> bool + Send + 'a,
{
    match remote_file
        .read_to_writer_pipelined(writer, pipeline_depth)
        .await
    {
        Ok(_) => Ok(()),
        // Prefer the writer flag: the SFTP crate collapses io::Error kinds
        // into Error::IO(display string), so classification by kind/message
        // across that boundary is unreliable.
        Err(_) if writer.cancelled => Err(DownloadFlowError::Cancelled),
        // Preserve Display text from the SFTP crate (Status / IO / etc.).
        Err(err) => Err(DownloadFlowError::Write(err.to_string())),
    }
}

const PARTIAL_SUFFIX_BYTES: usize = 16;
const MAX_PARTIAL_CREATE_ATTEMPTS: usize = 5;

/// Timeout applied to each SFTP WRITE acknowledgement and to the `shutdown`
/// (drain pending acks) during uploads.
///
/// The fork's `File::write_all` waits for the WRITE ack without a timeout,
/// so a server that stops responding would hang the upload forever. This
/// mirrors the session-level `connection_timeout_secs` applied to other
/// outgoing requests (issue #306).
const UPLOAD_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

fn random_partial_suffix() -> Result<String, SftpError> {
    let mut bytes = [0_u8; PARTIAL_SUFFIX_BYTES];
    rand::rng()
        .try_fill_bytes(&mut bytes)
        .map_err(|err| SftpError::UploadFailed {
            local: String::new(),
            remote: String::new(),
            message: format!("failed to generate random partial suffix: {err}"),
        })?;
    Ok(bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>())
}

/// Deterministic partial suffix derived from the `(local, remote)` pair so an
/// interrupted transfer's partial can be found and continued on a later
/// attempt (issue #313). Stable across processes; truncated SHA-1 hex.
fn resume_partial_suffix(local: &str, remote: &str) -> String {
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(local.as_bytes());
    hasher.update(b"|");
    hasher.update(remote.as_bytes());
    let hex: String = hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    hex[..32].to_string()
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
    /// When `true`, an error path must NOT delete the partial: a later attempt
    /// can resume it (issue #313). Cancellation always deletes.
    keep_on_error: bool,
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
            keep_on_error: false,
        })
    }

    /// Reopens an existing partial left by a previous attempt so the upload
    /// continues at `start_offset` (issue #313). The caller is responsible for
    /// validating the partial against the local file before calling this.
    async fn begin_resume(
        client: &'a SftpClient<'a>,
        partial_path: String,
        start_offset: u64,
        local: &str,
        remote: &str,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<Option<Self>, SftpError> {
        let mut remote_file = match client
            .sftp()
            .open_with_flags(&partial_path, OpenFlags::WRITE)
            .await
        {
            Ok(remote_file) => remote_file,
            Err(_) => {
                // The partial disappeared (or cannot be reopened). Restart
                // from scratch instead of allowing CREATE to synthesize a new
                // partial and seek to an offset that does not exist.
                return Ok(None);
            }
        };
        let actual_size = client
            .sftp()
            .metadata(&partial_path)
            .await
            .ok()
            .and_then(|metadata| metadata.size)
            .unwrap_or(0);
        if actual_size != start_offset {
            // A truncated or otherwise invalid partial would create a sparse
            // hole and corrupt the final file. Remove it and restart cleanly.
            let _ = client.sftp().remove_file(&partial_path).await;
            return Ok(None);
        }
        use tokio::io::AsyncSeekExt;
        remote_file
            .seek(std::io::SeekFrom::Start(start_offset))
            .await
            .map_err(|err| SftpError::UploadFailed {
                local: local.to_string(),
                remote: remote.to_string(),
                message: format!("failed to seek partial to the resume offset: {err}"),
            })?;
        Ok(Some(Self {
            client,
            partial_path,
            remote_file: Some(remote_file),
            committed: false,
            local: local.to_string(),
            remote: remote.to_string(),
            overwrite_policy,
            keep_on_error: true,
        }))
    }

    fn remote_file_mut(&mut self) -> Result<&mut RemoteFileHandle, SftpError> {
        self.remote_file
            .as_mut()
            .ok_or_else(|| SftpError::UploadFailed {
                local: self.local.clone(),
                remote: self.remote.clone(),
                message: "partial remote file handle missing before commit".to_string(),
            })
    }

    /// Marks the partial to survive ordinary error paths so a later attempt
    /// can resume from it (issue #313). Strict aborts (cancellation) still
    /// delete.
    fn mark_keep_on_error(&mut self) {
        self.keep_on_error = true;
    }

    fn client_timeout(&self) -> Duration {
        self.client.upload_request_timeout
    }

    async fn shutdown(&mut self) -> Result<(), SftpError> {
        if let Some(mut remote_file) = self.remote_file.take() {
            let request_timeout = self.client_timeout();
            let local = self.local.clone();
            let remote = self.remote.clone();
            let shutdown = async move {
                remote_file
                    .shutdown()
                    .await
                    .map_err(|err| SftpError::UploadFailed {
                        local,
                        remote,
                        message: err.to_string(),
                    })
            };
            // `File::shutdown` drains pending WRITE acks without a timeout in
            // the fork; a server that never acks would hang forever (issue
            // #306). Bound it like the other SFTP requests.
            match tokio::time::timeout(request_timeout, shutdown).await {
                Ok(result) => result?,
                Err(_) => {
                    return Err(SftpError::UploadFailed {
                        local: self.local.clone(),
                        remote: self.remote.clone(),
                        message: format!(
                            "timed out after {request_timeout:?} waiting for the server to acknowledge the final write (shutdown)"
                        ),
                    });
                }
            }
        }
        Ok(())
    }

    async fn finalize_rename(
        mut self,
        final_path: &str,
        local_metadata: Option<std::fs::Metadata>,
    ) -> Result<(), SftpError> {
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

        // OpenSSH implements regular-file SSH_FXP_RENAME via link()+unlink()
        // and refuses to replace an existing destination, so Replace relies on
        // the `posix-rename@openssh.com` extension for an atomic overwrite.
        // No delete is issued before the rename, so a failing rename can never
        // destroy the original file. When the server lacks the extension, the
        // rename only proceeds while the destination is absent — a
        // delete-then-rename fallback would risk destroying the original and
        // is therefore never issued. On rename failure the fully-transferred
        // partial is *preserved* so the user can recover it; the original
        // final file is untouched.
        let committed: Result<bool, SftpError> = match self.overwrite_policy {
            TransferOverwritePolicy::Replace => {
                match self
                    .client
                    .posix_rename(&self.partial_path, final_path)
                    .await
                {
                    Ok(true) => Ok(true),
                    Ok(false) => match remote_path_exists(self.client, final_path).await {
                        Ok(false) => self
                            .client
                            .rename(&self.partial_path, final_path)
                            .await
                            .map(|_| true),
                        Ok(true) => Ok(false),
                        Err(err) => Err(err),
                    },
                    Err(err) => Err(err),
                }
            }
            TransferOverwritePolicy::FailIfExists => self
                .client
                .rename(&self.partial_path, final_path)
                .await
                .map(|_| true),
        };
        match committed {
            Ok(true) => {
                self.committed = true;
                // Preserve the source file's mtime and permission bits on the
                // remote copy. Failures are logged but do not fail the transfer
                // (metadata is best-effort; scp/rsync expose the same caveat).
                if let Some(metadata) = local_metadata {
                    let mut attrs = FileAttributes::empty();
                    attrs.mtime = metadata.modified().ok().and_then(modified_secs);
                    attrs.atime = attrs.mtime;
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        attrs.permissions = Some(metadata.permissions().mode() & 0o7777);
                    }
                    if let Err(err) = self.client.set_metadata(final_path, attrs).await {
                        tracing::warn!(
                            remote = %final_path,
                            error = %err,
                            "failed to preserve mtime/permissions on uploaded file"
                        );
                    }
                }
                Ok(())
            }
            Ok(false) => {
                let message = format!(
                    "upload was not committed: the source file '{}' still exists and the new file is preserved at '{}': the server does not support the posix-rename@openssh.com extension, so an existing destination cannot be replaced atomically",
                    self.remote,
                    self.partial_path,
                );
                Err(SftpError::UploadFailed {
                    local: self.local.clone(),
                    remote: self.remote.clone(),
                    message,
                })
            }
            Err(err) => {
                let message = format!(
                    "upload was not committed: the source file '{}' still exists and the new file is preserved at '{}': {err}",
                    self.remote,
                    self.partial_path,
                );
                Err(SftpError::UploadFailed {
                    local: self.local.clone(),
                    remote: self.remote.clone(),
                    message,
                })
            }
        }
    }

    async fn abort(&mut self, strict: bool) -> Result<Option<SftpError>, SftpError> {
        if self.committed {
            return Ok(None);
        }

        if let Some(mut remote_file) = self.remote_file.take() {
            let request_timeout = self.client_timeout();
            let close = async move { remote_file.shutdown().await.map_err(|err| err.to_string()) };
            // Bound the close too: a hung WRITE ack would otherwise block the
            // cleanup path forever after a timeout/cancel (issue #306).
            match tokio::time::timeout(request_timeout, close).await {
                Ok(Ok(())) => {}
                Ok(Err(message)) => {
                    tracing::warn!(
                        partial_remote_path = %self.partial_path,
                        error = %message,
                        "failed to close partial remote file during cleanup"
                    );
                }
                Err(_) => {
                    tracing::warn!(
                        partial_remote_path = %self.partial_path,
                        "closing the partial remote file timed out during cleanup"
                    );
                }
            }
        }

        let delete_timeout = self.client_timeout();
        if self.keep_on_error && !strict {
            // A later attempt can continue this partial; keep it on disk for
            // ordinary errors (issue #313). Strict aborts (cancellation) still
            // delete.
            return Ok(None);
        }
        match tokio::time::timeout(delete_timeout, self.client.delete(&self.partial_path)).await {
            Ok(Ok(())) => Ok(None),
            Ok(Err(err)) if !strict => {
                tracing::warn!(
                    partial_remote_path = %self.partial_path,
                    error = %err,
                    "failed to delete partial remote file after transfer error"
                );
                Ok(Some(SftpError::CleanupFailed {
                    path: self.partial_path.clone(),
                    message: err.to_string(),
                }))
            }
            Ok(Err(err)) => Err(SftpError::CleanupFailed {
                path: self.partial_path.clone(),
                message: err.to_string(),
            }),
            Err(_) if !strict => {
                tracing::warn!(
                    partial_remote_path = %self.partial_path,
                    "deleting the partial remote file timed out during cleanup"
                );
                Ok(Some(SftpError::CleanupFailed {
                    path: self.partial_path.clone(),
                    message: format!("deleted timed out after {delete_timeout:?}"),
                }))
            }
            Err(_) => Err(SftpError::CleanupFailed {
                path: self.partial_path.clone(),
                message: format!("delete timed out after {delete_timeout:?}"),
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
    /// Remote mtime/permissions to apply to the local final file, when available.
    remote_metadata: Option<FileAttributes>,
    /// When `true`, an error path must NOT delete the partial: a later attempt
    /// can resume it (issue #313). Cancellation always deletes.
    keep_on_error: bool,
}

impl PartialLocalTransfer {
    async fn begin(
        parent: &Path,
        remote: &str,
        local: &str,
        overwrite_policy: TransferOverwritePolicy,
        remote_metadata: Option<FileAttributes>,
    ) -> Result<Self, SftpError> {
        let (partial_path, local_file) = create_exclusive_local_partial(parent).await?;
        Ok(Self {
            partial_path,
            local_file: Some(local_file),
            committed: false,
            remote: remote.to_string(),
            local: local.to_string(),
            overwrite_policy,
            remote_metadata,
            keep_on_error: false,
        })
    }

    /// Reopens an existing local partial left by a previous attempt so the
    /// download continues where it stopped (issue #313). The caller must
    /// validate the partial against the remote size before calling this.
    async fn begin_resume(
        local_parent: &Path,
        remote: &str,
        local: &str,
        overwrite_policy: TransferOverwritePolicy,
        remote_metadata: Option<FileAttributes>,
    ) -> Result<Self, SftpError> {
        let partial_path =
            partial_local_path_for_suffix(local_parent, &resume_partial_suffix(local, remote));
        let local_file = tokio::fs::OpenOptions::new()
            .append(true)
            .open(&partial_path)
            .await
            .map_err(|err| SftpError::DownloadFailed {
                remote: remote.to_string(),
                local: local.to_string(),
                message: format!("failed to reopen local partial for resume: {err}"),
            })?;
        Ok(Self {
            partial_path,
            local_file: Some(local_file),
            committed: false,
            remote: remote.to_string(),
            local: local.to_string(),
            overwrite_policy,
            remote_metadata,
            keep_on_error: true,
        })
    }

    /// Applies the captured remote mtime (and Unix permission bits) to the
    /// local final file. Failures are logged and do not fail the transfer.
    fn apply_remote_metadata(&self, final_path: &Path) {
        if let Some(metadata) = &self.remote_metadata {
            apply_downloaded_metadata(final_path, metadata);
        }
    }

    /// Clones the underlying file handle for out-of-band streaming writes
    /// (used by the pipelined download adapter). The clone shares the same
    /// OS-level file description, so writes are visible to the original
    /// handle; offsets are managed by the caller.
    async fn clone_file_for_write(&self) -> std::io::Result<tokio::fs::File> {
        let file = self
            .local_file
            .as_ref()
            .ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "partial local file handle is unavailable",
                )
            })?
            .try_clone()
            .await?;
        Ok(file)
    }

    async fn finalize_rename(
        mut self,
        final_path: &Path,
        remote_file: &mut RemoteFileHandle,
    ) -> Result<(), SftpError> {
        self.local_file.take();

        // Always check for symlinks and existing files first. The final
        // no-replace rename below is still authoritative and closes the race
        // between this early diagnostic check and commit.
        if let Err(err) = prepare_local_finalize_destination(
            final_path,
            self.overwrite_policy,
            &self.remote,
            &self.local,
        )
        .await
        {
            return self.abort_preserving_error(err, remote_file).await;
        }

        match self.overwrite_policy {
            TransferOverwritePolicy::FailIfExists => {
                // Use the platform's exclusive rename primitive. Unlike a
                // metadata check followed by plain rename, this cannot replace
                // a destination created concurrently. It also works on filesystems
                // that reject hard links but support atomic rename.
                match rename_local_noreplace(&self.partial_path, final_path).await {
                    Ok(()) => {
                        self.committed = true;
                        self.apply_remote_metadata(final_path);
                        Ok(())
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
                        let primary = SftpError::DownloadFailed {
                            remote: self.remote.clone(),
                            local: self.local.clone(),
                            message: TransferOverwritePolicy::destination_exists_message(
                                &final_path.display().to_string(),
                            ),
                        };
                        self.abort_preserving_error(primary, remote_file).await
                    }
                    Err(err) => {
                        let primary = SftpError::DownloadFailed {
                            remote: self.remote.clone(),
                            local: self.local.clone(),
                            message: err.to_string(),
                        };
                        self.abort_preserving_error(primary, remote_file).await
                    }
                }
            }
            TransferOverwritePolicy::Replace => {
                match tokio::fs::rename(&self.partial_path, final_path).await {
                    Ok(()) => {
                        self.committed = true;
                        self.apply_remote_metadata(final_path);
                        Ok(())
                    }
                    Err(err) => {
                        let primary = SftpError::DownloadFailed {
                            remote: self.remote.clone(),
                            local: self.local.clone(),
                            message: err.to_string(),
                        };
                        self.abort_preserving_error(primary, remote_file).await
                    }
                }
            }
        }
    }

    async fn abort_preserving_error(
        &mut self,
        primary: SftpError,
        remote_file: &mut RemoteFileHandle,
    ) -> Result<(), SftpError> {
        if let Err(cleanup_error) = self.abort(true, remote_file).await {
            tracing::warn!(
                primary_error = %primary,
                cleanup_error = %cleanup_error,
                local = %self.partial_path.display(),
                "failed to clean up a partial download after commit failure"
            );
        }
        Err(primary)
    }

    /// Aborts an in-progress local download: closes the local partial handle,
    /// best-effort closes `remote_file`, then deletes the partial path.
    ///
    /// Remote shutdown failures (including an already-closed handle after a
    /// failed pipelined read) are logged and ignored so local cleanup still
    /// runs. With `strict == false`, local delete failures become
    /// `Ok(Some(CleanupFailed))` instead of hard errors.
    async fn abort(
        &mut self,
        strict: bool,
        remote_file: &mut RemoteFileHandle,
    ) -> Result<Option<SftpError>, SftpError> {
        if self.committed {
            return Ok(None);
        }

        self.local_file.take();

        // Best-effort only: the SFTP session may already have torn down the
        // remote handle when `read_to_writer_pipelined` returned an error.
        if let Err(err) = remote_file.shutdown().await {
            tracing::warn!(
                local = %self.partial_path.display(),
                error = %err,
                "failed to close remote file during download cleanup (continuing local cleanup)"
            );
        }

        if self.keep_on_error && !strict {
            // A later attempt can continue this partial; keep it on disk for
            // ordinary errors (issue #313). Strict aborts (cancellation) still
            // delete.
            return Ok(None);
        }

        match tokio::fs::remove_file(&self.partial_path).await {
            Ok(()) => Ok(None),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(err) if !strict => {
                tracing::warn!(
                    local = %self.partial_path.display(),
                    error = %err,
                    "failed to delete partial local file after transfer error"
                );
                Ok(Some(SftpError::CleanupFailed {
                    path: self.partial_path.display().to_string(),
                    message: err.to_string(),
                }))
            }
            Err(err) => Err(SftpError::CleanupFailed {
                path: self.partial_path.display().to_string(),
                message: err.to_string(),
            }),
        }
    }
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

/// Converts a stdout/systemtime mtime to the SFTP `u32` seconds representation.
fn modified_secs(modified: std::time::SystemTime) -> Option<u32> {
    use std::time::UNIX_EPOCH;
    modified
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| d.as_secs().try_into().ok())
}

fn apply_downloaded_metadata(final_path: &Path, metadata: &FileAttributes) {
    if metadata.atime.is_some() || metadata.mtime.is_some() {
        let mut times = std::fs::FileTimes::new();
        if let Some(atime) = metadata.atime.or(metadata.mtime) {
            times = times
                .set_accessed(std::time::UNIX_EPOCH + std::time::Duration::from_secs(atime as u64));
        }
        if let Some(mtime) = metadata.mtime {
            times = times
                .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(mtime as u64));
        }

        match std::fs::File::open(final_path) {
            Ok(file) => {
                if let Err(err) = file.set_times(times) {
                    tracing::warn!(
                        local = %final_path.display(),
                        error = %err,
                        "failed to preserve timestamps on downloaded file"
                    );
                }
            }
            Err(err) => {
                tracing::warn!(
                    local = %final_path.display(),
                    error = %err,
                    "failed to open downloaded file to preserve timestamps"
                );
            }
        }
    }

    #[cfg(unix)]
    if let Some(permissions) = metadata.permissions {
        use std::os::unix::fs::PermissionsExt;

        // Apply zero as well: mode 0000 is a valid and intentional mode.
        let mode = permissions & 0o7777;
        if let Err(err) =
            std::fs::set_permissions(final_path, std::fs::Permissions::from_mode(mode))
        {
            tracing::warn!(
                local = %final_path.display(),
                error = %err,
                "failed to preserve permissions on downloaded file"
            );
        }
    }
}

/// Returns the parent directory of a remote path, or `None` for the root.
fn remote_parent_path(remote: &str) -> Option<String> {
    let normalized = normalize_remote_path(remote).ok()?;
    if normalized == "/" {
        return None;
    }
    let parent = normalized
        .rsplit_once('/')
        .map(|(dir, _)| if dir.is_empty() { "/" } else { dir })
        .unwrap_or("/");
    Some(parent.to_string())
}

async fn create_exclusive_remote_partial(
    client: &SftpClient<'_>,
    parent: &str,
    local: &str,
    remote: &str,
) -> Result<(String, RemoteFileHandle), SftpError> {
    // Verify the final remote parent exists before attempting create; a
    // missing parent is a real error rather than something to auto-create
    // (issue #658).
    if let Some(parent_path) = remote_parent_path(remote) {
        match client.sftp().metadata(&parent_path).await {
            Ok(_) => {}
            Err(err) if is_remote_no_such_file_error(&err) => {
                return Err(SftpError::UploadFailed {
                    local: local.to_string(),
                    remote: remote.to_string(),
                    message: format!("upload parent directory does not exist: {parent_path}"),
                });
            }
            Err(err) => {
                return Err(classify_sftp_client_error(err, &parent_path));
            }
        }
    }

    for _ in 0..MAX_PARTIAL_CREATE_ATTEMPTS {
        let suffix = random_partial_suffix()?;
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
            Err(err) if is_remote_file_exists_error(&err) => {
                // SSH_FX_FAILURE is generic: it may mean "the exclusive create
                // lost a race", but also permission or I/O problems. Confirm the path actually exists via
                // stat before retrying; otherwise propagate the real error.
                if remote_path_exists(client, &partial_path).await? {
                    continue;
                }
                return Err(SftpError::UploadFailed {
                    local: local.to_string(),
                    remote: remote.to_string(),
                    message: err.to_string(),
                });
            }
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

/// Maximum buffer size used while comparing the complete saved prefix.
const RESUME_VERIFICATION_BYTES: u64 = 64 * 1024;

/// Returns the byte offset to continue a previous download attempt from, when
/// a leftover local partial for this `(local, remote)` pair exists, is a
/// strict prefix of the remote file, and all saved bytes match the current
/// remote content (issue #313, #655). `None` starts from scratch.
