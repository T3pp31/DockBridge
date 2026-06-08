use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Arc;

use clap::{Parser, Subcommand};
use dockbridge_core::{
    AppConfig, AuthType, ConnectionProfile, HostKeyPrompt, KnownHostsManager, SecretPassword,
    SftpClient, SshSession, TransferManager,
};
use tokio::sync::Mutex;
use tracing_subscriber::EnvFilter;
use zeroize::Zeroizing;

#[derive(Parser, Debug)]
#[command(name = "dockbridge", about = "DockBridge SFTP CLI")]
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
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 22)]
        port: u16,
        #[arg(long)]
        user: String,
        #[arg(long)]
        password: String,
        #[arg(long, default_value = ".")]
        path: String,
    },
    /// Upload a local file to a remote path.
    Upload {
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 22)]
        port: u16,
        #[arg(long)]
        user: String,
        #[arg(long)]
        password: String,
        #[arg(long)]
        local: PathBuf,
        #[arg(long)]
        remote: String,
    },
    /// Download a remote file to a local path.
    Download {
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 22)]
        port: u16,
        #[arg(long)]
        user: String,
        #[arg(long)]
        password: String,
        #[arg(long)]
        remote: String,
        #[arg(long)]
        local: PathBuf,
    },
    /// Delete a remote file.
    Delete {
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 22)]
        port: u16,
        #[arg(long)]
        user: String,
        #[arg(long)]
        password: String,
        #[arg(long)]
        remote: String,
    },
    /// Rename a remote file or directory.
    Rename {
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 22)]
        port: u16,
        #[arg(long)]
        user: String,
        #[arg(long)]
        password: String,
        #[arg(long)]
        from: String,
        #[arg(long)]
        to: String,
    },
    /// Create a remote directory.
    Mkdir {
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 22)]
        port: u16,
        #[arg(long)]
        user: String,
        #[arg(long)]
        password: String,
        #[arg(long)]
        remote: String,
    },
}

#[derive(Debug)]
struct ConnectionArgs {
    host: String,
    port: u16,
    user: String,
    password: Zeroizing<String>,
}

impl ConnectionArgs {
    fn into_profile(self) -> ConnectionProfile {
        ConnectionProfile {
            host: self.host,
            port: self.port,
            username: self.user,
            auth: AuthType::Password {
                password: SecretPassword::new(self.password.as_str()),
            },
        }
    }
}

struct CliHostKeyPrompt;

impl HostKeyPrompt for CliHostKeyPrompt {
    fn prompt_unknown_host(&self, host: &str, port: u16, fingerprint_sha256: &str) -> bool {
        eprintln!("The authenticity of host '{host}:{port}' can't be established.");
        eprintln!("Host key fingerprint is {fingerprint_sha256}.");
        eprint!("Are you sure you want to continue connecting (yes/no)? ");
        let _ = io::stderr().flush();

        let mut input = String::new();
        if io::stdin().read_line(&mut input).is_err() {
            return false;
        }

        matches!(input.trim().to_ascii_lowercase().as_str(), "y" | "yes")
    }
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
        Commands::List {
            host,
            port,
            user,
            password,
            path,
        } => {
            let session = connect(
                ConnectionArgs {
                    host,
                    port,
                    user,
                    password: Zeroizing::new(password),
                },
                &config,
                known_hosts,
                prompt,
            )
            .await?;

            let client = SftpClient::new(&session);
            let entries = client.list_directory(&path).await?;
            for entry in entries {
                let kind = if entry.is_directory { "dir" } else { "file" };
                println!("{kind}\t{}\t{}", entry.size, entry.path);
            }
        }
        Commands::Upload {
            host,
            port,
            user,
            password,
            local,
            remote,
        } => {
            let session = connect(
                ConnectionArgs {
                    host,
                    port,
                    user,
                    password: Zeroizing::new(password),
                },
                &config,
                known_hosts,
                prompt,
            )
            .await?;

            let manager = TransferManager::new(&config);
            let task = manager.enqueue_upload(&session, &local, remote).await?;
            println!("upload completed (task #{})", task.id);
        }
        Commands::Download {
            host,
            port,
            user,
            password,
            remote,
            local,
        } => {
            let session = connect(
                ConnectionArgs {
                    host,
                    port,
                    user,
                    password: Zeroizing::new(password),
                },
                &config,
                known_hosts,
                prompt,
            )
            .await?;

            let manager = TransferManager::new(&config);
            let task = manager.enqueue_download(&session, remote, &local).await?;
            println!("download completed (task #{})", task.id);
        }
        Commands::Delete {
            host,
            port,
            user,
            password,
            remote,
        } => {
            let session = connect(
                ConnectionArgs {
                    host,
                    port,
                    user,
                    password: Zeroizing::new(password),
                },
                &config,
                known_hosts,
                prompt,
            )
            .await?;

            SftpClient::new(&session).delete(&remote).await?;
            println!("deleted {remote}");
        }
        Commands::Rename {
            host,
            port,
            user,
            password,
            from,
            to,
        } => {
            let session = connect(
                ConnectionArgs {
                    host,
                    port,
                    user,
                    password: Zeroizing::new(password),
                },
                &config,
                known_hosts,
                prompt,
            )
            .await?;

            SftpClient::new(&session).rename(&from, &to).await?;
            println!("renamed {from} -> {to}");
        }
        Commands::Mkdir {
            host,
            port,
            user,
            password,
            remote,
        } => {
            let session = connect(
                ConnectionArgs {
                    host,
                    port,
                    user,
                    password: Zeroizing::new(password),
                },
                &config,
                known_hosts,
                prompt,
            )
            .await?;

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
    args: ConnectionArgs,
    config: &AppConfig,
    known_hosts: Arc<Mutex<KnownHostsManager>>,
    prompt: Arc<dyn HostKeyPrompt>,
) -> anyhow::Result<SshSession> {
    SshSession::connect(args.into_profile(), config, known_hosts, prompt)
        .await
        .map_err(Into::into)
}
