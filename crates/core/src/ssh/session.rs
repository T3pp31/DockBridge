use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, AuthResult, Handle, KeyboardInteractiveAuthResponse};
use russh::keys::PublicKey;
use russh::keys::{decode_secret_key, PrivateKeyWithHashAlg};
use russh::MethodKind;
use russh_sftp::client::{Config as SftpConfig, SftpSession};
use tokio::sync::Mutex;
use tokio::time::{Instant as TokioInstant, Sleep};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use super::algorithm_policy::build_client_config;
use crate::config::AppConfig;
use crate::error::{AuthError, ConnectionError, SecurityError, SftpError};
use crate::security::{fingerprint_sha256, HostKeyCheckResult, KnownHostsManager};

/// Callback invoked when a host key is not yet trusted.
pub trait HostKeyPrompt: Send + Sync {
    /// Prompts the user to accept or reject an unknown host key.
    fn prompt_unknown_host(&self, host: &str, port: u16, fingerprint_sha256: &str) -> bool;

    /// Prompts the user to accept or reject a changed host key.
    ///
    /// The default implementation rejects mismatches.
    fn prompt_mismatch_host(
        &self,
        host: &str,
        port: u16,
        expected_fingerprint_sha256: &str,
        actual_fingerprint_sha256: &str,
    ) -> bool {
        let _ = (
            host,
            port,
            expected_fingerprint_sha256,
            actual_fingerprint_sha256,
        );
        false
    }
}

/// One challenge prompt from a keyboard-interactive authentication round.
#[derive(Debug, Clone)]
pub struct KbdInteractivePrompt {
    pub text: String,
    pub echo: bool,
}

/// Callback invoked when the server requests keyboard-interactive input
/// (PAM/2FA challenges, `KbdInteractiveAuthentication yes` servers).
pub trait AuthPromptHandler: Send + Sync {
    /// Shows the challenge to the user and returns one answer per prompt.
    /// `None` answers mean the user cancelled; authentication is abandoned.
    fn prompt(
        &self,
        name: &str,
        instructions: &str,
        prompts: &[KbdInteractivePrompt],
    ) -> Vec<Option<String>>;
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
    upload_pipeline_depth: usize,
}

struct SshClientHandler {
    host: String,
    port: u16,
    known_hosts: Arc<Mutex<KnownHostsManager>>,
    prompt: Arc<dyn HostKeyPrompt>,
    prompt_deadline: Arc<PromptAwareDeadline>,
    known_hosts_strict_mode: bool,
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
            manager.check_host_key(
                &self.host,
                self.port,
                server_public_key,
                self.known_hosts_strict_mode,
            )
        };

        match check {
            HostKeyCheckResult::Trust => Ok(true),
            HostKeyCheckResult::Reject => Err(ConnectionError::HostKeyRejected {
                host: self.host.clone(),
                port: self.port,
            }),
            HostKeyCheckResult::Mismatch {
                expected_fingerprint,
                actual_fingerprint,
            } => {
                let prompt_started_at = TokioInstant::now();
                let accept = self.prompt.prompt_mismatch_host(
                    &self.host,
                    self.port,
                    &expected_fingerprint,
                    &actual_fingerprint,
                );
                self.prompt_deadline.extend_by(prompt_started_at.elapsed());

                if !accept {
                    return Err(SecurityError::HostKeyMismatch {
                        host: self.host.clone(),
                        port: self.port,
                        expected: expected_fingerprint,
                        actual: actual_fingerprint,
                    }
                    .into());
                }

                let mut manager = self.known_hosts.lock().await;
                manager
                    .accept_host_key(&self.host, self.port, server_public_key)
                    .map_err(ConnectionError::from)?;
                Ok(true)
            }
            HostKeyCheckResult::Unknown => {
                let prompt_started_at = TokioInstant::now();
                let accept = self
                    .prompt
                    .prompt_unknown_host(&self.host, self.port, &fingerprint);
                self.prompt_deadline.extend_by(prompt_started_at.elapsed());

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

/// A deadline that can be extended after interactive host-key prompts.
#[derive(Debug)]
struct PromptAwareDeadline {
    deadline: std::sync::Mutex<TokioInstant>,
}

impl PromptAwareDeadline {
    fn from_secs(secs: u64) -> Self {
        Self {
            deadline: std::sync::Mutex::new(TokioInstant::now() + Duration::from_secs(secs)),
        }
    }

    fn extend_by(&self, elapsed: Duration) {
        let mut deadline = self.deadline.lock().expect("prompt deadline lock poisoned");
        *deadline += elapsed;
    }
}

/// Applies a timeout whose deadline can be extended while a prompt blocks the future.
struct PromptAwareTimeout<F> {
    future: std::pin::Pin<Box<F>>,
    deadline: Arc<PromptAwareDeadline>,
    sleep: std::pin::Pin<Box<Sleep>>,
}

impl<F: std::future::Future> PromptAwareTimeout<F> {
    fn new(future: F, deadline: Arc<PromptAwareDeadline>) -> Self {
        let initial_deadline = *deadline
            .deadline
            .lock()
            .expect("prompt deadline lock poisoned");
        Self {
            future: Box::pin(future),
            deadline,
            sleep: Box::pin(tokio::time::sleep_until(initial_deadline)),
        }
    }
}

impl<F: std::future::Future> std::future::Future for PromptAwareTimeout<F> {
    type Output = Result<F::Output, ()>;

    fn poll(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Self::Output> {
        if let std::task::Poll::Ready(output) = self.future.as_mut().poll(cx) {
            return std::task::Poll::Ready(Ok(output));
        }

        let current_deadline = *self
            .deadline
            .deadline
            .lock()
            .expect("prompt deadline lock poisoned");
        if self.sleep.as_ref().get_ref().deadline() != current_deadline {
            self.sleep = Box::pin(tokio::time::sleep_until(current_deadline));
        }
        if self.sleep.as_mut().poll(cx).is_ready() {
            return std::task::Poll::Ready(Err(()));
        }

        std::task::Poll::Pending
    }
}

impl SshSession {
    /// Connects to a remote host and opens an SFTP subsystem.
    pub async fn connect(
        profile: ConnectionProfile,
        config: &AppConfig,
        known_hosts: Arc<Mutex<KnownHostsManager>>,
        prompt: Arc<dyn HostKeyPrompt>,
        auth_prompt: Option<Arc<dyn AuthPromptHandler>>,
    ) -> Result<Self, crate::error::AppError> {
        let host = profile.host.clone();
        let port = profile.port;
        let username = profile.username.clone();

        {
            let mut manager = known_hosts.lock().await;
            manager.merge_openssh_on_connect(config)?;
        }

        let russh_config = build_client_config(config);

        let prompt_deadline = Arc::new(PromptAwareDeadline::from_secs(
            config.connection_timeout_secs,
        ));

        let handler = SshClientHandler {
            host: host.clone(),
            port,
            known_hosts,
            prompt,
            prompt_deadline: prompt_deadline.clone(),
            known_hosts_strict_mode: config.known_hosts_strict_mode,
        };

        let connect_future =
            client::connect(Arc::new(russh_config), (host.as_str(), port), handler);

        let mut handle = PromptAwareTimeout::new(connect_future, prompt_deadline)
            .await
        .map_err(|_| ConnectionError::Timeout {
            timeout_secs: config.connection_timeout_secs,
        })?
        .map_err(|err| preserve_connection_error(err, &host, port))?;

        // TCP/SSH handshake and post-handshake startup have separate budgets.
        // Authentication, channel open, subsystem request and SFTP INIT share
        // this second deadline, so no server-response wait is unbounded (#663).
        let deadline =
            tokio::time::Instant::now() + Duration::from_secs(config.connection_timeout_secs);

        let authenticated = tokio::time::timeout_at(
            deadline,
            authenticate(
                &mut handle,
                &username,
                &profile.auth,
                &host,
                port,
                auth_prompt.as_ref(),
            ),
        )
        .await
        .map_err(|_| ConnectionError::Timeout {
            timeout_secs: config.connection_timeout_secs,
        })??;

        if !authenticated {
            return Err(AuthError::Failed { username }.into());
        }

        let channel = tokio::time::timeout_at(deadline, handle.channel_open_session())
            .await
            .map_err(|_| ConnectionError::Timeout {
                timeout_secs: config.connection_timeout_secs,
            })?
            .map_err(|err| ConnectionError::ConnectFailed {
                host: host.clone(),
                port,
                message: err.to_string(),
            })?;

        tokio::time::timeout_at(deadline, channel.request_subsystem(true, "sftp"))
            .await
            .map_err(|_| ConnectionError::Timeout {
                timeout_secs: config.connection_timeout_secs,
            })?
            .map_err(|err| SftpError::SubsystemFailed {
                message: err.to_string(),
            })?;

        let sftp = tokio::time::timeout_at(
            deadline,
            SftpSession::new_with_config(
                channel.into_stream(),
                SftpConfig {
                    max_concurrent_writes: config.transfer_upload_pipeline_depth,
                    ..SftpConfig::default()
                },
            ),
        )
        .await
        .map_err(|_| ConnectionError::Timeout {
            timeout_secs: config.connection_timeout_secs,
        })?
        .map_err(|err| SftpError::SubsystemFailed {
            message: err.to_string(),
        })?;

        sftp.set_timeout(config.connection_timeout_secs);

        Ok(Self {
            handle,
            sftp,
            host,
            port,
            upload_pipeline_depth: config.transfer_upload_pipeline_depth,
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

    /// Maximum number of concurrent in-flight SFTP WRITE requests configured
    /// when this session was created.
    pub(crate) fn upload_pipeline_depth(&self) -> usize {
        self.upload_pipeline_depth
    }
}

async fn authenticate(
    handle: &mut Handle<SshClientHandler>,
    username: &str,
    auth: &AuthType,
    host: &str,
    port: u16,
    auth_prompt: Option<&Arc<dyn AuthPromptHandler>>,
) -> Result<bool, crate::error::AppError> {
    match auth {
        AuthType::Password { password } => {
            let result = handle
                .authenticate_password(username, password.expose())
                .await
                .map_err(|err| ConnectionError::ConnectFailed {
                    host: host.to_string(),
                    port,
                    message: err.to_string(),
                })?;
            if result.success() {
                return Ok(true);
            }
            // The server rejected the password but may still offer
            // keyboard-interactive (PAM/2FA, or `PasswordAuthentication no`
            // with `KbdInteractiveAuthentication yes`). Fall through to it
            // when offered and a prompt handler is wired up; otherwise
            // surface the plain failure — or, when the server no longer
            // offers any method at all, the dedicated error.
            match &result {
                AuthResult::Failure {
                    remaining_methods, ..
                } => {
                    if remaining_methods.contains(&MethodKind::KeyboardInteractive) {
                        if let Some(handler) = auth_prompt {
                            return keyboard_interactive_auth(
                                handle, username, host, port, handler,
                            )
                            .await;
                        }
                        return Ok(false);
                    }
                    if remaining_methods.is_empty() {
                        return Err(AuthError::MethodUnavailable.into());
                    }
                    Ok(false)
                }
                _ => Ok(false),
            }
        }
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
            let rsa_hash = handle.best_supported_rsa_hash().await.map_err(|err| {
                ConnectionError::ConnectFailed {
                    host: host.to_string(),
                    port,
                    message: err.to_string(),
                }
            })?;
            let signing_key = PrivateKeyWithHashAlg::new(Arc::new(private_key), rsa_hash.flatten());
            let result = handle
                .authenticate_publickey(username, signing_key)
                .await
                .map_err(|err| ConnectionError::ConnectFailed {
                    host: host.to_string(),
                    port,
                    message: err.to_string(),
                })?;
            // Public key accepted but the server still requires an additional
            // challenge (e.g. TOTP via keyboard-interactive). Fall through to
            // keyboard-interactive when offered and a prompt handler is wired
            // up (issue #800).
            if result.success() {
                return Ok(true);
            }
            match &result {
                AuthResult::Failure {
                    remaining_methods, ..
                } => {
                    if remaining_methods.contains(&MethodKind::KeyboardInteractive) {
                        if let Some(handler) = auth_prompt {
                            return keyboard_interactive_auth(
                                handle, username, host, port, handler,
                            )
                            .await;
                        }
                        return Ok(false);
                    }
                    if remaining_methods.is_empty() {
                        return Err(AuthError::MethodUnavailable.into());
                    }
                    Ok(false)
                }
                _ => Ok(false),
            }
        }
    }
}

/// Keeps structured connection errors intact and only flattens low-level
/// transport errors into `ConnectFailed`. This preserves host-key rejection and
/// mismatch details across `client::connect`.
fn preserve_connection_error(
    error: ConnectionError,
    host: &str,
    port: u16,
) -> crate::error::AppError {
    match error {
        err @ (ConnectionError::HostKeyRejected { .. } | ConnectionError::Timeout { .. }) => {
            err.into()
        }
        ConnectionError::Other(source) => match source.downcast::<SecurityError>() {
            Ok(security) => security.into(),
            Err(source) => ConnectionError::ConnectFailed {
                host: host.to_string(),
                port,
                message: source.to_string(),
            }
            .into(),
        },
        error => ConnectionError::ConnectFailed {
            host: host.to_string(),
            port,
            message: error.to_string(),
        }
        .into(),
    }
}

/// Runs a keyboard-interactive authentication round against the server,
/// relaying each `USERAUTH_INFO_REQUEST` to the user-facing prompt handler.
async fn keyboard_interactive_auth(
    handle: &mut Handle<SshClientHandler>,
    username: &str,
    host: &str,
    port: u16,
    auth_prompt: &Arc<dyn AuthPromptHandler>,
) -> Result<bool, crate::error::AppError> {
    let connect_failed = |err: russh::Error| ConnectionError::ConnectFailed {
        host: host.to_string(),
        port,
        message: err.to_string(),
    };
    let mut response = handle
        .authenticate_keyboard_interactive_start(username, None)
        .await
        .map_err(connect_failed)?;
    loop {
        let prompts = match response {
            KeyboardInteractiveAuthResponse::Success => return Ok(true),
            KeyboardInteractiveAuthResponse::Failure { .. } => {
                // The server rejected the answers; report plain failure.
                return Ok(false);
            }
            KeyboardInteractiveAuthResponse::InfoRequest {
                name,
                instructions,
                prompts,
            } => (name, instructions, prompts),
        };
        let (name, instructions, raw_prompts) = prompts;
        let challenge: Vec<KbdInteractivePrompt> = raw_prompts
            .iter()
            .map(|prompt| KbdInteractivePrompt {
                text: prompt.prompt.clone(),
                echo: prompt.echo,
            })
            .collect();
        let mut answers = auth_prompt.prompt(&name, &instructions, &challenge);
        if answers.len() != challenge.len() || answers.iter().any(Option::is_none) {
            // Cancelled: abandon the round instead of sending partial answers.
            answers.zeroize();
            return Ok(false);
        }
        // russh owns Vec<String> while sending the round. Move the answers
        // directly rather than retaining an extra plaintext clone. Cancellation
        // above is zeroized here; russh's internal buffers are outside our control.
        let responses = answers
            .into_iter()
            .map(|answer| answer.unwrap_or_default())
            .collect();
        response = handle
            .authenticate_keyboard_interactive_respond(responses)
            .await
            .map_err(connect_failed)?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserve_connection_error_keeps_host_key_rejection() {
        // Given: a structured host-key rejection from the SSH handler
        let original = ConnectionError::HostKeyRejected {
            host: "example.com".to_string(),
            port: 2222,
        };

        // When: the connect future is flattened for reporting
        let mapped = preserve_connection_error(original, "example.com", 2222);

        // Then: the typed rejection is preserved instead of becoming ConnectFailed
        assert!(matches!(
            mapped,
            crate::error::AppError::Connection(ConnectionError::HostKeyRejected { host, port })
                if host == "example.com" && port == 2222
        ));
    }

    #[test]
    fn preserve_connection_error_keeps_handler_security_errors() {
        for security in [
            SecurityError::HostKeyRejected {
                host: "example.com".into(),
                port: 2222,
            },
            SecurityError::HostKeyMismatch {
                host: "example.com".into(),
                port: 2222,
                expected: "old".into(),
                actual: "new".into(),
            },
        ] {
            let expected = security.to_string();
            let mapped = preserve_connection_error(security.into(), "example.com", 2222);
            assert!(matches!(mapped, crate::error::AppError::Security(_)));
            assert_eq!(mapped.to_string(), expected);
        }
    }

    #[tokio::test]
    async fn prompt_time_extends_connect_timeout() {
        let deadline = Arc::new(PromptAwareDeadline::from_secs(1));
        let future = {
            let deadline = deadline.clone();
            async move {
                deadline.extend_by(Duration::from_secs(1));
                tokio::time::sleep(Duration::from_millis(1500)).await;
            }
        };

        let result = tokio::time::timeout(
            Duration::from_secs(3),
            PromptAwareTimeout::new(future, deadline),
        )
        .await;

        assert!(matches!(result, Ok(Ok(()))));
    }

    use std::sync::atomic::{AtomicBool, Ordering};

    use crate::sftp::test_server::{FailureConfig, TestSftpServer};

    struct TrustTestHost;

    impl HostKeyPrompt for TrustTestHost {
        fn prompt_unknown_host(&self, _: &str, _: u16, _: &str) -> bool {
            true
        }
    }

    async fn assert_stalled_phase_times_out(
        stage: &str,
        select_flag: fn(&FailureConfig) -> &AtomicBool,
    ) {
        let server = TestSftpServer::start().await;
        select_flag(&server.failures).store(true, Ordering::SeqCst);
        let directory = tempfile::tempdir().unwrap();
        let config = AppConfig {
            connection_timeout_secs: 1,
            known_hosts_path: directory.path().join("known_hosts.json"),
            merge_openssh_known_hosts_on_connect: false,
            ..AppConfig::default()
        };
        let known_hosts = Arc::new(Mutex::new(
            KnownHostsManager::load(&config.known_hosts_path).unwrap(),
        ));
        let profile =
            ConnectionProfile::with_password("127.0.0.1", server.addr.port(), "test", "test");
        let connection =
            SshSession::connect(profile, &config, known_hosts, Arc::new(TrustTestHost), None);
        // The server must reach the selected phase; a handshake timeout alone
        // must not make this regression test pass.
        let (result, ()) = tokio::time::timeout(Duration::from_secs(3), async {
            tokio::join!(
                connection,
                server.failures.connection_phase_started.notified()
            )
        })
        .await
        .unwrap_or_else(|_| panic!("stalled {stage} exceeded the configured timeout"));
        assert!(
            matches!(
                result,
                Err(crate::error::AppError::Connection(
                    ConnectionError::Timeout { timeout_secs: 1 }
                ))
            ),
            "stalled {stage} must return a connection timeout"
        );
    }

    #[tokio::test]
    async fn connect_times_out_when_authentication_stalls() {
        assert_stalled_phase_times_out("authentication", |failures| &failures.hang_auth).await;
    }

    #[tokio::test]
    async fn connect_times_out_when_channel_open_stalls() {
        assert_stalled_phase_times_out("channel open", |failures| &failures.hang_channel_open)
            .await;
    }

    #[tokio::test]
    async fn connect_times_out_when_subsystem_request_stalls() {
        assert_stalled_phase_times_out("subsystem request", |failures| {
            &failures.hang_subsystem_request
        })
        .await;
    }

    #[tokio::test]
    async fn connect_times_out_when_sftp_init_stalls() {
        assert_stalled_phase_times_out("SFTP INIT", |failures| &failures.hang_sftp_init).await;
    }
}
