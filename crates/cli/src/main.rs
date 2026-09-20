mod password;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use clap::{Args, Parser, Subcommand};
use dockbridge_core::{
    expand_tilde, inspect_private_key_algorithm, AppConfig, AuthType, ConnectionProfile,
    HostKeyPrompt, KnownHostsManager, PrivateKeyAlgorithm, SecretPassword, SftpClient, SshSession,
    TransferManager,
};
use tokio::sync::Mutex;
use tracing_subscriber::EnvFilter;

#[cfg(feature = "disable-cli-password")]
const PASSWORD_AFTER_HELP: &str = "\
Authentication:\n  \
Use --password-stdin for scripts, CI, and production, or authenticate with a\n  \
private key via --identity (repeatable with --passphrase-stdin for an\n  \
encrypted key). Examples:\n  \
  printf '%s\\n' \"$PASSWORD\" | dockbridge list --host HOST --user USER --password-stdin\n  \
  dockbridge list --host HOST --user USER --identity ~/.ssh/id_ed25519";

#[cfg(not(feature = "disable-cli-password"))]
const PASSWORD_AFTER_HELP: &str = "\
Authentication:\n  \
Prefer --password-stdin for scripts, CI, and production, or authenticate with\n  \
a private key via --identity (add --passphrase-stdin for an encrypted key).\n  \
Examples:\n  \
  printf '%s\\n' \"$PASSWORD\" | dockbridge list --host HOST --user USER --password-stdin\n  \
  dockbridge list --host HOST --user USER --identity ~/.ssh/id_ed25519\n\n  \
--password is for local development and testing only. Passwords passed on the \
command line may appear in argv, shell history, and process listings (CWE-214).";

#[derive(Parser, Debug)]
#[command(
    name = "dockbridge",
    version = env!("CARGO_PKG_VERSION"),
    about = "DockBridge SFTP CLI",
    after_help = PASSWORD_AFTER_HELP
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
    },
    /// Upload a local file to a remote path.
    Upload {
        #[command(flatten)]
        connection: ConnectionArgs,
        #[arg(long)]
        local: PathBuf,
        #[arg(long)]
        remote: String,
    },
    /// Download a remote file to a local path.
    Download {
        #[command(flatten)]
        connection: ConnectionArgs,
        #[arg(long)]
        remote: String,
        #[arg(long)]
        local: PathBuf,
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
}

#[derive(Args, Debug)]
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

/// Whether the CLI supports authenticating with a key algorithm. Keys outside
/// this allow-list are rejected with a clear error before any network I/O.
fn is_supported_key_algorithm(algorithm: &PrivateKeyAlgorithm) -> bool {
    use PrivateKeyAlgorithm::{Ecdsa, Ed25519, Rsa};
    matches!(algorithm, Ed25519 | Ecdsa | Rsa)
}

struct CliHostKeyPrompt;

impl HostKeyPrompt for CliHostKeyPrompt {
    fn prompt_unknown_host(&self, host: &str, port: u16, fingerprint_sha256: &str) -> bool {
        eprintln!("The authenticity of host '{host}:{port}' can't be established.");
        eprintln!("Host key fingerprint is {fingerprint_sha256}.");
        prompt_yes_no("Are you sure you want to continue connecting (yes/no)? ")
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
        prompt_yes_no("Are you sure you want to continue connecting (yes/no)? ")
    }
}

/// Prompts on stderr and reads the answer from the controlling terminal when
/// one is available, falling back to stdin.
///
/// Reading from `/dev/tty` (rather than stdin) avoids racing with credentials
/// piped via `--password-stdin` / `--passphrase-stdin`: the piped secret bytes
/// are consumed by the credential reader, while an interactive user still gets
/// the host-key prompt on the controlling terminal. When no TTY exists (fully
/// non-interactive CI/scripts) the prompt degrades to stdin and a `yes` can be
/// piped before the secret.
fn prompt_yes_no(prompt: &str) -> bool {
    eprint!("{prompt}");
    let _ = std::io::stderr().flush();

    let read_line = |source: &mut dyn std::io::BufRead| -> Option<bool> {
        let mut input = String::new();
        source.read_line(&mut input).ok()?;
        Some(input.trim().eq_ignore_ascii_case("yes"))
    };

    // Prefer the controlling TTY so a script piping a secret via stdin does not
    // starve the interactive host-key confirmation.
    if let Ok(tty) = std::fs::File::open("/dev/tty") {
        let mut tty = std::io::BufReader::new(tty);
        if let Some(answer) = read_line(&mut tty) {
            return answer;
        }
    }

    // No controlling terminal (CI, fully scripted runs): fall back to stdin.
    // Credential readers use `BufRead` on stdin too, so any piped `yes`
    // (sent after the secret line) remains available; we read from the same
    // shared handle via `lock()` to avoid an extra buffering layer.
    let mut stdin = std::io::stdin().lock();
    read_line(&mut stdin).unwrap_or(false)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_target(false)
        .init();

    let cli = Cli::parse();
    let config = load_config(cli.config.as_deref())?;
    let known_hosts = Arc::new(Mutex::new(KnownHostsManager::load(
        config.known_hosts_path(),
    )?));
    let prompt = Arc::new(CliHostKeyPrompt);

    match cli.command {
        Commands::List { connection, path } => {
            let session = connect(connection.into_profile()?, &config, known_hosts, prompt).await?;

            let client = SftpClient::new(&session);
            let entries = client.list_directory(&path).await?;
            for entry in entries {
                let kind = if entry.is_directory { "dir" } else { "file" };
                println!("{kind}\t{}\t{}", entry.size, entry.path);
            }
        }
        Commands::Upload {
            connection,
            local,
            remote,
        } => {
            let session = connect(connection.into_profile()?, &config, known_hosts, prompt).await?;

            let manager = TransferManager::new(&config);
            let task = manager.enqueue_upload(&session, &local, remote).await?;
            println!("upload completed (task #{})", task.id);
        }
        Commands::Download {
            connection,
            remote,
            local,
        } => {
            let session = connect(connection.into_profile()?, &config, known_hosts, prompt).await?;

            let manager = TransferManager::new(&config);
            let task = manager.enqueue_download(&session, remote, &local).await?;
            println!("download completed (task #{})", task.id);
        }
        Commands::Delete { connection, remote } => {
            let session = connect(connection.into_profile()?, &config, known_hosts, prompt).await?;

            SftpClient::new(&session).delete(&remote).await?;
            println!("deleted {remote}");
        }
        Commands::Rename {
            connection,
            from,
            to,
        } => {
            let session = connect(connection.into_profile()?, &config, known_hosts, prompt).await?;

            SftpClient::new(&session).rename(&from, &to).await?;
            println!("renamed {from} -> {to}");
        }
        Commands::Mkdir { connection, remote } => {
            let session = connect(connection.into_profile()?, &config, known_hosts, prompt).await?;

            SftpClient::new(&session).create_directory(&remote).await?;
            println!("created directory {remote}");
        }
    }

    Ok(())
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
    profile: ConnectionProfile,
    config: &AppConfig,
    known_hosts: Arc<Mutex<KnownHostsManager>>,
    prompt: Arc<dyn HostKeyPrompt>,
) -> anyhow::Result<SshSession> {
    SshSession::connect(profile, config, known_hosts, prompt)
        .await
        .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

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
