//! DockBridge core library for SSH/SFTP operations.

pub mod config;
pub mod error;
pub mod security;
pub mod sftp;
pub mod ssh;
pub mod transfer;

pub use config::{ensure_known_hosts_parent, expand_tilde, AppConfig};
pub use error::{
    AppError, AuthError, ConfigError, ConnectionError, SecurityError, SftpError, TransferError,
};
pub use security::{fingerprint_sha256, HostKeyCheckResult, KnownHostsManager};
pub use sftp::{RemoteFile, SftpClient};
pub use ssh::{
    is_connection_lost_message, AuthType, ConnectionProfile, HostKeyPrompt, SecretPassword,
    SshSession,
};
pub use transfer::{TransferDirection, TransferManager, TransferStatus, TransferTask};
