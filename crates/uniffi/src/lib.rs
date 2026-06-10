//! UniFFI bridge exposing DockBridge core to Swift.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use dockbridge_core::{
    ensure_known_hosts_parent, expand_tilde, is_connection_lost_message, AppConfig, AuthType,
    ConnectionProfile, HostKeyPrompt, KnownHostsManager, RemoteFile, SecretPassword, SftpClient,
    SshSession, TransferDirection, TransferManager, TransferStatus, TransferTask,
};
use tokio::sync::Mutex as AsyncMutex;
use tokio::task::JoinHandle;

uniffi::include_scaffolding!("dockbridge_uniffi");

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to create Tokio runtime")
    })
}

fn block_on<F: std::future::Future>(future: F) -> F::Output {
    runtime().block_on(future)
}

/// Application configuration passed from Swift.
#[derive(uniffi::Record)]
pub struct AppConfigRecord {
    pub connection_timeout_secs: u64,
    pub session_health_check_interval_secs: u64,
    pub transfer_retry_count: u32,
    pub known_hosts_path: String,
}

/// Authentication method for a connection profile.
#[derive(uniffi::Enum)]
pub enum AuthTypeRecord {
    Password {
        password: String,
    },
    PrivateKey {
        key_path: String,
        passphrase: Option<String>,
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
    pub size: u64,
}

/// Direction of a file transfer task.
#[derive(uniffi::Enum)]
pub enum TransferDirectionRecord {
    Upload,
    Download,
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

/// A queued or completed file transfer operation.
#[derive(uniffi::Record)]
pub struct TransferTaskRecord {
    pub id: u64,
    pub direction: TransferDirectionRecord,
    pub local_path: String,
    pub remote_path: String,
    pub status: TransferStatusRecord,
}

/// Host key verification challenge presented to Swift.
#[derive(uniffi::Record)]
pub struct HostKeyChallenge {
    pub host: String,
    pub port: u16,
    pub fingerprint_sha256: String,
}

/// Flat error type exposed to Swift.
#[derive(Debug, uniffi::Error)]
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
    sessions: Arc<AsyncMutex<HashMap<u64, SshSession>>>,
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
        let config = AppConfig {
            connection_timeout_secs: app_config.connection_timeout_secs,
            session_health_check_interval_secs: app_config.session_health_check_interval_secs,
            transfer_retry_count: app_config.transfer_retry_count,
            transfer_chunk_size_bytes: AppConfig::default().transfer_chunk_size_bytes,
            known_hosts_path,
        };
        let known_hosts_manager =
            KnownHostsManager::load(config.known_hosts_path()).map_err(map_error)?;

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
        ))
        .map_err(map_error)?;

        let session_id = self.next_session_id.fetch_add(1, Ordering::Relaxed);
        block_on(async {
            self.sessions.lock().await.insert(session_id, session);
        });
        self.spawn_health_monitor(session_id);
        Ok(session_id)
    }

    fn disconnect(&self, session_id: u64) -> Result<(), DockBridgeError> {
        self.remove_session(session_id, false, String::new());
        Ok(())
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
                SftpClient::new(session)
                    .initial_directory()
                    .await
                    .map_err(map_error)
            }),
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
                SftpClient::new(session)
                    .list_directory(&path)
                    .await
                    .map_err(map_error)
            }),
        )?;
        Ok(files.into_iter().map(to_remote_file_record).collect())
    }

    fn upload(
        &self,
        session_id: u64,
        local_path: String,
        remote_path: String,
    ) -> Result<(), DockBridgeError> {
        self.upload_entry(session_id, local_path, remote_path)
    }

    fn download(
        &self,
        session_id: u64,
        remote_path: String,
        local_path: String,
    ) -> Result<(), DockBridgeError> {
        self.download_entry(session_id, remote_path, local_path)
    }

    fn upload_entry(
        &self,
        session_id: u64,
        local_path: String,
        remote_directory: String,
    ) -> Result<(), DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        let transfer_manager = Arc::clone(&self.transfer_manager);
        self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                transfer_manager
                    .enqueue_upload_entry(session, &local_path, remote_directory)
                    .await
                    .map_err(map_error)?;
                Ok(())
            }),
        )?;
        Ok(())
    }

    fn download_entry(
        &self,
        session_id: u64,
        remote_path: String,
        local_directory: String,
    ) -> Result<(), DockBridgeError> {
        let sessions = Arc::clone(&self.sessions);
        let transfer_manager = Arc::clone(&self.transfer_manager);
        self.handle_session_result(
            session_id,
            block_on(async move {
                let sessions = sessions.lock().await;
                let session = sessions
                    .get(&session_id)
                    .ok_or_else(|| map_error_string(format!("session {session_id} not found")))?;
                transfer_manager
                    .enqueue_download_entry(session, remote_path, &local_directory)
                    .await
                    .map_err(map_error)?;
                Ok(())
            }),
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
                SftpClient::new(session)
                    .delete(&remote_path)
                    .await
                    .map_err(map_error)
            }),
        )?;
        Ok(())
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
                SftpClient::new(session)
                    .rename(&from, &to)
                    .await
                    .map_err(map_error)
            }),
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
                SftpClient::new(session)
                    .create_directory(&remote_path)
                    .await
                    .map_err(map_error)
            }),
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
}

impl DockBridgeClient {
    fn remove_session(&self, session_id: u64, notify: bool, reason: String) {
        block_on(async {
            if let Some(handle) = self.monitors.lock().await.remove(&session_id) {
                handle.abort();
            }
            self.sessions.lock().await.remove(&session_id);
        });

        if notify {
            self.connection_event_handler
                .on_session_disconnected(session_id, reason);
        }
    }

    fn handle_session_result<T>(
        &self,
        session_id: u64,
        result: Result<T, DockBridgeError>,
    ) -> Result<T, DockBridgeError> {
        if let Err(DockBridgeError::Generic { ref message }) = result {
            if is_connection_lost_message(message) {
                self.remove_session(session_id, true, message.clone());
            }
        }
        result
    }

    fn spawn_health_monitor(&self, session_id: u64) {
        let interval_secs = self.config.session_health_check_interval_secs.max(1);
        let sessions = Arc::clone(&self.sessions);
        let monitors = Arc::clone(&self.monitors);
        let monitors_in_task = Arc::clone(&monitors);
        let connection_event_handler = Arc::clone(&self.connection_event_handler);

        let monitor_task = runtime().spawn(async move {
            let interval = Duration::from_secs(interval_secs);

            loop {
                tokio::time::sleep(interval).await;

                let check_result = {
                    let sessions = sessions.lock().await;
                    match sessions.get(&session_id) {
                        Some(session) => SftpClient::new(session).check_alive().await,
                        None => return,
                    }
                };

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
        });
    }
}

fn to_core_profile(profile: ConnectionProfileRecord) -> ConnectionProfile {
    let auth = match profile.auth_type {
        AuthTypeRecord::Password { password } => AuthType::Password {
            password: SecretPassword::new(password),
        },
        AuthTypeRecord::PrivateKey {
            key_path,
            passphrase,
        } => AuthType::PrivateKey {
            key_path: PathBuf::from(key_path),
            passphrase: passphrase.map(SecretPassword::new),
        },
    };

    ConnectionProfile {
        host: profile.host,
        port: profile.port,
        username: profile.username,
        auth,
    }
}

fn to_remote_file_record(file: RemoteFile) -> RemoteFileRecord {
    RemoteFileRecord {
        name: file.name,
        path: file.path,
        is_directory: file.is_directory,
        size: file.size,
    }
}

fn to_transfer_task_record(task: TransferTask) -> TransferTaskRecord {
    TransferTaskRecord {
        id: task.id,
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
