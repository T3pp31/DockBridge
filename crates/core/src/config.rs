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
/// Minimum concurrent in-flight READ requests during a download.
pub const MIN_TRANSFER_DOWNLOAD_PIPELINE_DEPTH: usize = 1;
/// Maximum concurrent in-flight READ requests during a download.
pub const MAX_TRANSFER_DOWNLOAD_PIPELINE_DEPTH: usize = 256;
/// Default concurrent in-flight READ requests during a download.
///
/// Mirrors OpenSSH `sftp(1)`'s default of ~64 outstanding requests, which
/// hides per-request round-trip latency on high-latency links while keeping
/// memory bounded (depth x chunk size).
pub const DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH: usize = 64;

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
///
/// `#[serde(default)]` lets users specify only the keys they care about, and
/// `deny_unknown_fields` turns key typos into parse errors instead of silently
/// ignoring them.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AppConfig {
    /// SSH connection timeout in seconds.
    pub connection_timeout_secs: u64,
    /// Interval between background SFTP health checks for active sessions.
    pub session_health_check_interval_secs: u64,
    /// Number of retries for failed transfers (additional attempts after the
    /// first one). Each retry waits an exponential backoff (1s, 2s, 4s,
    /// capped at 30s) with jitter before re-attempting. `0` disables retries.
    pub transfer_retry_count: u32,
    /// Read/write chunk size for cancellable SFTP transfers.
    pub transfer_chunk_size_bytes: usize,
    /// Maximum number of concurrent in-flight READ requests during a
    /// download (pipelined SFTP reads hide per-request round-trip latency).
    /// Peak buffered memory is roughly `depth × ~256 KiB` (SFTP packet ceiling).
    pub transfer_download_pipeline_depth: usize,
    /// Path to the DockBridge known hosts JSON store.
    pub known_hosts_path: PathBuf,
    /// Path to the OpenSSH `known_hosts` file merged on connect.
    pub openssh_known_hosts_path: PathBuf,
    /// When true, merges [`openssh_known_hosts_path`] into the DockBridge store before connecting.
    pub merge_openssh_known_hosts_on_connect: bool,
    /// When true, trusts host keys only for exact host/port matches (no fingerprint alias fallback).
    pub known_hosts_strict_mode: bool,
    /// When true, aborts connection if merging OpenSSH `known_hosts` fails.
    pub fail_connect_on_openssh_merge_error: bool,
    /// Maximum number of files collected during recursive directory walks.
    pub directory_walk_max_files: u64,
    /// Maximum directory nesting depth during recursive directory walks.
    pub directory_walk_max_depth: u32,
    /// Maximum combined file bytes collected during recursive directory walks.
    pub directory_walk_max_total_bytes: u64,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            connection_timeout_secs: 30,
            session_health_check_interval_secs: 10,
            transfer_retry_count: 3,
            transfer_chunk_size_bytes: DEFAULT_TRANSFER_CHUNK_SIZE_BYTES,
            transfer_download_pipeline_depth: DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH,
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
        // Single source of truth for validation: validate() normalizes and
        // checks chunk size / pipeline depth / retry count / timeouts here too.
        config = config.validate()?;
        Ok(config)
    }

    /// Validates all fields have sane ranges, normalizing values that can be
    /// safely clamped. Single source of truth shared by TOML, CLI, and UniFFI
    /// entry points.
    pub fn validate(mut self) -> Result<Self, ConfigError> {
        ensure_range(
            "connection_timeout_secs",
            self.connection_timeout_secs,
            1..=3600,
            "must be between 1 and 3600 seconds",
        )?;
        ensure_range(
            "session_health_check_interval_secs",
            self.session_health_check_interval_secs,
            1..=3600,
            "must be between 1 and 3600 seconds",
        )?;
        ensure_range(
            "transfer_retry_count",
            u64::from(self.transfer_retry_count),
            0..=10,
            "must be between 0 and 10",
        )?;
        self.transfer_chunk_size_bytes =
            validate_transfer_chunk_size(self.transfer_chunk_size_bytes)?;
        self.transfer_download_pipeline_depth =
            validate_transfer_download_pipeline_depth(self.transfer_download_pipeline_depth);
        ensure_range(
            "directory_walk_max_files",
            self.directory_walk_max_files,
            1..=u64::MAX,
            "must be at least 1",
        )?;
        ensure_range(
            "directory_walk_max_depth",
            u64::from(self.directory_walk_max_depth),
            1..=1024,
            "must be between 1 and 1024",
        )?;
        ensure_range(
            "directory_walk_max_total_bytes",
            self.directory_walk_max_total_bytes,
            1..=u64::MAX,
            "must be at least 1",
        )?;
        Ok(self)
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

/// Validates that `value` falls within `range`, returning an
/// [`ConfigError::InvalidValue`] otherwise.
fn ensure_range(
    field: &'static str,
    value: u64,
    range: std::ops::RangeInclusive<u64>,
    reason: &'static str,
) -> Result<(), ConfigError> {
    if range.contains(&value) {
        Ok(())
    } else {
        Err(ConfigError::InvalidValue {
            field,
            value,
            reason,
        })
    }
}

/// Converts a `u64`-typed config value into `usize` without silent truncation.
///
/// UniFFI receives chunk-size / pipeline-depth values as `u64`; on 32-bit
/// targets a value above `usize::MAX` would otherwise be truncated before
/// `validate()` sees it. Rejecting the value here (rather than wrapping)
/// keeps the "single source of truth" validation meaningful.
pub fn u64_to_usize_or_invalid(field: &'static str, value: u64) -> Result<usize, ConfigError> {
    usize::try_from(value).map_err(|_| ConfigError::InvalidValue {
        field,
        value,
        reason: "value exceeds usize::MAX on this platform",
    })
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

/// Validates a transfer download pipeline depth from configuration.
///
/// Alias of [`clamp_transfer_download_pipeline_depth`]; kept for callers that
/// load config from TOML.
pub fn validate_transfer_download_pipeline_depth(depth: usize) -> usize {
    clamp_transfer_download_pipeline_depth(depth)
}

/// Clamps a transfer download pipeline depth to the allowed range
/// ([`MIN_TRANSFER_DOWNLOAD_PIPELINE_DEPTH`] ..=
/// [`MAX_TRANSFER_DOWNLOAD_PIPELINE_DEPTH`]).
pub fn clamp_transfer_download_pipeline_depth(depth: usize) -> usize {
    depth.clamp(
        MIN_TRANSFER_DOWNLOAD_PIPELINE_DEPTH,
        MAX_TRANSFER_DOWNLOAD_PIPELINE_DEPTH,
    )
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
    fn clamp_transfer_download_pipeline_depth_enforces_bounds() {
        // Given: pipeline depths at and beyond the allowed range
        // When: clamp_transfer_download_pipeline_depth is called
        // Then: values are clamped to the allowed range
        assert_eq!(
            clamp_transfer_download_pipeline_depth(0),
            MIN_TRANSFER_DOWNLOAD_PIPELINE_DEPTH
        );
        assert_eq!(
            clamp_transfer_download_pipeline_depth(MIN_TRANSFER_DOWNLOAD_PIPELINE_DEPTH),
            MIN_TRANSFER_DOWNLOAD_PIPELINE_DEPTH
        );
        assert_eq!(
            clamp_transfer_download_pipeline_depth(MAX_TRANSFER_DOWNLOAD_PIPELINE_DEPTH),
            MAX_TRANSFER_DOWNLOAD_PIPELINE_DEPTH
        );
        assert_eq!(
            clamp_transfer_download_pipeline_depth(MAX_TRANSFER_DOWNLOAD_PIPELINE_DEPTH + 1),
            MAX_TRANSFER_DOWNLOAD_PIPELINE_DEPTH
        );
        // The default is a concrete, in-range value (OpenSSH sftp's ~64).
        assert_eq!(DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH, 64);
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

    #[test]
    fn all_repo_config_toml_files_parse() {
        // Given: the repository's AppConfig-format config files
        // (release.toml uses a separate `[release]` schema and is excluded)
        // When: every one is loaded as an AppConfig
        // Then: every file parses successfully (regression for duplicate-key
        // files like the old config/test.toml)
        //
        // NOTE: every `.toml` file in this directory other than release.toml
        // must use the AppConfig schema - this test fails (loudly) when a
        // different schema is added so the exclusion list is kept in sync.
        let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let config_dir = manifest_dir.join("../../config");
        let config_dir_abs = config_dir.canonicalize().unwrap_or_else(|err| {
            panic!(
                "cannot resolve config directory {} (workspace layout moved?): {err}",
                config_dir.display()
            )
        });
        let mut found_any = false;
        let entries = std::fs::read_dir(&config_dir_abs).unwrap_or_else(|err| {
            panic!(
                "cannot read config directory {}: {err}",
                config_dir_abs.display()
            )
        });
        for entry in entries {
            let path = entry
                .unwrap_or_else(|err| {
                    panic!("cannot read entry in {}: {err}", config_dir_abs.display())
                })
                .path();
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if name.ends_with(".toml") && name != "release.toml" {
                found_any = true;
                AppConfig::from_toml_file(&path).unwrap_or_else(|err| {
                    panic!(
                        "config file {} failed to parse: {err}",
                        path.canonicalize().unwrap_or(path.clone()).display()
                    )
                });
            }
        }
        assert!(
            found_any,
            "no .toml files found under {}",
            config_dir_abs.display()
        );
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

    #[test]
    fn validate_rejects_zero_timeout() {
        // Given: a config with connection_timeout_secs = 0
        let config = AppConfig {
            connection_timeout_secs: 0,
            ..AppConfig::default()
        };

        // When: validating
        // Then: an InvalidValue error is returned
        let err = config.validate().unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidValue {
                field: "connection_timeout_secs",
                value: 0,
                ..
            }
        ));
    }

    #[test]
    fn validate_rejects_zero_health_check_interval() {
        // Given: a config with session_health_check_interval_secs = 0
        let config = AppConfig {
            session_health_check_interval_secs: 0,
            ..AppConfig::default()
        };

        // When: validating
        // Then: an InvalidValue error is returned
        let err = config.validate().unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidValue {
                field: "session_health_check_interval_secs",
                value: 0,
                ..
            }
        ));
    }

    #[test]
    fn validate_rejects_zero_directory_walk_limits() {
        // Given: configs with zero directory walk limits
        let config = AppConfig {
            directory_walk_max_files: 0,
            ..AppConfig::default()
        };
        assert!(config.validate().is_err());

        let config = AppConfig {
            directory_walk_max_depth: 0,
            ..AppConfig::default()
        };
        assert!(config.validate().is_err());

        let config = AppConfig {
            directory_walk_max_total_bytes: 0,
            ..AppConfig::default()
        };
        assert!(config.validate().is_err());
    }

    #[test]
    fn validate_clamps_pipeline_depth() {
        // Given: out-of-range pipeline depth
        let config = AppConfig {
            transfer_download_pipeline_depth: 0,
            ..AppConfig::default()
        };

        // When: validating
        // Then: the pipeline depth is clamped to the allowed range
        let config = config.validate().unwrap();
        assert_eq!(
            config.transfer_download_pipeline_depth,
            MIN_TRANSFER_DOWNLOAD_PIPELINE_DEPTH
        );
    }

    #[test]
    fn validate_rejects_oversized_chunk_size() {
        // Given: a chunk size above the allowed maximum
        let config = AppConfig {
            transfer_chunk_size_bytes: 1_000_000_000,
            ..AppConfig::default()
        };

        // When: validating
        // Then: an InvalidTransferChunkSize error is returned
        let err = config.validate().unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidTransferChunkSize {
                value: 1_000_000_000,
                ..
            }
        ));
    }

    #[test]
    fn validate_accepts_default_config() {
        // Given: the default config
        // When: validating
        // Then: it succeeds and is unchanged
        let config = AppConfig::default().validate().unwrap();
        assert_eq!(config.connection_timeout_secs, 30);
        assert_eq!(
            config.directory_walk_max_files,
            DEFAULT_DIRECTORY_WALK_MAX_FILES
        );
    }

    #[test]
    fn validate_rejects_retry_count_above_maximum() {
        // Given: a transfer_retry_count above the allowed maximum
        let config = AppConfig {
            transfer_retry_count: 11,
            ..AppConfig::default()
        };

        // When: validating
        // Then: an InvalidValue error is returned
        let err = config.validate().unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidValue {
                field: "transfer_retry_count",
                value: 11,
                ..
            }
        ));
    }

    #[test]
    fn validate_accepts_zero_retry_count() {
        // Given: transfer_retry_count = 0 (retries explicitly disabled)
        // When: validating
        // Then: it is accepted
        let config = AppConfig {
            transfer_retry_count: 0,
            ..AppConfig::default()
        };
        assert!(config.validate().is_ok());
    }

    #[test]
    fn validate_rejects_timeout_above_maximum() {
        // Given: connection_timeout_secs above the allowed maximum
        let config = AppConfig {
            connection_timeout_secs: 3601,
            ..AppConfig::default()
        };

        // When: validating
        // Then: an InvalidValue error is returned
        let err = config.validate().unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidValue {
                field: "connection_timeout_secs",
                value: 3601,
                ..
            }
        ));
    }

    #[test]
    fn validate_rejects_directory_walk_depth_above_maximum() {
        // Given: directory_walk_max_depth above the allowed maximum
        let config = AppConfig {
            directory_walk_max_depth: 1025,
            ..AppConfig::default()
        };

        // When: validating
        // Then: an InvalidValue error is returned
        let err = config.validate().unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidValue {
                field: "directory_walk_max_depth",
                value: 1025,
                ..
            }
        ));
    }

    #[test]
    fn from_toml_empty_file_equals_default() {
        // Given: an empty TOML file
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("empty.toml");
        std::fs::write(&path, "").unwrap();

        // When: loading it as an AppConfig
        // Then: it succeeds and equals AppConfig::default()
        // (struct-level #[serde(default)] falls back to AppConfig::default(),
        // so path fields keep their real defaults rather than empty PathBufs)
        let config = AppConfig::from_toml_file(&path).unwrap();
        assert_eq!(config.connection_timeout_secs, 30);
        assert_eq!(
            config.transfer_chunk_size_bytes,
            DEFAULT_TRANSFER_CHUNK_SIZE_BYTES
        );
        assert_eq!(
            config.transfer_download_pipeline_depth,
            DEFAULT_TRANSFER_DOWNLOAD_PIPELINE_DEPTH
        );
        assert_eq!(config.known_hosts_path, default_known_hosts_path());
        assert_eq!(
            config.openssh_known_hosts_path,
            default_openssh_known_hosts_path()
        );
        assert!(config.known_hosts_strict_mode);
        assert!(config.merge_openssh_known_hosts_on_connect);
    }

    #[test]
    fn from_toml_partial_file_uses_defaults() {
        // Given: a TOML file with only one key
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("partial.toml");
        std::fs::write(&path, "connection_timeout_secs = 15\n").unwrap();

        // When: loading it as an AppConfig
        // Then: the specified key is applied and the rest use defaults
        let config = AppConfig::from_toml_file(&path).unwrap();
        assert_eq!(config.connection_timeout_secs, 15);
        assert_eq!(config.transfer_retry_count, 3);
        assert_eq!(config.known_hosts_path, default_known_hosts_path());
    }

    #[test]
    fn from_toml_unknown_key_is_rejected() {
        // Given: a TOML file with a typo'd key name
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("unknown.toml");
        std::fs::write(&path, "known_host_strict_mode = false\n").unwrap();

        // When: loading it as an AppConfig
        // Then: it fails with a parse error instead of silently ignoring it
        let err = AppConfig::from_toml_file(&path).unwrap_err();
        assert!(matches!(err, ConfigError::ParseFailed { .. }));
    }

    #[test]
    fn default_toml_fields_match_app_config_schema() {
        // Given: config/default.toml (the schema template the CLI ships with)
        // When: every key it defines is loaded as an AppConfig
        // Then: parsing succeeds, proving deny_unknown_fields rejects only
        //       truly unknown keys in the repo's own config files
        let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let path = manifest_dir.join("../../config/default.toml");
        AppConfig::from_toml_file(&path).unwrap_or_else(|err| {
            panic!(
                "config/default.toml must match AppConfig schema: {err} (path: {})",
                path.display()
            )
        });
    }
}
