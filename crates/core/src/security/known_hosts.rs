use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use russh::keys::{HashAlg, PublicKey};
use serde::{Deserialize, Serialize};
use ssh_key::known_hosts::{HostPatterns, KnownHosts as OpenSshKnownHosts};

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

/// An alternate host identifier associated with a trusted key entry.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostAlias {
    pub host: String,
    pub port: u16,
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
    #[serde(default)]
    aliases: Vec<HostAlias>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    public_key_openssh: Option<String>,
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
    ///
    /// Lookup order:
    /// 1. Exact canonical host/port or stored alias
    /// 2. Same port and matching fingerprint (hostname/IP alias normalization)
    pub fn check_host_key(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyCheckResult {
        let actual = fingerprint_sha256(key);

        if let Some(entry) = self.find_entry(host, port) {
            return fingerprint_check(entry, &actual);
        }

        if self.find_entry_by_fingerprint(port, &actual).is_some() {
            return HostKeyCheckResult::Trust;
        }

        HostKeyCheckResult::Unknown
    }

    /// Saves a trusted host key to the store with file mode `0600`.
    ///
    /// When the fingerprint already exists for the same port under another host,
    /// the new host is recorded as an alias instead of creating a duplicate entry.
    pub fn accept_host_key(
        &mut self,
        host: &str,
        port: u16,
        key: &PublicKey,
    ) -> Result<(), SecurityError> {
        let fingerprint = fingerprint_sha256(key);
        let public_key_openssh = key.to_openssh().ok();

        if let Some(canonical_key) = self.find_canonical_key_by_fingerprint(port, &fingerprint) {
            let entry = self.entries.get_mut(&canonical_key).ok_or_else(|| {
                SecurityError::KnownHostsWriteFailed {
                    path: self.path.display().to_string(),
                    message: "internal known hosts index inconsistency".to_string(),
                }
            })?;

            if !entry_matches_host(entry, host, port) {
                entry.aliases.push(HostAlias {
                    host: host.to_string(),
                    port,
                });
            }

            if entry.public_key_openssh.is_none() {
                entry.public_key_openssh = public_key_openssh;
            }

            return self.persist();
        }

        let entry = KnownHostEntry {
            host: host.to_string(),
            port,
            fingerprint_sha256: fingerprint,
            algorithm: format!("{:?}", key.algorithm()),
            aliases: Vec::new(),
            public_key_openssh,
        };

        self.entries.insert(entry_key(host, port), entry);
        self.persist()
    }

    /// Merges trusted keys from an OpenSSH `known_hosts` file into this store.
    ///
    /// Hashed host entries (`|1|...`) and certificate-authority markers are skipped.
    /// Returns the number of entries merged.
    pub fn import_openssh(&mut self, path: &Path) -> Result<usize, SecurityError> {
        let contents =
            fs::read_to_string(path).map_err(|err| SecurityError::KnownHostsReadFailed {
                path: path.display().to_string(),
                message: err.to_string(),
            })?;

        let mut merged = 0;
        for line_result in OpenSshKnownHosts::new(&contents) {
            let entry = line_result.map_err(|err| SecurityError::KnownHostsReadFailed {
                path: path.display().to_string(),
                message: err.to_string(),
            })?;

            if entry.marker().is_some() {
                continue;
            }

            let hosts = openssh_host_patterns(entry.host_patterns());
            if hosts.is_empty() {
                continue;
            }

            let fingerprint = entry.public_key().fingerprint(HashAlg::Sha256).to_string();
            let public_key_openssh = entry.public_key().to_openssh().ok();

            let (primary_host, primary_port) = hosts[0].clone();
            let aliases: Vec<HostAlias> = hosts[1..]
                .iter()
                .map(|(host, port)| HostAlias {
                    host: host.clone(),
                    port: *port,
                })
                .collect();

            if self.merge_imported_entry(
                &primary_host,
                primary_port,
                &fingerprint,
                &format!("{:?}", entry.public_key().algorithm()),
                public_key_openssh,
                aliases,
            ) {
                merged += 1;
            }
        }

        if merged > 0 {
            self.persist()?;
        }

        Ok(merged)
    }

    /// Writes trusted keys to an OpenSSH `known_hosts` file with mode `0600`.
    ///
    /// Entries without a stored OpenSSH public key representation are omitted.
    pub fn export_openssh(&self, path: &Path) -> Result<(), SecurityError> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent).map_err(|err| SecurityError::KnownHostsWriteFailed {
                    path: path.display().to_string(),
                    message: err.to_string(),
                })?;
            }
        }

        let mut lines = Vec::new();
        let mut entries: Vec<&KnownHostEntry> = self.entries.values().collect();
        entries.sort_by(|left, right| {
            left.host
                .cmp(&right.host)
                .then_with(|| left.port.cmp(&right.port))
        });

        for entry in entries {
            let Some(public_key_openssh) = entry.public_key_openssh.as_deref() else {
                continue;
            };

            let mut host_patterns = vec![openssh_host_pattern(&entry.host, entry.port)];
            for alias in &entry.aliases {
                host_patterns.push(openssh_host_pattern(&alias.host, alias.port));
            }

            lines.push(format!(
                "{} {}",
                host_patterns.join(","),
                public_key_openssh
            ));
        }

        let payload = if lines.is_empty() {
            String::new()
        } else {
            format!("{}\n", lines.join("\n"))
        };

        write_file_mode_0600(path, payload.as_bytes())
    }

    fn find_entry(&self, host: &str, port: u16) -> Option<&KnownHostEntry> {
        self.entries
            .values()
            .find(|entry| entry_matches_host(entry, host, port))
    }

    fn find_entry_by_fingerprint(&self, port: u16, fingerprint: &str) -> Option<&KnownHostEntry> {
        self.entries
            .values()
            .find(|entry| entry.port == port && entry.fingerprint_sha256 == fingerprint)
    }

    fn find_canonical_key_by_fingerprint(&self, port: u16, fingerprint: &str) -> Option<String> {
        self.entries.iter().find_map(|(key, entry)| {
            if entry.port == port && entry.fingerprint_sha256 == fingerprint {
                Some(key.clone())
            } else {
                None
            }
        })
    }

    fn merge_imported_entry(
        &mut self,
        host: &str,
        port: u16,
        fingerprint: &str,
        algorithm: &str,
        public_key_openssh: Option<String>,
        aliases: Vec<HostAlias>,
    ) -> bool {
        if let Some(canonical_key) = self.find_canonical_key_by_fingerprint(port, fingerprint) {
            let entry = self
                .entries
                .get_mut(&canonical_key)
                .expect("canonical key must exist");

            if !entry_matches_host(entry, host, port) {
                entry.aliases.push(HostAlias {
                    host: host.to_string(),
                    port,
                });
            }

            for alias in aliases {
                if !entry_matches_host(entry, &alias.host, alias.port) {
                    entry.aliases.push(alias);
                }
            }

            if entry.public_key_openssh.is_none() {
                entry.public_key_openssh = public_key_openssh;
            }

            return false;
        }

        if let Some(existing) = self.find_entry(host, port) {
            let canonical_key = entry_key(&existing.host, existing.port);
            let entry = self.entries.get_mut(&canonical_key).expect("entry exists");

            if entry.fingerprint_sha256 != fingerprint {
                return false;
            }

            for alias in aliases {
                if !entry_matches_host(entry, &alias.host, alias.port) {
                    entry.aliases.push(alias);
                }
            }

            if entry.public_key_openssh.is_none() {
                entry.public_key_openssh = public_key_openssh;
            }

            return false;
        }

        self.entries.insert(
            entry_key(host, port),
            KnownHostEntry {
                host: host.to_string(),
                port,
                fingerprint_sha256: fingerprint.to_string(),
                algorithm: algorithm.to_string(),
                aliases,
                public_key_openssh,
            },
        );

        true
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

fn fingerprint_check(entry: &KnownHostEntry, actual: &str) -> HostKeyCheckResult {
    if entry.fingerprint_sha256 == *actual {
        HostKeyCheckResult::Trust
    } else {
        HostKeyCheckResult::Mismatch {
            expected_fingerprint: entry.fingerprint_sha256.clone(),
            actual_fingerprint: actual.to_string(),
        }
    }
}

fn entry_matches_host(entry: &KnownHostEntry, host: &str, port: u16) -> bool {
    entry.host == host && entry.port == port
        || entry
            .aliases
            .iter()
            .any(|alias| alias.host == host && alias.port == port)
}

fn entry_key(host: &str, port: u16) -> String {
    format!("{host}:{port}")
}

fn openssh_host_pattern(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    }
}

fn openssh_host_patterns(patterns: &HostPatterns) -> Vec<(String, u16)> {
    match patterns {
        HostPatterns::HashedName { .. } => Vec::new(),
        HostPatterns::Patterns(items) => items
            .iter()
            .filter_map(|pattern| parse_openssh_host_pattern(pattern))
            .collect(),
    }
}

fn parse_openssh_host_pattern(pattern: &str) -> Option<(String, u16)> {
    if pattern.starts_with('!') || pattern.starts_with("|1|") {
        return None;
    }

    if let Some(rest) = pattern.strip_prefix('[') {
        if let Some((host, port_str)) = rest.split_once("]:") {
            let port = port_str.parse().ok()?;
            return Some((host.to_string(), port));
        }
    }

    Some((pattern.to_string(), 22))
}

/// Computes an OpenSSH-style SHA256 fingerprint (`SHA256:base64...`).
pub fn fingerprint_sha256(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
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
    fn trusts_same_fingerprint_under_different_host_alias() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.accept_host_key("example.com", 22, &key).unwrap();

        assert_eq!(
            manager.check_host_key("203.0.113.1", 22, &key),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn accept_merges_same_fingerprint_into_aliases() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.accept_host_key("example.com", 22, &key).unwrap();
        manager.accept_host_key("203.0.113.1", 22, &key).unwrap();

        let reloaded = KnownHostsManager::load(&path).unwrap();
        let entry = reloaded.find_entry("example.com", 22).unwrap();
        assert_eq!(entry.aliases.len(), 1);
        assert_eq!(entry.aliases[0].host, "203.0.113.1");
        assert_eq!(entry.aliases[0].port, 22);
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

    #[test]
    fn import_openssh_merges_comma_separated_hosts() {
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();

        fs::write(
            &openssh_path,
            format!("example.com,203.0.113.1 {openssh_key}\n"),
        )
        .unwrap();

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let merged = manager.import_openssh(&openssh_path).unwrap();
        assert_eq!(merged, 1);

        assert_eq!(
            manager.check_host_key("example.com", 22, &key),
            HostKeyCheckResult::Trust
        );
        assert_eq!(
            manager.check_host_key("203.0.113.1", 22, &key),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn export_openssh_writes_comma_separated_hosts() {
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("exported_known_hosts");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        manager.accept_host_key("example.com", 22, &key).unwrap();
        manager.accept_host_key("203.0.113.1", 22, &key).unwrap();
        manager.export_openssh(&openssh_path).unwrap();

        let exported = fs::read_to_string(&openssh_path).unwrap();
        assert!(exported.contains("example.com,203.0.113.1"));
        assert!(exported.contains("ssh-ed25519"));
    }

    #[test]
    fn parse_openssh_host_pattern_handles_bracketed_port() {
        assert_eq!(
            parse_openssh_host_pattern("[example.com]:2222"),
            Some(("example.com".to_string(), 2222))
        );
        assert_eq!(
            parse_openssh_host_pattern("example.com"),
            Some(("example.com".to_string(), 22))
        );
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
