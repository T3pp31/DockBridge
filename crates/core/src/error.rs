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

    #[error(
        "invalid remote path '{path}': parent directory traversal ('..') and null bytes are not allowed"
    )]
    InvalidRemotePath { path: String },

    #[error("directory walk limit exceeded: {limit} (value {value}) at '{path}'")]
    DirectoryWalkLimitExceeded {
        limit: String,
        value: u64,
        path: String,
    },

    #[error("SFTP server reported {code} for '{path}'")]
    RemoteStatus {
        code: RemoteStatusCode,
        path: String,
    },

    #[error("timed out waiting for the SFTP server to respond for '{path}'")]
    Timeout { path: String },

    #[error("failed to stat '{path}': {message}")]
    StatFailed { path: String, message: String },

    #[error("failed to walk directory '{path}': {message}")]
    WalkFailed { path: String, message: String },

    #[error("transfer was cancelled")]
    Cancelled,

    #[error("failed to clean up partial file at '{path}': {message}")]
    CleanupFailed { path: String, message: String },

    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

/// SFTP status codes from the SFTP protocol specification
/// (draft-ietf-secsh-filexfer-02 section 7, SSH_FX_*).
///
/// These are protocol-defined numeric codes, unlike `error_message` which is
/// a free-form, server-localized string. Judging errors by these codes works
/// with OpenSSH and any standards-conforming server regardless of locale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum RemoteStatusCode {
    /// End-of-file condition.
    Eof = 1,
    /// The referenced file or directory should exist but does not.
    NoSuchFile = 2,
    /// The authenticated user lacks sufficient permissions.
    PermissionDenied = 3,
    /// Generic catch-all failure.
    Failure = 4,
    /// Badly formatted packet or protocol incompatibility.
    BadMessage = 5,
    /// No connection to the server (generated locally).
    NoConnection = 6,
    /// The connection to the server has been lost (generated locally).
    ConnectionLost = 7,
    /// The server does not implement the requested operation.
    OpUnsupported = 8,
    /// Any other status code.
    Other(u32),
}

impl RemoteStatusCode {
    /// Converts a raw SFTP `SSH_FX_*` status code to a typed variant.
    pub fn from_raw(code: u32) -> Self {
        match code {
            1 => Self::Eof,
            2 => Self::NoSuchFile,
            3 => Self::PermissionDenied,
            4 => Self::Failure,
            5 => Self::BadMessage,
            6 => Self::NoConnection,
            7 => Self::ConnectionLost,
            8 => Self::OpUnsupported,
            other => Self::Other(other),
        }
    }
}

impl std::fmt::Display for RemoteStatusCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Eof => write!(f, "SSH_FX_EOF"),
            Self::NoSuchFile => write!(f, "SSH_FX_NO_SUCH_FILE"),
            Self::PermissionDenied => write!(f, "SSH_FX_PERMISSION_DENIED"),
            Self::Failure => write!(f, "SSH_FX_FAILURE"),
            Self::BadMessage => write!(f, "SSH_FX_BAD_MESSAGE"),
            Self::NoConnection => write!(f, "SSH_FX_NO_CONNECTION"),
            Self::ConnectionLost => write!(f, "SSH_FX_CONNECTION_LOST"),
            Self::OpUnsupported => write!(f, "SSH_FX_OP_UNSUPPORTED"),
            Self::Other(code) => write!(f, "SSH_FX_{code}"),
        }
    }
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

    #[error(
        "invalid transfer_chunk_size_bytes {value}: must be between {min} and {max} bytes inclusive"
    )]
    InvalidTransferChunkSize {
        value: usize,
        min: usize,
        max: usize,
    },
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
