use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

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
    directory_walk_limits: DirectoryWalkLimits,
    tasks: Mutex<Vec<TransferTask>>,
    cancellation_flags: Mutex<HashMap<u64, Arc<AtomicBool>>>,
}

impl TransferManager {
    /// Creates a manager using retry settings from application config.
    pub fn new(config: &AppConfig) -> Self {
        Self {
            next_id: AtomicU64::new(1),
            retry_count: config.transfer_retry_count,
            chunk_size: config.transfer_chunk_size_bytes,
            directory_walk_limits: config.directory_walk_limits(),
            tasks: Mutex::new(Vec::new()),
            cancellation_flags: Mutex::new(HashMap::new()),
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

        let attempts = self.retry_count.max(1);
        let mut last_error = String::from("unknown transfer error");
        let mut attempt = 0;

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

        let attempts = self.retry_count.max(1);
        let mut last_error = String::from("unknown transfer error");
        let mut attempt = 0;

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
}
