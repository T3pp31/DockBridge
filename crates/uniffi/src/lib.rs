//! UniFFI bridge exposing DockBridge core to Swift.

// UniFFI scaffolding emits a large `MetadataBuffer` const; allow it under `-D warnings`.
#![allow(clippy::large_const_arrays)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use dockbridge_core::{
    ensure_known_hosts_parent, expand_tilde,
    inspect_private_key_algorithm as core_inspect_private_key_algorithm,
    is_connection_lost_message, u64_to_usize_or_invalid, AppConfig, AuthType, ConnectionProfile,
    HostKeyPrompt, KnownHostEntry, KnownHostsManager, KnownHostsStatus, PrivateKeyAlgorithm,
    RemoteFile, SecretPassword, SftpClient, SshSession, TransferDirection, TransferManager,
    TransferOverwritePolicy, TransferStatus, TransferTask,
};
#[cfg(test)]
use dockbridge_core::{
    validate_transfer_chunk_size, MAX_TRANSFER_CHUNK_SIZE_BYTES, MIN_TRANSFER_CHUNK_SIZE_BYTES,
};
use tokio::sync::Mutex as AsyncMutex;
use tokio::task::JoinHandle;
use zeroize::{Zeroize, ZeroizeOnDrop};

uniffi::include_scaffolding!("dockbridge_uniffi");

/// Credential received across the FFI boundary; zeroized on drop.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct SecretCredential(String);

impl SecretCredential {
    fn into_inner(mut self) -> String {
        std::mem::take(&mut self.0)
    }
}

impl std::fmt::Debug for SecretCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}

uniffi::custom_type!(SecretCredential, String, {
    lower: |v| v.0.clone(),
    try_lift: |v| Ok(SecretCredential(v)),
});

static RUNTIME: OnceLock<Result<tokio::runtime::Runtime, DockBridgeError>> = OnceLock::new();

fn runtime() -> Result<&'static tokio::runtime::Runtime, DockBridgeError> {
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .map_err(|err| DockBridgeError::Generic {
                    message: format!("failed to create Tokio runtime: {err}"),
                })
        })
        .as_ref()
        .map_err(Clone::clone)
}

fn block_on<F: std::future::Future>(future: F) -> Result<F::Output, DockBridgeError> {
    Ok(runtime()?.block_on(future))
}

/// Application configuration passed from Swift.
#[derive(uniffi::Record)]
pub struct AppConfigRecord {
    pub connection_timeout_secs: u64,
    pub session_health_check_interval_secs: u64,
    pub transfer_retry_count: u32,
    pub transfer_chunk_size_bytes: u64,
    pub transfer_download_pipeline_depth: u64,
    pub transfer_upload_pipeline_depth: u64,
    pub ssh_inactivity_timeout_secs: Option<u64>,
    pub ssh_keepalive_interval_secs: u64,
    pub known_hosts_path: String,
    pub openssh_known_hosts_path: String,
    pub merge_openssh_known_hosts_on_connect: bool,
    pub known_hosts_strict_mode: bool,
    pub fail_connect_on_openssh_merge_error: bool,
    pub directory_walk_max_files: u64,
    pub directory_walk_max_depth: u32,
    pub directory_walk_max_total_bytes: u64,
}

/// Authentication method for a connection profile.
#[derive(uniffi::Enum)]
pub enum AuthTypeRecord {
    Password {
        password: SecretCredential,
    },
    PrivateKey {
        key_path: String,
        passphrase: Option<SecretCredential>,
    },
}

/// SSH connection parameters passed from Swift.
#[derive(uniffi::Record)]
pub struct ConnectionProfileRecord {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: AuthTypeRecord,
}

/// Remote file metadata returned to Swift.
#[derive(uniffi::Record)]
pub struct RemoteFileRecord {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub modified_at_secs: Option<u64>,
    /// POSIX permission bits (e.g. `0o755`) when reported by the server.
    pub permissions: Option<u32>,
    /// Numeric owner id when reported by the server.
    pub uid: Option<u32>,
    /// Numeric group id when reported by the server.
    pub gid: Option<u32>,
    /// Resolved symlink target (only set for single-path `stat`).
    pub symlink_target: Option<String>,
    /// Whether the symlink target resolves to a directory.
    pub symlink_target_is_dir: Option<bool>,
}

/// Direction of a file transfer task.
#[derive(uniffi::Enum)]
pub enum TransferDirectionRecord {
    Upload,
    Download,
}

/// Policy applied when the transfer destination already exists.
#[derive(uniffi::Enum)]
pub enum TransferOverwritePolicyRecord {
    Replace,
    FailIfExists,
}

impl From<TransferOverwritePolicyRecord> for TransferOverwritePolicy {
    fn from(value: TransferOverwritePolicyRecord) -> Self {
        match value {
            TransferOverwritePolicyRecord::Replace => TransferOverwritePolicy::Replace,
            TransferOverwritePolicyRecord::FailIfExists => TransferOverwritePolicy::FailIfExists,
        }
    }
}

/// Lifecycle status of a transfer task.
#[derive(uniffi::Enum)]
pub enum TransferStatusRecord {
    Pending,
    InProgress,
    Completed,
    Failed { message: String },
    Cancelled,
}

/// Private key algorithm classification exposed to Swift.
#[derive(uniffi::Enum)]
pub enum PrivateKeyAlgorithmRecord {
    Ed25519,
    Ecdsa,
    Rsa,
    Other { label: String },
}

/// A queued or completed file transfer operation.
#[derive(uniffi::Record)]
pub struct TransferTaskRecord {
    pub id: u64,
    /// ID of the SSH session that enqueued this transfer.
    pub session_id: u64,
    pub direction: TransferDirectionRecord,
    pub local_path: String,
    pub remote_path: String,
    pub status: TransferStatusRecord,
    pub bytes_transferred: u64,
    pub total_bytes: u64,
}

/// Host key verification challenge presented to Swift.
#[derive(uniffi::Record)]
pub struct HostKeyChallenge {
    pub host: String,
    pub port: u16,
    pub fingerprint_sha256: String,
    pub expected_fingerprint_sha256: Option<String>,
}

/// Health of the known hosts trust store exposed to Swift.
#[derive(uniffi::Enum)]
pub enum KnownHostsStatusRecord {
    Available,
    Unavailable { reason: String },
}

/// A host identifier attached to a trusted key entry.
#[derive(uniffi::Record)]
pub struct KnownHostAliasRecord {
    pub host: String,
    pub port: u16,
}

/// Snapshot of a stored host key entry exposed to Swift.
#[derive(uniffi::Record)]
pub struct KnownHostEntryRecord {
    pub host: String,
    pub port: u16,
    pub fingerprint_sha256: String,
    pub algorithm: String,
    pub aliases: Vec<KnownHostAliasRecord>,
    pub excluded_aliases: Vec<KnownHostAliasRecord>,
    pub public_key_openssh: Option<String>,
}

/// Flat error type exposed to Swift.
#[derive(Debug, Clone, uniffi::Error)]
#[uniffi(flat_error)]
pub enum DockBridgeError {
    Generic { message: String },
}

impl std::fmt::Display for DockBridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Generic { message } => write!(f, "{message}"),
        }
    }
}

/// Callback invoked when a host key is not yet trusted.
#[uniffi::export(callback_interface)]
pub trait HostKeyHandler: Send + Sync {
    fn prompt_unknown_host(&self, challenge: HostKeyChallenge) -> bool;
}

/// Callback invoked when an active SSH/SFTP session is lost.
#[uniffi::export(callback_interface)]
pub trait ConnectionEventHandler: Send + Sync {
    fn on_session_disconnected(&self, session_id: u64, reason: String);
}

struct UniffiHostKeyPrompt {
    handler: Arc<dyn HostKeyHandler>,
}

impl HostKeyPrompt for UniffiHostKeyPrompt {
    fn prompt_unknown_host(&self, host: &str, port: u16, fingerprint_sha256: &str) -> bool {
        self.handler.prompt_unknown_host(HostKeyChallenge {
            host: host.to_string(),
            port,
            fingerprint_sha256: fingerprint_sha256.to_string(),
            expected_fingerprint_sha256: None,
        })
    }

    fn prompt_mismatch_host(
        &self,
        host: &str,
        port: u16,
        expected_fingerprint_sha256: &str,
        actual_fingerprint_sha256: &str,
    ) -> bool {
        self.handler.prompt_unknown_host(HostKeyChallenge {
            host: host.to_string(),
            port,
            fingerprint_sha256: actual_fingerprint_sha256.to_string(),
            expected_fingerprint_sha256: Some(expected_fingerprint_sha256.to_string()),
        })
    }
}

/// Main DockBridge client exposed to Swift.
#[derive(uniffi::Object)]
pub struct DockBridgeClient {
    config: AppConfig,
    known_hosts: Arc<AsyncMutex<KnownHostsManager>>,
    host_key_handler: Arc<dyn HostKeyHandler>,
    connection_event_handler: Arc<dyn ConnectionEventHandler>,
    sessions: Arc<AsyncMutex<HashMap<u64, Arc<SshSession>>>>,
    monitors: Arc<AsyncMutex<HashMap<u64, JoinHandle<()>>>>,
    next_session_id: AtomicU64,
    transfer_manager: Arc<TransferManager>,
}

#[uniffi::export]
impl DockBridgeClient {
    #[uniffi::constructor]
    fn new(
        app_config: AppConfigRecord,
        host_key_handler: Box<dyn HostKeyHandler>,
        connection_event_handler: Box<dyn ConnectionEventHandler>,
    ) -> Result<Arc<Self>, DockBridgeError> {
        let known_hosts_path = expand_tilde(PathBuf::from(app_config.known_hosts_path).as_path());
        ensure_known_hosts_parent(&known_hosts_path).map_err(map_error)?;
        let openssh_known_hosts_path =
            expand_tilde(PathBuf::from(app_config.openssh_known_hosts_path).as_path());
        let config = AppConfig {
            connection_timeout_secs: app_config.connection_timeout_secs,
            session_health_check_interval_secs: app_config.session_health_check_interval_secs,
            transfer_retry_count: app_config.transfer_retry_count,
            transfer_chunk_size_bytes: u64_to_usize_or_invalid(
                "transfer_chunk_size_bytes",
                app_config.transfer_chunk_size_bytes,
            )
            .map_err(map_error)?,
            known_hosts_path,
            openssh_known_hosts_path,
            merge_openssh_known_hosts_on_connect: app_config.merge_openssh_known_hosts_on_connect,
            known_hosts_strict_mode: app_config.known_hosts_strict_mode,
            fail_connect_on_openssh_merge_error: app_config.fail_connect_on_openssh_merge_error,
            directory_walk_max_files: app_config.directory_walk_max_files,
            directory_walk_max_depth: app_config.directory_walk_max_depth,
            directory_walk_max_total_bytes: app_config.directory_walk_max_total_bytes,
            transfer_download_pipeline_depth: u64_to_usize_or_invalid(
                "transfer_download_pipeline_depth",
                app_config.transfer_download_pipeline_depth,
            )
            .map_err(map_error)?,
            transfer_upload_pipeline_depth: u64_to_usize_or_invalid(
                "transfer_upload_pipeline_depth",
                app_config.transfer_upload_pipeline_depth,
            )
            .map_err(map_error)?,
            ssh_inactivity_timeout_secs: app_config.ssh_inactivity_timeout_secs,
            ssh_keepalive_interval_secs: app_config.ssh_keepalive_interval_secs,
        }
        .validate()
        .map_err(map_error)?;
        // Keep the app operable when the trust store is corrupt or its
        // permissions drift. The failure reason remains available through
        // `known_hosts_status` until repair or reset succeeds.
        let known_hosts_manager = KnownHostsManager::load_or_empty(config.known_hosts_path());

        Ok(Arc::new(Self {
            transfer_manager: Arc::new(TransferManager::new(&config)),
            config,
            known_hosts: Arc::new(AsyncMutex::new(known_hosts_manager)),
            host_key_handler: Arc::from(host_key_handler),
            connection_event_handler: Arc::from(connection_event_handler),
            sessions: Arc::new(AsyncMutex::new(HashMap::new())),
            monitors: Arc::new(AsyncMutex::new(HashMap::new())),
            next_session_id: AtomicU64::new(1),
        }))
    }

    fn connect(&self, profile: ConnectionProfileRecord) -> Result<u64, DockBridgeError> {
        let core_profile = to_core_profile(profile);
        let config = self.config.clone();
        let known_hosts = Arc::clone(&self.known_hosts);
        let prompt: Arc<dyn HostKeyPrompt> = Arc::new(UniffiHostKeyPrompt {
            handler: Arc::clone(&self.host_key_handler),
        });

        let session = block_on(SshSession::connect(
            core_profile,
            &config,
            known_hosts,
            prompt,
        ))?
        .map_err(map_error)?;

        let session_id = self.next_session_id.fetch_add(1, Ordering::Relaxed);
        block_on(async {
            self.sessions
                .lock()
                .await
                .insert(session_id, Arc::new(session));
        })?;
        self.spawn_health_monitor(session_id)?;
        Ok(session_id)
    }

    fn disconnect(&self, session_id: u64) -> Result<(), DockBridgeError> {
        self.remove_session(session_id, false, String::new())
    }

    fn known_hosts_status(&self) -> KnownHostsStatusRecord {
        let known_hosts = self.known_hosts.blocking_lock();
        match known_hosts.status() {
            KnownHostsStatus::Available => KnownHostsStatusRecord::Available,
            KnownHostsStatus::Unavailable { reason } => {
                KnownHostsStatusRecord::Unavailable { reason }
            }
        }
    }

    fn known_hosts_entries(&self) -> Vec<KnownHostEntryRecord> {
        let entries = { self.known_hosts.blocking_lock().entries() };
        entries
            .into_iter()
            .map(to_known_host_entry_record)
            .collect()
    }

    fn known_hosts_remove(&self, host: String, port: u16) -> Result<bool, DockBridgeError> {
        let mut known_hosts = self.known_hosts.blocking_lock();
        known_hosts.remove(&host, port).map_err(map_error)
    }

    fn known_hosts_reset(&self, backup: bool) -> Result<(), DockBridgeError> {
        let mut known_hosts = self.known_hosts.blocking_lock();
        known_hosts.reset(backup).map_err(map_error)
    }

    fn known_hosts_repair_permissions(&self) -> Result<(), DockBridgeError> {
        let mut known_hosts = self.known_hosts.blocking_lock();
        known_hosts.repair_permissions().map_err(map_error)
    }

    fn get_initial_directory(&self, session_id: u64) -> Result<String, DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .initial_directory()
                    .await
                    .map_err(map_error)
            })?,
        )
    }

    fn list_directory(
        &self,
        session_id: u64,
        path: String,
    ) -> Result<Vec<RemoteFileRecord>, DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        let files = self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .list_directory(&path)
                    .await
                    .map_err(map_error)
            })?,
        )?;
        Ok(files.into_iter().map(to_remote_file_record).collect())
    }

    /// Returns metadata for a single remote path.
    ///
    /// When `follow_symlinks` is `false`, symlinks are reported as symlinks
    /// with their target resolved via READLINK. When `true`, the target's
    /// metadata is returned instead.
    fn stat(
        &self,
        session_id: u64,
        path: String,
        follow_symlinks: bool,
    ) -> Result<RemoteFileRecord, DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        let file = self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .stat(&path, follow_symlinks)
                    .await
                    .map_err(map_error)
            })?,
        )?;
        Ok(to_remote_file_record(file))
    }

    /// Resolves the target of a remote symlink (SFTP READLINK).
    fn read_link(&self, session_id: u64, path: String) -> Result<String, DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        let target = self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .read_link(&path)
                    .await
                    .map_err(map_error)
            })?,
        )?;
        Ok(target)
    }

    /// Sets POSIX permission mode bits on a remote entry.
    fn set_permissions(
        &self,
        session_id: u64,
        path: String,
        mode: u32,
    ) -> Result<(), DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .set_permissions(&path, mode)
                    .await
                    .map_err(map_error)
            })?,
        )?;
        Ok(())
    }

    fn upload(
        &self,
        session_id: u64,
        local_path: String,
        remote_path: String,
        overwrite_policy: TransferOverwritePolicyRecord,
    ) -> Result<(), DockBridgeError> {
        self.upload_entry(session_id, local_path, remote_path, overwrite_policy)
    }

    fn download(
        &self,
        session_id: u64,
        remote_path: String,
        local_path: String,
        overwrite_policy: TransferOverwritePolicyRecord,
    ) -> Result<(), DockBridgeError> {
        self.download_entry(session_id, remote_path, local_path, overwrite_policy)
    }

    fn upload_entry(
        &self,
        session_id: u64,
        local_path: String,
        remote_directory: String,
        overwrite_policy: TransferOverwritePolicyRecord,
    ) -> Result<(), DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        let transfer_manager = Arc::clone(&self.transfer_manager);
        let overwrite_policy: TransferOverwritePolicy = overwrite_policy.into();
        self.handle_session_result(
            session_id,
            block_on(async move {
                let session = {
                    let sessions = sessions.lock().await;
                    sessions.get(&session_id).cloned().ok_or_else(|| {
                        map_error_string(format!("session {session_id} not found"))
                    })?
                };
                transfer_manager
                    .enqueue_upload_entry_for_session_with_policy(
                        session.as_ref(),
                        session_id,
                        &local_path,
                        remote_directory,
                        overwrite_policy,
                    )
                    .await
                    .map_err(map_error)?;
                Ok(())
            })?,
        )?;
        Ok(())
    }

    fn download_entry(
        &self,
        session_id: u64,
        remote_path: String,
        local_directory: String,
        overwrite_policy: TransferOverwritePolicyRecord,
    ) -> Result<(), DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        let transfer_manager = Arc::clone(&self.transfer_manager);
        let overwrite_policy: TransferOverwritePolicy = overwrite_policy.into();
        self.handle_session_result(
            session_id,
            block_on(async move {
                let session = {
                    let sessions = sessions.lock().await;
                    sessions.get(&session_id).cloned().ok_or_else(|| {
                        map_error_string(format!("session {session_id} not found"))
                    })?
                };
                transfer_manager
                    .enqueue_download_entry_for_session_with_policy(
                        session.as_ref(),
                        session_id,
                        remote_path,
                        &local_directory,
                        overwrite_policy,
                    )
                    .await
                    .map_err(map_error)?;
                Ok(())
            })?,
        )?;
        Ok(())
    }

    fn delete(&self, session_id: u64, remote_path: String) -> Result<(), DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .delete(&remote_path)
                    .await
                    .map_err(map_error)
            })?,
        )?;
        Ok(())
    }

    /// Deletes a remote entry, optionally recursing into directories.
    ///
    /// Returns the number of entries removed. Distinguishes between files,
    /// symlinks (removed as links) and directories (recursively removed when
    /// `recursive` is true, otherwise rejected when not empty).
    fn delete_entry(
        &self,
        session_id: u64,
        remote_path: String,
        recursive: bool,
    ) -> Result<u64, DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        let count = self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .delete_entry(&remote_path, recursive)
                    .await
                    .map_err(map_error)
            })?,
        )?;
        Ok(count as u64)
    }

    fn rename(&self, session_id: u64, from: String, to: String) -> Result<(), DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .rename(&from, &to)
                    .await
                    .map_err(map_error)
            })?,
        )?;
        Ok(())
    }

    fn create_directory(
        &self,
        session_id: u64,
        remote_path: String,
    ) -> Result<(), DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                SftpClient::new(session.as_ref())
                    .create_directory(&remote_path)
                    .await
                    .map_err(map_error)
            })?,
        )?;
        Ok(())
    }

    fn get_transfer_queue(&self) -> Vec<TransferTaskRecord> {
        self.transfer_manager
            .get_transfer_queue()
            .into_iter()
            .map(to_transfer_task_record)
            .collect()
    }

    fn cancel_transfer(&self, task_id: u64) -> Result<(), DockBridgeError> {
        self.transfer_manager
            .cancel_transfer(task_id)
            .map_err(map_error)
    }

    fn clear_completed_transfers(&self) {
        self.transfer_manager.clear_completed_transfers();
    }

    fn clear_all_transfers(&self) -> Result<(), DockBridgeError> {
        self.transfer_manager
            .clear_all_transfers()
            .map_err(map_error)
    }

    fn retry_transfer(&self, session_id: u64, task_id: u64) -> Result<(), DockBridgeError> {
        // A failed task belongs to the session that enqueued it.
        // Refuse to retry it against a different session so bytes never go
        // to the wrong host (issue #568).
        let original_session_id = self
            .transfer_manager
            .task_session_id(task_id)
            .ok_or_else(|| map_error_string(format!("task {task_id} not found")))?;
        if original_session_id != session_id {
            return Err(map_error_string(format!(
                "task {task_id} belongs to session {original_session_id}, not {session_id}"
            )));
        }
        let sessions = Arc::clone(&self.sessions);
        let transfer_manager = Arc::clone(&self.transfer_manager);
        self.handle_session_result(
            session_id,
            block_on(async move {
                let session = {
                    let sessions = sessions.lock().await;
                    sessions.get(&session_id).cloned().ok_or_else(|| {
                        map_error_string(format!("session {session_id} not found"))
                    })?
                };
                transfer_manager
                    .retry_transfer(session.as_ref(), task_id)
                    .await
                    .map_err(map_error)?;
                Ok(())
            })?,
        )?;
        Ok(())
    }
}

impl DockBridgeClient {
    fn remove_session(
        &self,
        session_id: u64,
        notify: bool,
        reason: String,
    ) -> Result<(), DockBridgeError> {
        block_on(async {
            if let Some(handle) = self.monitors.lock().await.remove(&session_id) {
                handle.abort();
            }
            self.sessions.lock().await.remove(&session_id);
        })?;

        if notify {
            self.connection_event_handler
                .on_session_disconnected(session_id, reason);
        }
        Ok(())
    }

    fn handle_session_result<T>(
        &self,
        session_id: u64,
        result: Result<T, DockBridgeError>,
    ) -> Result<T, DockBridgeError> {
        if let Err(DockBridgeError::Generic { ref message }) = result {
            if is_connection_lost_message(message) {
                if let Err(error) = self.remove_session(session_id, true, message.clone()) {
                    eprintln!("failed to remove disconnected session {session_id}: {error}");
                }
            }
        }
        result
    }

    fn spawn_health_monitor(&self, session_id: u64) -> Result<(), DockBridgeError> {
        let interval_secs = self.config.session_health_check_interval_secs.max(1);
        let sessions = Arc::clone(&self.sessions);
        let monitors = Arc::clone(&self.monitors);
        let monitors_in_task = Arc::clone(&monitors);
        let connection_event_handler = Arc::clone(&self.connection_event_handler);

        let monitor_task = runtime()?.spawn(async move {
            let interval = Duration::from_secs(interval_secs);

            loop {
                tokio::time::sleep(interval).await;

                let session = {
                    let sessions = sessions.lock().await;
                    sessions.get(&session_id).cloned()
                };
                let Some(session) = session else {
                    return;
                };

                let check_result = SftpClient::new(session.as_ref()).check_alive().await;

                if let Err(error) = check_result {
                    let message = error.to_string();
                    if is_connection_lost_message(&message) {
                        if let Some(handle) = monitors_in_task.lock().await.remove(&session_id) {
                            handle.abort();
                        }
                        sessions.lock().await.remove(&session_id);
                        connection_event_handler.on_session_disconnected(session_id, message);
                        break;
                    }
                }
            }
        });

        block_on(async {
            monitors.lock().await.insert(session_id, monitor_task);
        })?;
        Ok(())
    }
}

fn to_core_profile(profile: ConnectionProfileRecord) -> ConnectionProfile {
    let auth = match profile.auth_type {
        AuthTypeRecord::Password { password } => AuthType::Password {
            password: SecretPassword::new(password.into_inner()),
        },
        AuthTypeRecord::PrivateKey {
            key_path,
            passphrase,
        } => AuthType::PrivateKey {
            key_path: PathBuf::from(key_path),
            passphrase: passphrase.map(|value| SecretPassword::new(value.into_inner())),
        },
    };

    ConnectionProfile {
        host: profile.host,
        port: profile.port,
        username: profile.username,
        auth,
    }
}

fn to_known_host_entry_record(entry: KnownHostEntry) -> KnownHostEntryRecord {
    KnownHostEntryRecord {
        host: entry.host,
        port: entry.port,
        fingerprint_sha256: entry.fingerprint_sha256,
        algorithm: entry.algorithm,
        aliases: entry
            .aliases
            .into_iter()
            .map(|alias| KnownHostAliasRecord {
                host: alias.host,
                port: alias.port,
            })
            .collect(),
        excluded_aliases: entry
            .excluded_aliases
            .into_iter()
            .map(|alias| KnownHostAliasRecord {
                host: alias.host,
                port: alias.port,
            })
            .collect(),
        public_key_openssh: entry.public_key_openssh,
    }
}

fn to_remote_file_record(file: RemoteFile) -> RemoteFileRecord {
    RemoteFileRecord {
        name: file.name,
        path: file.path,
        is_directory: file.is_directory,
        is_symlink: file.is_symlink,
        size: file.size,
        modified_at_secs: file.modified_at_secs,
        permissions: file.permissions,
        uid: file.uid,
        gid: file.gid,
        symlink_target: file.symlink_target,
        symlink_target_is_dir: file.symlink_target_is_dir,
    }
}

fn to_transfer_task_record(task: TransferTask) -> TransferTaskRecord {
    TransferTaskRecord {
        id: task.id,
        session_id: task.session_id,
        direction: match task.direction {
            TransferDirection::Upload => TransferDirectionRecord::Upload,
            TransferDirection::Download => TransferDirectionRecord::Download,
        },
        local_path: task.local_path.display().to_string(),
        remote_path: task.remote_path,
        status: match task.status {
            TransferStatus::Pending => TransferStatusRecord::Pending,
            TransferStatus::InProgress => TransferStatusRecord::InProgress,
            TransferStatus::Completed => TransferStatusRecord::Completed,
            TransferStatus::Failed { message } => TransferStatusRecord::Failed { message },
            TransferStatus::Cancelled => TransferStatusRecord::Cancelled,
        },
        bytes_transferred: task.bytes_transferred,
        total_bytes: task.total_bytes,
    }
}

fn map_error(error: impl std::fmt::Display) -> DockBridgeError {
    DockBridgeError::Generic {
        message: error.to_string(),
    }
}

fn map_error_string(message: impl Into<String>) -> DockBridgeError {
    DockBridgeError::Generic {
        message: message.into(),
    }
}

#[uniffi::export]
fn inspect_private_key_algorithm(
    key_path: String,
    passphrase: Option<SecretCredential>,
) -> Result<PrivateKeyAlgorithmRecord, DockBridgeError> {
    let passphrase = passphrase.map(SecretCredential::into_inner);
    let algorithm = core_inspect_private_key_algorithm(
        PathBuf::from(&key_path).as_path(),
        passphrase.as_deref(),
    )
    .map_err(map_error)?;

    Ok(match algorithm {
        PrivateKeyAlgorithm::Ed25519 => PrivateKeyAlgorithmRecord::Ed25519,
        PrivateKeyAlgorithm::Ecdsa => PrivateKeyAlgorithmRecord::Ecdsa,
        PrivateKeyAlgorithm::Rsa => PrivateKeyAlgorithmRecord::Rsa,
        PrivateKeyAlgorithm::Other(label) => PrivateKeyAlgorithmRecord::Other { label },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(status: TransferStatus) -> TransferTask {
        TransferTask {
            id: 1,
            session_id: 1,
            direction: TransferDirection::Upload,
            local_path: PathBuf::from("/tmp/local.txt"),
            remote_path: "/remote.txt".to_string(),
            status,
            bytes_transferred: 0,
            total_bytes: 100,
        }
    }

    #[test]
    fn transfer_task_record_maps_all_statuses() {
        // Given: every TransferStatus variant
        // When: converted to TransferTaskRecord
        // Then: each maps to the corresponding TransferStatusRecord variant
        let cases = [
            (TransferStatus::Pending, TransferStatusRecord::Pending),
            (TransferStatus::InProgress, TransferStatusRecord::InProgress),
            (TransferStatus::Completed, TransferStatusRecord::Completed),
            (TransferStatus::Cancelled, TransferStatusRecord::Cancelled),
        ];
        for (status, expected) in cases {
            let record = to_transfer_task_record(task(status));
            assert!(
                std::mem::discriminant(&record.status) == std::mem::discriminant(&expected),
                "status mapping mismatch"
            );
        }

        let failed = to_transfer_task_record(task(TransferStatus::Failed {
            message: "boom".to_string(),
        }));
        match failed.status {
            TransferStatusRecord::Failed { message } => assert_eq!(message, "boom"),
            _ => panic!("expected Failed status in record"),
        }
    }

    #[test]
    fn transfer_task_record_maps_direction() {
        // Given: an upload and a download task
        // When: converted to TransferTaskRecord
        // Then: directions round-trip to the correct record variants
        let upload = to_transfer_task_record(task(TransferStatus::Pending));
        assert_eq!(upload.session_id, 1);
        assert!(
            std::mem::discriminant(&upload.direction)
                == std::mem::discriminant(&TransferDirectionRecord::Upload)
        );

        let mut t = task(TransferStatus::Pending);
        t.direction = TransferDirection::Download;
        let download = to_transfer_task_record(t);
        assert!(
            std::mem::discriminant(&download.direction)
                == std::mem::discriminant(&TransferDirectionRecord::Download)
        );
    }

    #[test]
    fn chunk_size_below_minimum_is_raised_to_minimum() {
        // Given: a chunk size below the 4 KiB minimum
        // When: validated
        // Then: it is raised to the minimum instead of erroring
        let validated = validate_transfer_chunk_size(1).unwrap();
        assert_eq!(validated, MIN_TRANSFER_CHUNK_SIZE_BYTES);
        let validated = validate_transfer_chunk_size(MIN_TRANSFER_CHUNK_SIZE_BYTES - 1).unwrap();
        assert_eq!(validated, MIN_TRANSFER_CHUNK_SIZE_BYTES);
    }

    #[test]
    fn chunk_size_at_minimum_and_maximum_are_accepted() {
        // Given: chunk sizes at the accepted boundaries
        // When: validated
        // Then: they pass through unchanged
        assert_eq!(
            validate_transfer_chunk_size(MIN_TRANSFER_CHUNK_SIZE_BYTES).unwrap(),
            MIN_TRANSFER_CHUNK_SIZE_BYTES
        );
        assert_eq!(
            validate_transfer_chunk_size(MAX_TRANSFER_CHUNK_SIZE_BYTES).unwrap(),
            MAX_TRANSFER_CHUNK_SIZE_BYTES
        );
    }

    #[test]
    fn chunk_size_above_maximum_is_rejected() {
        // Given: a chunk size above the 8 MiB maximum
        // When: validated
        // Then: Err is returned
        assert!(validate_transfer_chunk_size(MAX_TRANSFER_CHUNK_SIZE_BYTES + 1).is_err());
        assert!(validate_transfer_chunk_size(usize::MAX).is_err());
    }

    #[test]
    fn map_error_wraps_display_message() {
        // Given: a displayable error
        // When: mapped via map_error
        // Then: a Generic DockBridgeError is produced with its message
        struct TestError;
        impl std::fmt::Display for TestError {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(f, "test display error")
            }
        }

        let err = map_error(TestError);
        match err {
            DockBridgeError::Generic { message } => assert_eq!(message, "test display error"),
        }
    }
}
