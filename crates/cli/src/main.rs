mod password;

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use clap::{Args, Parser, Subcommand, ValueEnum};
use dockbridge_core::{
    expand_tilde, inspect_private_key_algorithm, AppConfig, AppError, AuthType, ConnectionError,
    ConnectionProfile, HostKeyPrompt, KnownHostsManager, PrivateKeyAlgorithm, SecretPassword,
    SecurityError, SftpClient, SftpError, SshSession, TransferError, TransferManager,
};
use serde::Serialize;
use tokio::sync::Mutex;
use tracing_subscriber::EnvFilter;

/// Exit codes produced by the CLI (documented in `--help`).
const EXIT_OK: u8 = 0;
const EXIT_OTHER: u8 = 1;
const EXIT_USAGE_CONFIG: u8 = 2;
const EXIT_HOST_KEY: u8 = 3;
const EXIT_AUTH: u8 = 4;
const EXIT_TRANSFER: u8 = 5;
const EXIT_CANCELLED: u8 = 6;

#[cfg(feature = "disable-cli-password")]
const AFTER_HELP: &str = "\
Authentication:\n  \
Use --password-stdin for scripts, CI, and production, or authenticate with a\n  \
private key via --identity (add --passphrase-stdin for an encrypted key).\n  \
Examples:\n  \
  printf '%s\\n' \"$PASSWORD\" | dockbridge list --host HOST --user USER --password-stdin\n\n\
  dockbridge list --host HOST --user USER --identity ~/.ssh/id_ed25519\n\n\
Host key verification (--host-key-policy):\n  \
  ask         prompt on /dev/tty when a key is unknown or changed (default)\n  \
  accept-new  trust unknown keys automatically, still reject changed keys\n  \
  strict      only trust keys already present in the known-hosts store\n\n\
Exit codes:\n  \
  0  success\n  \
  1  other error\n  \
  2  usage or configuration error\n  \
  3  host key verification failed\n  \
  4  authentication failed\n  \
  5  transfer failed\n  \
  6  transfer cancelled";

#[cfg(not(feature = "disable-cli-password"))]
const AFTER_HELP: &str = "\
Authentication:\n  \
Prefer --password-stdin for scripts, CI, and production, or authenticate with\n  \
a private key via --identity (add --passphrase-stdin for an encrypted key).\n  \
Examples:\n  \
  printf '%s\\n' \"$PASSWORD\" | dockbridge list --host HOST --user USER --password-stdin\n  \
  dockbridge list --host HOST --user USER --identity ~/.ssh/id_ed25519\n\n  \
--password is for local development and testing only. Passwords passed on the \
command line may appear in argv, shell history, and process listings (CWE-214).\n\n\
Host key verification (--host-key-policy):\n  \
  ask         prompt on /dev/tty when a key is unknown or changed (default)\n  \
  accept-new  trust unknown keys automatically, still reject changed keys\n  \
  strict      only trust keys already present in the known-hosts store\n\n\
Exit codes:\n  \
  0  success\n  \
  1  other error\n  \
  2  usage or configuration error\n  \
  3  host key verification failed\n  \
  4  authentication failed\n  \
  5  transfer failed\n  \
  6  transfer cancelled";

#[derive(Parser, Debug)]
#[command(
    name = "dockbridge",
    version = env!("CARGO_PKG_VERSION"),
    about = "DockBridge SFTP CLI",
    after_help = AFTER_HELP
)]
struct Cli {
    /// Path to TOML config file. When omitted, DockBridge searches
    /// `$DOCKBRIDGE_CONFIG`, `$XDG_CONFIG_HOME/dockbridge/config.toml`, and
    /// `~/.dockbridge/config.toml` before falling back to the built-in defaults.
    #[arg(long)]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// List a remote directory.
    List {
        #[command(flatten)]
        connection: ConnectionArgs,
        #[arg(long, default_value = ".")]
        path: String,
        /// Output format for the listing.
        #[arg(long, value_enum, default_value = "text")]
        output: OutputFormat,
    },
    /// Upload a local file (or directory tree with --recursive) to a remote path.
    Upload {
        #[command(flatten)]
        connection: ConnectionArgs,
        #[arg(long)]
        local: PathBuf,
        /// For a single file upload this is the destination path; with
        /// --recursive it is the destination directory the file/directory tree
        /// is uploaded into.
        #[arg(long)]
        remote: String,
        /// Upload a directory tree; --remote is treated as a destination directory.
        #[arg(long)]
        recursive: bool,
    },
    /// Download a remote file (or directory tree with --recursive) to a local path.
    Download {
        #[command(flatten)]
        connection: ConnectionArgs,
        #[arg(long)]
        remote: String,
        /// For a single file download this is the destination path; with
        /// --recursive it is the local directory the remote file/directory tree
        /// is downloaded into.
        #[arg(long)]
        local: PathBuf,
        /// Download a directory tree; --local is treated as a destination directory.
        #[arg(long)]
        recursive: bool,
    },
    /// Delete a remote file.
    Delete {
        #[command(flatten)]
        connection: ConnectionArgs,
        #[arg(long)]
        remote: String,
    },
    /// Rename a remote file or directory.
    Rename {
        #[command(flatten)]
        connection: ConnectionArgs,
        #[arg(long)]
        from: String,
        #[arg(long)]
        to: String,
    },
    /// Create a remote directory.
    Mkdir {
        #[command(flatten)]
        connection: ConnectionArgs,
        #[arg(long)]
        remote: String,
    },
    /// Print the SFTP session's initial (home) remote directory.
    Pwd {
        #[command(flatten)]
        connection: ConnectionArgs,
    },
}

#[derive(Args, Debug, Clone)]
struct ConnectionArgs {
    #[arg(long)]
    host: String,
    #[arg(long, default_value_t = 22)]
    port: u16,
    #[arg(long)]
    user: String,
    /// Password for local development and testing only (insecure: visible in argv, history, and ps).
    #[cfg(not(feature = "disable-cli-password"))]
    #[arg(long, conflicts_with = "password_stdin")]
    password: Option<String>,
    /// Read password from standard input (recommended for scripts, CI, and production).
    #[arg(long, conflicts_with_all = ["identity", "passphrase_stdin"])]
    password_stdin: bool,
    /// Authenticate with a private key file. `~` is expanded to the home directory.
    #[arg(short = 'i', long)]
    identity: Option<PathBuf>,
    /// Read the private key passphrase from standard input instead of prompting.
    #[arg(long, requires = "identity")]
    passphrase_stdin: bool,
    /// How to handle an unknown or changed host key.
    #[arg(long, value_enum, default_value = "ask")]
    host_key_policy: HostKeyPolicy,
}

impl ConnectionArgs {
    fn into_profile(self) -> anyhow::Result<ConnectionProfile> {
        if let Some(key_path) = self.identity {
            // --identity conflicts with --password-stdin / --passphrase-stdin
            // are already enforced declaratively by clap (conflicts_with_all).
            // Read the passphrase first so encrypted keys can be inspected and,
            // later, unlocked by the core authenticator.
            let passphrase = password::resolve_passphrase(self.passphrase_stdin)?
                .map(|value| SecretPassword::new(value.as_str()));
            let key_path = expand_tilde(&key_path);
            let algorithm =
                inspect_private_key_algorithm(&key_path, passphrase.as_ref().map(|p| p.expose()))?;
            if !is_supported_key_algorithm(&algorithm) {
                anyhow::bail!(
                    "private key at '{}' uses unsupported algorithm {:?}; \
                     supported algorithms are ed25519, ec (ecdsa), and rsa",
                    key_path.display(),
                    algorithm
                );
            }
            return Ok(ConnectionProfile {
                host: self.host,
                port: self.port,
                username: self.user,
                auth: AuthType::PrivateKey {
                    key_path,
                    passphrase,
                },
            });
        }

        let password = password::resolve_password(
            #[cfg(not(feature = "disable-cli-password"))]
            self.password,
            self.password_stdin,
        )?;
        Ok(ConnectionProfile {
            host: self.host,
            port: self.port,
            username: self.user,
            auth: AuthType::Password {
                password: SecretPassword::new(password.as_str()),
            },
        })
    }
}

/// How to handle host keys that are not already trusted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum HostKeyPolicy {
    /// Prompt on the controlling terminal (/dev/tty); fall back to strict when unavailable.
    Ask,
    /// Trust unknown keys automatically; still reject changed keys.
    AcceptNew,
    /// Only trust keys already present in the known-hosts store.
    Strict,
}

/// Output format for `list`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum OutputFormat {
    Text,
    Json,
}

struct CliHostKeyPrompt {
    policy: HostKeyPolicy,
}

/// Whether the CLI supports authenticating with a key algorithm. Keys outside
/// this allow-list are rejected with a clear error before any network I/O.
fn is_supported_key_algorithm(algorithm: &PrivateKeyAlgorithm) -> bool {
    use PrivateKeyAlgorithm::{Ecdsa, Ed25519, Rsa};
    matches!(algorithm, Ed25519 | Ecdsa | Rsa)
}

impl HostKeyPrompt for CliHostKeyPrompt {
    fn prompt_unknown_host(&self, host: &str, port: u16, fingerprint_sha256: &str) -> bool {
        eprintln!("The authenticity of host '{host}:{port}' can't be established.");
        eprintln!("Host key fingerprint is {fingerprint_sha256}.");
        match self.policy {
            HostKeyPolicy::AcceptNew => true,
            HostKeyPolicy::Strict => {
                eprintln!("Host key verification failed (--host-key-policy strict).");
                false
            }
            HostKeyPolicy::Ask => {
                prompt_yes_no_tty("Are you sure you want to continue connecting (yes/no)? ")
            }
        }
    }

    fn prompt_mismatch_host(
        &self,
        host: &str,
        port: u16,
        expected_fingerprint_sha256: &str,
        actual_fingerprint_sha256: &str,
    ) -> bool {
        eprintln!("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@");
        eprintln!("@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @");
        eprintln!("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@");
        eprintln!("Host key for '{host}:{port}' has changed.");
        eprintln!("Expected fingerprint: {expected_fingerprint_sha256}");
        eprintln!("Received fingerprint: {actual_fingerprint_sha256}");
        match self.policy {
            HostKeyPolicy::Ask => {
                prompt_yes_no_tty("Are you sure you want to continue connecting (yes/no)? ")
            }
            HostKeyPolicy::AcceptNew | HostKeyPolicy::Strict => {
                eprintln!(
                    "Host key verification failed (--host-key-policy {}).",
                    match self.policy {
                        HostKeyPolicy::AcceptNew => "accept-new",
                        HostKeyPolicy::Strict => "strict",
                        HostKeyPolicy::Ask => unreachable!(),
                    }
                );
                false
            }
        }
    }
}

/// Prompts on the controlling terminal so that `--password-stdin` /
/// `--passphrase-stdin` strictly own stdin. Falls back to rejecting the host
/// key (strict behavior) when no controlling terminal is available.
fn prompt_yes_no_tty(prompt: &str) -> bool {
    let mut tty = match std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
    {
        Ok(tty) => tty,
        Err(err) => {
            // /dev/tty open can fail for reasons other than "no tty"
            // (permissions, missing device node); surface the OS error so the
            // cause is actionable rather than a misleading blanket message.
            eprintln!(
                "cannot open controlling terminal (/dev/tty): {err}; refusing to accept host key"
            );
            return false;
        }
    };
    eprint!("{prompt}");
    let _ = std::io::stderr().flush();

    let mut input = String::new();
    let mut reader = std::io::BufReader::new(&mut tty);
    if reader.read_line(&mut input).is_err() {
        return false;
    }

    input.trim().eq_ignore_ascii_case("yes")
}

#[tokio::main]
async fn main() -> ExitCode {
    run().await
}

async fn run() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_target(false)
        .init();

    let cli = Cli::parse();
    match execute(cli).await {
        Ok(()) => ExitCode::from(EXIT_OK),
        Err(err) => {
            eprintln!("Error: {err:#}");
            ExitCode::from(exit_code_for_error(&err))
        }
    }
}

async fn execute(cli: Cli) -> anyhow::Result<()> {
    let config = load_config(cli.config.as_deref())?;
    let known_hosts = Arc::new(Mutex::new(KnownHostsManager::load(
        config.known_hosts_path(),
    )?));

    match cli.command {
        Commands::List {
            connection,
            path,
            output,
        } => {
            let session = connect(&connection, &config, known_hosts).await?;

            let client = SftpClient::new(&session);
            let entries = client.list_directory(&path).await?;
            match output {
                OutputFormat::Text => {
                    for entry in entries {
                        let kind = if entry.is_directory { "dir" } else { "file" };
                        println!("{kind}\t{}\t{}", entry.size, entry.path);
                    }
                }
                OutputFormat::Json => print_json_listing(entries)?,
            }
        }
        Commands::Upload {
            connection,
            local,
            remote,
            recursive,
        } => {
            let session = connect(&connection, &config, known_hosts).await?;

            let manager = TransferManager::new(&config);
            if recursive {
                // With --recursive the remote argument is a DESTINATION
                // DIRECTORY. Reject it early if it points at an existing file
                // so we never treat a file path as a directory (silent data
                // loss / confusing rename).
                reject_remote_file_destination(&session, &remote).await?;
                let tasks = manager
                    .enqueue_upload_entry(&session, &local, &remote)
                    .await?;
                println!(
                    "uploaded {} entr{}",
                    tasks.len(),
                    if tasks.len() == 1 { "y" } else { "ies" }
                );
            } else {
                let task = manager.enqueue_upload(&session, &local, remote).await?;
                println!("upload completed (task #{})", task.id);
            }
        }
        Commands::Download {
            connection,
            remote,
            local,
            recursive,
        } => {
            let session = connect(&connection, &config, known_hosts).await?;

            let manager = TransferManager::new(&config);
            if recursive {
                // With --recursive the local argument is a DESTINATION
                // DIRECTORY. Reject an existing regular file up front so we
                // never try to treat a file as a directory.
                if local.exists() && local.is_file() {
                    anyhow::bail!(
                        "--recursive destination '{}' is an existing file; it must be a directory",
                        local.display()
                    );
                }
                let tasks = manager
                    .enqueue_download_entry(&session, &remote, &local)
                    .await?;
                println!(
                    "downloaded {} entr{}",
                    tasks.len(),
                    if tasks.len() == 1 { "y" } else { "ies" }
                );
            } else {
                let task = manager.enqueue_download(&session, remote, &local).await?;
                println!("download completed (task #{})", task.id);
            }
        }
        Commands::Delete { connection, remote } => {
            let session = connect(&connection, &config, known_hosts).await?;

            SftpClient::new(&session).delete(&remote).await?;
            println!("deleted {remote}");
        }
        Commands::Rename {
            connection,
            from,
            to,
        } => {
            let session = connect(&connection, &config, known_hosts).await?;

            SftpClient::new(&session).rename(&from, &to).await?;
            println!("renamed {from} -> {to}");
        }
        Commands::Mkdir { connection, remote } => {
            let session = connect(&connection, &config, known_hosts).await?;

            SftpClient::new(&session).create_directory(&remote).await?;
            println!("created directory {remote}");
        }
        Commands::Pwd { connection } => {
            let session = connect(&connection, &config, known_hosts).await?;

            let directory = SftpClient::new(&session).initial_directory().await?;
            println!("{directory}");
        }
    }

    Ok(())
}

fn print_json_listing(entries: Vec<dockbridge_core::RemoteFile>) -> anyhow::Result<()> {
    println!("{}", json_listing(&entries)?);
    Ok(())
}

/// Serializes a remote directory listing as a JSON array. Each entry's
/// `modified_at` is `null` when the server did not report a modification time.
fn json_listing(entries: &[dockbridge_core::RemoteFile]) -> anyhow::Result<String> {
    #[derive(Serialize)]
    struct JsonEntry<'a> {
        kind: &'a str,
        size: u64,
        path: &'a str,
        // `null` when no mtime is available — consumers must handle null.
        modified_at: Option<u64>,
    }

    let serde_entries: Vec<JsonEntry<'_>> = entries
        .iter()
        .map(|entry| JsonEntry {
            kind: if entry.is_directory { "dir" } else { "file" },
            size: entry.size,
            path: &entry.path,
            modified_at: entry.modified_at_secs,
        })
        .collect();
    serde_json::to_string(&serde_entries).map_err(Into::into)
}

/// Maps an application error to a stable CLI exit code so scripts can branch on
/// the failure category. See `--help` for the documented table.
fn exit_code_for_error(err: &anyhow::Error) -> u8 {
    // Walk the whole cause chain: ConfigError reach the `?` operator as bare
    // errors and are not always wrapped in `AppError`.
    for cause in err.chain() {
        if let Some(app) = cause.downcast_ref::<AppError>() {
            return match app {
                AppError::Config(_) => EXIT_USAGE_CONFIG,
                AppError::Auth(_) => EXIT_AUTH,
                AppError::Transfer(TransferError::Cancelled) => EXIT_CANCELLED,
                AppError::Transfer(_) => EXIT_TRANSFER,
                AppError::Sftp(SftpError::Cancelled) => EXIT_CANCELLED,
                // Any other SFTP error during a transfer/list is a transfer
                // failure (I/O, status code, timeout) for script classification.
                AppError::Sftp(_) => EXIT_TRANSFER,
                AppError::Security(
                    SecurityError::HostKeyMismatch { .. } | SecurityError::HostKeyRejected { .. },
                ) => EXIT_HOST_KEY,
                AppError::Connection(ConnectionError::HostKeyRejected) => EXIT_HOST_KEY,
                _ => EXIT_OTHER,
            };
        }
        if cause
            .downcast_ref::<dockbridge_core::ConfigError>()
            .is_some()
        {
            return EXIT_USAGE_CONFIG;
        }
    }
    EXIT_OTHER
}

/// Loads CLI configuration from an explicitly provided path, a well-known
/// config location, or the built-in defaults.
///
/// When `--config` is given explicitly, a missing file is an error
/// (`ConfigError::NotFound`). When omitted, `$DOCKBRIDGE_CONFIG`,
/// `$XDG_CONFIG_HOME/dockbridge/config.toml`, and `~/.dockbridge/config.toml`
/// are searched in that order; the chosen source (or the built-in default) is
/// logged.
fn load_config(explicit: Option<&Path>) -> anyhow::Result<AppConfig> {
    if let Some(path) = explicit {
        return AppConfig::from_toml_file(path).map_err(Into::into);
    }

    // An explicitly set $DOCKBRIDGE_CONFIG is treated like --config: a missing
    // file is an error rather than a silent fall-back to other locations.
    if let Some(path) = std::env::var_os("DOCKBRIDGE_CONFIG") {
        let path = PathBuf::from(path);
        tracing::info!(path = %path.display(), "using $DOCKBRIDGE_CONFIG configuration file");
        return AppConfig::from_toml_file(&path).map_err(Into::into);
    }

    let candidates = [
        // XDG_CONFIG_HOME must be absolute (per the XDG Base Directory spec);
        // a relative value would silently depend on the CWD.
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .map(|dir| dir.join("dockbridge/config.toml")),
        home_dir_path().map(|home| home.join(".dockbridge/config.toml")),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>();

    for candidate in &candidates {
        tracing::debug!(path = %candidate.display(), "checking configuration file");
        if candidate.exists() {
            tracing::info!(path = %candidate.display(), "using configuration file");
            return AppConfig::from_toml_file(candidate).map_err(Into::into);
        }
    }

    tracing::info!(
        paths = ?candidates,
        "no configuration file found; using built-in default configuration"
    );
    Ok(AppConfig::default())
}

fn home_dir_path() -> Option<PathBuf> {
    let home = if cfg!(target_os = "windows") {
        std::env::var_os("USERPROFILE")
    } else {
        std::env::var_os("HOME")
    };
    home.map(PathBuf::from).filter(|p| p.is_absolute())
}

async fn connect(
    connection: &ConnectionArgs,
    config: &AppConfig,
    known_hosts: Arc<Mutex<KnownHostsManager>>,
) -> anyhow::Result<SshSession> {
    let profile = connection.clone().into_profile()?;
    let prompt = Arc::new(CliHostKeyPrompt {
        policy: connection.host_key_policy,
    });
    SshSession::connect(profile, config, known_hosts, prompt)
        .await
        .map_err(Into::into)
}

/// Rejects a remote destination that is an existing *file* when the caller is
/// about to treat it as a directory (recursive upload). A `SSH_FX_NO_SUCH_FILE`
/// (or an empty parent) is fine — the directory will be created.
///
/// Fails the whole command loudly rather than silently misinterpreting a file
/// path as a directory (which could place files in an unexpected location or
/// error only after transfer began).
async fn reject_remote_file_destination(session: &SshSession, remote: &str) -> anyhow::Result<()> {
    let client = SftpClient::new(session);
    // None = path does not exist (the directory will be created); Some(true) =
    // directory; Some(false) = existing non-directory which must be rejected.
    match client.remote_path_kind(remote).await? {
        Some(true) | None => Ok(()),
        Some(false) => anyhow::bail!(
            "--recursive destination '{remote}' is an existing remote file; it must be a directory"
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dockbridge_core::AuthError;
    use serial_test::serial;

    #[test]
    fn exit_code_mapping_covers_categories() {
        let err = anyhow::Error::new(AppError::Auth(AuthError::Failed {
            username: "test".to_string(),
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_AUTH);

        let err = anyhow::Error::new(AppError::Transfer(TransferError::Cancelled));
        assert_eq!(exit_code_for_error(&err), EXIT_CANCELLED);

        let err = anyhow::Error::new(AppError::Sftp(SftpError::Cancelled));
        assert_eq!(exit_code_for_error(&err), EXIT_CANCELLED);

        let err = anyhow::Error::new(AppError::Transfer(TransferError::TaskNotFound {
            task_id: 1,
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_TRANSFER);

        let err = anyhow::Error::new(AppError::Security(SecurityError::HostKeyRejected {
            host: "h".to_string(),
            port: 22,
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_HOST_KEY);

        let err = anyhow::Error::new(AppError::Connection(ConnectionError::HostKeyRejected));
        assert_eq!(exit_code_for_error(&err), EXIT_HOST_KEY);

        let err = anyhow::Error::new(AppError::Config(dockbridge_core::ConfigError::NotFound {
            path: "x".to_string(),
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_USAGE_CONFIG);

        let err = anyhow::Error::new(AppError::Connection(ConnectionError::Timeout {
            timeout_secs: 30,
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_OTHER);
    }

    #[test]
    fn exit_code_mapping_covers_additional_variants() {
        // Non-cancelled SFTP errors map to EXIT_TRANSFER.
        let err = anyhow::Error::new(AppError::Sftp(SftpError::ListFailed {
            path: "/".to_string(),
            message: "boom".to_string(),
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_TRANSFER);

        let err = anyhow::Error::new(AppError::Sftp(SftpError::UploadFailed {
            local: "l".to_string(),
            remote: "r".to_string(),
            message: "boom".to_string(),
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_TRANSFER);

        // Host key mismatch is EXIT_HOST_KEY.
        let err = anyhow::Error::new(AppError::Security(SecurityError::HostKeyMismatch {
            host: "h".to_string(),
            port: 22,
            expected: "abc".to_string(),
            actual: "def".to_string(),
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_HOST_KEY);

        // Non-host-key connection variants are EXIT_OTHER.
        let err = anyhow::Error::new(AppError::Connection(ConnectionError::ConnectFailed {
            host: "h".to_string(),
            port: 22,
            message: "nope".to_string(),
        }));
        assert_eq!(exit_code_for_error(&err), EXIT_OTHER);
    }

    #[test]
    fn unknown_anyhow_error_maps_to_other() {
        let err = anyhow::anyhow!("something else went wrong");
        assert_eq!(exit_code_for_error(&err), EXIT_OTHER);
    }

    #[test]
    fn json_listing_serializes_entries_with_expected_keys() {
        use dockbridge_core::RemoteFile;
        use serde_json::Value;

        let entries = vec![
            RemoteFile {
                name: "a.txt".to_string(),
                path: "/upload/a.txt".to_string(),
                is_directory: false,
                is_symlink: false,
                size: 12,
                modified_at_secs: Some(1_700_000_000),
            },
            RemoteFile {
                name: "dir".to_string(),
                path: "/upload/dir".to_string(),
                is_directory: true,
                is_symlink: false,
                size: 0,
                modified_at_secs: None,
            },
        ];

        let json_text = json_listing(&entries).expect("serialize listing");
        let json: Value = serde_json::from_str(&json_text).expect("valid JSON");
        let array = json.as_array().expect("array");
        assert_eq!(array.len(), 2);
        assert_eq!(array[0]["kind"], "file");
        assert_eq!(array[0]["size"], 12);
        assert_eq!(array[0]["path"], "/upload/a.txt");
        assert_eq!(array[0]["modified_at"], 1_700_000_000);
        assert_eq!(array[1]["kind"], "dir");
        assert_eq!(array[1]["modified_at"], serde_json::Value::Null);
    }

    #[test]
    fn host_key_policy_variants_round_trip() {
        use super::HostKeyPolicy;
        use clap::ValueEnum;
        for (text, expected) in [
            ("ask", HostKeyPolicy::Ask),
            ("accept-new", HostKeyPolicy::AcceptNew),
            ("strict", HostKeyPolicy::Strict),
        ] {
            assert_eq!(HostKeyPolicy::from_str(text, true).ok(), Some(expected));
        }
        assert!(HostKeyPolicy::from_str("bogus", true).is_err());
    }

    // Snapshot the three env vars the search reads, run `f`, then restore.
    // Tests mutating process-wide env are also marked #[serial].
    fn with_config_env(f: impl FnOnce()) {
        const VARS: [&str; 3] = ["DOCKBRIDGE_CONFIG", "XDG_CONFIG_HOME", "HOME"];
        let saved: Vec<(&str, Option<std::ffi::OsString>)> = VARS
            .iter()
            .map(|name| (*name, std::env::var_os(name)))
            .collect();
        for (name, _) in &saved {
            std::env::remove_var(name);
        }

        struct Guard(Vec<(&'static str, Option<std::ffi::OsString>)>);
        impl Drop for Guard {
            fn drop(&mut self) {
                for (name, value) in self.0.drain(..).rev() {
                    match value {
                        Some(v) => std::env::set_var(name, v),
                        None => std::env::remove_var(name),
                    }
                }
            }
        }
        let _guard = Guard(saved);

        f();
    }

    fn app_config_matches_default(config: &AppConfig) -> bool {
        config.connection_timeout_secs == AppConfig::default().connection_timeout_secs
            && config.transfer_retry_count == AppConfig::default().transfer_retry_count
    }

    fn write_temp_toml(dir: &Path, contents: &str) -> PathBuf {
        let path = dir.join("config.toml");
        std::fs::write(&path, contents).unwrap();
        path
    }

    fn write_temp_config(dir: &Path, timeout: u32, retry: u32) -> PathBuf {
        write_temp_toml(
            dir,
            &format!(
                "connection_timeout_secs = {timeout}\n\
                 session_health_check_interval_secs = 10\n\
                 transfer_retry_count = {retry}\n\
                 transfer_chunk_size_bytes = 262144\n\
                 transfer_download_pipeline_depth = 64\n\
                 known_hosts_path = \"{}/known_hosts.json\"\n\
                 openssh_known_hosts_path = \"/dev/null\"\n\
                 merge_openssh_known_hosts_on_connect = false\n\
                 known_hosts_strict_mode = true\n\
                 fail_connect_on_openssh_merge_error = false\n\
                 directory_walk_max_files = 100000\n\
                 directory_walk_max_depth = 64\n\
                 directory_walk_max_total_bytes = 107374182400\n",
                dir.display()
            ),
        )
    }

    #[test]
    fn explicit_missing_config_is_error() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("nope.toml");
        let err = load_config(Some(&missing)).unwrap_err();
        assert!(
            err.to_string().contains("not found") || err.to_string().contains("No such file"),
            "expected a not-found error, got: {err}"
        );
    }

    #[serial]
    #[test]
    fn environment_missing_config_is_error() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing.toml");
        with_config_env(|| {
            std::env::set_var("DOCKBRIDGE_CONFIG", missing.as_os_str());
            let err = load_config(None).unwrap_err();
            assert!(
                err.to_string().contains("not found"),
                "expected a not-found error, got: {err}"
            );
        });
    }

    #[serial]
    #[test]
    fn environment_config_is_used() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_temp_config(dir.path(), 42, 7);
        with_config_env(|| {
            std::env::set_var("DOCKBRIDGE_CONFIG", path.as_os_str());
            let config = load_config(None).unwrap();
            assert_eq!(config.connection_timeout_secs, 42);
            assert_eq!(config.transfer_retry_count, 7);
        });
    }

    #[serial]
    #[test]
    fn xdg_config_home_is_used() {
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join("dockbridge");
        std::fs::create_dir_all(&config_dir).unwrap();
        write_temp_config(&config_dir, 99, 3);

        with_config_env(|| {
            std::env::set_var("XDG_CONFIG_HOME", dir.path().as_os_str());
            let config = load_config(None).unwrap();
            assert_eq!(config.connection_timeout_secs, 99);
        });
    }

    #[serial]
    #[test]
    fn relative_xdg_config_home_is_ignored() {
        // A relative XDG_CONFIG_HOME must not be used (spec requires absolute).
        with_config_env(|| {
            std::env::set_var("XDG_CONFIG_HOME", "relative/path");
            let config = load_config(None).unwrap();
            assert!(
                app_config_matches_default(&config),
                "relative XDG_CONFIG_HOME must be ignored"
            );
        });
    }

    #[serial]
    #[test]
    fn home_config_is_used() {
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join(".dockbridge");
        std::fs::create_dir_all(&config_dir).unwrap();
        write_temp_config(&config_dir, 123, 3);

        with_config_env(|| {
            std::env::set_var("HOME", dir.path().as_os_str());
            let config = load_config(None).unwrap();
            assert_eq!(config.connection_timeout_secs, 123);
        });
    }

    #[serial]
    #[test]
    fn no_config_falls_back_to_default() {
        let dir = tempfile::tempdir().unwrap();
        with_config_env(|| {
            let config = load_config(None).unwrap();
            assert!(app_config_matches_default(&config));
        });
        drop(dir);
    }

    #[test]
    fn supported_key_algorithms_are_accepted() {
        assert!(is_supported_key_algorithm(&PrivateKeyAlgorithm::Ed25519));
        assert!(is_supported_key_algorithm(&PrivateKeyAlgorithm::Ecdsa));
        assert!(is_supported_key_algorithm(&PrivateKeyAlgorithm::Rsa));
    }

    #[test]
    fn unknown_key_algorithms_are_rejected() {
        assert!(!is_supported_key_algorithm(&PrivateKeyAlgorithm::Other(
            "dss".to_string()
        )));
    }
}
