mod password;

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use clap::{Args, Parser, Subcommand, ValueEnum};
use dockbridge_core::{
    AppConfig, AppError, AuthType, ConnectionError, ConnectionProfile, HostKeyPrompt,
    KnownHostsManager, SecretPassword, SecurityError, SftpClient, SftpError, SshSession,
    TransferError, TransferManager,
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
Use --password-stdin for scripts, CI, and production. Example:\n  \
  printf '%s\\n' \"$PASSWORD\" | dockbridge list --host HOST --user USER --password-stdin\n\n\
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
Prefer --password-stdin for scripts, CI, and production. Example:\n  \
  printf '%s\\n' \"$PASSWORD\" | dockbridge list --host HOST --user USER --password-stdin\n\n  \
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
    about = "DockBridge SFTP CLI",
    after_help = AFTER_HELP
)]
struct Cli {
    /// Path to TOML config file.
    #[arg(long, default_value = "config/default.toml")]
    config: PathBuf,

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
    #[arg(long)]
    password_stdin: bool,
    /// How to handle an unknown or changed host key.
    #[arg(long, value_enum, default_value = "ask")]
    host_key_policy: HostKeyPolicy,
}

impl ConnectionArgs {
    fn into_profile(self) -> anyhow::Result<ConnectionProfile> {
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
        Err(_) => {
            eprintln!("no controlling terminal available; refusing to accept host key");
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
    let config = load_config(&cli.config)?;
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
                OutputFormat::Json => print_json_listing(entries),
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

fn print_json_listing(entries: Vec<dockbridge_core::RemoteFile>) {
    println!("{}", json_listing(&entries));
}

fn json_listing(entries: &[dockbridge_core::RemoteFile]) -> String {
    #[derive(Serialize)]
    struct JsonEntry<'a> {
        kind: &'a str,
        size: u64,
        path: &'a str,
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
    serde_json::to_string(&serde_entries).unwrap_or_else(|_| "[]".to_string())
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

fn load_config(path: &PathBuf) -> anyhow::Result<AppConfig> {
    if path.exists() {
        AppConfig::from_toml_file(path).map_err(Into::into)
    } else {
        Ok(AppConfig::default())
    }
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

#[cfg(test)]
mod tests {
    use dockbridge_core::{
        AppError, AuthError, ConnectionError, SecurityError, SftpError, TransferError,
    };

    use super::{
        exit_code_for_error, json_listing, EXIT_AUTH, EXIT_CANCELLED, EXIT_HOST_KEY, EXIT_OTHER,
        EXIT_TRANSFER, EXIT_USAGE_CONFIG,
    };

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

        let json: Value = serde_json::from_str(&json_listing(&entries)).expect("valid JSON");
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
}
