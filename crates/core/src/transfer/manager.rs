use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rand::RngExt as _;

use crate::config::{AppConfig, DirectoryWalkLimits};
use crate::error::{SftpError, TransferError};
use crate::sftp::{
    ensure_local_path_within_root, is_local_directory, join_remote_path, local_entry_name,
    normalize_remote_path, walk_local_directory_with_options, walk_remote_directory_with_limits,
    SftpClient, WalkLocalDirectoryOptions,
};
use crate::ssh::SshSession;
use crate::transfer::TransferOverwritePolicy;

/// Direction of a file transfer task.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferDirection {
    Upload,
    Download,
}

/// Lifecycle status of a transfer task.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransferStatus {
    Pending,
    InProgress,
    Completed,
    Failed { message: String },
    Cancelled,
}

/// A queued file transfer operation.
#[derive(Debug, Clone)]
pub struct TransferTask {
    pub id: u64,
    pub direction: TransferDirection,
    pub local_path: PathBuf,
    pub remote_path: String,
    pub status: TransferStatus,
    pub bytes_transferred: u64,
    pub total_bytes: u64,
}

/// Sequential transfer queue manager.
pub struct TransferManager {
    next_id: AtomicU64,
    retry_count: u32,
    chunk_size: usize,
    download_pipeline_depth: usize,
    directory_walk_limits: DirectoryWalkLimits,
    tasks: Mutex<Vec<TransferTask>>,
    cancellation_flags: Mutex<HashMap<u64, Arc<AtomicBool>>>,
    /// Fixed backoff delay in milliseconds between retries, used by tests to
    /// avoid real sleeping. `None` uses the exponential jittered backoff.
    #[cfg(test)]
    backoff_override_ms: Option<u64>,
}

impl TransferManager {
    /// Creates a manager using retry settings from application config.
    pub fn new(config: &AppConfig) -> Self {
        Self {
            next_id: AtomicU64::new(1),
            retry_count: config.transfer_retry_count,
            chunk_size: config.transfer_chunk_size_bytes,
            download_pipeline_depth: config.transfer_download_pipeline_depth,
            directory_walk_limits: config.directory_walk_limits(),
            tasks: Mutex::new(Vec::new()),
            cancellation_flags: Mutex::new(HashMap::new()),
            #[cfg(test)]
            backoff_override_ms: None,
        }
    }

    /// Returns a snapshot of all transfer tasks.
    pub fn get_transfer_queue(&self) -> Vec<TransferTask> {
        self.tasks
            .lock()
            .map(|tasks| tasks.clone())
            .unwrap_or_default()
    }

    /// Removes completed, failed, and cancelled tasks from the queue.
    pub fn clear_completed_transfers(&self) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.retain(|task| {
                matches!(
                    task.status,
                    TransferStatus::Pending | TransferStatus::InProgress
                )
            });
        }
    }

    /// Removes every task from the queue, cancelling active transfers first.
    pub fn clear_all_transfers(&self) -> Result<(), TransferError> {
        let active_ids: Vec<u64> = self
            .get_transfer_queue()
            .into_iter()
            .filter(|task| {
                matches!(
                    task.status,
                    TransferStatus::Pending | TransferStatus::InProgress
                )
            })
            .map(|task| task.id)
            .collect();

        for task_id in active_ids {
            let _ = self.cancel_transfer(task_id);
        }

        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.clear();
        }

        Ok(())
    }

    /// Re-enqueues a failed or cancelled transfer task.
    pub async fn retry_transfer(
        &self,
        session: &SshSession,
        task_id: u64,
    ) -> Result<TransferTask, TransferError> {
        let task = self
            .find_task(task_id)
            .ok_or(TransferError::TaskNotFound { task_id })?;

        match task.status {
            TransferStatus::Failed { .. } | TransferStatus::Cancelled => {}
            _ => return Err(TransferError::TaskNotFound { task_id }),
        }

        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.retain(|existing| existing.id != task_id);
        }
        self.remove_cancellation_flag(task_id);

        match task.direction {
            TransferDirection::Upload => {
                self.enqueue_upload(session, &task.local_path, &task.remote_path)
                    .await
            }
            TransferDirection::Download => {
                self.enqueue_download(session, &task.remote_path, &task.local_path)
                    .await
            }
        }
    }

    /// Cancels a pending or in-progress transfer task.
    pub fn cancel_transfer(&self, task_id: u64) -> Result<(), TransferError> {
        let mut tasks = self
            .tasks
            .lock()
            .map_err(|_| TransferError::TaskNotFound { task_id })?;

        let task = tasks
            .iter_mut()
            .find(|task| task.id == task_id)
            .ok_or(TransferError::TaskNotFound { task_id })?;

        match task.status {
            TransferStatus::Pending | TransferStatus::InProgress => {
                self.request_cancellation(task_id);
                task.status = TransferStatus::Cancelled;
                Ok(())
            }
            _ => Err(TransferError::TaskNotFound { task_id }),
        }
    }

    fn insert_task(&self, task: TransferTask) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.push(task);
        }
    }

    fn update_task_status(&self, task_id: u64, status: TransferStatus) {
        if let Ok(mut tasks) = self.tasks.lock() {
            if let Some(task) = tasks.iter_mut().find(|task| task.id == task_id) {
                task.status = status;
            }
        }
    }

    fn set_task_total_bytes(&self, task_id: u64, total_bytes: u64) {
        if let Ok(mut tasks) = self.tasks.lock() {
            if let Some(task) = tasks.iter_mut().find(|task| task.id == task_id) {
                task.total_bytes = total_bytes;
            }
        }
    }

    fn reset_task_progress(&self, task_id: u64) {
        if let Ok(mut tasks) = self.tasks.lock() {
            if let Some(task) = tasks.iter_mut().find(|task| task.id == task_id) {
                task.bytes_transferred = 0;
            }
        }
    }

    fn update_task_progress(&self, task_id: u64, bytes_transferred: u64) {
        if let Ok(mut tasks) = self.tasks.lock() {
            if let Some(task) = tasks.iter_mut().find(|task| task.id == task_id) {
                task.bytes_transferred = bytes_transferred;
            }
        }
    }

    fn mark_task_progress_complete(&self, task_id: u64) {
        if let Ok(mut tasks) = self.tasks.lock() {
            if let Some(task) = tasks.iter_mut().find(|task| task.id == task_id) {
                if task.total_bytes > 0 {
                    task.bytes_transferred = task.total_bytes;
                }
            }
        }
    }

    fn find_task(&self, task_id: u64) -> Option<TransferTask> {
        self.tasks
            .lock()
            .ok()
            .and_then(|tasks| tasks.iter().find(|task| task.id == task_id).cloned())
    }

    fn register_cancellation_flag(&self, task_id: u64) {
        if let Ok(mut flags) = self.cancellation_flags.lock() {
            flags
                .entry(task_id)
                .or_insert_with(|| Arc::new(AtomicBool::new(false)));
        }
    }

    fn remove_cancellation_flag(&self, task_id: u64) {
        if let Ok(mut flags) = self.cancellation_flags.lock() {
            flags.remove(&task_id);
        }
    }

    fn request_cancellation(&self, task_id: u64) {
        if let Ok(mut flags) = self.cancellation_flags.lock() {
            let flag = flags
                .entry(task_id)
                .or_insert_with(|| Arc::new(AtomicBool::new(false)));
            flag.store(true, Ordering::Relaxed);
        }
    }

    fn is_cancelled(&self, task_id: u64) -> bool {
        self.cancellation_flags
            .lock()
            .ok()
            .and_then(|flags| flags.get(&task_id).map(|flag| flag.load(Ordering::Relaxed)))
            .unwrap_or(false)
    }

    fn finalize_task_result(
        &self,
        task_id: u64,
        result: Result<(), TransferError>,
    ) -> Result<(), TransferError> {
        let was_cancelled = self.is_cancelled(task_id);
        self.remove_cancellation_flag(task_id);

        if was_cancelled {
            return match result {
                Ok(()) => {
                    self.update_task_status(task_id, TransferStatus::Completed);
                    Ok(())
                }
                Err(TransferError::Cancelled) => {
                    self.update_task_status(task_id, TransferStatus::Cancelled);
                    Err(TransferError::Cancelled)
                }
                Err(err) => {
                    let message = format!(
                        "転送はキャンセルされましたが、部分ファイルの削除に失敗しました: {err}"
                    );
                    self.update_task_status(
                        task_id,
                        TransferStatus::Failed {
                            message: message.clone(),
                        },
                    );
                    Err(TransferError::RetriesExhausted {
                        attempts: 1,
                        message,
                    })
                }
            };
        }

        match result {
            Ok(()) => {
                self.mark_task_progress_complete(task_id);
                self.update_task_status(task_id, TransferStatus::Completed);
                Ok(())
            }
            Err(TransferError::Cancelled) => {
                self.update_task_status(task_id, TransferStatus::Cancelled);
                Err(TransferError::Cancelled)
            }
            Err(err) => {
                self.update_task_status(
                    task_id,
                    TransferStatus::Failed {
                        message: err.to_string(),
                    },
                );
                Err(err)
            }
        }
    }

    /// Enqueues and immediately executes a single upload task.
    pub async fn enqueue_upload(
        &self,
        session: &SshSession,
        local_path: impl AsRef<Path>,
        remote_path: impl Into<String>,
    ) -> Result<TransferTask, TransferError> {
        let local_path = local_path.as_ref().to_path_buf();
        let remote_path = remote_path.into();

        let task = TransferTask {
            id: self.next_id.fetch_add(1, Ordering::Relaxed),
            direction: TransferDirection::Upload,
            local_path: local_path.clone(),
            remote_path: remote_path.clone(),
            status: TransferStatus::Pending,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        self.insert_task(task.clone());
        self.register_cancellation_flag(task.id);
        self.update_task_status(task.id, TransferStatus::InProgress);

        if self.is_cancelled(task.id) {
            self.finalize_task_result(task.id, Err(TransferError::Cancelled))?;
        }

        let result = self
            .run_upload_with_retries(session, task.id, &local_path, &remote_path)
            .await;

        self.finalize_task_result(task.id, result)?;

        Ok(self.find_task(task.id).unwrap_or(task))
    }

    /// Enqueues and immediately executes a single download task.
    pub async fn enqueue_download(
        &self,
        session: &SshSession,
        remote_path: impl Into<String>,
        local_path: impl AsRef<Path>,
    ) -> Result<TransferTask, TransferError> {
        let remote_path = remote_path.into();
        let local_path = local_path.as_ref().to_path_buf();

        let task = TransferTask {
            id: self.next_id.fetch_add(1, Ordering::Relaxed),
            direction: TransferDirection::Download,
            local_path: local_path.clone(),
            remote_path: remote_path.clone(),
            status: TransferStatus::Pending,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        self.insert_task(task.clone());
        self.register_cancellation_flag(task.id);
        self.update_task_status(task.id, TransferStatus::InProgress);

        if self.is_cancelled(task.id) {
            self.finalize_task_result(task.id, Err(TransferError::Cancelled))?;
        }

        let result = self
            .run_download_with_retries(session, task.id, &remote_path, &local_path)
            .await;

        self.finalize_task_result(task.id, result)?;

        Ok(self.find_task(task.id).unwrap_or(task))
    }

    /// Enqueues and executes upload tasks for a local file or directory tree.
    pub async fn enqueue_upload_entry(
        &self,
        session: &SshSession,
        local_path: impl AsRef<std::path::Path>,
        remote_directory: impl Into<String>,
    ) -> Result<Vec<TransferTask>, TransferError> {
        let local_path = local_path.as_ref();
        let remote_directory = remote_directory.into();
        let client = SftpClient::new(session);

        if is_local_directory(local_path)
            .await
            .map_err(transfer_error_from_sftp)?
        {
            let directory_name = local_entry_name(local_path);
            let remote_root =
                join_remote_path(&remote_directory, std::path::Path::new(&directory_name))
                    .map_err(transfer_error_from_sftp)?;
            client
                .create_directory_all(&remote_root)
                .await
                .map_err(transfer_error_from_sftp)?;

            let files = walk_local_directory_with_options(
                local_path,
                WalkLocalDirectoryOptions {
                    limits: self.directory_walk_limits,
                    ..Default::default()
                },
            )
            .await
            .map_err(transfer_error_from_sftp)?;
            let mut tasks = Vec::with_capacity(files.len());
            for entry in files {
                let remote_path = join_remote_path(&remote_root, &entry.relative_path)
                    .map_err(transfer_error_from_sftp)?;
                if let Some(parent) =
                    parent_remote_path(&remote_path).map_err(transfer_error_from_sftp)?
                {
                    client
                        .create_directory_all(&parent)
                        .await
                        .map_err(transfer_error_from_sftp)?;
                }
                let task = self
                    .enqueue_upload(session, &entry.local_path, remote_path)
                    .await?;
                tasks.push(task);
            }
            return Ok(tasks);
        }

        let remote_path = join_remote_path(
            &remote_directory,
            std::path::Path::new(&local_entry_name(local_path)),
        )
        .map_err(transfer_error_from_sftp)?;
        if let Some(parent) = parent_remote_path(&remote_path).map_err(transfer_error_from_sftp)? {
            client
                .create_directory_all(&parent)
                .await
                .map_err(transfer_error_from_sftp)?;
        }
        let task = self
            .enqueue_upload(session, local_path, remote_path)
            .await?;
        Ok(vec![task])
    }

    /// Enqueues and executes download tasks for a remote file or directory tree.
    pub async fn enqueue_download_entry(
        &self,
        session: &SshSession,
        remote_path: impl Into<String>,
        local_directory: impl AsRef<std::path::Path>,
    ) -> Result<Vec<TransferTask>, TransferError> {
        let remote_path = remote_path.into();
        let local_directory = local_directory.as_ref();
        let normalized = normalize_remote_path(&remote_path).map_err(transfer_error_from_sftp)?;
        let client = SftpClient::new(session);

        if client
            .remote_is_directory(&normalized)
            .await
            .map_err(transfer_error_from_sftp)?
        {
            let entries = client
                .list_directory(&normalized)
                .await
                .map_err(transfer_error_from_sftp)?;
            let directory_name = normalized
                .trim_end_matches('/')
                .rsplit('/')
                .next()
                .filter(|name| !name.is_empty())
                .unwrap_or("download");
            let local_root = local_directory.join(directory_name);
            tokio::fs::create_dir_all(&local_root)
                .await
                .map_err(|err| transfer_error_from_message(err.to_string()))?;

            if entries.is_empty() {
                return Ok(Vec::new());
            }

            let files =
                walk_remote_directory_with_limits(&client, &normalized, self.directory_walk_limits)
                    .await
                    .map_err(transfer_error_from_sftp)?;
            let mut tasks = Vec::with_capacity(files.len());
            for entry in files {
                let local_path = local_root.join(&entry.relative_path);
                ensure_local_path_within_root(&local_root, &local_path)
                    .map_err(transfer_error_from_sftp)?;
                if let Some(parent) = local_path.parent() {
                    tokio::fs::create_dir_all(parent)
                        .await
                        .map_err(|err| transfer_error_from_message(err.to_string()))?;
                }
                let task = self
                    .enqueue_download(session, &entry.remote_path, &local_path)
                    .await?;
                tasks.push(task);
            }
            Ok(tasks)
        } else {
            let file_name = normalized
                .rsplit('/')
                .next()
                .filter(|name| !name.is_empty())
                .unwrap_or("download");
            let local_path = local_directory.join(file_name);
            let task = self
                .enqueue_download(session, &normalized, &local_path)
                .await?;
            Ok(vec![task])
        }
    }

    async fn run_upload_with_retries(
        &self,
        session: &SshSession,
        task_id: u64,
        local_path: &Path,
        remote_path: &str,
    ) -> Result<(), TransferError> {
        let client = SftpClient::new(session);
        let total_bytes = tokio::fs::metadata(local_path)
            .await
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        self.set_task_total_bytes(task_id, total_bytes);

        // `retry_count` config means the number of RETRIES after the first
        // attempt (issue #310): `transfer_retry_count = 3` performs 3
        // retries, i.e. up to 4 attempts total.
        let attempts = self.retry_count.saturating_add(1).max(1);
        let mut last_error = String::from("unknown transfer error");
        let mut attempt = 0;

        let mut retry_index = 0_u32;
        for current in 1..=attempts {
            if self.is_cancelled(task_id) {
                return Err(TransferError::Cancelled);
            }

            attempt = current;
            self.reset_task_progress(task_id);
            match client
                .upload_cancellable(
                    local_path,
                    remote_path,
                    self.chunk_size,
                    TransferOverwritePolicy::default(),
                    || self.is_cancelled(task_id),
                    |transferred| self.update_task_progress(task_id, transferred),
                )
                .await
            {
                Ok(()) => return Ok(()),
                Err(SftpError::Cancelled) => return Err(TransferError::Cancelled),
                Err(SftpError::CleanupFailed { message, .. }) if self.is_cancelled(task_id) => {
                    return Err(TransferError::RetriesExhausted {
                        attempts: 1,
                        message: format!(
                            "転送はキャンセルされましたが、部分ファイルの削除に失敗しました: {message}"
                        ),
                    });
                }
                Err(err) => {
                    last_error = err.to_string();
                    if is_non_retryable_transfer_error(&last_error) {
                        break;
                    }
                    if current < attempts {
                        // Exponential backoff with jitter between retries;
                        // still abortable while waiting.
                        retry_index = retry_index.saturating_add(1);
                        if self.sleep_backoff(task_id, retry_index).await {
                            return Err(TransferError::Cancelled);
                        }
                        tracing::warn!(
                            task_id,
                            attempt = current,
                            max_attempts = attempts,
                            "upload attempt failed, retrying"
                        );
                    }
                }
            }
        }

        Err(TransferError::RetriesExhausted {
            attempts: attempt.max(1),
            message: last_error,
        })
    }

    /// Sleeps with exponential backoff + jitter (1s, 2s, 4s, ... capped at 30s)
    /// between retry attempts. Returns `true` when the transfer was cancelled
    /// during the wait (so the caller aborts immediately).
    async fn sleep_backoff(&self, task_id: u64, retry_index: u32) -> bool {
        #[cfg(test)]
        let delay = Duration::from_millis(
            self.backoff_override_ms
                .unwrap_or_else(|| backoff_delay_ms(retry_index)),
        );
        #[cfg(not(test))]
        let delay = Duration::from_millis(backoff_delay_ms(retry_index));

        tracing::info!(
            task_id,
            retry_backoff_ms = delay.as_millis(),
            "waiting before retrying transfer"
        );

        tokio::time::timeout(delay, async {
            loop {
                if self.is_cancelled(task_id) {
                    return true;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .is_ok_and(|cancelled| cancelled)
    }

    async fn run_download_with_retries(
        &self,
        session: &SshSession,
        task_id: u64,
        remote_path: &str,
        local_path: &Path,
    ) -> Result<(), TransferError> {
        let client = SftpClient::new(session);
        let total_bytes = client.remote_file_size(remote_path).await.unwrap_or(0);
        self.set_task_total_bytes(task_id, total_bytes);

        // `retry_count` config means the number of RETRIES after the first
        // attempt (issue #310).
        let attempts = self.retry_count.saturating_add(1).max(1);
        let mut last_error = String::from("unknown transfer error");
        let mut attempt = 0;

        let mut retry_index = 0_u32;
        for current in 1..=attempts {
            if self.is_cancelled(task_id) {
                return Err(TransferError::Cancelled);
            }

            attempt = current;
            self.reset_task_progress(task_id);
            match client
                .download_cancellable(
                    remote_path,
                    local_path,
                    self.chunk_size,
                    self.download_pipeline_depth,
                    TransferOverwritePolicy::default(),
                    || self.is_cancelled(task_id),
                    |transferred| self.update_task_progress(task_id, transferred),
                )
                .await
            {
                Ok(()) => return Ok(()),
                Err(SftpError::Cancelled) => return Err(TransferError::Cancelled),
                Err(SftpError::CleanupFailed { message, .. }) if self.is_cancelled(task_id) => {
                    return Err(TransferError::RetriesExhausted {
                        attempts: 1,
                        message: format!(
                            "転送はキャンセルされましたが、部分ファイルの削除に失敗しました: {message}"
                        ),
                    });
                }
                Err(err) => {
                    last_error = err.to_string();
                    if is_non_retryable_transfer_error(&last_error) {
                        break;
                    }
                    if current < attempts {
                        // Exponential backoff with jitter between retries;
                        // still abortable while waiting.
                        retry_index = retry_index.saturating_add(1);
                        if self.sleep_backoff(task_id, retry_index).await {
                            return Err(TransferError::Cancelled);
                        }
                        tracing::warn!(
                            task_id,
                            attempt = current,
                            max_attempts = attempts,
                            "download attempt failed, retrying"
                        );
                    }
                }
            }
        }

        Err(TransferError::RetriesExhausted {
            attempts: attempt.max(1),
            message: last_error,
        })
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

/// Returns the exponential-backoff delay in milliseconds for retry
/// `retry_index` (1-based), with 50%..100% jitter. Sequence: ~1s, ~2s, ~4s,
/// ... capped at 30s.
fn backoff_delay_ms(retry_index: u32) -> u64 {
    const BACKOFF_BASE_MS: u64 = 1_000;
    const BACKOFF_MAX_MS: u64 = 30_000;

    let exponent = (retry_index.saturating_sub(1)).min(6);
    let base = BACKOFF_BASE_MS.saturating_mul(1_u64 << exponent);
    let capped = base.min(BACKOFF_MAX_MS);
    // Jitter: 50%..100% of the computed delay to avoid thundering herds.
    rand::rng().random_range(capped / 2..=capped)
}

/// Returns `true` when retrying the same transfer is unlikely to succeed.
pub(crate) fn is_non_retryable_transfer_error(message: &str) -> bool {
    let lower = message.to_lowercase();
    crate::ssh::is_connection_lost_message(message)
        || lower.contains("permission denied")
        || lower.contains("failure")
        || lower.contains("no such file")
        || lower.contains("already exists and overwrite is disabled")
        || lower.contains("failed to create directory")
}

fn transfer_error_from_sftp(error: SftpError) -> TransferError {
    match error {
        SftpError::Cancelled => TransferError::Cancelled,
        other => TransferError::RetriesExhausted {
            attempts: 1,
            message: other.to_string(),
        },
    }
}

fn transfer_error_from_message(message: String) -> TransferError {
    TransferError::RetriesExhausted {
        attempts: 1,
        message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::sftp::test_server::TestSftpServer;

    #[test]
    fn creates_monotonic_task_ids() {
        let manager = TransferManager::new(&AppConfig::default());
        assert_eq!(manager.next_id.load(Ordering::Relaxed), 1);
        assert_eq!(manager.next_id.fetch_add(1, Ordering::Relaxed), 1);
        assert_eq!(manager.next_id.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn insert_task_records_pending_status() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 1,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::Pending,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        manager.insert_task(task);

        let queue = manager.get_transfer_queue();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].status, TransferStatus::Pending);
    }

    #[test]
    fn update_task_status_changes_recorded_task() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 42,
            direction: TransferDirection::Download,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::Pending,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        manager.insert_task(task);
        manager.update_task_status(42, TransferStatus::InProgress);

        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].status, TransferStatus::InProgress);
    }

    #[test]
    fn cancel_pending_task_marks_cancelled() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 7,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::Pending,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        manager.insert_task(task);
        manager.cancel_transfer(7).unwrap();

        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].status, TransferStatus::Cancelled);
    }

    #[test]
    fn backoff_delay_is_exponential_and_capped() {
        // Jitter range is 50%..100% of the base delay:
        // first retry 0.5-1s, second 1-2s, third 2-4s.
        let d1 = backoff_delay_ms(1);
        assert!(
            (500..=1_000).contains(&d1),
            "first retry delay should be 0.5-1s: {d1}ms"
        );

        let d2 = backoff_delay_ms(2);
        assert!(
            (1_000..=2_000).contains(&d2),
            "second retry delay should be 1-2s: {d2}ms"
        );

        let d3 = backoff_delay_ms(3);
        assert!(
            (2_000..=4_000).contains(&d3),
            "third retry delay should be 2-4s: {d3}ms"
        );

        for index in [8, 20, 100] {
            let delay = backoff_delay_ms(index);
            assert!(
                (15_000..=30_000).contains(&delay),
                "large retry indexes must be capped at 30s, got {delay}ms (index {index})"
            );
        }
    }

    #[test]
    fn retry_count_means_number_of_retries_not_attempts() {
        // transfer_retry_count is stored verbatim for the retry loop to turn
        // into `retry_count + 1` attempts.
        let config_with_retries = AppConfig {
            transfer_retry_count: 3,
            ..AppConfig::default()
        };
        let manager = TransferManager::new(&config_with_retries);
        assert_eq!(manager.retry_count, 3);

        let config_zero = AppConfig {
            transfer_retry_count: 0,
            ..AppConfig::default()
        };
        let manager_zero = TransferManager::new(&config_zero);
        assert_eq!(manager_zero.retry_count, 0);
    }

    #[test]
    fn cancel_unknown_task_returns_not_found() {
        let manager = TransferManager::new(&AppConfig::default());
        let err = manager.cancel_transfer(999).unwrap_err();
        assert!(matches!(err, TransferError::TaskNotFound { task_id: 999 }));
    }

    #[test]
    fn cancel_in_progress_task_sets_cancel_flag() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 8,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        manager.insert_task(task);
        manager.register_cancellation_flag(8);
        manager.cancel_transfer(8).unwrap();

        assert!(manager.is_cancelled(8));
        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].status, TransferStatus::Cancelled);
    }

    #[test]
    fn sftp_cancelled_maps_to_transfer_cancelled() {
        let err = transfer_error_from_sftp(SftpError::Cancelled);
        assert!(matches!(err, TransferError::Cancelled));
    }

    #[test]
    fn non_retryable_errors_are_detected() {
        assert!(is_non_retryable_transfer_error("session closed"));
        assert!(is_non_retryable_transfer_error(
            "failed to upload '/a' to '/b': Permission denied"
        ));
        assert!(is_non_retryable_transfer_error("SFTP failure"));
        assert!(is_non_retryable_transfer_error("connection reset"));
        assert!(is_non_retryable_transfer_error(
            "failed to upload '/a' to '/b': No such file: No such file"
        ));
        assert!(is_non_retryable_transfer_error(
            "failed to create directory '/home/demo': Permission denied"
        ));
        assert!(is_non_retryable_transfer_error(
            "failed to upload '/a' to '/b': destination '/b' already exists and overwrite is disabled"
        ));
    }

    #[test]
    fn in_progress_task_can_be_cancelled() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 99,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::Pending,
            bytes_transferred: 0,
            total_bytes: 0,
        };
        manager.insert_task(task.clone());
        manager.register_cancellation_flag(task.id);
        manager.update_task_status(task.id, TransferStatus::InProgress);

        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].status, TransferStatus::InProgress);

        manager.cancel_transfer(99).unwrap();
        assert!(manager.is_cancelled(99));

        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].status, TransferStatus::Cancelled);
    }

    #[test]
    fn cancelled_task_is_detected_before_retry_attempt() {
        let manager = TransferManager::new(&AppConfig::default());
        manager.register_cancellation_flag(10);
        manager.request_cancellation(10);

        assert!(manager.is_cancelled(10));
    }

    #[test]
    fn finalize_task_result_marks_completed_when_transfer_succeeds_despite_cancel_flag() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 11,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        manager.insert_task(task);
        manager.register_cancellation_flag(11);
        manager.request_cancellation(11);

        manager
            .finalize_task_result(11, Ok(()))
            .expect("successful transfer should finalize as completed");

        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].status, TransferStatus::Completed);
    }

    #[test]
    fn cancel_after_rename_success_marks_transfer_completed_not_cancelled() {
        // Given: cancel was requested but rename already succeeded (Ok result)
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 13,
            direction: TransferDirection::Download,
            local_path: PathBuf::from("/tmp/downloaded.txt"),
            remote_path: "/remote/downloaded.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 1024,
            total_bytes: 1024,
        };

        manager.insert_task(task);
        manager.register_cancellation_flag(13);
        manager.request_cancellation(13);

        // When: finalize receives Ok after rename completed
        manager
            .finalize_task_result(13, Ok(()))
            .expect("post-rename success should finalize as completed");

        // Then: status is Completed, not Cancelled
        let queue = manager.get_transfer_queue();
        assert_eq!(
            queue[0].status,
            TransferStatus::Completed,
            "rename-after-cancel must prefer Completed over Cancelled"
        );
    }

    #[test]
    fn finalize_task_result_marks_cancelled_when_transfer_returns_cancelled() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 12,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        manager.insert_task(task);
        manager.register_cancellation_flag(12);
        manager.request_cancellation(12);

        let err = manager
            .finalize_task_result(12, Err(TransferError::Cancelled))
            .expect_err("cancelled transfer should not finalize as completed");

        assert!(matches!(err, TransferError::Cancelled));
        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].status, TransferStatus::Cancelled);
    }

    #[test]
    fn failed_status_is_persisted_in_queue() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 3,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::Pending,
            bytes_transferred: 0,
            total_bytes: 0,
        };

        manager.insert_task(task);
        manager.update_task_status(
            3,
            TransferStatus::Failed {
                message: "permission denied".to_string(),
            },
        );

        let queue = manager.get_transfer_queue();
        assert_eq!(
            queue[0].status,
            TransferStatus::Failed {
                message: "permission denied".to_string(),
            }
        );
    }

    #[test]
    fn set_task_total_bytes_updates_recorded_task() {
        // Given: a queued transfer task
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 100,
            direction: TransferDirection::Download,
            local_path: PathBuf::from("/tmp/file.bin"),
            remote_path: "/remote/file.bin".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 0,
        };
        manager.insert_task(task);

        // When: total bytes are set
        manager.set_task_total_bytes(100, 1_024);

        // Then: the queue reflects the total
        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].total_bytes, 1_024);
    }

    #[test]
    fn update_task_progress_updates_transferred_bytes() {
        // Given: a queued transfer task with a known total
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 101,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.bin"),
            remote_path: "/remote/file.bin".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 2_048,
        };
        manager.insert_task(task);

        // When: progress is updated
        manager.update_task_progress(101, 512);

        // Then: transferred bytes are recorded
        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].bytes_transferred, 512);
    }

    #[test]
    fn reset_task_progress_clears_transferred_bytes_on_retry() {
        // Given: a task with partial progress
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 102,
            direction: TransferDirection::Download,
            local_path: PathBuf::from("/tmp/file.bin"),
            remote_path: "/remote/file.bin".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 900,
            total_bytes: 1_000,
        };
        manager.insert_task(task);

        // When: progress is reset before a retry
        manager.reset_task_progress(102);

        // Then: transferred bytes return to zero
        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].bytes_transferred, 0);
        assert_eq!(queue[0].total_bytes, 1_000);
    }

    #[test]
    fn mark_task_progress_complete_sets_transferred_to_total() {
        // Given: a task with total bytes set
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 103,
            direction: TransferDirection::Download,
            local_path: PathBuf::from("/tmp/file.bin"),
            remote_path: "/remote/file.bin".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 500,
            total_bytes: 1_000,
        };
        manager.insert_task(task);

        // When: completion progress is applied
        manager.mark_task_progress_complete(103);

        // Then: transferred bytes match total
        let queue = manager.get_transfer_queue();
        assert_eq!(queue[0].bytes_transferred, 1_000);
    }

    #[test]
    fn clear_completed_transfers_removes_finished_tasks() {
        let manager = TransferManager::new(&AppConfig::default());
        manager.insert_task(TransferTask {
            id: 1,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/a.txt"),
            remote_path: "/remote/a.txt".to_string(),
            status: TransferStatus::Completed,
            bytes_transferred: 10,
            total_bytes: 10,
        });
        manager.insert_task(TransferTask {
            id: 2,
            direction: TransferDirection::Download,
            local_path: PathBuf::from("/tmp/b.txt"),
            remote_path: "/remote/b.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 5,
            total_bytes: 10,
        });

        manager.clear_completed_transfers();

        let queue = manager.get_transfer_queue();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].id, 2);
    }

    #[test]
    fn clear_all_transfers_cancels_active_and_empties_queue() {
        let manager = TransferManager::new(&AppConfig::default());
        manager.insert_task(TransferTask {
            id: 1,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/a.txt"),
            remote_path: "/remote/a.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 10,
        });
        manager.register_cancellation_flag(1);

        manager.clear_all_transfers().unwrap();

        assert!(manager.get_transfer_queue().is_empty());
        assert!(manager.is_cancelled(1));
    }

    #[tokio::test]
    async fn enqueue_download_transfers_remote_file_end_to_end() {
        // Given: a remote file, a session, and a manager fed by default config
        let server = TestSftpServer::start().await;
        let payload: Vec<u8> = (0..5 * 1024 * 1024).map(|i| (i * 13) as u8).collect();
        server
            .write_remote_file("/download/e2e.bin", &payload)
            .await;
        let session = server.connect_session().await;
        let manager = TransferManager::new(&AppConfig::default());
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("e2e.bin");

        // When: a download task is enqueued (goes through the retry loop and the
        // pipelined download path)
        let task = manager
            .enqueue_download(&session, "/download/e2e.bin", &local_path)
            .await
            .expect("download should succeed");

        // Then: the task is completed and the local bytes match the source
        assert!(matches!(task.status, TransferStatus::Completed));
        assert_eq!(task.total_bytes, payload.len() as u64);
        assert_eq!(task.bytes_transferred, payload.len() as u64);
        let downloaded = tokio::fs::read(&local_path).await.unwrap();
        assert_eq!(downloaded, payload);
        assert!(
            crate::sftp::test_server::list_partial_paths(local_dir.path()).is_empty(),
            "no partial files may remain"
        );
    }

    #[tokio::test]
    async fn upload_retries_and_succeeds_after_one_write_failure() {
        // Given: a manager configured for exactly one retry, no backoff delay,
        // and a server whose first WRITE fails (one-shot).
        let config = AppConfig {
            transfer_retry_count: 1,
            ..AppConfig::default()
        };
        let mut manager = TransferManager::new(&config);
        manager.backoff_override_ms = Some(0);

        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("retry.bin");
        let payload = vec![0x5Au8; 512 * 1024];
        tokio::fs::write(&local_path, &payload).await.unwrap();

        server
            .failures
            .fail_remote_write
            .store(true, Ordering::SeqCst);

        // When: an upload task is enqueued; the first attempt fails mid-write,
        // and the retry (with backoff) succeeds.
        let task = manager
            .enqueue_upload(&session, &local_path, "/upload/retry.bin")
            .await
            .expect("upload should succeed after one retry");

        // Then: the task completes and the remote bytes match.
        assert!(matches!(task.status, TransferStatus::Completed));
        let remote_bytes = tokio::fs::read(server.root.join("upload/retry.bin"))
            .await
            .unwrap();
        assert_eq!(remote_bytes, payload);
    }

    #[tokio::test]
    async fn upload_retry_count_zero_does_not_retry() {
        // Given: a manager with retries disabled and a server whose first
        // WRITE fails.
        let config = AppConfig {
            transfer_retry_count: 0,
            ..AppConfig::default()
        };
        let manager = TransferManager::new(&config);

        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("no-retry.bin");
        tokio::fs::write(&local_path, b"payload").await.unwrap();

        server
            .failures
            .fail_remote_write
            .store(true, Ordering::SeqCst);

        // When: an upload task is enqueued with retries disabled
        let task = manager
            .enqueue_upload(&session, &local_path, "/upload/no-retry.bin")
            .await
            .expect_err("upload should fail without retries");

        // Then: it fails with RetriesExhausted and exactly 1 attempt reported.
        assert!(matches!(
            task,
            TransferError::RetriesExhausted { attempts: 1, .. }
        ));
    }

    #[tokio::test]
    async fn retry_sleep_aborts_when_cancelled_during_backoff() {
        // Given: a manager with retries enabled, a server whose first WRITE
        // fails (one-shot), and the real exponential backoff so the retry is
        // still waiting when we cancel.
        let config = AppConfig {
            transfer_retry_count: 5,
            ..AppConfig::default()
        };
        let manager = Arc::new(TransferManager::new(&config));

        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("cancelled-retry.bin");
        tokio::fs::write(&local_path, b"payload").await.unwrap();

        server
            .failures
            .fail_remote_write
            .store(true, Ordering::SeqCst);

        // When: an upload task is spawned, then cancelled while it waits on
        // the exponential backoff before retrying.
        let manager_for_task = Arc::clone(&manager);
        let upload = tokio::spawn(async move {
            manager_for_task
                .enqueue_upload(&session, &local_path, "/upload/cancelled-retry.bin")
                .await
        });

        // Give the transfer a moment to fail the first write and enter the
        // backoff sleep (first retry waits 0.5-1s without override), then
        // cancel while it is sleeping.
        tokio::time::sleep(Duration::from_millis(300)).await;
        let tasks = manager.tasks.lock().unwrap();
        let task_id = tasks
            .iter()
            .find(|task| task.local_path.ends_with("cancelled-retry.bin"))
            .map(|task| task.id)
            .unwrap_or_else(|| panic!("task not found"));
        drop(tasks);

        let cancel_result = manager.cancel_transfer(task_id);
        assert!(
            cancel_result.is_ok(),
            "task should be cancellable: {cancel_result:?}"
        );

        // Then: the spawned upload finishes with an error (cancelled at the
        // next check boundary) and the task settles as Cancelled.
        let result = upload.await.unwrap();
        assert!(result.is_err(), "upload should not complete");
        let status = manager
            .tasks
            .lock()
            .unwrap()
            .iter()
            .find(|task| task.id == task_id)
            .map(|task| task.status.clone())
            .unwrap();
        assert_eq!(status, TransferStatus::Cancelled);
    }
}
