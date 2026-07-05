use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::{ConfigError, SecurityError};

/// Minimum read/write chunk size for cancellable SFTP transfers.
pub const MIN_TRANSFER_CHUNK_SIZE_BYTES: usize = 4_096;
/// Maximum read/write chunk size for cancellable SFTP transfers.
pub const MAX_TRANSFER_CHUNK_SIZE_BYTES: usize = 8 * 1024 * 1024;
/// Default read/write chunk size for cancellable SFTP transfers.
pub const DEFAULT_TRANSFER_CHUNK_SIZE_BYTES: usize = 262_144;

/// Default maximum number of files collected during a recursive directory walk.
pub const DEFAULT_DIRECTORY_WALK_MAX_FILES: u64 = 100_000;
/// Default maximum directory nesting depth during a recursive directory walk.
pub const DEFAULT_DIRECTORY_WALK_MAX_DEPTH: u32 = 64;
/// Default maximum total file bytes collected during a recursive directory walk (100 GiB).
pub const DEFAULT_DIRECTORY_WALK_MAX_TOTAL_BYTES: u64 = 100 * 1024 * 1024 * 1024;

/// Resource limits applied while recursively walking local or remote directory trees.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DirectoryWalkLimits {
    /// Maximum number of file entries to collect.
    pub max_files: u64,
    /// Maximum directory nesting depth (root directory depth is 0).
    pub max_depth: u32,
    /// Maximum combined size in bytes of collected files.
    pub max_total_bytes: u64,
}

impl Default for DirectoryWalkLimits {
    fn default() -> Self {
        Self {
            max_files: DEFAULT_DIRECTORY_WALK_MAX_FILES,
            max_depth: DEFAULT_DIRECTORY_WALK_MAX_DEPTH,
            max_total_bytes: DEFAULT_DIRECTORY_WALK_MAX_TOTAL_BYTES,
        }
    }
}

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
    /// Path to the OpenSSH `known_hosts` file merged on connect.
    #[serde(default = "default_openssh_known_hosts_path")]
    pub openssh_known_hosts_path: PathBuf,
    /// When true, merges [`openssh_known_hosts_path`] into the DockBridge store before connecting.
    #[serde(default = "default_merge_openssh_known_hosts_on_connect")]
    pub merge_openssh_known_hosts_on_connect: bool,
    /// When true, trusts host keys only for exact host/port matches (no fingerprint alias fallback).
    #[serde(default = "default_known_hosts_strict_mode")]
    pub known_hosts_strict_mode: bool,
    /// When true, aborts connection if merging OpenSSH `known_hosts` fails.
    #[serde(default = "default_fail_connect_on_openssh_merge_error")]
    pub fail_connect_on_openssh_merge_error: bool,
    /// Maximum number of files collected during recursive directory walks.
    #[serde(default = "default_directory_walk_max_files")]
    pub directory_walk_max_files: u64,
    /// Maximum directory nesting depth during recursive directory walks.
    #[serde(default = "default_directory_walk_max_depth")]
    pub directory_walk_max_depth: u32,
    /// Maximum combined file bytes collected during recursive directory walks.
    #[serde(default = "default_directory_walk_max_total_bytes")]
    pub directory_walk_max_total_bytes: u64,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            connection_timeout_secs: 30,
            session_health_check_interval_secs: 10,
            transfer_retry_count: 3,
            transfer_chunk_size_bytes: DEFAULT_TRANSFER_CHUNK_SIZE_BYTES,
            known_hosts_path: default_known_hosts_path(),
            openssh_known_hosts_path: default_openssh_known_hosts_path(),
            merge_openssh_known_hosts_on_connect: true,
            known_hosts_strict_mode: true,
            fail_connect_on_openssh_merge_error: true,
            directory_walk_max_files: DEFAULT_DIRECTORY_WALK_MAX_FILES,
            directory_walk_max_depth: DEFAULT_DIRECTORY_WALK_MAX_DEPTH,
            directory_walk_max_total_bytes: DEFAULT_DIRECTORY_WALK_MAX_TOTAL_BYTES,
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
        config.openssh_known_hosts_path = expand_tilde(&config.openssh_known_hosts_path);
        config.transfer_chunk_size_bytes =
            validate_transfer_chunk_size(config.transfer_chunk_size_bytes)?;
        Ok(config)
    }

    /// Returns the resolved known hosts path.
    pub fn known_hosts_path(&self) -> &Path {
        &self.known_hosts_path
    }

    /// Returns directory walk resource limits derived from this configuration.
    pub fn directory_walk_limits(&self) -> DirectoryWalkLimits {
        DirectoryWalkLimits {
            max_files: self.directory_walk_max_files,
            max_depth: self.directory_walk_max_depth,
            max_total_bytes: self.directory_walk_max_total_bytes,
        }
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
///
/// `HOME` must be an absolute path; relative values are ignored to avoid
/// redirecting config paths (e.g. `known_hosts`) to unexpected locations.
/// The `~/` remainder is rejected if it contains `..` segments to prevent
/// traversal outside the home directory.
pub fn expand_tilde(path: &Path) -> PathBuf {
    expand_tilde_with_home(path, home_dir().as_deref())
}

fn expand_tilde_with_home(path: &Path, home: Option<&Path>) -> PathBuf {
    let Some(path_str) = path.to_str() else {
        return path.to_path_buf();
    };

    // Only accept absolute home directories; a relative HOME could redirect
    // config paths (e.g. known_hosts) to unexpected locations.
    let home = home.filter(|h| h.is_absolute());

    if let Some(rest) = path_str.strip_prefix("~/") {
        if let Some(home) = home {
            if rest.split('/').any(|segment| segment == "..") {
                return path.to_path_buf();
            }
            return home.join(rest);
        }
    }

    if path_str == "~" {
        if let Some(home) = home {
            return home.to_path_buf();
        }
    }

    path.to_path_buf()
}

fn home_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    let path = PathBuf::from(home);
    if path.is_absolute() {
        Some(path)
    } else {
        None
    }
}

fn default_known_hosts_path() -> PathBuf {
    expand_tilde(Path::new("~/.dockbridge/known_hosts.json"))
}

fn default_openssh_known_hosts_path() -> PathBuf {
    expand_tilde(Path::new("~/.ssh/known_hosts"))
}

fn default_merge_openssh_known_hosts_on_connect() -> bool {
    true
}

fn default_known_hosts_strict_mode() -> bool {
    true
}

fn default_fail_connect_on_openssh_merge_error() -> bool {
    true
}

fn default_directory_walk_max_files() -> u64 {
    DEFAULT_DIRECTORY_WALK_MAX_FILES
}

fn default_directory_walk_max_depth() -> u32 {
    DEFAULT_DIRECTORY_WALK_MAX_DEPTH
}

fn default_directory_walk_max_total_bytes() -> u64 {
    DEFAULT_DIRECTORY_WALK_MAX_TOTAL_BYTES
}

/// Ensures the parent directory for the known hosts file exists.
pub fn ensure_known_hosts_parent(path: &Path) -> Result<(), SecurityError> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    if parent.as_os_str().is_empty() {
        return Ok(());
    }

    create_known_hosts_parent_dir(parent).map_err(|err| SecurityError::KnownHostsWriteFailed {
        path: path.display().to_string(),
        message: err.to_string(),
    })
}

#[cfg(unix)]
fn create_known_hosts_parent_dir(parent: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

    match std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)
    {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(err) => return Err(err),
    }
    std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
fn create_known_hosts_parent_dir(parent: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(parent)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_uses_strict_security_defaults() {
        // Given: the default AppConfig
        // When: security-related defaults are inspected
        // Then: strict host matching and merge failure abort are enabled
        let config = AppConfig::default();
        assert!(config.known_hosts_strict_mode);
        assert!(config.fail_connect_on_openssh_merge_error);
    }

    #[test]
    fn default_config_uses_directory_walk_limits() {
        let config = AppConfig::default();
        assert_eq!(
            config.directory_walk_limits(),
            DirectoryWalkLimits::default()
        );
    }

    #[test]
    fn expand_tilde_replaces_home_prefix() {
        let home = PathBuf::from("/tmp/home");
        let expanded =
            expand_tilde_with_home(Path::new("~/.dockbridge/known_hosts.json"), Some(&home));
        assert_eq!(
            expanded,
            PathBuf::from("/tmp/home/.dockbridge/known_hosts.json")
        );
    }

    #[test]
    fn expand_tilde_ignores_relative_home() {
        // A relative HOME should not be used to expand ~.
        let relative = PathBuf::from("relative/path");
        assert_eq!(
            expand_tilde_with_home(Path::new("~/known_hosts.json"), Some(&relative)),
            PathBuf::from("~/known_hosts.json")
        );
    }

    #[test]
    fn expand_tilde_rejects_parent_dir_in_remainder() {
        let home = PathBuf::from("/tmp/home");
        assert_eq!(
            expand_tilde_with_home(Path::new("~/../etc/passwd"), Some(&home)),
            PathBuf::from("~/../etc/passwd")
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

    #[cfg(unix)]
    #[test]
    fn ensure_known_hosts_parent_creates_parent_with_0700_permissions() {
        use std::os::unix::fs::PermissionsExt;

        // Given: a known_hosts path whose parent directory does not exist yet
        let dir = std::env::temp_dir().join(format!(
            "dockbridge-known-hosts-parent-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("nested/known_hosts.json");

        // When: ensure_known_hosts_parent is called
        ensure_known_hosts_parent(&path).unwrap();

        // Then: the parent directory is created with mode 0700
        let parent = path.parent().unwrap();
        let mode = std::fs::metadata(parent).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn ensure_known_hosts_parent_tightens_existing_parent_permissions() {
        use std::os::unix::fs::PermissionsExt;

        // Given: an existing parent directory with permissive mode 0755
        let dir = std::env::temp_dir().join(format!(
            "dockbridge-known-hosts-tighten-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = dir.join("known_hosts.json");

        // When: ensure_known_hosts_parent is called
        ensure_known_hosts_parent(&path).unwrap();

        // Then: the parent directory mode is tightened to 0700
        let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
