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

    /// Cancels a pending transfer task.
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
            TransferStatus::Pending => {
                task.status = TransferStatus::Cancelled;
                Ok(())
            }
            TransferStatus::InProgress => Err(TransferError::Cancelled),
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

    fn find_task(&self, task_id: u64) -> Option<TransferTask> {
        self.tasks
            .lock()
            .ok()
            .and_then(|tasks| tasks.iter().find(|task| task.id == task_id).cloned())
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
        };

        self.insert_task(task.clone());
        self.update_task_status(task.id, TransferStatus::InProgress);

        let result = self
            .run_upload_with_retries(session, task.id, &local_path, &remote_path)
            .await;

        match result {
            Ok(()) => self.update_task_status(task.id, TransferStatus::Completed),
            Err(err) => {
                self.update_task_status(
                    task.id,
                    TransferStatus::Failed {
                        message: err.to_string(),
                    },
                );
                return Err(err);
            }
        }

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
        };

        self.insert_task(task.clone());
        self.update_task_status(task.id, TransferStatus::InProgress);

        let result = self
            .run_download_with_retries(session, task.id, &remote_path, &local_path)
            .await;

        match result {
            Ok(()) => self.update_task_status(task.id, TransferStatus::Completed),
            Err(err) => {
                self.update_task_status(
                    task.id,
                    TransferStatus::Failed {
                        message: err.to_string(),
                    },
                );
                return Err(err);
            }
        }

        Ok(self.find_task(task.id).unwrap_or(task))
    }

    async fn run_upload_with_retries(
        &self,
        session: &SshSession,
        task_id: u64,
        local_path: &Path,
        remote_path: &str,
    ) -> Result<(), TransferError> {
        let client = SftpClient::new(session);
        let attempts = self.retry_count.max(1);
        let mut last_error = String::from("unknown transfer error");

        for attempt in 1..=attempts {
            match client.upload(local_path, remote_path).await {
                Ok(()) => return Ok(()),
                Err(err) => {
                    last_error = err.to_string();
                    if attempt < attempts {
                        tracing::warn!(
                            task_id,
                            attempt,
                            max_attempts = attempts,
                            "upload attempt failed, retrying"
                        );
                    }
                }
            }
        }

        Err(TransferError::RetriesExhausted {
            attempts,
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
        let attempts = self.retry_count.max(1);
        let mut last_error = String::from("unknown transfer error");

        for attempt in 1..=attempts {
            match client.download(remote_path, local_path).await {
                Ok(()) => return Ok(()),
                Err(err) => {
                    last_error = err.to_string();
                    if attempt < attempts {
                        tracing::warn!(
                            task_id,
                            attempt,
                            max_attempts = attempts,
                            "download attempt failed, retrying"
                        );
                    }
                }
            }
        }

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

    #[test]
    fn insert_task_records_pending_status() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 1,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::Pending,
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
    fn cancel_in_progress_task_is_rejected() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 8,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::InProgress,
        };

        manager.insert_task(task);
        let err = manager.cancel_transfer(8).unwrap_err();
        assert!(matches!(err, TransferError::Cancelled));
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
}
