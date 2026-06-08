use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use crate::config::AppConfig;
use crate::error::TransferError;
use crate::sftp::SftpClient;
use crate::ssh::SshSession;

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
}

/// Sequential transfer queue manager.
pub struct TransferManager {
    next_id: AtomicU64,
    retry_count: u32,
    tasks: Mutex<Vec<TransferTask>>,
}

impl TransferManager {
    /// Creates a manager using retry settings from application config.
    pub fn new(config: &AppConfig) -> Self {
        Self {
            next_id: AtomicU64::new(1),
            retry_count: config.transfer_retry_count,
            tasks: Mutex::new(Vec::new()),
        }
    }

    /// Returns a snapshot of all transfer tasks.
    pub fn get_transfer_queue(&self) -> Vec<TransferTask> {
        self.tasks
            .lock()
            .map(|tasks| tasks.clone())
            .unwrap_or_default()
    }

    /// Cancels a transfer task.
    ///
    /// Currently a stub that always succeeds.
    pub fn cancel_transfer(&self, _task_id: u64) -> Result<(), TransferError> {
        Ok(())
    }

    fn record_task(&self, task: &TransferTask) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.push(task.clone());
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
        let mut task = TransferTask {
            id: self.next_id.fetch_add(1, Ordering::Relaxed),
            direction: TransferDirection::Upload,
            local_path: local_path.clone(),
            remote_path: remote_path.clone(),
            status: TransferStatus::Pending,
        };

        self.run_upload_with_retries(session, &mut task, &local_path, &remote_path)
            .await?;
        self.record_task(&task);

        Ok(task)
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
        let mut task = TransferTask {
            id: self.next_id.fetch_add(1, Ordering::Relaxed),
            direction: TransferDirection::Download,
            local_path: local_path.clone(),
            remote_path: remote_path.clone(),
            status: TransferStatus::Pending,
        };

        self.run_download_with_retries(session, &mut task, &remote_path, &local_path)
            .await?;
        self.record_task(&task);

        Ok(task)
    }

    async fn run_upload_with_retries(
        &self,
        session: &SshSession,
        task: &mut TransferTask,
        local_path: &Path,
        remote_path: &str,
    ) -> Result<(), TransferError> {
        task.status = TransferStatus::InProgress;
        let client = SftpClient::new(session);
        let attempts = self.retry_count.max(1);
        let mut last_error = String::from("unknown transfer error");

        for attempt in 1..=attempts {
            match client.upload(local_path, remote_path).await {
                Ok(()) => {
                    task.status = TransferStatus::Completed;
                    return Ok(());
                }
                Err(err) => {
                    last_error = err.to_string();
                    if attempt < attempts {
                        tracing::warn!(
                            task_id = task.id,
                            attempt,
                            max_attempts = attempts,
                            "upload attempt failed, retrying"
                        );
                    }
                }
            }
        }

        task.status = TransferStatus::Failed {
            message: last_error.clone(),
        };
        Err(TransferError::RetriesExhausted {
            attempts,
            message: last_error,
        })
    }

    async fn run_download_with_retries(
        &self,
        session: &SshSession,
        task: &mut TransferTask,
        remote_path: &str,
        local_path: &Path,
    ) -> Result<(), TransferError> {
        task.status = TransferStatus::InProgress;
        let client = SftpClient::new(session);
        let attempts = self.retry_count.max(1);
        let mut last_error = String::from("unknown transfer error");

        for attempt in 1..=attempts {
            match client.download(remote_path, local_path).await {
                Ok(()) => {
                    task.status = TransferStatus::Completed;
                    return Ok(());
                }
                Err(err) => {
                    last_error = err.to_string();
                    if attempt < attempts {
                        tracing::warn!(
                            task_id = task.id,
                            attempt,
                            max_attempts = attempts,
                            "download attempt failed, retrying"
                        );
                    }
                }
            }
        }

        task.status = TransferStatus::Failed {
            message: last_error.clone(),
        };
        Err(TransferError::RetriesExhausted {
            attempts,
            message: last_error,
        })
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
}
