use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, Handle};
use russh::keys::PublicKey;
use russh::keys::{decode_secret_key, PrivateKeyWithHashAlg};
use russh_sftp::client::SftpSession;
use tokio::sync::Mutex;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use super::algorithm_policy::build_client_config;
use crate::config::AppConfig;
use crate::error::{AuthError, ConnectionError, SecurityError, SftpError};
use crate::security::{fingerprint_sha256, HostKeyCheckResult, KnownHostsManager};

/// Callback invoked when a host key is not yet trusted.
pub trait HostKeyPrompt: Send + Sync {
    /// Prompts the user to accept or reject an unknown host key.
    fn prompt_unknown_host(&self, host: &str, port: u16, fingerprint_sha256: &str) -> bool;
}

/// SSH authentication method.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub enum AuthType {
    /// Password-based authentication.
    Password { password: SecretPassword },
    /// Private key file authentication.
    PrivateKey {
        #[zeroize(skip)]
        key_path: PathBuf,
        passphrase: Option<SecretPassword>,
    },
}

/// SSH connection parameters.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct ConnectionProfile {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthType,
}

impl ConnectionProfile {
    /// Creates a password-authenticated connection profile.
    pub fn with_password(
        host: impl Into<String>,
        port: u16,
        username: impl Into<String>,
        password: impl Into<String>,
    ) -> Self {
        Self {
            host: host.into(),
            port,
            username: username.into(),
            auth: AuthType::Password {
                password: SecretPassword::new(password),
            },
        }
    }
}

/// Password wrapper that avoids accidental logging.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct SecretPassword(String);

impl SecretPassword {
    /// Creates a new secret password value.
    pub fn new(password: impl Into<String>) -> Self {
        Self(password.into())
    }

    /// Returns the password for authentication.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for SecretPassword {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}

impl std::fmt::Debug for AuthType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Password { password } => f
                .debug_struct("AuthType::Password")
                .field("password", password)
                .finish(),
            Self::PrivateKey {
                key_path,
                passphrase,
            } => f
                .debug_struct("AuthType::PrivateKey")
                .field("key_path", key_path)
                .field("passphrase", passphrase)
                .finish(),
        }
    }
}

impl std::fmt::Debug for ConnectionProfile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionProfile")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("username", &self.username)
            .field("auth", &self.auth)
            .finish()
    }
}

/// Established SSH session with an open SFTP channel.
pub struct SshSession {
    #[allow(dead_code)]
    handle: Handle<SshClientHandler>,
    pub(crate) sftp: SftpSession,
    host: String,
    port: u16,
}

struct SshClientHandler {
    host: String,
    port: u16,
    known_hosts: Arc<Mutex<KnownHostsManager>>,
    prompt: Arc<dyn HostKeyPrompt>,
}

impl client::Handler for SshClientHandler {
    type Error = ConnectionError;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        let fingerprint = fingerprint_sha256(server_public_key);
        let check = {
            let manager = self.known_hosts.lock().await;
            manager.check_host_key(&self.host, self.port, server_public_key)
        };

        match check {
            HostKeyCheckResult::Trust => Ok(true),
            HostKeyCheckResult::Reject => Err(ConnectionError::HostKeyRejected),
            HostKeyCheckResult::Mismatch {
                expected_fingerprint,
                actual_fingerprint,
            } => Err(SecurityError::HostKeyMismatch {
                host: self.host.clone(),
                port: self.port,
                expected: expected_fingerprint,
                actual: actual_fingerprint,
            }
            .into()),
            HostKeyCheckResult::Unknown => {
                let accept = self
                    .prompt
                    .prompt_unknown_host(&self.host, self.port, &fingerprint);

                if !accept {
                    return Err(SecurityError::HostKeyRejected {
                        host: self.host.clone(),
                        port: self.port,
                    }
                    .into());
                }

                let mut manager = self.known_hosts.lock().await;
                manager
                    .accept_host_key(&self.host, self.port, server_public_key)
                    .map_err(ConnectionError::from)?;
                Ok(true)
            }
        }
    }
}

impl From<SecurityError> for ConnectionError {
    fn from(value: SecurityError) -> Self {
        Self::Other(value.into())
    }
}

impl SshSession {
    /// Connects to a remote host and opens an SFTP subsystem.
    pub async fn connect(
        profile: ConnectionProfile,
        config: &AppConfig,
        known_hosts: Arc<Mutex<KnownHostsManager>>,
        prompt: Arc<dyn HostKeyPrompt>,
    ) -> Result<Self, crate::error::AppError> {
        let host = profile.host.clone();
        let port = profile.port;
        let username = profile.username.clone();

        let russh_config = build_client_config(config.connection_timeout_secs);

        let handler = SshClientHandler {
            host: host.clone(),
            port,
            known_hosts,
            prompt,
        };

        let connect_future =
            client::connect(Arc::new(russh_config), (host.as_str(), port), handler);

        let mut handle = tokio::time::timeout(
            Duration::from_secs(config.connection_timeout_secs),
            connect_future,
        )
        .await
        .map_err(|_| ConnectionError::Timeout {
            timeout_secs: config.connection_timeout_secs,
        })?
        .map_err(|err| ConnectionError::ConnectFailed {
            host: host.clone(),
            port,
            message: err.to_string(),
        })?;

        let authenticated =
            authenticate(&mut handle, &username, &profile.auth, &host, port).await?;

        if !authenticated {
            return Err(AuthError::Failed { username }.into());
        }

        let channel =
            handle
                .channel_open_session()
                .await
                .map_err(|err| ConnectionError::ConnectFailed {
                    host: host.clone(),
                    port,
                    message: err.to_string(),
                })?;

        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|err| SftpError::SubsystemFailed {
                message: err.to_string(),
            })?;

        let sftp = SftpSession::new(channel.into_stream())
            .await
            .map_err(|err| SftpError::SubsystemFailed {
                message: err.to_string(),
            })?;

        sftp.set_timeout(config.connection_timeout_secs);

        Ok(Self {
            handle,
            sftp,
            host,
            port,
        })
    }

    /// Returns the connected host name.
    pub fn host(&self) -> &str {
        &self.host
    }

    /// Returns the connected port.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Returns a reference to the underlying SFTP session.
    pub fn sftp(&self) -> &SftpSession {
        &self.sftp
    }
}

async fn authenticate(
    handle: &mut Handle<SshClientHandler>,
    username: &str,
    auth: &AuthType,
    host: &str,
    port: u16,
) -> Result<bool, crate::error::AppError> {
    match auth {
        AuthType::Password { password } => handle
            .authenticate_password(username, password.expose())
            .await
            .map_err(|err| ConnectionError::ConnectFailed {
                host: host.to_string(),
                port,
                message: err.to_string(),
            })
            .map(|result| result.success())
            .map_err(Into::into),
        AuthType::PrivateKey {
            key_path,
            passphrase,
        } => {
            let key_contents =
                Zeroizing::new(std::fs::read_to_string(key_path).map_err(|err| {
                    AuthError::PrivateKeyLoadFailed {
                        path: key_path.display().to_string(),
                        message: err.to_string(),
                    }
                })?);
            let passphrase = passphrase.as_ref().map(|value| value.expose());
            let private_key =
                decode_secret_key(key_contents.as_str(), passphrase).map_err(|err| {
                    AuthError::PrivateKeyLoadFailed {
                        path: key_path.display().to_string(),
                        message: err.to_string(),
                    }
                })?;
            drop(key_contents);
            let rsa_hash = handle
                .best_supported_rsa_hash()
                .await
                .map_err(|err| ConnectionError::ConnectFailed {
                    host: host.to_string(),
                    port,
                    message: err.to_string(),
                })?;
            let signing_key =
                PrivateKeyWithHashAlg::new(Arc::new(private_key), rsa_hash.flatten());
            handle
                .authenticate_publickey(username, signing_key)
                .await
                .map_err(|err| ConnectionError::ConnectFailed {
                    host: host.to_string(),
                    port,
                    message: err.to_string(),
                })
                .map(|result| result.success())
                .map_err(Into::into)
        }
    }
}
