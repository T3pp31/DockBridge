use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::{ConfigError, SecurityError};

/// Runtime configuration passed into DockBridge core.
#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    /// SSH connection timeout in seconds.
    pub connection_timeout_secs: u64,
    /// Interval between background SFTP health checks for active sessions.
    pub session_health_check_interval_secs: u64,
    /// Number of retries for failed transfers.
    pub transfer_retry_count: u32,
    /// Read/write chunk size for cancellable SFTP transfers.
    pub transfer_chunk_size_bytes: usize,
    /// Path to the DockBridge known hosts JSON store.
    pub known_hosts_path: PathBuf,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            connection_timeout_secs: 30,
            session_health_check_interval_secs: 10,
            transfer_retry_count: 3,
            transfer_chunk_size_bytes: default_transfer_chunk_size_bytes(),
            known_hosts_path: default_known_hosts_path(),
        }
    }
}

impl AppConfig {
    /// Loads configuration from a TOML file, expanding `~` in paths.
    pub fn from_toml_file(path: impl AsRef<Path>) -> Result<Self, ConfigError> {
        let path = path.as_ref();
        let contents = std::fs::read_to_string(path).map_err(|err| {
            if err.kind() == std::io::ErrorKind::NotFound {
                ConfigError::NotFound {
                    path: path.display().to_string(),
                }
            } else {
                ConfigError::ParseFailed {
                    path: path.display().to_string(),
                    message: err.to_string(),
                }
            }
        })?;

        let mut config: Self =
            toml::from_str(&contents).map_err(|err| ConfigError::ParseFailed {
                path: path.display().to_string(),
                message: err.to_string(),
            })?;

        config.known_hosts_path = expand_tilde(&config.known_hosts_path);
        Ok(config)
    }

    /// Returns the resolved known hosts path.
    pub fn known_hosts_path(&self) -> &Path {
        &self.known_hosts_path
    }
}

/// Expands a leading `~` to the user's home directory.
pub fn expand_tilde(path: &Path) -> PathBuf {
    let Some(path_str) = path.to_str() else {
        return path.to_path_buf();
    };

    if let Some(rest) = path_str.strip_prefix("~/") {
        if let Some(home) = home_dir() {
            return home.join(rest);
        }
    }

    if path_str == "~" {
        if let Some(home) = home_dir() {
            return home;
        }
    }

    path.to_path_buf()
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn default_known_hosts_path() -> PathBuf {
    expand_tilde(Path::new("~/.dockbridge/known_hosts.json"))
}

fn default_transfer_chunk_size_bytes() -> usize {
    262_144
}

/// Ensures the parent directory for the known hosts file exists.
pub fn ensure_known_hosts_parent(path: &Path) -> Result<(), SecurityError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|err| SecurityError::KnownHostsWriteFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expand_tilde_replaces_home_prefix() {
        std::env::set_var("HOME", "/tmp/home");
        let expanded = expand_tilde(Path::new("~/.dockbridge/known_hosts.json"));
        assert_eq!(
            expanded,
            PathBuf::from("/tmp/home/.dockbridge/known_hosts.json")
        );
    }
}
