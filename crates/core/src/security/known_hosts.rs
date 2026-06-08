use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use russh::keys::{HashAlg, PublicKey};
use serde::{Deserialize, Serialize};

use crate::config::ensure_known_hosts_parent;
use crate::error::SecurityError;

/// Result of checking a host key against the known hosts store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKeyCheckResult {
    /// The host key matches a stored trusted key.
    Trust,
    /// The user or policy rejected the host key.
    Reject,
    /// No stored key exists for this host.
    Unknown,
    /// A stored key exists but does not match the presented key.
    Mismatch {
        expected_fingerprint: String,
        actual_fingerprint: String,
    },
}

/// Manages trusted host keys in a DockBridge-specific JSON store.
#[derive(Debug, Clone)]
pub struct KnownHostsManager {
    path: PathBuf,
    entries: HashMap<String, KnownHostEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct KnownHostEntry {
    host: String,
    port: u16,
    fingerprint_sha256: String,
    algorithm: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct KnownHostsFile {
    entries: Vec<KnownHostEntry>,
}

impl KnownHostsManager {
    /// Creates a manager and loads entries from the given path.
    pub fn load(path: impl Into<PathBuf>) -> Result<Self, SecurityError> {
        let path = path.into();
        let entries = if path.exists() {
            let contents =
                fs::read_to_string(&path).map_err(|err| SecurityError::KnownHostsReadFailed {
                    path: path.display().to_string(),
                    message: err.to_string(),
                })?;
            let file: KnownHostsFile = serde_json::from_str(&contents).map_err(|err| {
                SecurityError::KnownHostsReadFailed {
                    path: path.display().to_string(),
                    message: err.to_string(),
                }
            })?;
            file.entries
                .into_iter()
                .map(|entry| (entry_key(&entry.host, entry.port), entry))
                .collect()
        } else {
            HashMap::new()
        };

        Ok(Self { path, entries })
    }

    /// Returns the store path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Checks a host key against the store without modifying it.
    pub fn check_host_key(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyCheckResult {
        let actual = fingerprint_sha256(key);
        let key = entry_key(host, port);

        match self.entries.get(&key) {
            None => HostKeyCheckResult::Unknown,
            Some(entry) if entry.fingerprint_sha256 == actual => HostKeyCheckResult::Trust,
            Some(entry) => HostKeyCheckResult::Mismatch {
                expected_fingerprint: entry.fingerprint_sha256.clone(),
                actual_fingerprint: actual,
            },
        }
    }

    /// Saves a trusted host key to the store with file mode `0600`.
    pub fn accept_host_key(
        &mut self,
        host: &str,
        port: u16,
        key: &PublicKey,
    ) -> Result<(), SecurityError> {
        let entry = KnownHostEntry {
            host: host.to_string(),
            port,
            fingerprint_sha256: fingerprint_sha256(key),
            algorithm: format!("{:?}", key.algorithm()),
        };

        self.entries.insert(entry_key(host, port), entry.clone());
        self.persist()?;
        Ok(())
    }

    fn persist(&self) -> Result<(), SecurityError> {
        ensure_known_hosts_parent(&self.path)?;

        let mut entries: Vec<KnownHostEntry> = self.entries.values().cloned().collect();
        entries.sort_by(|left, right| {
            left.host
                .cmp(&right.host)
                .then_with(|| left.port.cmp(&right.port))
        });

        let payload = KnownHostsFile { entries };
        let json = serde_json::to_string_pretty(&payload).map_err(|err| {
            SecurityError::KnownHostsWriteFailed {
                path: self.path.display().to_string(),
                message: err.to_string(),
            }
        })?;

        write_file_mode_0600(&self.path, format!("{json}\n").as_bytes())?;
        Ok(())
    }
}

/// Computes an OpenSSH-style SHA256 fingerprint (`SHA256:base64...`).
pub fn fingerprint_sha256(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
}

fn entry_key(host: &str, port: u16) -> String {
    format!("{host}:{port}")
}

#[cfg(unix)]
fn write_file_mode_0600(path: &Path, data: &[u8]) -> Result<(), SecurityError> {
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|err| SecurityError::KnownHostsWriteFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        })?;

    file.write_all(data)
        .map_err(|err| SecurityError::KnownHostsWriteFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        })?;

    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|err| {
        SecurityError::KnownHostsWriteFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        }
    })?;

    Ok(())
}

#[cfg(not(unix))]
fn write_file_mode_0600(path: &Path, data: &[u8]) -> Result<(), SecurityError> {
    fs::write(path, data).map_err(|err| SecurityError::KnownHostsWriteFailed {
        path: path.display().to_string(),
        message: err.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::OsRng;
    use russh::keys::PrivateKey;
    use ssh_key::Algorithm;
    use tempfile::tempdir;

    fn test_public_key() -> PublicKey {
        PrivateKey::random(&mut OsRng, Algorithm::Ed25519)
            .unwrap()
            .public_key()
            .clone()
    }

    #[test]
    fn accept_and_trust_host_key() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            manager.check_host_key("localhost", 22, &key),
            HostKeyCheckResult::Unknown
        );

        manager.accept_host_key("localhost", 22, &key).unwrap();
        assert!(path.exists());

        let reloaded = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            reloaded.check_host_key("localhost", 22, &key),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn mismatch_detects_changed_key() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let first = test_public_key();
        let second = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.accept_host_key("example.com", 22, &first).unwrap();

        match manager.check_host_key("example.com", 22, &second) {
            HostKeyCheckResult::Mismatch { .. } => {}
            other => panic!("expected mismatch, got {other:?}"),
        }
    }

    #[test]
    fn load_missing_file_returns_empty_store() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("missing.json");

        let manager = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            manager.check_host_key("localhost", 22, &test_public_key()),
            HostKeyCheckResult::Unknown
        );
        assert!(!path.exists());
    }

    #[test]
    fn load_empty_entries_array_succeeds() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        fs::write(&path, r#"{"entries":[]}"#).unwrap();

        let manager = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            manager.check_host_key("localhost", 22, &test_public_key()),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn load_invalid_empty_object_returns_read_failed() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        fs::write(&path, "{}").unwrap();

        let err = KnownHostsManager::load(&path).unwrap_err();
        assert!(matches!(err, SecurityError::KnownHostsReadFailed { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn written_file_has_0600_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.accept_host_key("localhost", 22, &key).unwrap();

        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
