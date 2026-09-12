use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::task::{Context, Poll};
use std::{future::Future, io};

use rand::TryRng;
use russh_sftp::client::error::Error as SftpClientError;
use russh_sftp::client::fs::File as RemoteFileHandle;
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::OpenFlags;
use tokio::io::{AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::config::{
    clamp_transfer_chunk_size, clamp_transfer_download_pipeline_depth, DirectoryWalkLimits,
    DEFAULT_TRANSFER_CHUNK_SIZE_BYTES, DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH,
};
use crate::error::SftpError;
use crate::ssh::session::SshSession;
use crate::transfer::TransferOverwritePolicy;

use super::tree::{
    ensure_local_path_within_root, is_local_directory, join_remote_path, local_entry_name,
    normalize_remote_path, validated_remote_entry, walk_local_directory_with_options,
    walk_remote_directory_with_limits, WalkLocalDirectoryOptions,
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
}

/// High-level SFTP client built on top of an SSH session.
pub struct SftpClient<'a> {
    session: &'a SshSession,
    directory_walk_limits: DirectoryWalkLimits,
}

impl<'a> SftpClient<'a> {
    /// Creates a new SFTP client for the given SSH session.
    pub fn new(session: &'a SshSession) -> Self {
        Self {
            session,
            directory_walk_limits: DirectoryWalkLimits::default(),
        }
    }

    /// Sets resource limits applied during recursive directory walks.
    pub fn with_directory_walk_limits(mut self, limits: DirectoryWalkLimits) -> Self {
        self.directory_walk_limits = limits;
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

        upload_from_reader(
            &mut local_file,
            &mut partial,
            chunk_size,
            &is_cancelled,
            &mut on_progress,
            &local,
            &remote,
        )
        .await?;

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
    /// `pipeline_depth` controls how many SFTP READ requests stay in flight
    /// concurrently, trading memory (depth × chunk size) for latency hiding on
    /// high-latency links. `chunk_size` is accepted for API compatibility but
    /// is not used by the pipelined reader: `read_to_writer_pipelined` sizes
    /// each request from the SFTP `limits@openssh.com` extension or the packet
    /// ceiling (default 256 KiB), matching DockBridge's default chunk.
    #[allow(clippy::too_many_arguments)]
    pub async fn download_cancellable(
        &self,
        remote_path: &str,
        local_path: &Path,
        _chunk_size: usize,
        pipeline_depth: usize,
        overwrite_policy: TransferOverwritePolicy,
        is_cancelled: impl Fn() -> bool + Send,
        mut on_progress: impl FnMut(u64) + Send,
    ) -> Result<(), SftpError> {
        let remote_path = normalize_remote_path(remote_path)?;
        let remote = remote_path.clone();
        let local = local_path.display().to_string();
        let pipeline_depth = clamp_transfer_download_pipeline_depth(pipeline_depth);

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

        let writer_file =
            partial
                .clone_file_for_write()
                .await
                .map_err(|err| SftpError::DownloadFailed {
                    remote: remote.clone(),
                    local: local.clone(),
                    message: err.to_string(),
                })?;

        let mut writer = PipelinableTransferWriter {
            file: Some(writer_file),
            write_pos: 0_u64,
            is_cancelled: &is_cancelled,
            on_progress: &mut on_progress,
            transferred: 0_u64,
            pending_write: None,
            #[cfg(test)]
            fail_next_write: false,
        };
        let result =
            download_pipelined_to_writer(&mut remote_file, &mut writer, pipeline_depth).await;

        // Close the cloned write handle before touching the partial file's
        // finalization path so the rename/cleanup operates on a fully-flushed
        // file description.
        drop(writer);

        if let Err(err) = result {
            let cleanup_err = partial.abort(false, &mut remote_file).await?;
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
                // A generic SSH_FX_FAILURE may mean anything (permission denied,
                // disk full, etc.). Only treat it as "already exists" when the
                // path can be stat'd and is actually a directory.
                match self.sftp().metadata(&current).await {
                    Ok(metadata) if metadata.file_type().is_dir() => continue,
                    Ok(_) | Err(_) => {
                        return Err(SftpError::MkdirFailed { path, message });
                    }
                }
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

            let files = walk_local_directory_with_options(
                local_path,
                WalkLocalDirectoryOptions {
                    limits: self.directory_walk_limits,
                    ..Default::default()
                },
            )
            .await?;
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
        if self.remote_is_directory(&normalized).await? {
            let entries = self.list_directory(&normalized).await?;
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

            let files =
                walk_remote_directory_with_limits(self, &normalized, self.directory_walk_limits)
                    .await?;
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
        } else {
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

        if let Err(err) = partial
            .remote_file_mut()
            .write_all(&buffer[..bytes_read])
            .await
        {
            let cleanup_err = partial.abort(false).await?;
            return Err(SftpError::UploadFailed {
                local: local.to_string(),
                remote: remote.to_string(),
                message: append_cleanup_context(err.to_string(), cleanup_err),
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
        let cleanup_err = partial.abort(false).await?;
        return Err(SftpError::UploadFailed {
            local: local.to_string(),
            remote: remote.to_string(),
            message: append_cleanup_context(err.to_string(), cleanup_err),
        });
    }

    Ok(())
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
    /// Wraps a local write `io::Error`, preserving its kind so downstream
    /// cancellation detection never mistakes it for a cancellation.
    fn err_from_io(err: io::Error) -> io::Error {
        let kind = err.kind();
        io::Error::new(kind, DownloadFlowError::Write(err.to_string()).to_string())
    }

    /// From an `SftpClientError` surfaced by `read_to_writer_pipelined`.
    ///
    /// The crate collapses the writer's `io::Error` into `Error::IO` with
    /// its display text, so the error kind is not preserved across the
    /// boundary. Cancellation is therefore classified by an *exact* match on
    /// the sentinel message `poll_write` emits; no OS or local write error
    /// can reproduce the full sentinel string by coincidence (a path
    /// containing the phrase would not be an exact match).
    fn from_io_error(err: &SftpClientError) -> Self {
        match err {
            SftpClientError::IO(message) if message == DOWNLOAD_CANCELLED_MESSAGE => {
                DownloadFlowError::Cancelled
            }
            _ => DownloadFlowError::Write(err.to_string()),
        }
    }
}

/// Sentinel display text shared by the writer's cancellation error and the
/// downstream classifier (exact match, not substring).
const DOWNLOAD_CANCELLED_MESSAGE: &str = "transfer was cancelled";

impl std::fmt::Display for DownloadFlowError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DownloadFlowError::Cancelled => f.write_str(DOWNLOAD_CANCELLED_MESSAGE),
            DownloadFlowError::Write(message) => f.write_str(message),
        }
    }
}

/// Bounds a single `write_all` call. macOS caps a single file write below
/// 2 GiB (EINVAL) and other platforms behave differently, so oversized
/// buffers (the pipeline can hand us 256 KiB × 64) are split into
/// sub-buffer pieces.
const MAX_WRITE_SIZE: usize = 8 * 1024 * 1024; // 8 MiB

/// Adapter that presents a cloned local partial file handle as an
/// `AsyncWrite` sink while forwarding progress callbacks and cancellation
/// checks on every written chunk. Used to bridge `read_to_writer_pipelined`
/// (which streams into an `AsyncWrite`) with DockBridge's
/// progress/cancellation plumbing.
///
/// The file handle is taken from the struct while a chunk write is pending
/// and returned once the write completes, so the in-flight future does not
/// borrow from the struct itself.
struct PipelinableTransferWriter<'a, F>
where
    F: Fn() -> bool + 'a,
{
    file: Option<tokio::fs::File>,
    write_pos: u64,
    is_cancelled: &'a F,
    on_progress: &'a mut dyn FnMut(u64),
    transferred: u64,
    pending_write: Option<Pin<Box<dyn Future<Output = io::Result<tokio::fs::File>> + Send + 'a>>>,
    #[cfg(test)]
    fail_next_write: bool,
}

impl<'a, F> PipelinableTransferWriter<'a, F>
where
    F: Fn() -> bool + 'a,
{
    /// Prepares and polls a single pending chunk write. Used by both
    /// `poll_write` and the oversized-buffer branch.
    #[allow(clippy::too_many_arguments)]
    fn poll_chunk(
        self: &mut Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        #[cfg(test)]
        if self.fail_next_write {
            self.fail_next_write = false;
            return Poll::Ready(Err(io::Error::other(
                DownloadFlowError::Write("simulated local write failure".to_string()).to_string(),
            )));
        }

        if self.pending_write.is_none() {
            let mut file = self
                .file
                .take()
                .expect("partial file handle must be available");
            let offset = self.write_pos;
            let data = buf.to_vec();
            self.pending_write = Some(Box::pin(async move {
                use tokio::io::{AsyncSeekExt, AsyncWriteExt};
                file.seek(io::SeekFrom::Start(offset)).await?;
                file.write_all(&data).await?;
                Ok(file)
            }));
        }

        match self
            .pending_write
            .as_mut()
            .expect("pending write set")
            .as_mut()
            .poll(cx)
        {
            Poll::Pending => Poll::Pending,
            Poll::Ready(Ok(file)) => {
                self.file = Some(file);
                self.pending_write = None;
                self.write_pos += buf.len() as u64;
                self.transferred += buf.len() as u64;
                let transferred = self.transferred;
                let on_progress = &mut *self.on_progress;
                on_progress(transferred);
                Poll::Ready(Ok(buf.len()))
            }
            Poll::Ready(Err(err)) => {
                self.pending_write = None;
                Poll::Ready(Err(DownloadFlowError::err_from_io(err)))
            }
        }
    }
}

impl<'a, F> AsyncWrite for PipelinableTransferWriter<'a, F>
where
    F: Fn() -> bool + 'a,
{
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        // `buf.len() > MAX_WRITE_SIZE` is unreachable for pipelined reads
        // (chunk ≤ max_packet_len ≈ 256 KiB), but a single `write_all` above
        // ~2 GiB fails on macOS (EINVAL), so split oversized buffers.
        if buf.len() > MAX_WRITE_SIZE {
            if self.pending_write.is_none() {
                let mut file = self
                    .file
                    .take()
                    .expect("partial file handle must be available");
                let offset = self.write_pos;
                let mut data = buf.to_vec();
                self.pending_write = Some(Box::pin(async move {
                    use tokio::io::{AsyncSeekExt, AsyncWriteExt};
                    file.seek(io::SeekFrom::Start(offset)).await?;
                    loop {
                        let (head, tail) = if data.len() > MAX_WRITE_SIZE {
                            data.split_at(MAX_WRITE_SIZE)
                        } else {
                            (data.as_slice(), &[][..])
                        };
                        file.write_all(head).await?;
                        if tail.is_empty() {
                            break;
                        }
                        data = tail.to_vec();
                    }
                    Ok(file)
                }));
            }
            match self
                .pending_write
                .as_mut()
                .expect("pending write set")
                .as_mut()
                .poll(cx)
            {
                Poll::Pending => Poll::Pending,
                Poll::Ready(Ok(file)) => {
                    self.file = Some(file);
                    self.pending_write = None;
                    self.write_pos += buf.len() as u64;
                    self.transferred += buf.len() as u64;
                    let transferred = self.transferred;
                    let on_progress = &mut *self.on_progress;
                    on_progress(transferred);
                    Poll::Ready(Ok(buf.len()))
                }
                Poll::Ready(Err(err)) => {
                    self.pending_write = None;
                    Poll::Ready(Err(DownloadFlowError::err_from_io(err)))
                }
            }
        } else if (self.is_cancelled)() {
            // Classified downstream by an exact match on
            // `DOWNLOAD_CANCELLED_MESSAGE` (see
            // `DownloadFlowError::from_io_error`). The message is only for
            // display and never matched on.
            Poll::Ready(Err(io::Error::new(
                io::ErrorKind::Interrupted,
                DOWNLOAD_CANCELLED_MESSAGE,
            )))
        } else {
            self.poll_chunk(cx, buf)
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        if let Some(pending) = self.pending_write.as_mut() {
            match pending.as_mut().poll(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Ok(file)) => {
                    self.file = Some(file);
                    self.pending_write = None;
                }
                Poll::Ready(Err(err)) => {
                    self.pending_write = None;
                    return Poll::Ready(Err(DownloadFlowError::err_from_io(err)));
                }
            }
        }
        Poll::Ready(Ok(()))
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
    F: Fn() -> bool + 'a,
{
    remote_file
        .read_to_writer_pipelined(writer, pipeline_depth)
        .await
        .map(|_| ())
        .map_err(|err| DownloadFlowError::from_io_error(&err))
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

    async fn abort(&mut self, strict: bool) -> Result<Option<SftpError>, SftpError> {
        if self.committed {
            return Ok(None);
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
            Ok(()) => Ok(None),
            Err(err) if !strict => {
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
            Err(err) => Err(SftpError::CleanupFailed {
                path: self.partial_path.clone(),
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

        // Always check for symlinks and existing files first. This provides
        // an early failure path and rejects symlink targets that hard_link
        // would otherwise follow.
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

        match self.overwrite_policy {
            TransferOverwritePolicy::FailIfExists => {
                // Use hard_link + unlink to atomically reserve the final path.
                // hard_link fails with AlreadyExists if the target appears
                // between prepare_local_finalize_destination and here,
                // closing the TOCTOU window.
                match tokio::fs::hard_link(&self.partial_path, final_path).await {
                    Ok(()) => {
                        if let Err(err) = tokio::fs::remove_file(&self.partial_path).await {
                            tracing::warn!(
                                local = %self.partial_path.display(),
                                error = %err,
                                "failed to remove partial after hard_link"
                            );
                        }
                        self.committed = true;
                        Ok(())
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
                        let remote = self.remote.clone();
                        let local = self.local.clone();
                        self.abort(true, remote_file).await?;
                        Err(SftpError::DownloadFailed {
                            remote,
                            local,
                            message: TransferOverwritePolicy::destination_exists_message(
                                &final_path.display().to_string(),
                            ),
                        })
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
            TransferOverwritePolicy::Replace => {
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
        }
    }

    async fn abort(
        &mut self,
        strict: bool,
        remote_file: &mut RemoteFileHandle,
    ) -> Result<Option<SftpError>, SftpError> {
        if self.committed {
            return Ok(None);
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
mod tests {
    use std::collections::VecDeque;
    use std::io::{self, ErrorKind};
    use std::net::SocketAddr;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use std::time::{Duration, Instant};

    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    use super::{
        append_cleanup_context, create_exclusive_local_partial, download_pipelined_to_writer,
        normalize_remote_path, open_exclusive_local_file, parent_remote_path, partial_file_name,
        partial_local_path_for_suffix, partial_remote_path_for_suffix,
        prepare_local_finalize_destination, random_partial_suffix, upload_from_reader,
        DownloadFlowError, PartialLocalTransfer, PartialRemoteTransfer, PipelinableTransferWriter,
        SftpClient,
    };
    use crate::error::SftpError;
    use crate::sftp::test_server::{list_partial_paths, TestSftpServer};
    use crate::sftp::tree::walk_remote_directory;
    use crate::transfer::TransferOverwritePolicy;

    struct FailOnRead {
        fail_after_successful_reads: usize,
        reads: usize,
    }

    impl FailOnRead {
        fn new(fail_after_successful_reads: usize) -> Self {
            Self {
                fail_after_successful_reads,
                reads: 0,
            }
        }
    }

    impl tokio::io::AsyncRead for FailOnRead {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            if self.reads >= self.fail_after_successful_reads {
                return Poll::Ready(Err(io::Error::other("simulated local read failure")));
            }
            self.reads += 1;
            let data = b"partial-chunk";
            let len = data.len().min(buf.remaining());
            buf.put_slice(&data[..len]);
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn download_local_write_failure_cleans_up_local_partial() {
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/download/file.txt", b"payload")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("file.txt");

        let mut remote_file = client
            .open_remote_for_test("/download/file.txt")
            .await
            .expect("remote file should open");
        let mut partial = PartialLocalTransfer::begin(
            local_dir.path(),
            "/download/file.txt",
            &local_path.display().to_string(),
            TransferOverwritePolicy::default(),
        )
        .await
        .unwrap();
        assert!(!list_partial_paths(local_dir.path()).is_empty());

        let writer_file = partial
            .clone_file_for_write()
            .await
            .expect("partial file should clone");
        let mut failed = false;
        let mut writer = PipelinableTransferWriter {
            file: Some(writer_file),
            write_pos: 0,
            is_cancelled: &|| false,
            on_progress: &mut |_| {},
            transferred: 0,
            pending_write: None,
            fail_next_write: true,
        };
        let result = download_pipelined_to_writer(&mut remote_file, &mut writer, 8).await;
        if let Err(DownloadFlowError::Write(_)) = result {
            failed = true;
        }
        assert!(failed, "expected a write failure, got {result:?}");

        // Recover the cloned handle back into the partial so the cleanup path
        // mirrors production (writer owns the clone while we clean up).
        if let Some(file) = writer.file.take() {
            // Ensure the clone is closed so nothing holds the path open.
            drop(file);
        }
        if let Some(pending) = writer.pending_write.take() {
            drop(pending);
        }

        let _ = partial.abort(false, &mut remote_file).await;
        assert!(
            list_partial_paths(local_dir.path()).is_empty(),
            "partial local files must be cleaned up: {:?}",
            list_partial_paths(local_dir.path())
        );
    }

    #[tokio::test]
    async fn download_pipeline_zero_depth_is_rejected_by_library() {
        // Given: a remote file and a connected client
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/download/file.txt", b"payload")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("file.txt");

        let mut remote_file = client
            .open_remote_for_test("/download/file.txt")
            .await
            .expect("remote file should open");
        let mut partial = PartialLocalTransfer::begin(
            local_dir.path(),
            "/download/file.txt",
            &local_path.display().to_string(),
            TransferOverwritePolicy::default(),
        )
        .await
        .unwrap();

        let writer_file = partial
            .clone_file_for_write()
            .await
            .expect("partial file should clone");
        let mut writer = PipelinableTransferWriter {
            file: Some(writer_file),
            write_pos: 0,
            is_cancelled: &|| false,
            on_progress: &mut |_| {},
            transferred: 0,
            pending_write: None,
            fail_next_write: false,
        };
        let result = download_pipelined_to_writer(&mut remote_file, &mut writer, 0).await;
        assert!(
            matches!(result, Err(DownloadFlowError::Write(_))),
            "depth 0 should be rejected: {result:?}"
        );

        if let Some(pending) = writer.pending_write.take() {
            drop(pending);
        }
        if let Some(file) = writer.file.take() {
            drop(file);
        }
        let _ = partial.abort(false, &mut remote_file).await;
        assert!(list_partial_paths(local_dir.path()).is_empty());
    }

    #[tokio::test]
    async fn download_rename_failure_cleans_up_local_partial() {
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/download/file.txt", b"payload")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("file.txt");
        tokio::fs::create_dir(&local_path).await.unwrap();

        let err = client
            .download("/download/file.txt", &local_path)
            .await
            .unwrap_err();
        assert!(matches!(err, SftpError::DownloadFailed { .. }));
        assert!(list_partial_paths(local_dir.path()).is_empty(), "{err:?}");
    }

    #[tokio::test]
    async fn pipelined_download_cancel_midway_stops_and_cleans_up() {
        // Given: a remote file large enough to span many pipeline chunks
        let server = TestSftpServer::start().await;
        let payload = vec![0x3C_u8; 16 * 1024 * 1024];
        server
            .write_remote_file("/download/cancel.bin", &payload)
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("cancel.bin");
        let cancel_after = Arc::new(AtomicBool::new(false));

        // When: the transfer is cancelled partway (after the first reported
        // progress), the pipelined writer surfaces the cancellation
        let cancel_flag = Arc::clone(&cancel_after);
        let err = client
            .download_cancellable(
                "/download/cancel.bin",
                &local_path,
                262_144,
                64,
                TransferOverwritePolicy::Replace,
                move || cancel_flag.load(Ordering::Relaxed),
                {
                    let cancel_flag = Arc::clone(&cancel_after);
                    move |transferred| {
                        if transferred >= 1024 * 1024 {
                            cancel_flag.store(true, Ordering::Relaxed);
                        }
                    }
                },
            )
            .await
            .unwrap_err();

        // Then: the download is cancelled and the partial file is removed
        assert!(matches!(err, SftpError::Cancelled), "got {err:?}");
        assert!(
            !local_path.exists(),
            "final local file must not exist after cancel"
        );
        assert!(
            list_partial_paths(local_dir.path()).is_empty(),
            "partial local files must be cleaned up after cancel: {:?}",
            list_partial_paths(local_dir.path())
        );
    }

    #[test]
    fn append_cleanup_context_preserves_original_error() {
        let message = append_cleanup_context(
            "upload failed",
            Some(SftpError::CleanupFailed {
                path: "/tmp/.dockbridge-abc.partial".to_string(),
                message: "permission denied".to_string(),
            }),
        );
        assert!(message.contains("upload failed"));
        assert!(message.contains("partial cleanup failed"));
        assert!(message.contains("permission denied"));
    }

    #[test]
    fn append_cleanup_context_returns_original_when_cleanup_succeeds() {
        assert_eq!(
            append_cleanup_context("download failed", None),
            "download failed"
        );
    }

    #[tokio::test]
    async fn upload_local_read_failure_cleans_up_remote_partial() {
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("source.txt");
        tokio::fs::write(&local_path, b"ignored").await.unwrap();

        let mut partial = PartialRemoteTransfer::begin(
            &client,
            "/upload",
            &local_path.display().to_string(),
            "/upload/file.txt",
            TransferOverwritePolicy::default(),
        )
        .await
        .unwrap();
        assert!(!server.remote_partial_paths().is_empty());

        let mut reader = FailOnRead::new(0);
        let err = upload_from_reader(
            &mut reader,
            &mut partial,
            16,
            &|| false,
            &mut |_| {},
            &local_path.display().to_string(),
            "/upload/file.txt",
        )
        .await
        .unwrap_err();
        assert!(matches!(err, SftpError::UploadFailed { .. }));
        assert!(server.remote_partial_paths().is_empty());
    }

    #[tokio::test]
    async fn upload_remote_write_failure_cleans_up_remote_partial() {
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("source.txt");
        tokio::fs::write(&local_path, b"0123456789abcdef")
            .await
            .unwrap();

        server
            .failures
            .fail_remote_write
            .store(true, Ordering::SeqCst);
        let err = client
            .upload(&local_path, "/upload/file.txt")
            .await
            .unwrap_err();
        assert!(matches!(err, SftpError::UploadFailed { .. }));
        assert!(server.remote_partial_paths().is_empty(), "{err:?}");
    }

    #[tokio::test]
    async fn upload_remote_shutdown_failure_cleans_up_remote_partial() {
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("source.txt");
        tokio::fs::write(&local_path, b"done").await.unwrap();

        server
            .failures
            .fail_remote_close
            .store(true, Ordering::SeqCst);
        let err = client
            .upload(&local_path, "/upload/file.txt")
            .await
            .unwrap_err();
        assert!(matches!(err, SftpError::UploadFailed { .. }));
        assert!(server.remote_partial_paths().is_empty(), "{err:?}");
    }

    #[tokio::test]
    async fn download_remote_read_failure_cleans_up_local_partial() {
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/download/file.txt", b"payload")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("file.txt");

        server
            .failures
            .fail_remote_read
            .store(true, Ordering::SeqCst);
        let err = client
            .download("/download/file.txt", &local_path)
            .await
            .unwrap_err();
        assert!(matches!(err, SftpError::DownloadFailed { .. }));
        assert!(list_partial_paths(local_dir.path()).is_empty(), "{err:?}");
        assert!(!local_path.exists());
    }

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

    #[tokio::test]
    async fn create_directory_all_succeeds_when_directory_exists() {
        let server = TestSftpServer::start().await;
        server.write_remote_file("/upload/file.txt", b"").await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        client.create_directory_all("/upload").await.unwrap();
        assert!(server.remote_file_exists("/upload/file.txt"));
    }

    #[tokio::test]
    async fn create_directory_all_fails_on_generic_failure_without_existing_directory() {
        let server = TestSftpServer::start().await;
        server.failures.fail_mkdir.store(true, Ordering::SeqCst);
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        let err = client
            .create_directory_all("/upload/nested/dir")
            .await
            .unwrap_err();
        assert!(
            matches!(err, SftpError::MkdirFailed { ref path, .. } if path == "/upload"),
            "unexpected error: {err:?}"
        );
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
                TransferOverwritePolicy::default(),
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
                64,
                TransferOverwritePolicy::default(),
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

    #[tokio::test]
    async fn list_directory_marks_files_correctly() {
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/download/tree/nested/file.txt", b"x")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let entries = client
            .list_directory("/download/tree/nested")
            .await
            .unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "file.txt");
        assert!(!entries[0].is_directory, "{entries:?}");
        assert!(!entries[0].is_symlink, "{entries:?}");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn walk_remote_directory_skips_symlinks_by_default() {
        // Given: a remote directory with a symlink to an outside file and a normal file
        // When: walk_remote_directory collects files for bulk download
        // Then: symlink targets outside the selected subtree are not included
        let server = TestSftpServer::start().await;
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("secret.txt"), b"secret").unwrap();
        let download_dir = server.root.join("download");
        std::fs::create_dir_all(&download_dir).unwrap();
        std::fs::write(download_dir.join("normal.txt"), b"ok").unwrap();
        std::os::unix::fs::symlink(
            outside.path().join("secret.txt"),
            download_dir.join("link.txt"),
        )
        .unwrap();
        std::os::unix::fs::symlink(outside.path(), download_dir.join("link_dir")).unwrap();

        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let entries = walk_remote_directory(&client, "/download").await.unwrap();
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
    async fn list_directory_marks_symlinks_without_following() {
        let server = TestSftpServer::start().await;
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("target.txt"), b"x").unwrap();
        let download_dir = server.root.join("download");
        std::fs::create_dir_all(&download_dir).unwrap();
        std::os::unix::fs::symlink(
            outside.path().join("target.txt"),
            download_dir.join("link.txt"),
        )
        .unwrap();

        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let entries = client.list_directory("/download").await.unwrap();
        let link = entries
            .iter()
            .find(|entry| entry.name == "link.txt")
            .expect("symlink entry");
        assert!(link.is_symlink, "{link:?}");
        assert!(!link.is_directory, "{link:?}");
    }

    #[tokio::test]
    async fn download_entry_downloads_remote_file() {
        // Given: a remote file on the test SFTP server
        let server = TestSftpServer::start().await;
        let payload = b"download entry file payload";
        server
            .write_remote_file("/download/file.txt", payload)
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();

        // When: download_entry is called for the file path
        client
            .download_entry("/download/file.txt", local_dir.path())
            .await
            .unwrap();

        // Then: the file is saved under the local directory
        let local_path = local_dir.path().join("file.txt");
        let contents = tokio::fs::read(&local_path).await.unwrap();
        assert_eq!(contents, payload);
    }

    #[tokio::test]
    async fn download_entry_downloads_remote_directory() {
        // Given: a remote directory tree on the test SFTP server
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/download/tree/nested/file.txt", b"nested payload")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();

        // When: download_entry is called for the directory path
        client
            .download_entry("/download/tree", local_dir.path())
            .await
            .unwrap();

        // Then: the directory tree is mirrored locally
        let local_path = local_dir.path().join("tree/nested/file.txt");
        let contents = tokio::fs::read(&local_path).await.unwrap();
        assert_eq!(contents, b"nested payload");
    }

    #[tokio::test]
    async fn download_entry_propagates_missing_path_list_error() {
        // Given: a remote path that does not exist
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();

        // When: download_entry is called for the missing path
        let err = client
            .download_entry("/download/missing.txt", local_dir.path())
            .await
            .unwrap_err();

        // Then: the original list/metadata error is returned instead of a download fallback error
        assert!(matches!(err, SftpError::ListFailed { .. }));
        assert!(
            !matches!(err, SftpError::DownloadFailed { .. }),
            "unexpected download fallback error: {err}"
        );
    }

    #[tokio::test]
    async fn upload_writes_remote_file_matching_local_bytes() {
        // Given: a local file with a known payload
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let payload = b"characterization upload payload";
        let local_path = local_dir.path().join("file.txt");
        tokio::fs::write(&local_path, payload).await.unwrap();

        // When: the file is uploaded to a remote path
        client
            .upload(&local_path, "/upload/file.txt")
            .await
            .unwrap();

        // Then: the remote file bytes match the local payload and no partial remains
        let remote_bytes = tokio::fs::read(server.root.join("upload/file.txt"))
            .await
            .unwrap();
        assert_eq!(remote_bytes, payload);
        assert!(
            server.remote_partial_paths().is_empty(),
            "partial remote files must not remain after success: {:?}",
            server.remote_partial_paths()
        );
        assert!(server.remote_file_exists("/upload/file.txt"));
    }

    #[tokio::test]
    async fn pipelined_download_reassembles_chunks_in_order() {
        // Given: a remote file larger than one chunk whose size is not an
        // exact multiple of the read chunk, forcing out-of-order pipeline
        // reassembly and a partial final chunk
        const DATA_BYTES: usize = 4 * 1024 * 1024 + 317;
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let payload: Vec<u8> = (0..DATA_BYTES).map(|i| (i * 31 + 7) as u8).collect();
        server
            .write_remote_file("/download/large.bin", &payload)
            .await;

        // When: the file is downloaded with a deep pipeline
        let local_path = local_dir.path().join("large.bin");
        client
            .download_cancellable(
                "/download/large.bin",
                &local_path,
                262_144,
                64,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();

        // Then: the reassembled bytes match the source exactly
        let downloaded = tokio::fs::read(&local_path).await.unwrap();
        assert_eq!(downloaded.len(), DATA_BYTES);
        assert_eq!(downloaded, payload);
        assert!(list_partial_paths(local_dir.path()).is_empty());
    }

    #[tokio::test]
    async fn pipelined_download_reports_total_progress() {
        // Given: a remote file and a connected client
        let server = TestSftpServer::start().await;
        let payload = vec![0x5A_u8; 8 * 1024 * 1024];
        server
            .write_remote_file("/download/progress.bin", &payload)
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("progress.bin");
        let last_reported = std::sync::Mutex::new(0_u64);

        // When: the file is downloaded with progress tracking
        client
            .download_cancellable(
                "/download/progress.bin",
                &local_path,
                262_144,
                64,
                TransferOverwritePolicy::Replace,
                || false,
                |bytes| {
                    *last_reported.lock().unwrap() = bytes;
                },
            )
            .await
            .unwrap();

        // Then: the final progress value equals the full file size
        let reported = *last_reported.lock().unwrap();
        assert_eq!(reported, payload.len() as u64);
    }

    #[tokio::test]
    async fn walk_remote_directory_collects_nested_files() {
        // Given: a remote directory with a top-level file and a nested file
        let server = TestSftpServer::start().await;
        server.write_remote_file("/walk/top.txt", b"a").await;
        server
            .write_remote_file("/walk/nested/inner.txt", b"b")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: the remote directory is walked
        let entries = walk_remote_directory(&client, "/walk").await.unwrap();

        // Then: both files are collected with relative paths from the walk root
        assert_eq!(entries.len(), 2);
        let relatives: Vec<_> = entries
            .iter()
            .map(|entry| entry.relative_path.to_string_lossy().into_owned())
            .collect();
        assert!(
            relatives.contains(&"top.txt".to_string()),
            "missing top.txt: {relatives:?}"
        );
        assert!(
            relatives.contains(&"nested/inner.txt".to_string()),
            "missing nested/inner.txt: {relatives:?}"
        );
    }

    #[tokio::test]
    async fn upload_writes_empty_file() {
        // Given: an empty local file
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("empty.txt");
        tokio::fs::write(&local_path, b"").await.unwrap();

        // When: the empty file is uploaded
        client
            .upload(&local_path, "/upload/empty.txt")
            .await
            .unwrap();

        // Then: the remote file exists with empty contents and no partial remains
        let remote_bytes = tokio::fs::read(server.root.join("upload/empty.txt"))
            .await
            .unwrap();
        assert_eq!(remote_bytes, b"");
        assert!(
            server.remote_partial_paths().is_empty(),
            "partial remote files must not remain after empty upload: {:?}",
            server.remote_partial_paths()
        );
        assert!(server.remote_file_exists("/upload/empty.txt"));
    }

    #[tokio::test]
    async fn walk_remote_directory_empty_directory() {
        // Given: an empty remote directory
        let server = TestSftpServer::start().await;
        tokio::fs::create_dir_all(server.root.join("emptywalk"))
            .await
            .unwrap();
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: the empty directory is walked
        let entries = walk_remote_directory(&client, "/emptywalk").await.unwrap();

        // Then: an empty vector is returned rather than an error
        assert!(
            entries.is_empty(),
            "expected no files in empty directory, got {entries:?}"
        );
    }

    #[tokio::test]
    async fn upload_missing_local_file_returns_upload_failed() {
        // Given: a local path that does not exist
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("missing.txt");

        // When: upload is called for the missing local file
        let err = client
            .upload(&local_path, "/upload/missing.txt")
            .await
            .unwrap_err();

        // Then: UploadFailed is returned with a non-empty message and nothing is written remotely
        assert!(matches!(err, SftpError::UploadFailed { .. }));
        assert!(
            !err.to_string().is_empty(),
            "error message must not be empty"
        );
        assert!(
            !server.remote_file_exists("/upload/missing.txt"),
            "final remote file must not exist after failed upload"
        );
        assert!(
            server.remote_partial_paths().is_empty(),
            "partial remote files must not remain: {:?}",
            server.remote_partial_paths()
        );
    }

    #[tokio::test]
    async fn walk_remote_directory_propagates_missing_path_list_error() {
        // Given: a remote path that does not exist
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: a missing directory is walked
        let err = walk_remote_directory(&client, "/walk/missing")
            .await
            .unwrap_err();

        // Then: the original list error is returned instead of a download fallback
        assert!(matches!(err, SftpError::ListFailed { .. }));
        assert!(
            !matches!(err, SftpError::DownloadFailed { .. }),
            "unexpected download fallback error: {err}"
        );
    }

    #[tokio::test]
    async fn walk_remote_directory_rejects_parent_segments() {
        // Given: a connected SFTP client
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: walk is requested with a parent-directory segment
        let err = walk_remote_directory(&client, "/walk/../secret")
            .await
            .unwrap_err();

        // Then: InvalidRemotePath is returned
        assert!(
            matches!(err, SftpError::InvalidRemotePath { .. }),
            "unexpected error: {err:?}"
        );
    }

    #[tokio::test]
    async fn walk_remote_directory_lists_each_directory_once() {
        // Given: `/walkonce/top.txt` and `/walkonce/nested/inner.txt`
        // (same tree as walk_remote_directory_collects_nested_files)
        let server = TestSftpServer::start().await;
        server.write_remote_file("/walkonce/top.txt", b"a").await;
        server
            .write_remote_file("/walkonce/nested/inner.txt", b"b")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: the remote directory is walked
        let entries = walk_remote_directory(&client, "/walkonce").await.unwrap();

        // Then: both files are collected and each directory is listed once
        // (no discarded root listing).
        assert_eq!(entries.len(), 2);
        let relatives: Vec<_> = entries
            .iter()
            .map(|entry| entry.relative_path.to_string_lossy().into_owned())
            .collect();
        assert!(
            relatives.contains(&"top.txt".to_string()),
            "missing top.txt: {relatives:?}"
        );
        assert!(
            relatives.contains(&"nested/inner.txt".to_string()),
            "missing nested/inner.txt: {relatives:?}"
        );
        assert_eq!(
            server.opendir_count(),
            2,
            "expected one OPENDIR per directory (root + nested), got {}",
            server.opendir_count()
        );
    }

    #[tokio::test]
    async fn walk_remote_directory_lists_empty_directory_once() {
        // Given: an empty remote directory
        let server = TestSftpServer::start().await;
        tokio::fs::create_dir_all(server.root.join("emptyonce"))
            .await
            .unwrap();
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: the empty directory is walked
        let entries = walk_remote_directory(&client, "/emptyonce").await.unwrap();

        // Then: no files are collected and the empty root is listed once
        assert!(
            entries.is_empty(),
            "expected no files in empty directory, got {entries:?}"
        );
        assert_eq!(
            server.opendir_count(),
            1,
            "expected one OPENDIR for the empty root, got {}",
            server.opendir_count()
        );
    }

    #[tokio::test]
    async fn walk_remote_directory_missing_path_opens_directory_once() {
        // Given: a remote path that does not exist
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: a missing directory is walked
        let err = walk_remote_directory(&client, "/missingonce")
            .await
            .unwrap_err();

        // Then: ListFailed is returned (not DownloadFailed) after a single OPENDIR
        assert!(matches!(err, SftpError::ListFailed { .. }));
        assert!(
            !matches!(err, SftpError::DownloadFailed { .. }),
            "unexpected download fallback error: {err}"
        );
        assert_eq!(
            server.opendir_count(),
            1,
            "expected one OPENDIR for the failed list, got {}",
            server.opendir_count()
        );
    }

    #[tokio::test]
    async fn walk_remote_directory_file_path_returns_list_failed() {
        // Given: a remote file (not a directory)
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/notadir/file.txt", b"payload")
            .await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: walk is requested on the file path
        let err = walk_remote_directory(&client, "/notadir/file.txt")
            .await
            .unwrap_err();

        // Then: ListFailed is returned because the path is not a directory
        assert!(
            matches!(err, SftpError::ListFailed { .. }),
            "unexpected error: {err:?}"
        );
        assert!(
            !err.to_string().is_empty(),
            "error message must not be empty"
        );
        assert!(
            server.opendir_count() <= 1,
            "file-path walk must OPENDIR at most once, got {}",
            server.opendir_count()
        );
    }

    #[tokio::test]
    async fn upload_rejects_parent_segments_in_remote_path() {
        // Given: an existing local file and a traversal remote path
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("source.txt");
        tokio::fs::write(&local_path, b"should not escape")
            .await
            .unwrap();

        // When: upload is called with a parent-directory segment in the remote path
        let err = client
            .upload(&local_path, "/upload/../escape.txt")
            .await
            .unwrap_err();

        // Then: the public upload API rejects traversal and does not create escape.txt
        assert!(
            matches!(err, SftpError::InvalidRemotePath { .. }),
            "unexpected error: {err:?}"
        );
        assert!(
            !server.remote_file_exists("/escape.txt"),
            "traversal must not create /escape.txt"
        );
        assert!(
            !server.remote_file_exists("/upload/escape.txt"),
            "traversal must not create /upload/escape.txt"
        );
    }

    #[tokio::test]
    #[ignore]
    async fn bench_walk_remote_directory_counts_opendir() {
        // Given: root `/benchwalk` with 40 child directories, each containing one file
        const CHILD_DIR_COUNT: usize = 40;
        let server = TestSftpServer::start().await;
        for index in 0..CHILD_DIR_COUNT {
            let remote_path = format!("/benchwalk/dir{index:02}/file.txt");
            server.write_remote_file(&remote_path, b"x").await;
        }
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);

        // When: walk_remote_directory collects files under /benchwalk
        let started = std::time::Instant::now();
        let entries = walk_remote_directory(&client, "/benchwalk").await.unwrap();
        let elapsed_ms = started.elapsed().as_millis();

        // Then: collected file count is 40; elapsed time and OPENDIR count are reported
        assert_eq!(entries.len(), CHILD_DIR_COUNT);
        eprintln!(
            "bench_walk_remote_directory_counts_opendir elapsed_ms={elapsed_ms} opendir_count={}",
            server.opendir_count()
        );
    }

    #[tokio::test]
    #[ignore]
    async fn bench_upload_32mib_default_chunk() {
        // Given: a connected client, a 1 MiB warmup file, and a 32 MiB zero-filled payload
        const WARMUP_BYTES: usize = 1024 * 1024;
        const BENCH_BYTES: usize = 32 * 1024 * 1024;
        let chunk_size = crate::config::DEFAULT_TRANSFER_CHUNK_SIZE_BYTES;
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let warmup_path = local_dir.path().join("warmup.bin");
        let payload_path = local_dir.path().join("payload.bin");
        tokio::fs::write(&warmup_path, vec![0_u8; WARMUP_BYTES])
            .await
            .unwrap();
        tokio::fs::write(&payload_path, vec![0_u8; BENCH_BYTES])
            .await
            .unwrap();
        client
            .upload_cancellable(
                &warmup_path,
                "/bench/warmup.bin",
                chunk_size,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();

        // When: the 32 MiB file is uploaded with the default chunk size and noop callbacks
        let started = std::time::Instant::now();
        client
            .upload_cancellable(
                &payload_path,
                "/bench/payload.bin",
                chunk_size,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();
        let elapsed_ms = started.elapsed().as_millis();

        // Then: remote size matches and elapsed wall time is reported
        let remote_size = client.remote_file_size("/bench/payload.bin").await.unwrap();
        assert_eq!(remote_size, BENCH_BYTES as u64);
        eprintln!("bench_upload_32mib_default_chunk elapsed_ms={elapsed_ms}");
    }

    #[tokio::test]
    #[ignore]
    async fn bench_upload_32mib_with_mutex_progress() {
        // Given: a connected client, warmup, 32 MiB payload, and Mutex callbacks like TransferManager
        const WARMUP_BYTES: usize = 1024 * 1024;
        const BENCH_BYTES: usize = 32 * 1024 * 1024;
        let chunk_size = crate::config::DEFAULT_TRANSFER_CHUNK_SIZE_BYTES;
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        let warmup_path = local_dir.path().join("warmup.bin");
        let payload_path = local_dir.path().join("payload.bin");
        tokio::fs::write(&warmup_path, vec![0_u8; WARMUP_BYTES])
            .await
            .unwrap();
        tokio::fs::write(&payload_path, vec![0_u8; BENCH_BYTES])
            .await
            .unwrap();
        client
            .upload_cancellable(
                &warmup_path,
                "/bench/warmup.bin",
                chunk_size,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();
        let transferred = std::sync::Mutex::new(0_u64);
        let cancelled = std::sync::Mutex::new(false);

        // When: the 32 MiB file is uploaded while locking Mutex on every progress/cancel check
        let started = std::time::Instant::now();
        client
            .upload_cancellable(
                &payload_path,
                "/bench/payload-mutex.bin",
                chunk_size,
                TransferOverwritePolicy::Replace,
                || {
                    *cancelled
                        .lock()
                        .expect("cancel mutex should not be poisoned")
                },
                |bytes| {
                    *transferred
                        .lock()
                        .expect("progress mutex should not be poisoned") = bytes;
                },
            )
            .await
            .unwrap();
        let elapsed_ms = started.elapsed().as_millis();

        // Then: remote size matches and elapsed wall time is reported
        let remote_size = client
            .remote_file_size("/bench/payload-mutex.bin")
            .await
            .unwrap();
        assert_eq!(remote_size, BENCH_BYTES as u64);
        eprintln!("bench_upload_32mib_with_mutex_progress elapsed_ms={elapsed_ms}");
    }

    #[tokio::test]
    #[ignore]
    async fn bench_download_32mib_pipelined_depth64() {
        // Given: a 32 MiB remote file and a connected client
        const BENCH_BYTES: usize = 32 * 1024 * 1024;
        let chunk_size = crate::config::DEFAULT_TRANSFER_CHUNK_SIZE_BYTES;
        let pipeline_depth = crate::config::DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH;
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        server
            .write_remote_file("/bench/full.bin", &vec![0xAB_u8; BENCH_BYTES])
            .await;

        // When: the 32 MiB file is downloaded with a default-depth pipeline
        let started = std::time::Instant::now();
        client
            .download_cancellable(
                "/bench/full.bin",
                &local_dir.path().join("full.bin"),
                chunk_size,
                pipeline_depth,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();
        let elapsed_ms = started.elapsed().as_millis();

        // Then: local file matches the remote size and elapsed time is reported
        let local_size = tokio::fs::metadata(local_dir.path().join("full.bin"))
            .await
            .unwrap()
            .len();
        assert_eq!(local_size, BENCH_BYTES as u64);
        eprintln!("bench_download_32mib_pipelined_depth64 elapsed_ms={elapsed_ms}");
    }

    #[tokio::test]
    #[ignore]
    async fn bench_download_32mib_pipelined_depth1() {
        // Given: a 32 MiB remote file and a connected client
        const BENCH_BYTES: usize = 32 * 1024 * 1024;
        let chunk_size = crate::config::DEFAULT_TRANSFER_CHUNK_SIZE_BYTES;
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        server
            .write_remote_file("/bench/full.bin", &vec![0xAB_u8; BENCH_BYTES])
            .await;

        // When: the 32 MiB file is downloaded with a depth-1 pipeline
        // (approximates the old non-pipelined read loop)
        let started = std::time::Instant::now();
        client
            .download_cancellable(
                "/bench/full.bin",
                &local_dir.path().join("full.bin"),
                chunk_size,
                1,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();
        let elapsed_ms = started.elapsed().as_millis();

        // Then: local file matches the remote size and elapsed time is reported
        let local_size = tokio::fs::metadata(local_dir.path().join("full.bin"))
            .await
            .unwrap()
            .len();
        assert_eq!(local_size, BENCH_BYTES as u64);
        eprintln!("bench_download_32mib_pipelined_depth1 elapsed_ms={elapsed_ms}");
    }

    #[tokio::test]
    #[ignore]
    async fn bench_download_high_latency_depth1() {
        // Given: a remote file, a connected client, and ~5 ms per-read latency
        const BENCH_BYTES: usize = 32 * 1024 * 1024;
        let chunk_size = crate::config::DEFAULT_TRANSFER_CHUNK_SIZE_BYTES;
        let server = TestSftpServer::start().await;
        server
            .failures
            .read_delay_ms
            .store(5, std::sync::atomic::Ordering::SeqCst);
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        server
            .write_remote_file("/bench/full.bin", &vec![0xAB_u8; BENCH_BYTES])
            .await;

        // When: the file is downloaded serially (depth-1 pipeline)
        let started = std::time::Instant::now();
        client
            .download_cancellable(
                "/bench/full.bin",
                &local_dir.path().join("full.bin"),
                chunk_size,
                1,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();
        let elapsed_ms = started.elapsed().as_millis();

        // Then: completion time is reported (dominated by latency x chunks)
        assert_eq!(
            tokio::fs::metadata(local_dir.path().join("full.bin"))
                .await
                .unwrap()
                .len(),
            BENCH_BYTES as u64
        );
        eprintln!("bench_download_high_latency_depth1 elapsed_ms={elapsed_ms}");
    }

    #[tokio::test]
    #[ignore]
    async fn bench_download_high_latency_depth64() {
        // Given: a remote file, a connected client, and ~5 ms per-read latency
        const BENCH_BYTES: usize = 32 * 1024 * 1024;
        let chunk_size = crate::config::DEFAULT_TRANSFER_CHUNK_SIZE_BYTES;
        let pipeline_depth = crate::config::DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH;
        let server = TestSftpServer::start().await;
        server
            .failures
            .read_delay_ms
            .store(5, std::sync::atomic::Ordering::SeqCst);
        let session = server.connect_session().await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        server
            .write_remote_file("/bench/full.bin", &vec![0xAB_u8; BENCH_BYTES])
            .await;

        // When: the file is downloaded with a pipelined depth of 64
        let started = std::time::Instant::now();
        client
            .download_cancellable(
                "/bench/full.bin",
                &local_dir.path().join("full.bin"),
                chunk_size,
                pipeline_depth,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();
        let elapsed_ms = started.elapsed().as_millis();

        // Then: completion time is reported (latency hidden by pipelining)
        assert_eq!(
            tokio::fs::metadata(local_dir.path().join("full.bin"))
                .await
                .unwrap()
                .len(),
            BENCH_BYTES as u64
        );
        eprintln!("bench_download_high_latency_depth64 elapsed_ms={elapsed_ms}");
    }

    /// One-way delay line: bytes leave `delay` after they arrive, preserving
    /// inter-arrival gaps so multiple in-flight SFTP packets experience RTT
    /// rather than serialized server-side sleeps.
    async fn delay_copy<R, W>(mut reader: R, mut writer: W, delay: Duration)
    where
        R: tokio::io::AsyncRead + Unpin,
        W: tokio::io::AsyncWrite + Unpin,
    {
        let mut pending: VecDeque<(Instant, Vec<u8>)> = VecDeque::new();
        let mut buf = vec![0_u8; 64 * 1024];
        let mut eof = false;
        loop {
            while let Some((when, _)) = pending.front() {
                if Instant::now() < *when {
                    break;
                }
                let data = pending.pop_front().unwrap().1;
                if writer.write_all(&data).await.is_err() {
                    return;
                }
            }
            if eof && pending.is_empty() {
                let _ = writer.shutdown().await;
                return;
            }
            if eof {
                let wait = pending
                    .front()
                    .map(|(when, _)| when.saturating_duration_since(Instant::now()))
                    .unwrap_or(Duration::ZERO);
                tokio::time::sleep(wait).await;
                continue;
            }
            if let Some((when, _)) = pending.front() {
                let wait = when.saturating_duration_since(Instant::now());
                tokio::select! {
                    n = reader.read(&mut buf) => {
                        match n {
                            Ok(0) | Err(_) => eof = true,
                            Ok(n) => pending.push_back((Instant::now() + delay, buf[..n].to_vec())),
                        }
                    }
                    _ = tokio::time::sleep(wait) => {}
                }
            } else {
                match reader.read(&mut buf).await {
                    Ok(0) | Err(_) => eof = true,
                    Ok(n) => pending.push_back((Instant::now() + delay, buf[..n].to_vec())),
                }
            }
        }
    }

    async fn spawn_tcp_delay_proxy(upstream: SocketAddr, one_way: Duration) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((client, _)) = listener.accept().await else {
                    break;
                };
                tokio::spawn(async move {
                    let Ok(server) = TcpStream::connect(upstream).await else {
                        return;
                    };
                    let _ = client.set_nodelay(true);
                    let _ = server.set_nodelay(true);
                    let (client_reader, client_writer) = client.into_split();
                    let (server_reader, server_writer) = server.into_split();
                    let to_server = tokio::spawn(delay_copy(client_reader, server_writer, one_way));
                    let to_client = tokio::spawn(delay_copy(server_reader, client_writer, one_way));
                    let _ = tokio::join!(to_server, to_client);
                });
            }
        });
        addr
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore]
    async fn bench_download_rtt_proxy_depth1_vs_64() {
        // Given: 16 MiB remote file, ~40 ms RTT (20 ms each way) on the TCP path
        const BENCH_BYTES: usize = 16 * 1024 * 1024;
        const WARMUP_BYTES: usize = 256 * 1024;
        let chunk_size = crate::config::DEFAULT_TRANSFER_CHUNK_SIZE_BYTES;
        let one_way = Duration::from_millis(20);
        let server = TestSftpServer::start().await;
        let proxy_addr = spawn_tcp_delay_proxy(server.addr, one_way).await;
        let session = server.connect_session_to(proxy_addr.port()).await;
        let client = SftpClient::new(&session);
        let local_dir = tempfile::tempdir().unwrap();
        server
            .write_remote_file("/bench/warmup.bin", &vec![0xCD_u8; WARMUP_BYTES])
            .await;
        server
            .write_remote_file("/bench/full.bin", &vec![0xAB_u8; BENCH_BYTES])
            .await;
        client
            .download_cancellable(
                "/bench/warmup.bin",
                &local_dir.path().join("warmup.bin"),
                chunk_size,
                64,
                TransferOverwritePolicy::Replace,
                || false,
                |_| {},
            )
            .await
            .unwrap();

        let mut depth1_ms = Vec::new();
        let mut depth64_ms = Vec::new();
        for round in 0..3 {
            for depth in [1_usize, 64_usize] {
                let local_path = local_dir.path().join(format!("full-d{depth}-r{round}.bin"));
                let started = Instant::now();
                client
                    .download_cancellable(
                        "/bench/full.bin",
                        &local_path,
                        chunk_size,
                        depth,
                        TransferOverwritePolicy::Replace,
                        || false,
                        |_| {},
                    )
                    .await
                    .unwrap();
                let elapsed_ms = started.elapsed().as_millis();
                let local_size = tokio::fs::metadata(&local_path).await.unwrap().len();
                assert_eq!(local_size, BENCH_BYTES as u64);
                eprintln!(
                    "bench_download_rtt_proxy round={round} depth={depth} elapsed_ms={elapsed_ms}"
                );
                if depth == 1 {
                    depth1_ms.push(elapsed_ms);
                } else {
                    depth64_ms.push(elapsed_ms);
                }
            }
        }
        let mean1 = depth1_ms.iter().sum::<u128>() / depth1_ms.len() as u128;
        let mean64 = depth64_ms.iter().sum::<u128>() / depth64_ms.len() as u128;
        eprintln!(
            "bench_download_rtt_proxy summary one_way_ms=20 bytes={BENCH_BYTES} mean_depth1_ms={mean1} mean_depth64_ms={mean64}"
        );
    }
}
