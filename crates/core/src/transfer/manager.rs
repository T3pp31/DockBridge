use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rand::RngExt as _;

use crate::config::{AppConfig, DirectoryWalkLimits};
use crate::error::{RemoteStatusCode, SftpError, TransferError};
use crate::sftp::{
    ensure_local_path_within_root, is_local_directory, join_remote_path, local_directories,
    local_entry_name, normalize_remote_path, parent_remote_path, remote_directories,
    walk_local_directory_with_options, walk_remote_directory_with_limits, SftpClient,
    WalkLocalDirectoryOptions,
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

/// Outcome of a directory (batch) transfer: per-file counts and skipped
/// entries (unreadable during the walk).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BatchResult {
    /// Tasks that completed successfully.
    pub succeeded: u64,
    /// Tasks that finished with a failure.
    pub failed: u64,
    /// Entries that were skipped during the walk and never enqueued.
    pub skipped: u64,
}

/// Sequential transfer queue manager.
pub struct TransferManager {
    next_id: AtomicU64,
    retry_count: u32,
    chunk_size: usize,
    download_pipeline_depth: usize,
    directory_walk_limits: DirectoryWalkLimits,
    tasks: Mutex<Vec<TransferTask>>,
    overwrite_policies: Mutex<HashMap<u64, TransferOverwritePolicy>>,
    cancellation_flags: Mutex<HashMap<u64, Arc<AtomicBool>>>,
    /// Task ids whose transfer future has not finished yet. `retry_transfer`
    /// refuses to retry a task while it is in this set, so a cancelled task
    /// cannot be re-enqueued while its original future is still unwinding
    /// (which used to revive the cancelled transfer: issue #307).
    in_flight: Mutex<HashSet<u64>>,
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
            overwrite_policies: Mutex::new(HashMap::new()),
            cancellation_flags: Mutex::new(HashMap::new()),
            in_flight: Mutex::new(HashSet::new()),
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
            let mut retained_ids = HashSet::new();
            tasks.retain(|task| {
                let retain = matches!(
                    task.status,
                    TransferStatus::Pending | TransferStatus::InProgress
                );
                if retain {
                    retained_ids.insert(task.id);
                }
                retain
            });
            if let Ok(mut policies) = self.overwrite_policies.lock() {
                policies.retain(|task_id, _| retained_ids.contains(task_id));
            }
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
            if let Ok(mut policies) = self.overwrite_policies.lock() {
                policies.clear();
            }
        }

        Ok(())
    }

    /// Re-enqueues a failed or cancelled transfer task.
    pub async fn retry_transfer(
        &self,
        session: &SshSession,
        task_id: u64,
    ) -> Result<TransferTask, TransferError> {
        let (task, overwrite_policy) = self
            .find_task_with_policy(task_id)
            .ok_or(TransferError::TaskNotFound { task_id })?;

        match task.status {
            TransferStatus::Failed { .. } | TransferStatus::Cancelled => {}
            _ => return Err(TransferError::TaskNotFound { task_id }),
        }

        // Reject the retry while the original transfer future is still
        // unwinding. `cancel_transfer` flips the task status synchronously but
        // the future itself keeps running until it observes the cancellation;
        // re-enqueueing here would start a second transfer against the same
        // destination while the first one is still active (issue #307).
        if self.is_in_flight(task_id) {
            return Err(TransferError::TaskStillRunning { task_id });
        }

        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.retain(|existing| existing.id != task_id);
            if let Ok(mut policies) = self.overwrite_policies.lock() {
                policies.remove(&task_id);
            }
        }
        // The cancellation flag is *not* removed here: it is removed by
        // `finalize_task_result` when the original future completes. Removing
        // it early would let the still-running closure (which checks the
        // captured Arc) be revived by a re-issued id lookup.

        match task.direction {
            TransferDirection::Upload => {
                self.enqueue_upload_with_policy(
                    session,
                    &task.local_path,
                    &task.remote_path,
                    overwrite_policy,
                )
                .await
            }
            TransferDirection::Download => {
                self.enqueue_download_with_policy(
                    session,
                    &task.remote_path,
                    &task.local_path,
                    overwrite_policy,
                )
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

    #[cfg(test)]
    fn insert_task(&self, task: TransferTask) {
        self.register_task(task, TransferOverwritePolicy::default());
    }

    fn register_task(&self, task: TransferTask, overwrite_policy: TransferOverwritePolicy) {
        if let Ok(mut tasks) = self.tasks.lock() {
            if let Ok(mut policies) = self.overwrite_policies.lock() {
                policies.insert(task.id, overwrite_policy);
                tasks.push(task);
            }
        }
    }

    fn find_task_with_policy(
        &self,
        task_id: u64,
    ) -> Option<(TransferTask, TransferOverwritePolicy)> {
        let tasks = self.tasks.lock().ok()?;
        let task = tasks.iter().find(|task| task.id == task_id)?.clone();
        let policies = self.overwrite_policies.lock().ok()?;
        let overwrite_policy = policies.get(&task_id).copied().unwrap_or_default();
        Some((task, overwrite_policy))
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

    /// Returns the cancellation flag Arc for a task, or a fresh uncancelled
    /// flag when the task has not registered one. Callers should capture this
    /// Arc once and check it directly (via [`AtomicBool::load`]) rather than
    /// re-looking-up by id: a removed map entry would otherwise silently
    /// revive the cancellation state (issue #307).
    fn cancellation_flag(&self, task_id: u64) -> Arc<AtomicBool> {
        self.cancellation_flags
            .lock()
            .ok()
            .and_then(|flags| flags.get(&task_id).cloned())
            .unwrap_or_else(|| Arc::new(AtomicBool::new(false)))
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
        self.cancellation_flag(task_id).load(Ordering::Relaxed)
    }

    fn mark_in_flight(&self, task_id: u64) {
        if let Ok(mut in_flight) = self.in_flight.lock() {
            in_flight.insert(task_id);
        }
    }

    fn clear_in_flight(&self, task_id: u64) {
        if let Ok(mut in_flight) = self.in_flight.lock() {
            in_flight.remove(&task_id);
        }
    }

    fn is_in_flight(&self, task_id: u64) -> bool {
        self.in_flight
            .lock()
            .ok()
            .is_some_and(|in_flight| in_flight.contains(&task_id))
    }

    fn finalize_task_result(
        &self,
        task_id: u64,
        result: Result<(), TransferError>,
    ) -> Result<(), TransferError> {
        let was_cancelled = self.is_cancelled(task_id);
        self.remove_cancellation_flag(task_id);
        self.clear_in_flight(task_id);

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
                // A cancel raced with an actual partial-file cleanup failure.
                Err(TransferError::CleanupFailed { message }) => {
                    let failure = TransferError::CleanupFailed { message };
                    self.update_task_status(
                        task_id,
                        TransferStatus::Failed {
                            message: failure.to_string(),
                        },
                    );
                    Err(failure)
                }
                // Any other error that surfaces after a cancel is reported as
                // itself, never relabeled as a cleanup failure (issue #319).
                Err(err) => {
                    self.update_task_status(
                        task_id,
                        TransferStatus::Failed {
                            message: err.to_string(),
                        },
                    );
                    Err(err)
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
        self.enqueue_upload_with_policy(
            session,
            local_path,
            remote_path,
            TransferOverwritePolicy::default(),
        )
        .await
    }

    pub async fn enqueue_upload_with_policy(
        &self,
        session: &SshSession,
        local_path: impl AsRef<Path>,
        remote_path: impl Into<String>,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<TransferTask, TransferError> {
        let task = self.make_task(
            TransferDirection::Upload,
            local_path.as_ref(),
            &remote_path.into(),
        );
        self.run_upload_task(session, task, overwrite_policy).await
    }

    /// Builds a Pending task without registering it.
    fn make_task(
        &self,
        direction: TransferDirection,
        local_path: &Path,
        remote_path: &str,
    ) -> TransferTask {
        TransferTask {
            id: self.next_id.fetch_add(1, Ordering::Relaxed),
            direction,
            local_path: local_path.to_path_buf(),
            remote_path: remote_path.to_string(),
            status: TransferStatus::Pending,
            bytes_transferred: 0,
            total_bytes: 0,
        }
    }

    /// Registers an already-built task and executes it to completion.
    async fn run_upload_task(
        &self,
        session: &SshSession,
        task: TransferTask,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<TransferTask, TransferError> {
        let task_id = task.id;
        let local_path = task.local_path.clone();
        let remote_path = task.remote_path.clone();
        let original = task.clone();

        if self.find_task(task_id).is_none() {
            self.register_task(task, overwrite_policy);
        }
        self.register_cancellation_flag(task_id);
        self.mark_in_flight(task_id);
        self.update_task_status(task_id, TransferStatus::InProgress);

        if self.is_cancelled(task_id) {
            self.finalize_task_result(task_id, Err(TransferError::Cancelled))?;
        }

        let result = self
            .run_upload_with_retries(
                session,
                task_id,
                &local_path,
                &remote_path,
                overwrite_policy,
            )
            .await;

        self.finalize_task_result(task_id, result)?;

        Ok(self.find_task(task_id).unwrap_or(original))
    }

    /// Enqueues and immediately executes a single download task.
    pub async fn enqueue_download(
        &self,
        session: &SshSession,
        remote_path: impl Into<String>,
        local_path: impl AsRef<Path>,
    ) -> Result<TransferTask, TransferError> {
        self.enqueue_download_with_policy(
            session,
            remote_path,
            local_path,
            TransferOverwritePolicy::default(),
        )
        .await
    }

    pub async fn enqueue_download_with_policy(
        &self,
        session: &SshSession,
        remote_path: impl Into<String>,
        local_path: impl AsRef<Path>,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<TransferTask, TransferError> {
        let task = self.make_task(
            TransferDirection::Download,
            local_path.as_ref(),
            &remote_path.into(),
        );
        self.run_download_task(session, task, overwrite_policy)
            .await
    }

    /// Registers an already-built task and executes it to completion.
    async fn run_download_task(
        &self,
        session: &SshSession,
        task: TransferTask,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<TransferTask, TransferError> {
        let task_id = task.id;
        let local_path = task.local_path.clone();
        let remote_path = task.remote_path.clone();
        let original = task.clone();

        if self.find_task(task_id).is_none() {
            self.register_task(task, overwrite_policy);
        }
        self.register_cancellation_flag(task_id);
        self.mark_in_flight(task_id);
        self.update_task_status(task_id, TransferStatus::InProgress);

        if self.is_cancelled(task_id) {
            self.finalize_task_result(task_id, Err(TransferError::Cancelled))?;
        }

        let result = self
            .run_download_with_retries(
                session,
                task_id,
                &remote_path,
                &local_path,
                overwrite_policy,
            )
            .await;

        self.finalize_task_result(task_id, result)?;

        Ok(self.find_task(task_id).unwrap_or(original))
    }

    /// Enqueues and executes upload tasks for a local file or directory tree.
    ///
    /// All discovered files are registered as `Pending` tasks first (so they
    /// are immediately visible in the queue), then each is executed. A
    /// per-file transfer failure does NOT abort the batch: the task is left
    /// `Failed` and remaining files still transfer (issue #311). A
    /// [`BatchResult`] summarizes success / failure / skipped counts.
    pub async fn enqueue_upload_entry(
        &self,
        session: &SshSession,
        local_path: impl AsRef<std::path::Path>,
        remote_directory: impl Into<String>,
    ) -> Result<(Vec<TransferTask>, BatchResult), TransferError> {
        self.enqueue_upload_entry_with_policy(
            session,
            local_path,
            remote_directory,
            TransferOverwritePolicy::default(),
        )
        .await
    }

    pub async fn enqueue_upload_entry_with_policy(
        &self,
        session: &SshSession,
        local_path: impl AsRef<std::path::Path>,
        remote_directory: impl Into<String>,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<(Vec<TransferTask>, BatchResult), TransferError> {
        let local_path = local_path.as_ref();
        let remote_directory = remote_directory.into();
        let client = SftpClient::new(session);
        let mut batch = BatchResult::default();

        if is_local_directory(local_path)
            .await
            .map_err(transfer_error_from_sftp)?
        {
            let directory_name = local_entry_name(local_path);
            let remote_root =
                join_remote_path(&remote_directory, std::path::Path::new(&directory_name))
                    .map_err(transfer_error_from_sftp)?;
            let mut created_dirs = Some(HashSet::new());
            client
                .create_directory_all_cached(&remote_root, &mut created_dirs)
                .await
                .map_err(transfer_error_from_sftp)?;

            for relative_dir in local_directories(
                local_path,
                WalkLocalDirectoryOptions {
                    limits: self.directory_walk_limits,
                    ..Default::default()
                },
            )
            .await
            .map_err(transfer_error_from_sftp)?
            {
                let remote_dir = join_remote_path(&remote_root, &relative_dir)
                    .map_err(transfer_error_from_sftp)?;
                client
                    .create_directory_all_cached(&remote_dir, &mut created_dirs)
                    .await
                    .map_err(transfer_error_from_sftp)?;
            }

            let result = walk_local_directory_with_options(
                local_path,
                WalkLocalDirectoryOptions {
                    limits: self.directory_walk_limits,
                    ..Default::default()
                },
            )
            .await
            .map_err(transfer_error_from_sftp)?;

            // Register every task as Pending BEFORE running any of them, so a
            // failure in one file never leaves later files unregistered.
            let tasks: Vec<TransferTask> = result
                .files
                .iter()
                .map(|entry| {
                    join_remote_path(&remote_root, &entry.relative_path)
                        .map_err(transfer_error_from_sftp)
                        .map(|remote_path| {
                            self.make_task(
                                TransferDirection::Upload,
                                &entry.local_path,
                                &remote_path,
                            )
                        })
                })
                .collect::<Result<_, _>>()?;

            // Ensure every file parent exists while reusing the batch cache.
            for task in &tasks {
                if let Some(parent) =
                    parent_remote_path(&task.remote_path).map_err(transfer_error_from_sftp)?
                {
                    client
                        .create_directory_all_cached(&parent, &mut created_dirs)
                        .await
                        .map_err(transfer_error_from_sftp)?;
                }
            }

            batch.skipped = result.skipped.len() as u64;
            if !result.skipped.is_empty() {
                tracing::warn!(
                    skipped = ?result.skipped,
                    "local directory walk skipped unreadable entries"
                );
            }

            // Register all tasks (Pending), then execute each; failures
            // continue to the next file.
            for task in &tasks {
                self.register_task(task.clone(), overwrite_policy);
                self.register_cancellation_flag(task.id);
            }

            let mut executed = Vec::with_capacity(tasks.len());
            for task in tasks {
                let task_id = task.id;
                let final_task = match self.run_upload_task(session, task, overwrite_policy).await {
                    Ok(final_task) => final_task,
                    Err(_) => {
                        batch.failed += 1;
                        executed.push(
                            self.find_task(task_id)
                                .ok_or(TransferError::TaskNotFound { task_id })?,
                        );
                        continue;
                    }
                };
                match final_task.status {
                    TransferStatus::Completed => batch.succeeded += 1,
                    TransferStatus::Cancelled | TransferStatus::Failed { .. } => batch.failed += 1,
                    _ => {}
                }
                executed.push(final_task);
            }
            return Ok((executed, batch));
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
            .enqueue_upload_with_policy(session, local_path, remote_path, overwrite_policy)
            .await?;
        batch.succeeded += 1;
        Ok((vec![task], batch))
    }

    /// Enqueues and executes download tasks for a remote file or directory tree.
    ///
    /// All discovered files are registered as `Pending` first, then executed
    /// sequentially; a per-file failure does not abort the batch (issue #311).
    pub async fn enqueue_download_entry(
        &self,
        session: &SshSession,
        remote_path: impl Into<String>,
        local_directory: impl AsRef<std::path::Path>,
    ) -> Result<(Vec<TransferTask>, BatchResult), TransferError> {
        self.enqueue_download_entry_with_policy(
            session,
            remote_path,
            local_directory,
            TransferOverwritePolicy::default(),
        )
        .await
    }

    pub async fn enqueue_download_entry_with_policy(
        &self,
        session: &SshSession,
        remote_path: impl Into<String>,
        local_directory: impl AsRef<std::path::Path>,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<(Vec<TransferTask>, BatchResult), TransferError> {
        let remote_path = remote_path.into();
        let local_directory = local_directory.as_ref();
        let normalized = normalize_remote_path(&remote_path).map_err(transfer_error_from_sftp)?;
        let client = SftpClient::new(session);
        let mut batch = BatchResult::default();

        if client
            .remote_is_directory(&normalized)
            .await
            .map_err(transfer_error_from_sftp)?
        {
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

            // Mirror the complete directory tree before any file transfer,
            // including empty directories (issue #312).
            let mut created_dirs = HashSet::new();
            created_dirs.insert(local_root.clone());
            for relative_dir in remote_directories(&client, &normalized, self.directory_walk_limits)
                .await
                .map_err(transfer_error_from_sftp)?
            {
                let local_dir = local_root.join(relative_dir);
                ensure_local_path_within_root(&local_root, &local_dir)
                    .await
                    .map_err(transfer_error_from_sftp)?;
                tokio::fs::create_dir_all(&local_dir)
                    .await
                    .map_err(|err| transfer_error_from_message(err.to_string()))?;
                created_dirs.insert(local_dir);
            }

            let result =
                walk_remote_directory_with_limits(&client, &normalized, self.directory_walk_limits)
                    .await
                    .map_err(transfer_error_from_sftp)?;

            // Register every task as Pending before running any.
            let mut tasks = Vec::with_capacity(result.files.len());
            for entry in &result.files {
                let local_path = local_root.join(&entry.relative_path);
                ensure_local_path_within_root(&local_root, &local_path)
                    .await
                    .map_err(transfer_error_from_sftp)?;
                tasks.push(self.make_task(
                    TransferDirection::Download,
                    &local_path,
                    &entry.remote_path,
                ));
            }

            // Create all local parent directories once, before transfers.
            for task in &tasks {
                if let Some(parent) = task.local_path.parent() {
                    if created_dirs.contains(parent) {
                        continue;
                    }
                    tokio::fs::create_dir_all(parent)
                        .await
                        .map_err(|err| transfer_error_from_message(err.to_string()))?;
                    created_dirs.insert(parent.to_path_buf());
                }
            }

            batch.skipped = result.skipped.len() as u64;
            if !result.skipped.is_empty() {
                tracing::warn!(
                    skipped = ?result.skipped,
                    "remote directory walk skipped unreadable entries"
                );
            }

            for task in &tasks {
                self.register_task(task.clone(), overwrite_policy);
                self.register_cancellation_flag(task.id);
            }

            let mut executed = Vec::with_capacity(tasks.len());
            for task in tasks {
                let task_id = task.id;
                let final_task = match self
                    .run_download_task(session, task, overwrite_policy)
                    .await
                {
                    Ok(final_task) => final_task,
                    Err(_) => {
                        batch.failed += 1;
                        executed.push(
                            self.find_task(task_id)
                                .ok_or(TransferError::TaskNotFound { task_id })?,
                        );
                        continue;
                    }
                };
                match final_task.status {
                    TransferStatus::Completed => batch.succeeded += 1,
                    TransferStatus::Cancelled | TransferStatus::Failed { .. } => batch.failed += 1,
                    _ => {}
                }
                executed.push(final_task);
            }
            Ok((executed, batch))
        } else {
            let file_name = normalized
                .rsplit('/')
                .next()
                .filter(|name| !name.is_empty())
                .unwrap_or("download");
            let local_path = local_directory.join(file_name);
            let task = self
                .enqueue_download_with_policy(session, &normalized, &local_path, overwrite_policy)
                .await?;
            batch.succeeded += 1;
            Ok((vec![task], batch))
        }
    }

    async fn run_upload_with_retries(
        &self,
        session: &SshSession,
        task_id: u64,
        local_path: &Path,
        remote_path: &str,
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<(), TransferError> {
        let client = SftpClient::new(session);
        let total_bytes = tokio::fs::metadata(local_path)
            .await
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        self.set_task_total_bytes(task_id, total_bytes);

        // Capture the cancellation flag once. The closure must NOT re-lookup
        // by task id: `retry_transfer` removes the map entry for terminal
        // tasks, and an id-based check would revive a cancelled transfer
        // (issue #307).
        let cancel_flag = self.cancellation_flag(task_id);

        // `retry_count` config means the number of RETRIES after the first
        // attempt (issue #310): `transfer_retry_count = 3` performs 3
        // retries, i.e. up to 4 attempts total.
        let attempts = self.retry_count.saturating_add(1).max(1);
        let mut last_error: Option<SftpError> = None;
        let mut attempt = 0;

        let mut retry_index = 0_u32;
        for current in 1..=attempts {
            if cancel_flag.load(Ordering::Relaxed) {
                return Err(TransferError::Cancelled);
            }

            attempt = current;
            self.reset_task_progress(task_id);
            match client
                .upload_cancellable(
                    local_path,
                    remote_path,
                    self.chunk_size,
                    overwrite_policy,
                    {
                        let cancel_flag = Arc::clone(&cancel_flag);
                        move || cancel_flag.load(Ordering::Relaxed)
                    },
                    |transferred| self.update_task_progress(task_id, transferred),
                )
                .await
            {
                Ok(()) => return Ok(()),
                Err(SftpError::Cancelled) => return Err(TransferError::Cancelled),
                Err(SftpError::CleanupFailed { message, .. })
                    if cancel_flag.load(Ordering::Relaxed) =>
                {
                    // Only a genuine partial-cleanup failure is labeled as one;
                    // other errors that race a cancel propagate as themselves.
                    return Err(TransferError::CleanupFailed { message });
                }
                Err(err) => {
                    last_error = Some(err);
                    if is_non_retryable_error(last_error.as_ref().unwrap()) {
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
            message: last_error
                .map(|error| error.to_string())
                .unwrap_or_else(|| "unknown transfer error".to_string()),
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
        overwrite_policy: TransferOverwritePolicy,
    ) -> Result<(), TransferError> {
        let client = SftpClient::new(session);
        let total_bytes = client.remote_file_size(remote_path).await.unwrap_or(0);
        self.set_task_total_bytes(task_id, total_bytes);

        // Capture the cancellation flag once; see run_upload_with_retries.
        let cancel_flag = self.cancellation_flag(task_id);

        // `retry_count` config means the number of RETRIES after the first
        // attempt (issue #310).
        let attempts = self.retry_count.saturating_add(1).max(1);
        let mut last_error: Option<SftpError> = None;
        let mut attempt = 0;

        let mut retry_index = 0_u32;
        for current in 1..=attempts {
            if cancel_flag.load(Ordering::Relaxed) {
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
                    overwrite_policy,
                    {
                        let cancel_flag = Arc::clone(&cancel_flag);
                        move || cancel_flag.load(Ordering::Relaxed)
                    },
                    |transferred| self.update_task_progress(task_id, transferred),
                )
                .await
            {
                Ok(()) => return Ok(()),
                Err(SftpError::Cancelled) => return Err(TransferError::Cancelled),
                Err(SftpError::CleanupFailed { message, .. })
                    if cancel_flag.load(Ordering::Relaxed) =>
                {
                    // Only a genuine partial-cleanup failure is labeled as one;
                    // other errors that race a cancel propagate as themselves.
                    return Err(TransferError::CleanupFailed { message });
                }
                Err(err) => {
                    last_error = Some(err);
                    if is_non_retryable_error(last_error.as_ref().unwrap()) {
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
            message: last_error
                .map(|error| error.to_string())
                .unwrap_or_else(|| "unknown transfer error".to_string()),
        })
    }
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
///
/// Decided from the typed [`SftpError`] variant, not the formatted message
/// string. String matching on "failure" / "no such file" misfires for paths
/// like `~/Documents/failure-report.txt` (issue #308).
pub(crate) fn is_non_retryable_error(error: &SftpError) -> bool {
    match error {
        SftpError::RemoteStatus { code, .. } => {
            // SSH_FX_* codes that a retry cannot recover from.
            matches!(
                code,
                RemoteStatusCode::NoSuchFile
                    | RemoteStatusCode::PermissionDenied
                    | RemoteStatusCode::BadMessage
                    | RemoteStatusCode::OpUnsupported
            )
        }
        // A generic upload/download/cleanup failure may wrap a typed server
        // status; only the explicit "permission denied" / "overwrite disabled"
        // messages are deemed non-retryable from text.
        SftpError::UploadFailed { message, .. }
        | SftpError::DownloadFailed { message, .. }
        | SftpError::RenameFailed { message, .. }
        | SftpError::MkdirFailed { message, .. }
        | SftpError::DeleteFailed { message, .. }
        | SftpError::StatFailed { message, .. }
        | SftpError::WalkFailed { message, .. } => {
            let lower = message.to_lowercase();
            lower.contains("permission denied")
                || lower.contains("already exists and overwrite is disabled")
        }
        _ => false,
    }
}

/// Legacy string-based classifier kept for messaging-only call sites.
#[cfg(test)]
pub(crate) fn is_non_retryable_transfer_error(message: &str) -> bool {
    let lower = message.to_lowercase();
    crate::ssh::is_connection_lost_message(message)
        || lower.contains("permission denied")
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
        assert!(is_non_retryable_transfer_error("connection reset"));
        assert!(is_non_retryable_transfer_error(
            "failed to create directory '/home/demo': Permission denied"
        ));
        assert!(is_non_retryable_transfer_error(
            "failed to upload '/a' to '/b': destination '/b' already exists and overwrite is disabled"
        ));

        // A path containing the word "failure" must NOT be mistaken for a
        // retryable-status failure (issue #308): the typed classifier uses
        // status codes only, and the legacy message classifier no longer
        // matches the bare word "failure" or "no such file".
        assert!(!is_non_retryable_transfer_error(
            "failed to upload '/home/Documents/failure-report.txt': timed out"
        ));
        assert!(!is_non_retryable_transfer_error("SFTP Failure"));
    }

    #[test]
    fn typed_retryability_is_decided_by_status_code_not_message() {
        // A generic SSH_FX_FAILURE (OpenSSH's "Failure") IS retryable.
        assert!(!is_non_retryable_error(&SftpError::RemoteStatus {
            code: RemoteStatusCode::Failure,
            path: "/upload/file.txt".to_string(),
        }));
        // Typed non-retryable codes short-circuit regardless of message text.
        assert!(is_non_retryable_error(&SftpError::RemoteStatus {
            code: RemoteStatusCode::PermissionDenied,
            path: "/upload/file.txt".to_string(),
        }));
        assert!(is_non_retryable_error(&SftpError::RemoteStatus {
            code: RemoteStatusCode::NoSuchFile,
            path: "/upload/missing.txt".to_string(),
        }));
        assert!(!is_non_retryable_error(&SftpError::RemoteStatus {
            code: RemoteStatusCode::Failure,
            path: "/Documents/failure.txt".to_string(),
        }));
        // UploadFailed wrapping a permission text remains non-retryable.
        assert!(is_non_retryable_error(&SftpError::UploadFailed {
            local: "/a".to_string(),
            remote: "/b".to_string(),
            message: "permission denied".to_string(),
        }));
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
    fn cancellation_flag_is_captured_and_survives_map_removal() {
        // Given: a task with a registered cancellation flag
        let manager = TransferManager::new(&AppConfig::default());
        manager.register_cancellation_flag(21);
        manager.request_cancellation(21);

        // A running transfer captures the Arc once (issue #307).
        let captured = manager.cancellation_flag(21);
        assert!(captured.load(Ordering::Relaxed));

        // When: the task becomes terminal and the map entry is removed
        manager.remove_cancellation_flag(21);
        assert!(
            !manager.is_cancelled(21),
            "id-based lookup now returns false"
        );

        // Then: the captured Arc still reflects the original cancellation, so
        // a cancelled future cannot be revived by the flag's removal.
        assert!(
            captured.load(Ordering::Relaxed),
            "the captured flag must stay cancelled after map removal"
        );
    }

    #[test]
    fn finalize_clears_in_flight_marking() {
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 23,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 0,
        };
        manager.insert_task(task);
        manager.mark_in_flight(23);
        assert!(manager.is_in_flight(23));

        manager
            .finalize_task_result(23, Ok(()))
            .expect("finalize should succeed");
        assert!(!manager.is_in_flight(23), "finalize must clear in-flight");
        let queue = manager.get_transfer_queue();
        assert!(matches!(queue[0].status, TransferStatus::Completed));
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
    fn cancel_race_with_generic_error_reports_the_error_not_cleanup_message() {
        // Given: a task that was cancelled while its transfer returned a
        // non-cleanup error (e.g. remote write timeout) racing with the cancel.
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 14,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 1000,
        };
        manager.insert_task(task);
        manager.register_cancellation_flag(14);
        manager.request_cancellation(14);

        let raced_error = TransferError::RetriesExhausted {
            attempts: 1,
            message: "timed out waiting for the SFTP server".to_string(),
        };

        let err = manager
            .finalize_task_result(14, Err(raced_error))
            .expect_err("a failed transfer must stay failed");

        // Then: the original error is reported, NOT relabeled as a cleanup
        // failure. The Japanese cleanup-only message must never appear.
        let message = err.to_string();
        assert!(
            !message.contains("部分ファイルの削除に失敗"),
            "generic errors must not be relabeled as cleanup failures: {message}"
        );
        assert!(
            message.contains("timed out waiting for the SFTP server"),
            "the original error must be preserved: {message}"
        );

        let queue = manager.get_transfer_queue();
        assert!(matches!(
            queue[0].status,
            TransferStatus::Failed { ref message } if message.contains("timed out")
        ));
    }

    #[test]
    fn cancel_race_with_cleanup_failed_reports_cleanup_message() {
        // Given: a task that was cancelled while the partial-file deletion
        // genuinely failed.
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 15,
            direction: TransferDirection::Download,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 1000,
        };
        manager.insert_task(task);
        manager.register_cancellation_flag(15);
        manager.request_cancellation(15);

        let cleanup_error = TransferError::CleanupFailed {
            message: "permission denied".to_string(),
        };
        let err = manager
            .finalize_task_result(15, Err(cleanup_error))
            .expect_err("cleanup failure must stay failed");

        assert!(
            matches!(err, TransferError::CleanupFailed { ref message } if message == "permission denied"),
            "unexpected error: {err:?}"
        );
        let queue = manager.get_transfer_queue();
        assert!(matches!(
            queue[0].status,
            TransferStatus::Failed { ref message } if message.contains("failed to clean up the partial file")
        ));
    }

    #[test]
    fn finalize_cancelled_error_without_cancel_flag_marks_cancelled() {
        // Given: a task whose transfer returned Cancelled, but whose cancel
        // flag was not/is no longer set (e.g. late Detection after the flag
        // was consumed).
        let manager = TransferManager::new(&AppConfig::default());
        let task = TransferTask {
            id: 16,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/file.txt"),
            remote_path: "/remote/file.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 1000,
        };
        manager.insert_task(task);

        // No cancellation was requested/registered for this task.
        let err = manager
            .finalize_task_result(16, Err(TransferError::Cancelled))
            .expect_err("cancelled transfer does not finalize as completed");

        // Then: the task is Cancelled, never Failed.
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
    async fn enqueue_download_with_fail_if_exists_policy_rejects_existing_destination() {
        // Given: a remote file and an existing local destination
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/download/fie.bin", b"remote data")
            .await;
        let session = server.connect_session().await;
        let manager = TransferManager::new(&AppConfig::default());
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("fie.bin");
        tokio::fs::write(&local_path, b"existing local data")
            .await
            .unwrap();

        // When: downloading with FailIfExists
        let err = manager
            .enqueue_download_with_policy(
                &session,
                "/download/fie.bin",
                &local_path,
                TransferOverwritePolicy::FailIfExists,
            )
            .await
            .expect_err("FailIfExists download should fail");

        // Then: the transfer failed and the local bytes are untouched
        assert!(matches!(err, TransferError::RetriesExhausted { .. }));
        let local_contents = tokio::fs::read(&local_path).await.unwrap();
        assert_eq!(local_contents, b"existing local data");
        assert!(
            crate::sftp::test_server::list_partial_paths(local_dir.path()).is_empty(),
            "no partial files may remain"
        );
    }

    #[tokio::test]
    async fn enqueue_upload_with_fail_if_exists_policy_rejects_existing_remote() {
        // Given: an existing remote file and a local source
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/upload/fie.txt", b"old remote")
            .await;
        let session = server.connect_session().await;
        let manager = TransferManager::new(&AppConfig::default());
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("source.txt");
        tokio::fs::write(&local_path, b"new local").await.unwrap();

        // When: uploading with FailIfExists
        let err = manager
            .enqueue_upload_with_policy(
                &session,
                &local_path,
                "/upload/fie.txt",
                TransferOverwritePolicy::FailIfExists,
            )
            .await
            .expect_err("FailIfExists upload should fail");

        // Then: the transfer failed and the remote file keeps its old contents
        assert!(matches!(err, TransferError::RetriesExhausted { .. }));
        assert!(server.remote_file_exists("/upload/fie.txt"));
        assert_eq!(
            tokio::fs::read(server.root.join("upload/fie.txt"))
                .await
                .unwrap(),
            b"old remote"
        );
    }

    #[tokio::test]
    async fn retry_transfer_preserves_fail_if_exists_policy() {
        // Given: a failed upload task whose original policy forbids replacing
        // an existing destination.
        let server = TestSftpServer::start().await;
        server
            .write_remote_file("/upload/retry-policy.txt", b"existing remote")
            .await;
        let session = server.connect_session().await;
        let manager = TransferManager::new(&AppConfig::default());
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("retry-policy.txt");
        tokio::fs::write(&local_path, b"replacement").await.unwrap();

        let mut task = manager.make_task(
            TransferDirection::Upload,
            &local_path,
            "/upload/retry-policy.txt",
        );
        task.status = TransferStatus::Failed {
            message: "initial failure".to_string(),
        };
        let task_id = task.id;
        manager.register_task(task, TransferOverwritePolicy::FailIfExists);

        // When: the user retries the failed task.
        let err = manager
            .retry_transfer(&session, task_id)
            .await
            .expect_err("retry must retain FailIfExists");

        // Then: the existing remote file remains untouched. If retry had
        // fallen back to Replace, this assertion would observe "replacement".
        assert!(matches!(err, TransferError::RetriesExhausted { .. }));
        assert_eq!(
            tokio::fs::read(server.root.join("upload/retry-policy.txt"))
                .await
                .unwrap(),
            b"existing remote"
        );
    }

    #[tokio::test]
    async fn retry_transfer_is_rejected_while_original_future_is_in_flight() {
        // Given: a task that was cancelled; the transfer future is still
        // unwinding (in_flight) and the cancellation flag is still set.
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let manager = TransferManager::new(&AppConfig::default());

        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("retry-race.txt");
        tokio::fs::write(&local_path, b"payload").await.unwrap();

        let task = TransferTask {
            id: 42,
            direction: TransferDirection::Upload,
            local_path: local_path.clone(),
            remote_path: "/upload/retry-race.txt".to_string(),
            status: TransferStatus::Cancelled,
            bytes_transferred: 0,
            total_bytes: 0,
        };
        manager.insert_task(task);
        manager.register_cancellation_flag(42);
        manager.mark_in_flight(42);
        manager.request_cancellation(42);

        // When: a retry is requested immediately after the cancel (mirroring
        // cancel_transfer returning synchronously while the future runs)
        let err = manager
            .retry_transfer(&session, 42)
            .await
            .expect_err("retry while the original future is in flight must be rejected");

        // Then: retry is refused with TaskStillRunning, and the cancelled task
        // is NOT removed from the queue (no second transfer is spawned).
        assert!(
            matches!(err, TransferError::TaskStillRunning { task_id: 42 }),
            "unexpected error: {err:?}"
        );
        let queue = manager.get_transfer_queue();
        assert_eq!(queue.len(), 1, "the cancelled task must remain queued");
        assert_eq!(queue[0].id, 42);
        assert!(!server.remote_file_exists("/upload/retry-race.txt"));
    }

    #[tokio::test]
    async fn retry_transfer_succeeds_after_future_settles() {
        // Given: a fully finalized (cancelled, no longer in-flight) task
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let manager = TransferManager::new(&AppConfig::default());

        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("retry-ok.txt");
        tokio::fs::write(&local_path, b"retry payload")
            .await
            .unwrap();

        let task = TransferTask {
            id: 43,
            direction: TransferDirection::Upload,
            local_path: local_path.clone(),
            remote_path: "/upload/retry-ok.txt".to_string(),
            status: TransferStatus::Cancelled,
            bytes_transferred: 0,
            total_bytes: 0,
        };
        manager.insert_task(task.clone());
        manager.register_cancellation_flag(43);
        // The original future has fully settled: not in-flight anymore, and
        // finalize_task_result removed the flag.
        manager
            .finalize_task_result(43, Err(TransferError::Cancelled))
            .unwrap_err();
        assert!(!manager.is_in_flight(43));

        // When: retry is requested after the future has settled
        let retried = manager
            .retry_transfer(&session, 43)
            .await
            .expect("retry after settle should succeed");

        // Then: a NEW task id is enqueued and the transfer completes; only one
        // final file exists remotely (no duplicate).
        assert_ne!(retried.id, 43, "retry must create a fresh task");
        assert!(matches!(retried.status, TransferStatus::Completed));
        assert!(server.remote_file_exists("/upload/retry-ok.txt"));
        let remote_bytes = tokio::fs::read(server.root.join("upload/retry-ok.txt"))
            .await
            .unwrap();
        assert_eq!(remote_bytes, b"retry payload");
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
        let task_id = {
            let tasks = manager.tasks.lock().unwrap();
            tasks
                .iter()
                .find(|task| task.local_path.ends_with("cancelled-retry.bin"))
                .map(|task| task.id)
                .unwrap_or_else(|| panic!("task not found"))
        };

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

    #[tokio::test]
    async fn enqueue_upload_entry_continues_after_one_file_failure() {
        // Given: a manager without retries, a directory with 3 files, and a
        // server whose first WRITE fails (one-shot).
        let config = AppConfig {
            transfer_retry_count: 0,
            ..AppConfig::default()
        };
        let manager = TransferManager::new(&config);
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let local_dir = tempfile::tempdir().unwrap();
        let root = local_dir.path().join("batchsrc");
        std::fs::create_dir_all(&root).unwrap();
        tokio::fs::write(root.join("a.txt"), b"aaaa").await.unwrap();
        tokio::fs::write(root.join("b.txt"), b"bbbb").await.unwrap();
        tokio::fs::write(root.join("c.txt"), b"cccc").await.unwrap();

        server
            .failures
            .fail_remote_write
            .store(true, Ordering::SeqCst);

        // When: the whole directory is uploaded as a batch
        let (tasks, batch) = manager
            .enqueue_upload_entry(&session, &root, "/batchero")
            .await
            .expect("batch must complete even when a file fails");

        // Then: exactly one file failed, the other two completed, and ALL
        // files were enqueued (none silently dropped) (issue #311).
        assert_eq!(tasks.len(), 3, "all discovered files must be enqueued");
        assert_eq!(manager.get_transfer_queue().len(), 3);
        let failed = tasks
            .iter()
            .filter(|task| matches!(task.status, TransferStatus::Failed { .. }))
            .count();
        let completed = tasks
            .iter()
            .filter(|task| matches!(task.status, TransferStatus::Completed))
            .count();
        assert_eq!(failed, 1, "exactly one file should fail: {tasks:?}");
        assert_eq!(
            completed, 2,
            "the other files must still complete: {tasks:?}"
        );
        assert_eq!(batch.succeeded, 2);
        assert_eq!(batch.failed, 1);

        let remote_found = ["a.txt", "b.txt", "c.txt"]
            .iter()
            .filter(|name| server.remote_file_exists(&format!("/batchero/batchsrc/{name}")))
            .count();
        assert_eq!(remote_found, 2, "two remote files should be uploaded");
    }

    #[tokio::test]
    async fn enqueue_download_entry_continues_after_one_file_failure() {
        // Given: a manager without retries and three remote files whose first
        // READ fails (one-shot).
        let config = AppConfig {
            transfer_retry_count: 0,
            ..AppConfig::default()
        };
        let manager = TransferManager::new(&config);
        let server = TestSftpServer::start().await;
        for name in ["a.txt", "b.txt", "c.txt"] {
            server
                .write_remote_file(&format!("/batchdir/{name}"), b"data")
                .await;
        }
        let session = server.connect_session().await;
        let local_dir = tempfile::tempdir().unwrap();

        server
            .failures
            .fail_remote_read
            .store(true, Ordering::SeqCst);

        // When: the whole remote directory is downloaded as a batch
        let (tasks, batch) = manager
            .enqueue_download_entry(&session, "/batchdir", local_dir.path())
            .await
            .expect("batch must complete even when a file fails");

        // Then: exactly one file failed, the other two completed, and ALL
        // files were enqueued (issue #311).
        assert_eq!(tasks.len(), 3, "all discovered files must be enqueued");
        assert_eq!(manager.get_transfer_queue().len(), 3);
        let failed = tasks
            .iter()
            .filter(|task| matches!(task.status, TransferStatus::Failed { .. }))
            .count();
        let completed = tasks
            .iter()
            .filter(|task| matches!(task.status, TransferStatus::Completed))
            .count();
        assert_eq!(failed, 1, "exactly one file should fail: {tasks:?}");
        assert_eq!(
            completed, 2,
            "the other files must still complete: {tasks:?}"
        );
        assert_eq!(batch.succeeded, 2);
        assert_eq!(batch.failed, 1);

        let local_found = ["a.txt", "b.txt", "c.txt"]
            .iter()
            .filter(|name| local_dir.path().join("batchdir").join(name).is_file())
            .count();
        assert_eq!(local_found, 2, "two local files should be downloaded");
    }

    #[tokio::test]
    async fn retry_transfer_re_enqueues_failed_upload_and_completes() {
        // Given: a manager configured for no retries (so the first attempt
        // fails permanently) and a server whose first WRITE fails one-shot.
        let config = AppConfig {
            transfer_retry_count: 0,
            ..AppConfig::default()
        };
        let manager = TransferManager::new(&config);
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let local_dir = tempfile::tempdir().unwrap();
        let local_path = local_dir.path().join("retry.txt");
        tokio::fs::write(&local_path, b"retry me").await.unwrap();

        server
            .failures
            .fail_remote_write
            .store(true, Ordering::SeqCst);
        manager
            .enqueue_upload(&session, &local_path, "/upload/retry.txt")
            .await
            .expect_err("the first upload should fail");
        let failed_task = manager
            .get_transfer_queue()
            .into_iter()
            .find(|task| task.remote_path == "/upload/retry.txt")
            .expect("failed task must remain in the queue");
        assert!(
            matches!(failed_task.status, TransferStatus::Failed { .. }),
            "first attempt should fail: {:?}",
            failed_task.status
        );

        // When: the failed task is retried after its future has settled.
        let retried = manager
            .retry_transfer(&session, failed_task.id)
            .await
            .expect("retry of a finished task should succeed");

        // Then: the retry uses a fresh task id and completes.
        assert_ne!(retried.id, failed_task.id, "retry must create a fresh task");
        assert!(matches!(retried.status, TransferStatus::Completed));
        assert!(server.remote_file_exists("/upload/retry.txt"));
    }

    #[tokio::test]
    async fn retry_transfer_rejects_in_progress_task() {
        // Given: a task that is currently InProgress and already in the queue.
        let server = TestSftpServer::start().await;
        let session = server.connect_session().await;
        let manager = TransferManager::new(&AppConfig::default());
        manager.insert_task(TransferTask {
            id: 44,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/x.txt"),
            remote_path: "/upload/x.txt".to_string(),
            status: TransferStatus::InProgress,
            bytes_transferred: 0,
            total_bytes: 0,
        });

        // When: retry is requested for a non-terminal task.
        let err = manager
            .retry_transfer(&session, 44)
            .await
            .expect_err("retry of an in-progress task must be rejected");

        // Then: the public contract reports that no retryable task exists.
        assert!(
            matches!(err, TransferError::TaskNotFound { task_id: 44 }),
            "in-progress tasks are not retryable: {err:?}"
        );
    }
}
