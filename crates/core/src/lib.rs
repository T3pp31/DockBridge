//! DockBridge core library for SSH/SFTP operations.

pub mod config;
pub mod error;
pub mod security;
pub mod sftp;
pub mod ssh;
pub mod transfer;

pub use config::{
    clamp_transfer_chunk_size, ensure_known_hosts_parent, expand_tilde,
    validate_transfer_chunk_size, AppConfig, DEFAULT_TRANSFER_CHUNK_SIZE_BYTES,
    MAX_TRANSFER_CHUNK_SIZE_BYTES, MIN_TRANSFER_CHUNK_SIZE_BYTES,
};
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
