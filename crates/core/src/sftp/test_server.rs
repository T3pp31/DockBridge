use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::sftp::tree::normalize_remote_path;
use russh::keys::{Algorithm, PrivateKey};
use russh::server::{Auth, Msg, Server as _, Session};
use russh::{Channel, ChannelId};
use russh::{MethodKind, MethodSet};
use russh_sftp::de;
use russh_sftp::extensions::{PosixRenameExtension, POSIX_RENAME};
use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle, Name, OpenFlags, Packet, Status, StatusCode, Version,
};
use tokio::fs::{self, OpenOptions};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Mutex as AsyncMutex;

use crate::config::AppConfig;
use crate::security::KnownHostsManager;
use crate::ssh::{ConnectionProfile, HostKeyPrompt, SshSession};

#[derive(Default)]
pub struct FailureConfig {
    /// Post-handshake connection phases that can stop replying in timeout tests.
    pub hang_auth: AtomicBool,
    pub hang_channel_open: AtomicBool,
    pub hang_subsystem_request: AtomicBool,
    pub hang_sftp_init: AtomicBool,
    pub connection_phase_started: tokio::sync::Notify,
    pub fail_remote_write: AtomicBool,
    pub fail_remote_read: AtomicBool,
    pub fail_remote_close: AtomicBool,
    pub fail_remote_rename: AtomicBool,
    pub fail_setstat: AtomicBool,
    pub fail_mkdir: AtomicBool,
    pub opendir_count: AtomicU64,
    /// Number of SSH_FXP_MKDIR requests handled, used to assert that
    /// directory mirrors issue at most one mkdir per directory (issue #312).
    pub mkdir_count: AtomicU64,
    /// When set, a single OPENDIR for exactly this path fails (one-shot),
    /// letting tests simulate an unreadable remote subdirectory during a walk
    /// (issue #316).
    pub fail_opendir_path: Mutex<Option<String>>,
    /// Artificial delay applied to every SSH_FXP_READ reply, used by benchmarks
    /// to emulate a high-latency link (milliseconds).
    pub read_delay_ms: AtomicU64,
    /// Signals that a READ handler has started, before its optional delay.
    pub read_started: tokio::sync::Notify,
    /// Pauses a single opened file so tests can replace its pathname.
    pub pause_after_open: AtomicBool,
    pub file_opened: tokio::sync::Notify,
    pub continue_open: tokio::sync::Notify,
    /// When `true`, `open` with `SSH_FX_EXCLUDE` reports `SSH_FX_PERMISSION_DENIED`
    /// for an already-existing exclusive path (some servers' EEXIST).
    pub exclude_exists_permission_denied: AtomicBool,
    /// When `true`, the server receives WRITEs but does not acknowledge them
    /// until [`write_unhang`](Self::write_unhang) is notified, simulating a
    /// stalled link (issue #306). Clients must break out via timeout or
    /// cancellation.
    pub hang_write: AtomicBool,
    /// Notifies a single blocked WRITE handler to stop hanging and reply.
    pub write_unhang: tokio::sync::Notify,
    /// Whether the server advertises `posix-rename@openssh.com` in its
    /// SSH_FXP_VERSION and serves the extension. Defaults to `true` so tests
    /// exercise the OpenSSH-compatible atomic-overwrite path; set to `false`
    /// to simulate a server that lacks the extension.
    pub advertise_posix_rename: AtomicBool,
    /// When `true`, password authentication is rejected with
    /// keyboard-interactive listed as a remaining method, and the secret must
    /// be supplied via a keyboard-interactive round (issue #317).
    pub require_keyboard_interactive: AtomicBool,
    /// When `true`, every authentication method is rejected with no remaining
    /// methods offered at all (issue #317 `MethodUnavailable` case).
    pub reject_all_auth: AtomicBool,
    /// The secret expected by the keyboard-interactive challenge when
    /// [`Self::require_keyboard_interactive`] is set.
    pub keyboard_interactive_secret: Mutex<String>,
}

/// Secret required by the test server's keyboard-interactive challenge.
pub const KEYBOARD_INTERACTIVE_SECRET: &str = "kbd-interactive-secret";

#[derive(serde::Deserialize)]
struct TestServerSettings {
    accept_retry_delay_ms: u64,
}

struct AcceptAllPrompt;
impl HostKeyPrompt for AcceptAllPrompt {
    fn prompt_unknown_host(&self, _: &str, _: u16, _: &str) -> bool {
        true
    }
}

pub struct TestSftpServer {
    pub addr: SocketAddr,
    pub root: PathBuf,
    #[allow(dead_code)]
    pub failures: Arc<FailureConfig>,
    _root_dir: tempfile::TempDir,
    _known_hosts_dir: tempfile::TempDir,
    _server_task: tokio::task::JoinHandle<()>,
}

struct ServerFactory {
    clients: Arc<Mutex<HashMap<ChannelId, Channel<Msg>>>>,
    root: PathBuf,
    failures: Arc<FailureConfig>,
}

#[derive(Clone)]
struct ServerImpl {
    clients: Arc<Mutex<HashMap<ChannelId, Channel<Msg>>>>,
    root: PathBuf,
    failures: Arc<FailureConfig>,
}

impl russh::server::Server for ServerFactory {
    type Handler = ServerImpl;

    fn new_client(&mut self, _: Option<SocketAddr>) -> Self::Handler {
        ServerImpl {
            clients: Arc::clone(&self.clients),
            root: self.root.clone(),
            failures: Arc::clone(&self.failures),
        }
    }
}

impl russh::server::Handler for ServerImpl {
    type Error = anyhow::Error;

    async fn auth_password(&mut self, _user: &str, _password: &str) -> Result<Auth, Self::Error> {
        if self.failures.hang_auth.load(Ordering::SeqCst) {
            self.failures.connection_phase_started.notify_one();
            std::future::pending::<()>().await;
        }
        if self.failures.reject_all_auth.load(Ordering::SeqCst) {
            // An explicit empty set: no method is offered afterwards, which
            // the client must map to AuthError::MethodUnavailable.
            return Ok(Auth::Reject {
                proceed_with_methods: Some(MethodSet::empty()),
                partial_success: false,
            });
        }
        if self
            .failures
            .require_keyboard_interactive
            .load(Ordering::SeqCst)
        {
            // Mirror `PasswordAuthentication no`: steer the client to
            // keyboard-interactive instead of hard-failing.
            let mut methods = MethodSet::empty();
            methods.push(MethodKind::KeyboardInteractive);
            return Ok(Auth::Reject {
                proceed_with_methods: Some(methods),
                partial_success: false,
            });
        }
        Ok(Auth::Accept)
    }

    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        _user: &str,
        _submethods: &str,
        response: Option<russh::server::Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        let Some(response) = response else {
            return Ok(Auth::Partial {
                name: "DockBridge test".into(),
                instructions: "Enter the test secret".into(),
                prompts: std::borrow::Cow::Owned(vec![(
                    std::borrow::Cow::Borrowed("Password: "),
                    false,
                )]),
            });
        };
        let expected = self
            .failures
            .keyboard_interactive_secret
            .lock()
            .unwrap()
            .clone();
        let answers: Vec<Vec<u8>> = response.map(|item| item.to_vec()).collect();
        if answers.len() == 1 && answers[0] == expected.as_bytes() {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
                partial_success: false,
            })
        }
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<Msg>,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        if self.failures.hang_channel_open.load(Ordering::SeqCst) {
            self.failures.connection_phase_started.notify_one();
            std::future::pending::<()>().await;
        }
        self.clients.lock().unwrap().insert(channel.id(), channel);
        Ok(true)
    }

    async fn subsystem_request(
        &mut self,
        channel_id: ChannelId,
        name: &str,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.failures.hang_subsystem_request.load(Ordering::SeqCst) {
            self.failures.connection_phase_started.notify_one();
            std::future::pending::<()>().await;
        }
        if name != "sftp" {
            session.channel_failure(channel_id)?;
            return Ok(());
        }

        let channel = self.clients.lock().unwrap().remove(&channel_id).unwrap();
        let sftp = SftpHandler {
            root: self.root.clone(),
            failures: Arc::clone(&self.failures),
            handles: HashMap::new(),
            dir_handles: HashMap::new(),
            next_handle: 1,
        };
        session.channel_success(channel_id)?;
        russh_sftp::server::run(channel.into_stream(), sftp).await;
        Ok(())
    }
}

struct OpenHandle {
    file: tokio::fs::File,
}

struct DirHandle {
    entries: Vec<File>,
    read_offset: usize,
}

struct SftpHandler {
    root: PathBuf,
    failures: Arc<FailureConfig>,
    handles: HashMap<String, OpenHandle>,
    dir_handles: HashMap<String, DirHandle>,
    next_handle: u64,
}

impl SftpHandler {
    /// Resolves a remote path inside the sandbox, rejecting paths that escape
    /// via lexical components (issue #657).
    fn resolve(&self, path: &str) -> PathBuf {
        let mut components: Vec<String> = vec![];
        for raw in path.split('/') {
            match raw {
                "" | "." => continue,
                ".." => {
                    components.pop();
                }
                other => components.push(other.to_string()),
            }
        }
        components
            .iter()
            .fold(self.root.clone(), |acc, component| acc.join(component))
    }

    /// Returns whether the resolved path is still inside the sandbox root.
    fn is_within_root(&self, path: &Path) -> bool {
        path.starts_with(&self.root)
    }

    fn attrs_for(path: &Path) -> FileAttributes {
        let mut attrs = FileAttributes::empty();
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;

            let metadata = match std::fs::symlink_metadata(path) {
                Ok(metadata) => metadata,
                Err(_) => return attrs,
            };
            attrs.uid = Some(metadata.uid());
            attrs.gid = Some(metadata.gid());
            attrs.permissions = Some(metadata.mode());
            attrs.mtime = metadata.mtime().try_into().ok();
            if metadata.is_file() {
                attrs.size = Some(metadata.len());
            }
            attrs
        }
        #[cfg(not(unix))]
        {
            if path.is_dir() {
                attrs.set_dir(true);
            } else if path.is_file() {
                attrs.set_regular(true);
                attrs.size = std::fs::metadata(path).ok().map(|meta| meta.len());
            }
            attrs
        }
    }

    /// Like `attrs_for`, but follows symlinks (matching SFTP `STAT`, which
    /// resolves the target for the attributes).
    fn attrs_for_follow(path: &Path) -> FileAttributes {
        let mut attrs = FileAttributes::empty();
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let metadata = match std::fs::metadata(path) {
                Ok(meta) => meta,
                Err(_) => return Self::attrs_for(path),
            };
            attrs.uid = Some(metadata.uid());
            attrs.gid = Some(metadata.gid());
            attrs.permissions = Some(metadata.mode());
            if metadata.is_file() {
                attrs.size = Some(metadata.len());
            }
            attrs.mtime = metadata.mtime().try_into().ok();
            attrs
        }
        #[cfg(not(unix))]
        {
            Self::attrs_for(path)
        }
    }

    async fn read_directory_entries(&self, path: &str) -> Result<Vec<File>, StatusCode> {
        let local = self.resolve(path);
        if !local.exists() {
            return Err(StatusCode::NoSuchFile);
        }
        if !local.is_dir() {
            return Err(StatusCode::Failure);
        }

        let mut entries = Vec::new();
        let mut read_dir = fs::read_dir(&local)
            .await
            .map_err(|_| StatusCode::Failure)?;
        while let Some(entry) = read_dir
            .next_entry()
            .await
            .map_err(|_| StatusCode::Failure)?
        {
            let file_name = entry.file_name().to_string_lossy().into_owned();
            if file_name == "." || file_name == ".." {
                continue;
            }
            let child_remote = if path == "/" {
                format!("/{file_name}")
            } else {
                format!("{path}/{file_name}")
            };
            let local = self.resolve(&child_remote);
            entries.push(File::new(file_name, Self::attrs_for(&local)));
        }
        entries.sort_by(|left, right| left.filename.cmp(&right.filename));
        Ok(entries)
    }

    fn ok_status(id: u32) -> Status {
        Status {
            id,
            status_code: StatusCode::Ok,
            error_message: "Ok".to_string(),
            language_tag: "en-US".to_string(),
        }
    }

    fn err_status(id: u32, code: StatusCode, message: impl Into<String>) -> Status {
        Status {
            id,
            status_code: code,
            error_message: message.into(),
            language_tag: "en-US".to_string(),
        }
    }
}

impl russh_sftp::server::Handler for SftpHandler {
    type Error = StatusCode;

    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }

    async fn init(
        &mut self,
        _version: u32,
        _extensions: HashMap<String, String>,
    ) -> Result<Version, Self::Error> {
        if self.failures.hang_sftp_init.load(Ordering::SeqCst) {
            self.failures.connection_phase_started.notify_one();
            std::future::pending::<()>().await;
        }
        let mut version = Version::new();
        if self.failures.advertise_posix_rename.load(Ordering::SeqCst) {
            version
                .extensions
                .insert(POSIX_RENAME.to_string(), "1".to_string());
        }
        Ok(version)
    }

    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        // Match real servers: the resolved path must exist and the returned
        // remote path must be a normalized absolute form (issue #795).
        let local = self.resolve(&path);
        if !local.exists() {
            return Err(StatusCode::NoSuchFile);
        }
        Ok(Name {
            id,
            files: vec![File::dummy(
                normalize_remote_path(&path).unwrap_or_else(|_| format!("/{path}")),
            )],
        })
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let local = self.resolve(&path);
        if !local.exists() {
            return Err(StatusCode::NoSuchFile);
        }
        Ok(Attrs {
            id,
            attrs: Self::attrs_for_follow(&local),
        })
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let local = self.resolve(&path);
        if std::fs::symlink_metadata(&local).is_err() {
            return Err(StatusCode::NoSuchFile);
        }
        Ok(Attrs {
            id,
            attrs: Self::attrs_for(&local),
        })
    }

    async fn fstat(&mut self, id: u32, handle: String) -> Result<Attrs, Self::Error> {
        let open = self.handles.get(&handle).ok_or(StatusCode::Failure)?;
        let metadata = open
            .file
            .metadata()
            .await
            .map_err(|_| StatusCode::Failure)?;
        let mut attrs = FileAttributes::empty();
        if metadata.is_file() {
            attrs.set_regular(true);
            attrs.size = Some(metadata.len());
        } else if metadata.is_dir() {
            attrs.set_dir(true);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            attrs.uid = Some(metadata.uid());
            attrs.gid = Some(metadata.gid());
            attrs.permissions = Some(metadata.mode());
            attrs.mtime = metadata.mtime().try_into().ok();
        }
        Ok(Attrs { id, attrs })
    }

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        pflags: OpenFlags,
        _attrs: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        let local = self.resolve(&filename);
        if !self.is_within_root(&local) {
            return Err(StatusCode::PermissionDenied);
        }
        // Missing parents must fail instead of being created by OPEN.
        if let Some(parent) = local.parent() {
            if !parent.is_dir() {
                return Err(StatusCode::NoSuchFile);
            }
        }
        let mut options = OpenOptions::new();
        if pflags.contains(OpenFlags::READ) {
            options.read(true);
        }
        if pflags.contains(OpenFlags::WRITE) {
            options.write(true);
        }
        if pflags.contains(OpenFlags::CREATE) {
            options.create(true);
        }
        if pflags.contains(OpenFlags::EXCLUDE) {
            options.create_new(true);
        }
        if pflags.contains(OpenFlags::TRUNCATE) {
            options.truncate(true);
        }
        if pflags.contains(OpenFlags::APPEND) {
            options.append(true);
        }

        let file = options.open(&local).await.map_err(|err| {
            if err.kind() == std::io::ErrorKind::AlreadyExists {
                if self
                    .failures
                    .exclude_exists_permission_denied
                    .load(Ordering::Relaxed)
                {
                    // Some servers report EEXIST as permission denied.
                    StatusCode::PermissionDenied
                } else {
                    StatusCode::Failure
                }
            } else if err.kind() == std::io::ErrorKind::NotFound {
                StatusCode::NoSuchFile
            } else if err.kind() == std::io::ErrorKind::PermissionDenied {
                StatusCode::PermissionDenied
            } else {
                StatusCode::Failure
            }
        })?;

        if self.failures.pause_after_open.swap(false, Ordering::SeqCst) {
            self.failures.file_opened.notify_one();
            self.failures.continue_open.notified().await;
        }

        let handle_id = self.next_handle;
        self.next_handle += 1;
        let handle = format!("handle-{handle_id}");
        self.handles.insert(handle.clone(), OpenHandle { file });
        Ok(Handle { id, handle })
    }

    async fn read(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, Self::Error> {
        if self.failures.fail_remote_read.swap(false, Ordering::SeqCst) {
            return Err(StatusCode::Failure);
        }

        #[cfg(test)]
        {
            self.failures.read_started.notify_one();
            let delay = self.failures.read_delay_ms.load(Ordering::Relaxed);
            if delay > 0 {
                tokio::time::sleep(Duration::from_millis(delay)).await;
            }
