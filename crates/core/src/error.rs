use thiserror::Error;

/// Top-level application error for DockBridge core operations.
#[derive(Debug, Error)]
pub enum AppError {
    #[error(transparent)]
    Connection(#[from] ConnectionError),

    #[error(transparent)]
    Auth(#[from] AuthError),

    #[error(transparent)]
    Sftp(#[from] SftpError),

    #[error(transparent)]
    Transfer(#[from] TransferError),

    #[error(transparent)]
    Security(#[from] SecurityError),

    #[error(transparent)]
    Config(#[from] ConfigError),

    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Errors related to SSH connection establishment.
#[derive(Debug, Error)]
pub enum ConnectionError {
    #[error("failed to connect to {host}:{port}: {message}")]
    ConnectFailed {
        host: String,
        port: u16,
        message: String,
    },

    #[error("connection timed out after {timeout_secs} seconds")]
    Timeout { timeout_secs: u64 },

    #[error("host key verification failed")]
    HostKeyRejected,

    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl From<russh::Error> for ConnectionError {
    fn from(value: russh::Error) -> Self {
        Self::Other(value.into())
    }
}

/// Errors related to SSH authentication.
#[derive(Debug, Error)]
pub enum AuthError {
    #[error("authentication failed for user '{username}'")]
    Failed { username: String },

    #[error("password authentication is not supported by the server")]
    MethodUnavailable,

    #[error("failed to load private key from {path}: {message}")]
    PrivateKeyLoadFailed { path: String, message: String },
}

/// Errors related to SFTP operations.
#[derive(Debug, Error)]
pub enum SftpError {
    #[error("failed to open SFTP subsystem: {message}")]
    SubsystemFailed { message: String },

    #[error("failed to list directory '{path}': {message}")]
    ListFailed { path: String, message: String },

    #[error("failed to upload '{local}' to '{remote}': {message}")]
    UploadFailed {
        local: String,
        remote: String,
        message: String,
    },

    #[error("failed to download '{remote}' to '{local}': {message}")]
    DownloadFailed {
        remote: String,
        local: String,
        message: String,
    },

    #[error("failed to delete '{path}': {message}")]
    DeleteFailed { path: String, message: String },

    #[error("failed to rename '{from}' to '{to}': {message}")]
    RenameFailed {
        from: String,
        to: String,
        message: String,
    },

    #[error("failed to create directory '{path}': {message}")]
    MkdirFailed { path: String, message: String },

    #[error("failed to canonicalize remote path '{path}': {message}")]
    CanonicalizeFailed { path: String, message: String },

    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

/// Errors related to file transfer queue operations.
#[derive(Debug, Error)]
pub enum TransferError {
    #[error("transfer task {task_id} not found")]
    TaskNotFound { task_id: u64 },

    #[error("transfer failed after {attempts} attempts: {message}")]
    RetriesExhausted { attempts: u32, message: String },

    #[error("transfer was cancelled")]
    Cancelled,
}

/// Security-related errors.
#[derive(Debug, Error)]
pub enum SecurityError {
    #[error("host key mismatch for {host}:{port}: expected {expected}, got {actual}")]
    HostKeyMismatch {
        host: String,
        port: u16,
        expected: String,
        actual: String,
    },

    #[error("host key rejected by user for {host}:{port}")]
    HostKeyRejected { host: String, port: u16 },

    #[error("failed to read known hosts store at {path}: {message}")]
    KnownHostsReadFailed { path: String, message: String },

    #[error("failed to write known hosts store at {path}: {message}")]
    KnownHostsWriteFailed { path: String, message: String },
}

/// Configuration loading errors.
#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("failed to parse config at {path}: {message}")]
    ParseFailed { path: String, message: String },

    #[error("config file not found at {path}")]
    NotFound { path: String },
}

impl AppError {
    /// Returns `true` when the error is a host key mismatch.
    pub fn is_host_key_mismatch(&self) -> bool {
        matches!(
            self,
            AppError::Security(SecurityError::HostKeyMismatch { .. })
        )
    }
}
