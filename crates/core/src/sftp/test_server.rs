use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::keys::{Algorithm, PrivateKey};
use russh::server::{Auth, Msg, Server as _, Session};
use russh::{Channel, ChannelId};
use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle, Name, OpenFlags, Status, StatusCode, Version,
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
    pub fail_mkdir: AtomicBool,
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
        Ok(Auth::Accept)
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
        if path.is_symlink() {
            attrs.set_symlink(true);
            return attrs;
        }
        if path.is_dir() {
            attrs.set_dir(true);
        } else if path.is_file() {
            attrs.set_regular(true);
            attrs.size = std::fs::symlink_metadata(path)
                .ok()
                .or_else(|| std::fs::metadata(path).ok())
                .map(|meta| meta.len());
        }
        attrs
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
        Ok(Version::new())
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
            attrs: Self::attrs_for(&local),
        })
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let local = self.resolve(&path);
        if !local.exists() {
            return Err(StatusCode::NoSuchFile);
        }
        #[cfg(unix)]
        if local.is_symlink() {
            return Ok(Attrs {
                id,
                attrs: Self::attrs_for(&local),
            });
        }
        self.stat(id, path).await
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
                StatusCode::Failure
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
}

impl TestSftpServer {
    pub async fn start() -> Self {
        let root_dir = tempfile::tempdir().unwrap();
        let root = root_dir.path().to_path_buf();
        fs::create_dir_all(&root).await.unwrap();

        let failures = Arc::new(FailureConfig::default());
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
        struct AcceptAllPrompt;
        impl HostKeyPrompt for AcceptAllPrompt {
            fn prompt_unknown_host(&self, _: &str, _: u16, _: &str) -> bool {
                true
            }
        }

        let config = AppConfig {
            known_hosts_path: self._known_hosts_dir.path().join("known_hosts.json"),
            merge_openssh_known_hosts_on_connect: false,
            ..AppConfig::default()
        };
        let known_hosts = Arc::new(AsyncMutex::new(
            KnownHostsManager::load(&config.known_hosts_path).unwrap(),
        ));
        let profile =
            ConnectionProfile::with_password("127.0.0.1", self.addr.port(), "test", "test");

        SshSession::connect(profile, &config, known_hosts, Arc::new(AcceptAllPrompt))
            .await
            .expect("test SFTP connection should succeed")
    }

    pub fn remote_partial_paths(&self) -> Vec<PathBuf> {
        list_partial_paths(&self.root)
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
