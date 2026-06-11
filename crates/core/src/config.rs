use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::{ConfigError, SecurityError};

/// Minimum read/write chunk size for cancellable SFTP transfers.
pub const MIN_TRANSFER_CHUNK_SIZE_BYTES: usize = 4_096;
/// Maximum read/write chunk size for cancellable SFTP transfers.
pub const MAX_TRANSFER_CHUNK_SIZE_BYTES: usize = 8 * 1024 * 1024;
/// Default read/write chunk size for cancellable SFTP transfers.
pub const DEFAULT_TRANSFER_CHUNK_SIZE_BYTES: usize = 262_144;

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
            transfer_chunk_size_bytes: DEFAULT_TRANSFER_CHUNK_SIZE_BYTES,
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
        config.transfer_chunk_size_bytes =
            validate_transfer_chunk_size(config.transfer_chunk_size_bytes)?;
        Ok(config)
    }

    /// Returns the resolved known hosts path.
    pub fn known_hosts_path(&self) -> &Path {
        &self.known_hosts_path
    }
}

/// Validates a transfer chunk size from configuration.
///
/// Values below [`MIN_TRANSFER_CHUNK_SIZE_BYTES`] are raised to the minimum.
/// Values above [`MAX_TRANSFER_CHUNK_SIZE_BYTES`] are rejected.
pub fn validate_transfer_chunk_size(bytes: usize) -> Result<usize, ConfigError> {
    if bytes > MAX_TRANSFER_CHUNK_SIZE_BYTES {
        return Err(ConfigError::InvalidTransferChunkSize {
            value: bytes,
            min: MIN_TRANSFER_CHUNK_SIZE_BYTES,
            max: MAX_TRANSFER_CHUNK_SIZE_BYTES,
        });
    }
    Ok(bytes.max(MIN_TRANSFER_CHUNK_SIZE_BYTES))
}

/// Clamps a validated transfer chunk size to the allowed range.
pub fn clamp_transfer_chunk_size(bytes: usize) -> usize {
    bytes.clamp(MIN_TRANSFER_CHUNK_SIZE_BYTES, MAX_TRANSFER_CHUNK_SIZE_BYTES)
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

    #[test]
    fn validate_transfer_chunk_size_clamps_below_minimum() {
        // Given: values below the minimum chunk size
        // When: validate_transfer_chunk_size is called
        // Then: the minimum chunk size is returned
        assert_eq!(
            validate_transfer_chunk_size(0).unwrap(),
            MIN_TRANSFER_CHUNK_SIZE_BYTES
        );
        assert_eq!(
            validate_transfer_chunk_size(100).unwrap(),
            MIN_TRANSFER_CHUNK_SIZE_BYTES
        );
    }

    #[test]
    fn validate_transfer_chunk_size_accepts_maximum() {
        // Given: the maximum allowed chunk size
        // When: validate_transfer_chunk_size is called
        // Then: the value is accepted unchanged
        assert_eq!(
            validate_transfer_chunk_size(MAX_TRANSFER_CHUNK_SIZE_BYTES).unwrap(),
            MAX_TRANSFER_CHUNK_SIZE_BYTES
        );
    }

    #[test]
    fn validate_transfer_chunk_size_rejects_above_maximum() {
        // Given: a chunk size above the maximum
        // When: validate_transfer_chunk_size is called
        // Then: InvalidTransferChunkSize is returned
        let err = validate_transfer_chunk_size(MAX_TRANSFER_CHUNK_SIZE_BYTES + 1).unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidTransferChunkSize {
                value,
                min,
                max
            } if value == MAX_TRANSFER_CHUNK_SIZE_BYTES + 1
                && min == MIN_TRANSFER_CHUNK_SIZE_BYTES
                && max == MAX_TRANSFER_CHUNK_SIZE_BYTES
        ));
    }

    #[test]
    fn clamp_transfer_chunk_size_enforces_bounds() {
        // Given: chunk sizes at and beyond the allowed range
        // When: clamp_transfer_chunk_size is called
        // Then: values are clamped to the allowed range
        assert_eq!(clamp_transfer_chunk_size(0), MIN_TRANSFER_CHUNK_SIZE_BYTES);
        assert_eq!(
            clamp_transfer_chunk_size(100),
            MIN_TRANSFER_CHUNK_SIZE_BYTES
        );
        assert_eq!(
            clamp_transfer_chunk_size(MAX_TRANSFER_CHUNK_SIZE_BYTES),
            MAX_TRANSFER_CHUNK_SIZE_BYTES
        );
        assert_eq!(
            clamp_transfer_chunk_size(MAX_TRANSFER_CHUNK_SIZE_BYTES + 1),
            MAX_TRANSFER_CHUNK_SIZE_BYTES
        );
    }

    #[test]
    fn from_toml_file_rejects_oversized_chunk_size() {
        // Given: a TOML config with an oversized transfer chunk size
        // When: AppConfig::from_toml_file is called
        // Then: InvalidTransferChunkSize is returned
        let dir =
            std::env::temp_dir().join(format!("dockbridge-config-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("invalid.toml");
        std::fs::write(
            &path,
            format!(
                "connection_timeout_secs = 30\n\
                 session_health_check_interval_secs = 10\n\
                 transfer_retry_count = 3\n\
                 transfer_chunk_size_bytes = {}\n\
                 known_hosts_path = \"~/.dockbridge/known_hosts.json\"\n",
                MAX_TRANSFER_CHUNK_SIZE_BYTES + 1
            ),
        )
        .unwrap();

        let err = AppConfig::from_toml_file(&path).unwrap_err();
        assert!(matches!(err, ConfigError::InvalidTransferChunkSize { .. }));
    }
}
