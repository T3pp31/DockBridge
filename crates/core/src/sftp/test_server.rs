use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::keys::{Algorithm, PrivateKey};
use russh::server::{Auth, Msg, Server as _, Session};
use russh::{MethodKind, MethodSet};
use russh::{Channel, ChannelId};
use russh_sftp::de;
use russh_sftp::extensions::{POSIX_RENAME, PosixRenameExtension};
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
        self.clients.lock().unwrap().insert(channel.id(), channel);
        Ok(true)
    }

    async fn subsystem_request(
        &mut self,
        channel_id: ChannelId,
        name: &str,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
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
    fn resolve(&self, path: &str) -> PathBuf {
        let trimmed = path.trim_start_matches('/');
        if trimmed.is_empty() {
            self.root.clone()
        } else {
            self.root.join(trimmed)
        }
    }

    fn canonical(&self, path: &str) -> String {
        if path == "." || path.is_empty() {
            return "/".to_string();
        }
        if path.starts_with('/') {
            path.to_string()
        } else {
            format!("/{path}")
        }
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
        let mut version = Version::new();
        if self
            .failures
            .advertise_posix_rename
            .load(Ordering::SeqCst)
        {
            version
                .extensions
                .insert(POSIX_RENAME.to_string(), "1".to_string());
        }
        Ok(version)
    }

    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        Ok(Name {
            id,
            files: vec![File::dummy(self.canonical(&path))],
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

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        pflags: OpenFlags,
        _attrs: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        let local = self.resolve(&filename);
        if let Some(parent) = local.parent() {
            fs::create_dir_all(parent)
                .await
                .map_err(|_| StatusCode::Failure)?;
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
            } else {
                StatusCode::Failure
            }
        })?;

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
            let delay = self.failures.read_delay_ms.load(Ordering::Relaxed);
            if delay > 0 {
                tokio::time::sleep(Duration::from_millis(delay)).await;
            }
        }

        let open = self.handles.get_mut(&handle).ok_or(StatusCode::Failure)?;
        open.file
            .seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|_| StatusCode::Failure)?;
        let mut buffer = vec![0_u8; len as usize];
        let bytes_read = open
            .file
            .read(&mut buffer)
            .await
            .map_err(|_| StatusCode::Failure)?;
        buffer.truncate(bytes_read);
        Ok(Data { id, data: buffer })
    }

    async fn write(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        if self
            .failures
            .fail_remote_write
            .swap(false, Ordering::SeqCst)
        {
            return Ok(Self::err_status(id, StatusCode::Failure, "write failed"));
        }

        // Simulate a server that stalls on a WRITE ack (issue #306): block
        // this handler until `write_unhang` is notified. The client must time
        // out or cancel out of the write rather than hang forever.
        if self.failures.hang_write.load(Ordering::Relaxed) {
            self.failures.write_unhang.notified().await;
        }

        let open = self.handles.get_mut(&handle).ok_or(StatusCode::Failure)?;
        open.file
            .seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|_| StatusCode::Failure)?;
        open.file
            .write_all(&data)
            .await
            .map_err(|_| StatusCode::Failure)?;
        Ok(Self::ok_status(id))
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, Self::Error> {
        if self
            .failures
            .fail_remote_close
            .swap(false, Ordering::SeqCst)
        {
            self.handles.remove(&handle);
            self.dir_handles.remove(&handle);
            return Ok(Self::err_status(id, StatusCode::Failure, "close failed"));
        }
        self.handles.remove(&handle);
        self.dir_handles.remove(&handle);
        Ok(Self::ok_status(id))
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, Self::Error> {
        self.failures.opendir_count.fetch_add(1, Ordering::Relaxed);
        let should_fail = {
            let mut target = self.failures.fail_opendir_path.lock().unwrap();
            match target.as_ref() {
                Some(candidate) if *candidate == path => {
                    *target = None;
                    true
                }
                _ => false,
            }
        };
        if should_fail {
            return Err(StatusCode::Failure);
        }
        let entries = self.read_directory_entries(&path).await?;
        let handle_id = self.next_handle;
        self.next_handle += 1;
        let handle = format!("dir-{handle_id}");
        self.dir_handles.insert(
            handle.clone(),
            DirHandle {
                entries,
                read_offset: 0,
            },
        );
        Ok(Handle { id, handle })
    }

    async fn readdir(&mut self, id: u32, handle: String) -> Result<Name, Self::Error> {
        let dir = self
            .dir_handles
            .get_mut(&handle)
            .ok_or(StatusCode::Failure)?;
        if dir.read_offset >= dir.entries.len() {
            return Err(StatusCode::Eof);
        }
        let files = dir.entries[dir.read_offset..].to_vec();
        dir.read_offset = dir.entries.len();
        Ok(Name { id, files })
    }

    async fn mkdir(
        &mut self,
        id: u32,
        path: String,
        _attrs: FileAttributes,
    ) -> Result<Status, Self::Error> {
        if self.failures.fail_mkdir.swap(false, Ordering::SeqCst) {
            return Ok(Self::err_status(id, StatusCode::Failure, "Failure"));
        }
        self.failures.mkdir_count.fetch_add(1, Ordering::Relaxed);

        let local = self.resolve(&path);
        if local.exists() {
            return Ok(Self::err_status(id, StatusCode::Failure, "already exists"));
        }

        fs::create_dir(&local)
            .await
            .map_err(|_| StatusCode::Failure)?;
        Ok(Self::ok_status(id))
    }

    async fn remove(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        let local = self.resolve(&path);
        if fs::remove_file(&local).await.is_err() {
            return Ok(Self::err_status(id, StatusCode::NoSuchFile, "no such file"));
        }
        Ok(Self::ok_status(id))
    }

    async fn rmdir(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        let local = self.resolve(&path);
        if fs::remove_dir(&local).await.is_err() {
            return Ok(Self::err_status(id, StatusCode::Failure, "rmdir failed"));
        }
        Ok(Self::ok_status(id))
    }

    async fn symlink(
        &mut self,
        id: u32,
        linkpath: String,
        targetpath: String,
    ) -> Result<Status, Self::Error> {
        #[cfg(unix)]
        {
            let link = self.resolve(&linkpath);
            if let Some(parent) = link.parent() {
                if let Err(err) = fs::create_dir_all(parent).await {
                    tracing::warn!(path = %parent.display(), error = %err, "symlink parent mkdir failed");
                    return Ok(Self::err_status(id, StatusCode::Failure, "symlink failed"));
                }
            }
            // Absolute remote targets need translating into the test server's
            // local root. Relative targets must be stored verbatim because
            // READLINK returns the original value and resolution is relative
            // to the link's parent directory.
            let target_local = if targetpath.starts_with('/') {
                self.resolve(&targetpath)
            } else {
                PathBuf::from(&targetpath)
            };
            if std::os::unix::fs::symlink(&target_local, &link).is_err() {
                return Ok(Self::err_status(id, StatusCode::Failure, "symlink failed"));
            }
            Ok(Self::ok_status(id))
        }
        #[cfg(not(unix))]
        {
            let _ = (linkpath, targetpath);
            Err(self.unimplemented())
        }
    }

    async fn rename(
        &mut self,
        id: u32,
        oldpath: String,
        newpath: String,
    ) -> Result<Status, Self::Error> {
        if self
            .failures
            .fail_remote_rename
            .swap(false, Ordering::SeqCst)
        {
            return Ok(Self::err_status(id, StatusCode::Failure, "rename failed"));
        }
        let from = self.resolve(&oldpath);
        let to = self.resolve(&newpath);
        // Mirror OpenSSH's sftp-server: regular-file renames go through
        // link()+unlink() and refuse to replace an existing destination, so
        // a plain SSH_FXP_RENAME onto an existing file fails (issue #565).
        if let Ok(metadata) = fs::symlink_metadata(&to).await {
            if !metadata.is_dir() {
                return Ok(Self::err_status(
                    id,
                    StatusCode::Failure,
                    "rename: destination exists",
                ));
            }
        }
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent)
                .await
                .map_err(|_| StatusCode::Failure)?;
        }
        fs::rename(&from, &to)
            .await
            .map_err(|_| StatusCode::Failure)?;
        Ok(Self::ok_status(id))
    }

    async fn extended(
        &mut self,
        id: u32,
        request: String,
        data: Vec<u8>,
    ) -> Result<Packet, Self::Error> {
        match request.as_str() {
            POSIX_RENAME => {
                if !self
                    .failures
                    .advertise_posix_rename
                    .load(Ordering::SeqCst)
                {
                    return Err(StatusCode::OpUnsupported);
                }
                if self
                    .failures
                    .fail_remote_rename
                    .swap(false, Ordering::SeqCst)
                {
                    return Ok(Packet::Status(Self::err_status(
                        id,
                        StatusCode::Failure,
                        "rename failed",
                    )));
                }
                let parsed = de::from_bytes::<PosixRenameExtension>(&mut data.into())
                    .map_err(|_| StatusCode::BadMessage)?;
                let from = self.resolve(&parsed.oldpath);
                let to = self.resolve(&parsed.newpath);
                if let Some(parent) = to.parent() {
                    fs::create_dir_all(parent)
                        .await
                        .map_err(|_| StatusCode::Failure)?;
                }
                // posix-rename replaces an existing destination atomically.
                fs::rename(&from, &to)
                    .await
                    .map_err(|_| StatusCode::Failure)?;
                Ok(Packet::Status(Self::ok_status(id)))
            }
            _ => Err(StatusCode::OpUnsupported),
        }
    }

    async fn setstat(
        &mut self,
        id: u32,
        path: String,
        attrs: FileAttributes,
    ) -> Result<Status, Self::Error> {
        let local = self.resolve(&path);
        if self.failures.fail_setstat.swap(false, Ordering::SeqCst) {
            return Err(StatusCode::Failure);
        }

        if attrs.atime.is_some() || attrs.mtime.is_some() {
            let mut times = std::fs::FileTimes::new();
            if let Some(atime) = attrs.atime {
                times = times.set_accessed(
                    std::time::UNIX_EPOCH + std::time::Duration::from_secs(atime as u64),
                );
            }
            if let Some(mtime) = attrs.mtime {
                times = times.set_modified(
                    std::time::UNIX_EPOCH + std::time::Duration::from_secs(mtime as u64),
                );
            }
            std::fs::File::open(&local)
                .and_then(|file| file.set_times(times))
                .map_err(|_| StatusCode::Failure)?;
        }

        if let Some(mode) = attrs.permissions {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&local, std::fs::Permissions::from_mode(mode))
                    .await
                    .map_err(|_| StatusCode::Failure)?;
            }
            #[cfg(not(unix))]
            {
                let _ = &local;
            }
        }
        Ok(Self::ok_status(id))
    }

    async fn readlink(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        #[cfg(unix)]
        {
            let local = self.resolve(&path);
            let target = std::fs::read_link(&local).map_err(|_| StatusCode::Failure)?;
            // Return the link target as the remote-relative path.
            let remote_target = target
                .strip_prefix(&self.root)
                .map(|t| format!("/{}", t.display()))
                .unwrap_or_else(|_| target.display().to_string());
            Ok(Name {
                id,
                files: vec![File::dummy(remote_target)],
            })
        }
        #[cfg(not(unix))]
        {
            let _ = (id, path);
            Err(self.unimplemented())
        }
    }
}

impl TestSftpServer {
    pub async fn start() -> Self {
        let root_dir = tempfile::tempdir().unwrap();
        let root = root_dir.path().to_path_buf();
        fs::create_dir_all(&root).await.unwrap();

        let failures = Arc::new(FailureConfig::default());
        // Advertise posix-rename@openssh.com by default (OpenSSH-compatible);
        // tests opt out via `advertise_posix_rename.store(false, ..)`.
        failures
            .advertise_posix_rename
            .store(true, Ordering::SeqCst);
        let clients = Arc::new(Mutex::new(HashMap::new()));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let server_root = root.clone();
        let server_failures = Arc::clone(&failures);
        let server_task = tokio::spawn(async move {
            let config = Arc::new(russh::server::Config {
                auth_rejection_time: Duration::from_secs(1),
                auth_rejection_time_initial: Some(Duration::from_secs(0)),
                keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap()],
                ..Default::default()
            });

            loop {
                let (socket, _) = match listener.accept().await {
                    Ok(connection) => connection,
                    Err(_) => break,
                };
                let mut factory = ServerFactory {
                    clients: Arc::clone(&clients),
                    root: server_root.clone(),
                    failures: Arc::clone(&server_failures),
                };
                let handler = factory.new_client(None);
                let config = Arc::clone(&config);
                tokio::spawn(async move {
                    let _ = russh::server::run_stream(config, socket, handler).await;
                });
            }
        });

        let known_hosts_dir = tempfile::tempdir().unwrap();
        Self {
            addr,
            root,
            failures,
            _root_dir: root_dir,
            _known_hosts_dir: known_hosts_dir,
            _server_task: server_task,
        }
    }

    pub async fn connect_session(&self) -> SshSession {
        self.connect_session_to(self.addr.port()).await
    }

    pub async fn connect_session_to(&self, port: u16) -> SshSession {
        self.connect_session_to_with_upload_pipeline_depth(
            port,
            AppConfig::default().transfer_upload_pipeline_depth,
        )
        .await
    }

    pub async fn connect_session_to_with_upload_pipeline_depth(
        &self,
        port: u16,
        upload_pipeline_depth: usize,
    ) -> SshSession {
        let config = AppConfig {
            known_hosts_path: self._known_hosts_dir.path().join("known_hosts.json"),
            merge_openssh_known_hosts_on_connect: false,
            transfer_upload_pipeline_depth: upload_pipeline_depth,
            ..AppConfig::default()
        };
        let known_hosts = Arc::new(AsyncMutex::new(
            KnownHostsManager::load(&config.known_hosts_path).unwrap(),
        ));
        let profile = ConnectionProfile::with_password("127.0.0.1", port, "test", "test");

        SshSession::connect(
            profile,
            &config,
            known_hosts,
            Arc::new(AcceptAllPrompt),
            None,
        )
        .await
        .expect("test SFTP connection should succeed")
    }

    /// Enables the keyboard-interactive-only auth mode and connects with the
    /// given prompt handler (issue #317).
    pub async fn connect_session_with_auth_prompt(
        &self,
        auth_prompt: Arc<dyn crate::ssh::AuthPromptHandler>,
        password: &str,
    ) -> Result<SshSession, crate::error::AppError> {
        self.failures
            .require_keyboard_interactive
            .store(true, Ordering::SeqCst);
        *self
            .failures
            .keyboard_interactive_secret
            .lock()
            .unwrap() = KEYBOARD_INTERACTIVE_SECRET.to_string();

        let config = AppConfig {
            known_hosts_path: self._known_hosts_dir.path().join("known_hosts.json"),
            merge_openssh_known_hosts_on_connect: false,
            ..AppConfig::default()
        };
        let known_hosts = Arc::new(AsyncMutex::new(
            KnownHostsManager::load(&config.known_hosts_path).unwrap(),
        ));
        let profile =
            ConnectionProfile::with_password("127.0.0.1", self.addr.port(), "test", password);

        SshSession::connect(
            profile,
            &config,
            known_hosts,
            Arc::new(AcceptAllPrompt),
            Some(auth_prompt),
        )
        .await
    }

    pub fn remote_partial_paths(&self) -> Vec<PathBuf> {
        list_partial_paths(&self.root)
    }

    /// Path of the per-server known-hosts store used by `connect_session*`.
    pub fn known_hosts_path(&self) -> PathBuf {
        self._known_hosts_dir.path().join("known_hosts.json")
    }

    pub async fn write_remote_file(&self, remote_path: &str, contents: &[u8]) {
        let local = self.resolve(remote_path);
        if let Some(parent) = local.parent() {
            fs::create_dir_all(parent).await.unwrap();
        }
        fs::write(local, contents).await.unwrap();
    }

    pub fn remote_file_exists(&self, remote_path: &str) -> bool {
        self.resolve(remote_path).is_file()
    }

    /// Returns how many OPENDIR requests this server has handled.
    pub fn opendir_count(&self) -> u64 {
        self.failures.opendir_count.load(Ordering::Relaxed)
    }

    /// Returns how many MKDIR requests this server has handled.
    pub fn mkdir_count(&self) -> u64 {
        self.failures.mkdir_count.load(Ordering::Relaxed)
    }

    /// Returns true when the remote path exists as a directory.
    pub fn remote_dir_exists(&self, remote_path: &str) -> bool {
        self.resolve(remote_path).is_dir()
    }

    fn resolve(&self, path: &str) -> PathBuf {
        let trimmed = path.trim_start_matches('/');
        if trimmed.is_empty() {
            self.root.clone()
        } else {
            self.root.join(trimmed)
        }
    }
}

pub fn list_partial_paths(dir: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if !dir.exists() {
        return paths;
    }
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            paths.extend(list_partial_paths(&path));
        } else if is_partial_file_name(
            path.file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default(),
        ) {
            paths.push(path);
        }
    }
    paths
}

pub fn is_partial_file_name(name: &str) -> bool {
    name.starts_with(".dockbridge-") && name.ends_with(".partial")
}
