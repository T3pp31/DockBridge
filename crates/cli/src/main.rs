mod password;

use std::io::Write;
use std::path::PathBuf;
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
    about = "DockBridge SFTP CLI",
    after_help = PASSWORD_AFTER_HELP
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
            if self.password_stdin {
                anyhow::bail!("--identity and --password-stdin are mutually exclusive");
            }
            // Read the passphrase first so encrypted keys can be inspected and,
            // later, unlocked by the core authenticator.
            let passphrase = password::resolve_passphrase(self.passphrase_stdin)
                .transpose()?
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

fn prompt_yes_no(prompt: &str) -> bool {
    eprint!("{prompt}");
    let _ = std::io::stderr().flush();

    let mut input = String::new();
    if std::io::stdin().read_line(&mut input).is_err() {
        return false;
    }

    input.trim().eq_ignore_ascii_case("yes")
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_target(false)
        .init();

    let cli = Cli::parse();
    let config = load_config(&cli.config)?;
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

fn load_config(path: &PathBuf) -> anyhow::Result<AppConfig> {
    if path.exists() {
        AppConfig::from_toml_file(path).map_err(Into::into)
    } else {
        Ok(AppConfig::default())
    }
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
    use dockbridge_core::PrivateKeyAlgorithm;

    use super::is_supported_key_algorithm;

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
