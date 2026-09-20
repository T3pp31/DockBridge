use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use russh::keys::{HashAlg, PublicKey};
use serde::{Deserialize, Serialize};
use sha1::{Digest, Sha1};
use ssh_key::known_hosts::{
    HostPatterns, KnownHosts as OpenSshKnownHosts, Marker as OpenSshMarker,
};
use subtle::ConstantTimeEq;

use crate::config::{ensure_known_hosts_parent, AppConfig};
use crate::error::SecurityError;

/// Result of importing an OpenSSH `known_hosts` file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ImportSummary {
    /// Number of entries newly merged into the store.
    pub merged: usize,
    /// Number of lines skipped because they could not be parsed.
    pub skipped: usize,
}

impl ImportSummary {
    /// Returns `true` when nothing was imported *and* no lines were skipped
    /// (i.e. the store contents are untouched).
    pub fn is_empty(self) -> bool {
        self.merged == 0 && self.skipped == 0
    }

    /// Returns `true` when at least one entry was merged into the store.
    pub fn has_merged_entries(self) -> bool {
        self.merged > 0
    }
}

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

/// OpenSSH known_hosts marker stored alongside a host key entry.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum KnownHostMarker {
    /// `@revoked` — matching keys must be rejected.
    Revoked,
    /// `@cert-authority` — imported for compatibility; not used for host trust in v0.2.
    CertAuthority,
}

/// Plain host entry parsed from OpenSSH `known_hosts` during import.
struct ImportedPlainEntry {
    host: String,
    port: u16,
    fingerprint_sha256: String,
    algorithm: String,
    public_key_openssh: Option<String>,
    aliases: Vec<HostAlias>,
    excluded_aliases: Vec<HostAlias>,
    marker: Option<KnownHostMarker>,
}

/// A hashed OpenSSH known_hosts entry (`|1|salt|hash`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HashedHostEntry {
    pub salt: Vec<u8>,
    pub hash: [u8; 20],
    pub fingerprint_sha256: String,
    pub algorithm: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public_key_openssh: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub marker: Option<KnownHostMarker>,
}

/// Manages trusted host keys in a DockBridge-specific JSON store.
#[derive(Debug, Clone)]
pub struct KnownHostsManager {
    path: PathBuf,
    entries: HashMap<String, KnownHostEntry>,
    hashed_entries: Vec<HashedHostEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct KnownHostEntry {
    host: String,
    port: u16,
    fingerprint_sha256: String,
    algorithm: String,
    #[serde(default)]
    aliases: Vec<HostAlias>,
    #[serde(default)]
    excluded_aliases: Vec<HostAlias>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    public_key_openssh: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    marker: Option<KnownHostMarker>,
}

#[derive(Debug, Serialize, Deserialize)]
struct KnownHostsFile {
    entries: Vec<KnownHostEntry>,
    #[serde(default)]
    hashed_entries: Vec<HashedHostEntry>,
}

impl KnownHostsManager {
    /// Creates a manager and loads entries from the given path.
    pub fn load(path: impl Into<PathBuf>) -> Result<Self, SecurityError> {
        let path = path.into();
        let (entries, hashed_entries) = if path.exists() {
            let contents =
                read_secure_known_hosts_file(&path, KnownHostsReadPolicy::DockBridgeStore)?;
            let file: KnownHostsFile = serde_json::from_str(&contents).map_err(|err| {
                SecurityError::KnownHostsReadFailed {
                    path: path.display().to_string(),
                    message: err.to_string(),
                }
            })?;
            let hashed_entries = file.hashed_entries;
            let entries = file
                .entries
                .into_iter()
                .map(normalize_entry_case)
                .map(|entry| {
                    let key = entry_key(&entry.host, entry.port);
                    (key, entry)
                })
                .collect();
            (entries, hashed_entries)
        } else {
            (HashMap::new(), Vec::new())
        };

        Ok(Self {
            path,
            entries,
            hashed_entries,
        })
    }

    /// Returns the store path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Checks a host key against the store without modifying it.
    ///
    /// Lookup order:
    /// 1. `@revoked` entries (plain or hashed) matching host and fingerprint
    /// 2. Exact canonical host/port or stored alias (excluding cert-authority markers)
    /// 3. Same port and matching fingerprint (hostname/IP alias normalization; skipped in strict mode)
    /// 4. Hashed entries matching host and fingerprint
    /// 5. Unknown
    pub fn check_host_key(
        &self,
        host: &str,
        port: u16,
        key: &PublicKey,
        strict_mode: bool,
    ) -> HostKeyCheckResult {
        let actual = fingerprint_sha256(key);

        if self.is_revoked(host, port, &actual) {
            return HostKeyCheckResult::Reject;
        }

        if let Some(entry) = self.find_trusted_entry(host, port) {
            return fingerprint_check(entry, &actual);
        }

        if !strict_mode
            && self
                .find_trusted_entry_by_fingerprint(host, port, &actual)
                .is_some()
        {
            return HostKeyCheckResult::Trust;
        }

        if self
            .find_matching_hashed_entry(host, port, &actual)
            .is_some()
        {
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

        if let Some(existing) = self.find_trusted_entry(host, port) {
            let canonical_key = entry_key(&existing.host, existing.port);
            let entry = self.entries.get_mut(&canonical_key).ok_or_else(|| {
                SecurityError::KnownHostsWriteFailed {
                    path: self.path.display().to_string(),
                    message: "internal known hosts index inconsistency".to_string(),
                }
            })?;

            entry.fingerprint_sha256 = fingerprint.clone();
            entry.algorithm = format!("{:?}", key.algorithm());
            entry.public_key_openssh = public_key_openssh;
            entry.marker = None;

            return self.persist();
        }

        if let Some(canonical_key) = self.find_canonical_key_by_fingerprint(port, &fingerprint) {
            let entry = self.entries.get_mut(&canonical_key).ok_or_else(|| {
                SecurityError::KnownHostsWriteFailed {
                    path: self.path.display().to_string(),
                    message: "internal known hosts index inconsistency".to_string(),
                }
            })?;

            if !entry_matches_host(entry, host, port) {
                entry.aliases.push(HostAlias {
                    host: host.to_ascii_lowercase(),
                    port,
                });
            }

            if entry.public_key_openssh.is_none() {
                entry.public_key_openssh = public_key_openssh;
            }

            return self.persist();
        }

        let entry = KnownHostEntry {
            host: host.to_ascii_lowercase(),
            port,
            fingerprint_sha256: fingerprint,
            algorithm: format!("{:?}", key.algorithm()),
            aliases: Vec::new(),
            excluded_aliases: Vec::new(),
            public_key_openssh,
            marker: None,
        };

        self.entries.insert(entry_key(host, port), entry);
        self.persist()
    }

    /// Merges the configured OpenSSH `known_hosts` file into this store before connecting.
    ///
    /// When merging is disabled, returns an empty summary without reading the file.
    /// When the file does not exist, returns an empty summary without error.
    /// Read failures are logged and return `0` so connection is not blocked unless
    /// [`AppConfig::fail_connect_on_openssh_merge_error`] is enabled.
    pub fn merge_openssh_on_connect(
        &mut self,
        config: &AppConfig,
    ) -> Result<ImportSummary, SecurityError> {
        if !config.merge_openssh_known_hosts_on_connect {
            return Ok(ImportSummary::default());
        }

        let path = &config.openssh_known_hosts_path;
        if !path.exists() {
            return Ok(ImportSummary::default());
        }

        match self.import_openssh(path) {
            Ok(summary) => Ok(summary),
            Err(err) => {
                tracing::warn!(
                    path = %path.display(),
                    error = %err,
                    "failed to merge OpenSSH known_hosts on connect"
                );
                if config.fail_connect_on_openssh_merge_error {
                    Err(err)
                } else {
                    Ok(ImportSummary::default())
                }
            }
        }
    }

    /// Merges trusted keys from an OpenSSH `known_hosts` file into this store.
    ///
    /// Imports plain and hashed entries, including `@revoked` and `@cert-authority` markers.
    /// Returns an [`ImportSummary`] with the number of newly merged entries and the number of
    /// lines skipped because they could not be parsed.
    ///
    /// Line-level parse errors are tolerated: the offending line is logged and skipped while
    /// the remaining lines are still imported. Errors returned are file-level failures only
    /// (unreadable file, insecure permissions, or persistence failure).
    pub fn import_openssh(&mut self, path: &Path) -> Result<ImportSummary, SecurityError> {
        let contents = read_secure_known_hosts_file(path, KnownHostsReadPolicy::OpenSshImport)?;

        let mut merged = 0;
        let mut skipped = 0;
        for line_result in OpenSshKnownHosts::new(&contents) {
            let entry = match line_result {
                Ok(entry) => entry,
                Err(err) => {
                    // Log only the file path and error kind, never the raw line
                    // contents (a known_hosts line embeds the public key).
                    tracing::warn!(
                        path = %path.display(),
                        error = %err,
                        "skipping unparseable known_hosts line"
                    );
                    skipped += 1;
                    continue;
                }
            };

            let marker = entry.marker().map(openssh_marker_to_known_host_marker);
            let fingerprint = entry.public_key().fingerprint(HashAlg::Sha256).to_string();
            let public_key_openssh = entry.public_key().to_openssh().ok();
            let algorithm = format!("{:?}", entry.public_key().algorithm());

            match entry.host_patterns() {
                HostPatterns::HashedName { salt, hash } => {
                    if self.merge_imported_hashed_entry(HashedHostEntry {
                        salt: salt.clone(),
                        hash: *hash,
                        fingerprint_sha256: fingerprint,
                        algorithm,
                        public_key_openssh,
                        marker,
                    }) {
                        merged += 1;
                    }
                }
                HostPatterns::Patterns(_) => {
                    let (hosts, excluded_aliases) = openssh_host_patterns(
                        entry.host_patterns(),
                        marker == Some(KnownHostMarker::CertAuthority),
                    );
                    if hosts.is_empty() {
                        continue;
                    }

                    let (primary_host, primary_port) = hosts[0].clone();
                    let aliases: Vec<HostAlias> = hosts[1..]
                        .iter()
                        .map(|(host, port)| HostAlias {
                            host: host.clone(),
                            port: *port,
                        })
                        .collect();

                    if self.merge_imported_entry(ImportedPlainEntry {
                        host: primary_host,
                        port: primary_port,
                        fingerprint_sha256: fingerprint,
                        algorithm,
                        public_key_openssh,
                        aliases,
                        excluded_aliases,
                        marker,
                    }) {
                        merged += 1;
                    }
                }
            }
        }

        let summary = ImportSummary { merged, skipped };
        // Persist when anything changed OR lines were skipped. Skipped lines
        // don't currently mutate the store, but persisting ensures a future
        // side effect on the skipped path cannot be missed (e.g. if a parse
        // failure were recorded in the store).
        if summary.has_merged_entries() || summary.skipped > 0 {
            self.persist()?;
        }

        Ok(summary)
    }

    /// Writes trusted keys to an OpenSSH `known_hosts` file with mode `0600`.
    ///
    /// Entries without a stored OpenSSH public key representation are omitted.
    pub fn export_openssh(&self, path: &Path) -> Result<(), SecurityError> {
        ensure_known_hosts_parent(path)?;

        let mut lines = Vec::new();
        let mut entries: Vec<&KnownHostEntry> = self.entries.values().collect();
        entries.sort_by(|left, right| {
            left.host
                .cmp(&right.host)
                .then_with(|| left.port.cmp(&right.port))
        });

        for entry in entries {
            if entry.marker.is_some() {
                continue;
            }

            let Some(public_key_openssh) = entry.public_key_openssh.as_deref() else {
                continue;
            };

            let mut host_patterns = vec![openssh_host_pattern(&entry.host, entry.port)];
            for alias in &entry.aliases {
                host_patterns.push(openssh_host_pattern(&alias.host, alias.port));
            }
            for excluded in &entry.excluded_aliases {
                host_patterns.push(openssh_negated_host_pattern(&excluded.host, excluded.port));
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

    fn find_trusted_entry(&self, host: &str, port: u16) -> Option<&KnownHostEntry> {
        self.entries.values().find(|entry| {
            entry_matches_host(entry, host, port) && !entry_has_non_trusting_marker(entry.marker)
        })
    }

    fn find_trusted_entry_by_fingerprint(
        &self,
        host: &str,
        port: u16,
        fingerprint: &str,
    ) -> Option<&KnownHostEntry> {
        self.entries.values().find(|entry| {
            entry.port == port
                && fingerprints_match(&entry.fingerprint_sha256, fingerprint)
                && !entry_has_non_trusting_marker(entry.marker)
                && !entry_is_excluded_for_host(entry, host, port)
        })
    }

    fn is_revoked(&self, host: &str, port: u16, fingerprint: &str) -> bool {
        if self.entries.values().any(|entry| {
            entry.marker == Some(KnownHostMarker::Revoked)
                && fingerprints_match(&entry.fingerprint_sha256, fingerprint)
                && entry_matches_host(entry, host, port)
        }) {
            return true;
        }

        self.hashed_entries.iter().any(|entry| {
            entry.marker == Some(KnownHostMarker::Revoked)
                && fingerprints_match(&entry.fingerprint_sha256, fingerprint)
                && hashed_entry_matches_host(entry, host, port)
        })
    }

    fn find_matching_hashed_entry(
        &self,
        host: &str,
        port: u16,
        fingerprint: &str,
    ) -> Option<&HashedHostEntry> {
        self.hashed_entries.iter().find(|entry| {
            fingerprints_match(&entry.fingerprint_sha256, fingerprint)
                && entry.marker != Some(KnownHostMarker::Revoked)
                && entry.marker != Some(KnownHostMarker::CertAuthority)
                && hashed_entry_matches_host(entry, host, port)
        })
    }

    fn find_canonical_key_by_fingerprint(&self, port: u16, fingerprint: &str) -> Option<String> {
        self.entries.iter().find_map(|(key, entry)| {
            if entry.port == port
                && fingerprints_match(&entry.fingerprint_sha256, fingerprint)
                && !entry_has_non_trusting_marker(entry.marker)
            {
                Some(key.clone())
            } else {
                None
            }
        })
    }

    fn merge_imported_hashed_entry(&mut self, entry: HashedHostEntry) -> bool {
        if self.hashed_entries.iter().any(|existing| {
            existing.salt == entry.salt
                && existing.hash == entry.hash
                && fingerprints_match(&existing.fingerprint_sha256, &entry.fingerprint_sha256)
                && existing.marker == entry.marker
        }) {
            return false;
        }

        self.hashed_entries.push(entry);
        true
    }

    fn merge_imported_entry(&mut self, imported: ImportedPlainEntry) -> bool {
        let ImportedPlainEntry {
            host,
            port,
            fingerprint_sha256,
            algorithm,
            public_key_openssh,
            aliases,
            excluded_aliases,
            marker,
        } = imported;

        if marker == Some(KnownHostMarker::Revoked) {
            if self.entries.values().any(|entry| {
                entry.marker == Some(KnownHostMarker::Revoked)
                    && entry_matches_host(entry, &host, port)
                    && fingerprints_match(&entry.fingerprint_sha256, &fingerprint_sha256)
            }) {
                return false;
            }

            self.entries.insert(
                entry_key(&host, port),
                KnownHostEntry {
                    host,
                    port,
                    fingerprint_sha256,
                    algorithm,
                    aliases,
                    excluded_aliases,
                    public_key_openssh,
                    marker: Some(KnownHostMarker::Revoked),
                },
            );
            return true;
        }

        if marker == Some(KnownHostMarker::CertAuthority) {
            if self.entries.values().any(|entry| {
                entry.marker == Some(KnownHostMarker::CertAuthority)
                    && entry_matches_host(entry, &host, port)
                    && fingerprints_match(&entry.fingerprint_sha256, &fingerprint_sha256)
            }) {
                return false;
            }

            self.entries.insert(
                entry_key(&host, port),
                KnownHostEntry {
                    host,
                    port,
                    fingerprint_sha256,
                    algorithm,
                    aliases,
                    excluded_aliases,
                    public_key_openssh,
                    marker: Some(KnownHostMarker::CertAuthority),
                },
            );
            return true;
        }

        if let Some(canonical_key) =
            self.find_canonical_key_by_fingerprint(port, &fingerprint_sha256)
        {
            let entry = self
                .entries
                .get_mut(&canonical_key)
                .expect("canonical key must exist");

            if !entry_matches_host(entry, &host, port) {
                entry.aliases.push(HostAlias { host, port });
            }

            for alias in aliases {
                if !entry_matches_host(entry, &alias.host, alias.port) {
                    entry.aliases.push(alias);
                }
            }
            merge_excluded_aliases(entry, &excluded_aliases);

            if entry.public_key_openssh.is_none() {
                entry.public_key_openssh = public_key_openssh;
            }

            return false;
        }

        if let Some(existing) = self.find_entry(&host, port) {
            if existing.marker == Some(KnownHostMarker::Revoked)
                || existing.marker == Some(KnownHostMarker::CertAuthority)
            {
                return false;
            }

            let canonical_key = entry_key(&existing.host, existing.port);
            let entry = self.entries.get_mut(&canonical_key).expect("entry exists");

            if !fingerprints_match(&entry.fingerprint_sha256, &fingerprint_sha256) {
                return false;
            }

            for alias in aliases {
                if !entry_matches_host(entry, &alias.host, alias.port) {
                    entry.aliases.push(alias);
                }
            }
            merge_excluded_aliases(entry, &excluded_aliases);

            if entry.public_key_openssh.is_none() {
                entry.public_key_openssh = public_key_openssh;
            }

            return false;
        }

        self.entries.insert(
            entry_key(&host, port),
            KnownHostEntry {
                host,
                port,
                fingerprint_sha256,
                algorithm,
                aliases,
                excluded_aliases,
                public_key_openssh,
                marker: None,
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

        let mut hashed_entries = self.hashed_entries.clone();
        hashed_entries.sort_by(|left, right| {
            left.fingerprint_sha256
                .cmp(&right.fingerprint_sha256)
                .then_with(|| left.hash.cmp(&right.hash))
        });

        let payload = KnownHostsFile {
            entries,
            hashed_entries,
        };
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
    if fingerprints_match(&entry.fingerprint_sha256, actual) {
        HostKeyCheckResult::Trust
    } else {
        HostKeyCheckResult::Mismatch {
            expected_fingerprint: entry.fingerprint_sha256.clone(),
            actual_fingerprint: actual.to_string(),
        }
    }
}

fn entry_matches_host(entry: &KnownHostEntry, host: &str, port: u16) -> bool {
    if entry_is_excluded_for_host(entry, host, port) {
        return false;
    }

    entry.host.eq_ignore_ascii_case(host) && entry.port == port
        || entry
            .aliases
            .iter()
            .any(|alias| alias.host.eq_ignore_ascii_case(host) && alias.port == port)
}

fn entry_is_excluded_for_host(entry: &KnownHostEntry, host: &str, port: u16) -> bool {
    entry
        .excluded_aliases
        .iter()
        .any(|alias| alias.host.eq_ignore_ascii_case(host) && alias.port == port)
}

fn merge_excluded_aliases(entry: &mut KnownHostEntry, excluded: &[HostAlias]) {
    for alias in excluded {
        if !entry
            .excluded_aliases
            .iter()
            .any(|existing| existing.host == alias.host && existing.port == alias.port)
        {
            entry.excluded_aliases.push(alias.clone());
        }
    }
}

fn entry_key(host: &str, port: u16) -> String {
    format!("{}:{port}", host.to_ascii_lowercase())
}

/// Lowercases a stored entry's host identifiers so lookups are case-insensitive,
/// matching OpenSSH behaviour. Used when loading existing stores to migrate
/// entries written by older versions.
fn normalize_entry_case(mut entry: KnownHostEntry) -> KnownHostEntry {
    entry.host = entry.host.to_ascii_lowercase();
    for alias in &mut entry.aliases {
        alias.host = alias.host.to_ascii_lowercase();
    }
    for alias in &mut entry.excluded_aliases {
        alias.host = alias.host.to_ascii_lowercase();
    }
    entry
}

/// Returns `true` when the entry's marker means the key must NOT be trusted
/// for ordinary host verification: `@revoked` (always reject) or
/// `@cert-authority` (CA keys are out of scope for direct host trust). Such
/// entries must not be used for fingerprint alias matching or as merge targets.
fn entry_has_non_trusting_marker(marker: Option<KnownHostMarker>) -> bool {
    matches!(
        marker,
        Some(KnownHostMarker::Revoked) | Some(KnownHostMarker::CertAuthority)
    )
}

fn openssh_marker_to_known_host_marker(marker: &OpenSshMarker) -> KnownHostMarker {
    match marker {
        OpenSshMarker::Revoked => KnownHostMarker::Revoked,
        OpenSshMarker::CertAuthority => KnownHostMarker::CertAuthority,
    }
}

fn openssh_hostname_hash(salt: &[u8], host: &str, port: u16) -> [u8; 20] {
    // OpenSSH hashed-hostname entries use SHA-1 per the known_hosts format (see ssh-key crate).
    // SHA-256 is used for fingerprint display; this hash is spec-mandated for |1| entries.
    let mut hasher = Sha1::new();
    hasher.update(salt);
    if port == 22 {
        hasher.update(host.as_bytes());
    } else {
        hasher.update(format!("[{host}]:{port}").as_bytes());
    }
    hasher.finalize().into()
}

/// Constant-time comparison of two fingerprint strings to mitigate timing
/// attacks on fingerprint comparisons (CWE-208). Uses `subtle::ConstantTimeEq`
/// which is resistant to compiler optimizations that could short-circuit
/// the comparison.
fn fingerprints_match(a: &str, b: &str) -> bool {
    a.as_bytes().ct_eq(b.as_bytes()).into()
}

fn hashed_entry_matches_host(entry: &HashedHostEntry, host: &str, port: u16) -> bool {
    let computed = openssh_hostname_hash(&entry.salt, host, port);
    computed.as_slice().ct_eq(&entry.hash).into()
}

fn openssh_host_pattern(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    }
}

fn openssh_host_patterns(
    patterns: &HostPatterns,
    allow_wildcards: bool,
) -> (Vec<(String, u16)>, Vec<HostAlias>) {
    match patterns {
        HostPatterns::HashedName { .. } => (Vec::new(), Vec::new()),
        HostPatterns::Patterns(items) => {
            let mut positive = Vec::new();
            let mut excluded = Vec::new();
            for pattern in items {
                let Some(parsed) = parse_openssh_host_pattern(pattern) else {
                    continue;
                };
                if !allow_wildcards && (parsed.host.contains('*') || parsed.host.contains('?')) {
                    tracing::warn!(
                        pattern = %pattern,
                        "unsupported wildcard pattern in known_hosts line skipped"
                    );
                    continue;
                }
                if parsed.negated {
                    excluded.push(HostAlias {
                        host: parsed.host,
                        port: parsed.port,
                    });
                } else {
                    positive.push((parsed.host, parsed.port));
                }
            }
            (positive, excluded)
        }
    }
}

struct ParsedOpenSshHostPattern {
    host: String,
    port: u16,
    negated: bool,
}

fn parse_openssh_host_pattern(pattern: &str) -> Option<ParsedOpenSshHostPattern> {
    let negated = pattern.starts_with('!');
    let pattern = pattern.strip_prefix('!').unwrap_or(pattern);
    if pattern.starts_with("|1|") {
        return None;
    }

    let (host, port) = if let Some(rest) = pattern.strip_prefix('[') {
        if let Some((host, port_str)) = rest.split_once("]:") {
            let port = port_str.parse().ok()?;
            (host.to_string(), port)
        } else {
            return None;
        }
    } else {
        (pattern.to_string(), 22)
    };

    Some(ParsedOpenSshHostPattern {
        host,
        port,
        negated,
    })
}

fn openssh_negated_host_pattern(host: &str, port: u16) -> String {
    format!("!{}", openssh_host_pattern(host, port))
}

/// Computes an OpenSSH-style SHA256 fingerprint (`SHA256:base64...`).
pub fn fingerprint_sha256(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
}

const KNOWN_HOSTS_PARTIAL_SUFFIX_BYTES: usize = 16;
const MAX_KNOWN_HOSTS_PARTIAL_CREATE_ATTEMPTS: usize = 5;

/// Maximum byte size accepted when reading a known hosts file (16 MiB).
/// Guards the store/import readers against accidentally pointing at a huge
/// file; owner-only permission checks already limit exposure.
const MAX_KNOWN_HOSTS_FILE_BYTES: u64 = 16 * 1024 * 1024;

fn random_known_hosts_partial_suffix() -> String {
    use rand::TryRng;

    let mut bytes = [0_u8; KNOWN_HOSTS_PARTIAL_SUFFIX_BYTES];
    rand::rng()
        .try_fill_bytes(&mut bytes)
        .expect("failed to generate random partial suffix");
    bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

fn known_hosts_partial_file_name(suffix: &str) -> String {
    format!(".dockbridge-{suffix}.partial")
}

/// Permission policy applied when reading a known hosts file on Unix.
enum KnownHostsReadPolicy {
    /// DockBridge `known_hosts.json`: owner-only `0600` or `0400`.
    DockBridgeStore,
    /// External OpenSSH `known_hosts`: owner match, no group/other write (`0644` OK).
    OpenSshImport,
}

fn read_secure_known_hosts_file(
    path: &Path,
    policy: KnownHostsReadPolicy,
) -> Result<String, SecurityError> {
    #[cfg(unix)]
    {
        read_secure_known_hosts_file_unix(path, policy)
    }
    #[cfg(not(unix))]
    {
        let _ = policy;
        let metadata = fs::metadata(path).map_err(|err| SecurityError::KnownHostsReadFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        })?;
        if metadata.len() > MAX_KNOWN_HOSTS_FILE_BYTES {
            return Err(SecurityError::KnownHostsReadFailed {
                path: path.display().to_string(),
                message: "known hosts file is too large".to_string(),
            });
        }
        fs::read_to_string(path).map_err(|err| SecurityError::KnownHostsReadFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        })
    }
}

#[cfg(unix)]
fn read_secure_known_hosts_file_unix(
    path: &Path,
    policy: KnownHostsReadPolicy,
) -> Result<String, SecurityError> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;

    let path_str = path.display().to_string();
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|err| SecurityError::KnownHostsReadFailed {
            path: path_str.clone(),
            message: err.to_string(),
        })?;

    validate_known_hosts_fd_metadata(&file, &path_str, policy)?;

    let size = file
        .metadata()
        .map_err(|err| SecurityError::KnownHostsReadFailed {
            path: path_str.clone(),
            message: err.to_string(),
        })?
        .len();
    if size > MAX_KNOWN_HOSTS_FILE_BYTES {
        return Err(SecurityError::KnownHostsReadFailed {
            path: path_str,
            message: format!(
                "known hosts file is too large ({size} bytes, limit {MAX_KNOWN_HOSTS_FILE_BYTES})"
            ),
        });
    }

    let mut contents = String::new();
    file.read_to_string(&mut contents)
        .map_err(|err| SecurityError::KnownHostsReadFailed {
            path: path_str,
            message: err.to_string(),
        })?;

    Ok(contents)
}

#[cfg(unix)]
fn validate_known_hosts_fd_metadata(
    file: &std::fs::File,
    path_str: &str,
    policy: KnownHostsReadPolicy,
) -> Result<(), SecurityError> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let metadata = file
        .metadata()
        .map_err(|err| SecurityError::KnownHostsReadFailed {
            path: path_str.to_string(),
            message: err.to_string(),
        })?;

    let file_uid = metadata.uid();
    let effective_uid = unsafe { libc::geteuid() };
    if file_uid != effective_uid {
        return Err(SecurityError::KnownHostsReadFailed {
            path: path_str.to_string(),
            message: format!("owner uid {file_uid} does not match effective uid {effective_uid}"),
        });
    }

    let mode = metadata.permissions().mode() & 0o777;
    match policy {
        KnownHostsReadPolicy::DockBridgeStore => {
            if mode != 0o600 && mode != 0o400 {
                return Err(SecurityError::KnownHostsReadFailed {
                    path: path_str.to_string(),
                    message: format!("insecure permissions {mode:04o} (expected 0600 or 0400)"),
                });
            }
        }
        KnownHostsReadPolicy::OpenSshImport => {
            if mode & 0o022 != 0 {
                return Err(SecurityError::KnownHostsReadFailed {
                    path: path_str.to_string(),
                    message: format!(
                        "insecure permissions {mode:04o} (group/other write not permitted)"
                    ),
                });
            }
        }
    }

    Ok(())
}

#[cfg(unix)]
fn open_exclusive_local_file_sync(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;

    let mut options = OpenOptions::new();
    options.create_new(true).write(true).mode(0o600);
    options.custom_flags(libc::O_NOFOLLOW);
    options.open(path)
}

#[cfg(unix)]
fn write_file_mode_0600(path: &Path, data: &[u8]) -> Result<(), SecurityError> {
    use std::os::unix::fs::PermissionsExt;

    let parent = path
        .parent()
        .ok_or_else(|| SecurityError::KnownHostsWriteFailed {
            path: path.display().to_string(),
            message: "known hosts path has no parent directory".to_string(),
        })?;

    let mut temp_path = None;
    let mut file = None;

    for _ in 0..MAX_KNOWN_HOSTS_PARTIAL_CREATE_ATTEMPTS {
        let candidate = parent.join(known_hosts_partial_file_name(
            &random_known_hosts_partial_suffix(),
        ));
        match open_exclusive_local_file_sync(&candidate) {
            Ok(opened) => {
                temp_path = Some(candidate);
                file = Some(opened);
                break;
            }
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => {
                return Err(SecurityError::KnownHostsWriteFailed {
                    path: path.display().to_string(),
                    message: err.to_string(),
                });
            }
        }
    }

    let temp_path = temp_path.ok_or_else(|| SecurityError::KnownHostsWriteFailed {
        path: path.display().to_string(),
        message: format!(
            "failed to create exclusive partial file after {MAX_KNOWN_HOSTS_PARTIAL_CREATE_ATTEMPTS} attempts"
        ),
    })?;
    let mut file = file.expect("partial file handle must exist when temp path was created");

    if let Err(err) = file.write_all(data) {
        let _ = fs::remove_file(&temp_path);
        return Err(SecurityError::KnownHostsWriteFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        });
    }

    if let Err(err) = file.sync_all() {
        let _ = fs::remove_file(&temp_path);
        return Err(SecurityError::KnownHostsWriteFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        });
    }

    if let Err(err) = fs::rename(&temp_path, path) {
        let _ = fs::remove_file(&temp_path);
        return Err(SecurityError::KnownHostsWriteFailed {
            path: path.display().to_string(),
            message: err.to_string(),
        });
    }

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
    use rand::rng;
    use russh::keys::PrivateKey;
    use ssh_key::Algorithm;
    use tempfile::tempdir;

    fn test_public_key() -> PublicKey {
        PrivateKey::random(&mut rng(), Algorithm::Ed25519)
            .unwrap()
            .public_key()
            .clone()
    }

    fn write_test_file_mode_0600(path: &Path, contents: impl AsRef<[u8]>) {
        fs::write(path, contents).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
    }

    #[cfg(unix)]
    fn set_test_file_mode(path: &Path, mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn accept_and_trust_host_key() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            manager.check_host_key("localhost", 22, &key, false),
            HostKeyCheckResult::Unknown
        );

        manager.accept_host_key("localhost", 22, &key).unwrap();
        assert!(path.exists());

        let reloaded = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            reloaded.check_host_key("localhost", 22, &key, false),
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

        match manager.check_host_key("example.com", 22, &second, false) {
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
            manager.check_host_key("203.0.113.1", 22, &key, false),
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
            manager.check_host_key("localhost", 22, &test_public_key(), false),
            HostKeyCheckResult::Unknown
        );
        assert!(!path.exists());
    }

    #[test]
    fn load_empty_entries_array_succeeds() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        write_test_file_mode_0600(&path, r#"{"entries":[]}"#);

        let manager = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            manager.check_host_key("localhost", 22, &test_public_key(), false),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn load_invalid_empty_object_returns_read_failed() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        write_test_file_mode_0600(&path, "{}");

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

        write_test_file_mode_0600(
            &openssh_path,
            format!("example.com,203.0.113.1 {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let summary = manager.import_openssh(&openssh_path).unwrap();
        assert_eq!(summary.merged, 1);
        assert_eq!(summary.skipped, 0);

        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
        assert_eq!(
            manager.check_host_key("203.0.113.1", 22, &key, false),
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
        let parsed = parse_openssh_host_pattern("[example.com]:2222").unwrap();
        assert_eq!(parsed.host, "example.com");
        assert_eq!(parsed.port, 2222);
        assert!(!parsed.negated);

        let parsed = parse_openssh_host_pattern("example.com").unwrap();
        assert_eq!(parsed.host, "example.com");
        assert_eq!(parsed.port, 22);
        assert!(!parsed.negated);
    }

    #[test]
    fn parse_openssh_host_pattern_handles_negated_hosts() {
        let parsed = parse_openssh_host_pattern("!.bad.example.com").unwrap();
        assert_eq!(parsed.host, ".bad.example.com");
        assert_eq!(parsed.port, 22);
        assert!(parsed.negated);

        let parsed = parse_openssh_host_pattern("![bad.example.com]:2222").unwrap();
        assert_eq!(parsed.host, "bad.example.com");
        assert_eq!(parsed.port, 2222);
        assert!(parsed.negated);
    }

    #[test]
    fn import_openssh_honors_negated_host_patterns() {
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();

        write_test_file_mode_0600(
            &openssh_path,
            format!("bad.example.com,!bad.example.com {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        assert_eq!(
            manager.check_host_key("bad.example.com", 22, &key, false),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn import_openssh_exports_negated_host_patterns() {
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();

        write_test_file_mode_0600(
            &openssh_path,
            format!("example.com,!bad.example.com {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();
        manager.export_openssh(&openssh_path).unwrap();

        let exported = fs::read_to_string(&openssh_path).unwrap();
        assert!(exported.contains("example.com"));
        assert!(exported.contains("!bad.example.com"));
        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
        assert_eq!(
            manager.check_host_key("bad.example.com", 22, &key, false),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn hashed_entry_trusts_matching_host() {
        // Given: a hashed OpenSSH entry for example.com
        // When: check_host_key is called with the matching host and key
        // Then: Trust is returned
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let host = "hashed.example.com";
        let salt = b"test-salt-bytes!!";
        let hash = openssh_hostname_hash(salt, host, 22);

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager
            .import_openssh(&{
                let openssh_path = dir.path().join("known_hosts");
                let salt_b64 =
                    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, salt);
                let hash_b64 =
                    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, hash);
                write_test_file_mode_0600(
                    &openssh_path,
                    format!("|1|{salt_b64}|{hash_b64} {openssh_key}\n"),
                );
                openssh_path
            })
            .unwrap();

        assert_eq!(
            manager.check_host_key(host, 22, &key, false),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn hashed_entry_unknown_for_wrong_host() {
        // Given: a hashed entry for one host
        // When: check_host_key is called for a different host
        // Then: Unknown is returned
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let salt = b"another-salt!!!!";
        let hash = openssh_hostname_hash(salt, "real.example.com", 22);
        let openssh_path = dir.path().join("known_hosts");
        let salt_b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, salt);
        let hash_b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, hash);
        write_test_file_mode_0600(
            &openssh_path,
            format!("|1|{salt_b64}|{hash_b64} {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        assert_eq!(
            manager.check_host_key("other.example.com", 22, &key, false),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn revoked_plain_entry_rejects_matching_key() {
        // Given: a revoked plain host entry
        // When: the same key is presented for that host
        // Then: Reject is returned
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(
            &openssh_path,
            format!("@revoked example.com {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Reject
        );
    }

    #[test]
    fn cert_authority_entry_does_not_trust_host() {
        // Given: a cert-authority entry for a host pattern
        // When: check_host_key is called with the CA public key
        // Then: Unknown is returned (CA trust is out of scope)
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(
            &openssh_path,
            format!("@cert-authority *.example.com {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        assert_eq!(
            manager.check_host_key("server.example.com", 22, &key, false),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn accept_host_key_with_revoked_same_key_creates_new_trusted_entry() {
        // Given: a revoked entry for hostA with key K
        // When: hostB (same key, same port) is accepted
        // Then: a new trusted entry for hostB is created, and hostB is Trusted
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(&openssh_path, format!("@revoked hostA {openssh_key}\n"));

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        // Revoked for hostA, but hostB is Unknown (host names do not match)
        assert_eq!(
            manager.check_host_key("hostB", 22, &key, false),
            HostKeyCheckResult::Unknown
        );

        manager.accept_host_key("hostB", 22, &key).unwrap();

        // The revoked entry must be untouched and hostB must be trusted,
        // NOT attached as an alias of the revoked entry.
        let revoked = manager.find_entry("hostA", 22).unwrap();
        assert_eq!(revoked.marker, Some(KnownHostMarker::Revoked));
        assert!(revoked.aliases.is_empty());

        assert_eq!(
            manager.check_host_key("hostB", 22, &key, false),
            HostKeyCheckResult::Trust
        );

        let reloaded = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            reloaded.check_host_key("hostB", 22, &key, false),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn import_openssh_plain_host_after_revoked_same_key_is_trusted() {
        // Given: OpenSSH file with `@revoked hostA KEY` followed by `hostB KEY` (same key)
        // When: the file is imported
        // Then: hostA rejects the key but hostB remains trusted (order-independent)
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(
            &openssh_path,
            format!("@revoked hostA {openssh_key}\nhostB {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        let merged = manager.import_openssh(&openssh_path).unwrap();
        assert_eq!(merged.merged, 2);

        assert_eq!(
            manager.check_host_key("hostA", 22, &key, false),
            HostKeyCheckResult::Reject
        );
        assert_eq!(
            manager.check_host_key("hostB", 22, &key, false),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn accept_host_key_with_cert_authority_same_key_does_not_merge_into_ca_entry() {
        // Given: a cert-authority entry for *.example.com with key K
        // When: a plain host with the same key is accepted
        // Then: a new trusted entry is created and the CA entry stays unchanged
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(
            &openssh_path,
            format!("@cert-authority *.example.com {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        manager
            .accept_host_key("server.example.com", 22, &key)
            .unwrap();

        let ca_entry = manager
            .entries
            .get(&entry_key("*.example.com", 22))
            .unwrap();
        assert_eq!(ca_entry.marker, Some(KnownHostMarker::CertAuthority));
        assert!(ca_entry.aliases.is_empty());

        // Trust is persisted for the accepted host, not lost to the CA entry.
        assert_eq!(
            manager.check_host_key("server.example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );

        let reloaded = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            reloaded.check_host_key("server.example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn check_host_key_revoked_entry_does_not_trust_other_host_via_fingerprint_alias() {
        // Given: `@revoked hostA KEY` (hostB is not an alias, same key)
        // When: check_host_key is called for hostB in non-strict mode
        // Then: it must NOT be trusted via the revoked entry's fingerprint
        //       (fingerprint alias lookup excludes non-trusting markers)
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(&openssh_path, format!("@revoked hostA {openssh_key}\n"));

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        assert_eq!(
            manager.check_host_key("hostB", 22, &key, false),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn check_host_key_cert_authority_does_not_trust_other_host_via_fingerprint_alias() {
        // Given: `@cert-authority *.example.com KEY` (server.example.com is not
        //        stored as a plain host alias, same key)
        // When: check_host_key is called for server.example.com in non-strict mode
        // Then: it must NOT be trusted via the CA entry's fingerprint
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(
            &openssh_path,
            format!("@cert-authority *.example.com {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        assert_eq!(
            manager.check_host_key("server.example.com", 22, &key, false),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn import_openssh_plain_host_not_attached_to_cert_authority_alias() {
        // Given: `@cert-authority *.example.com KEY` + `host1.example.com KEY`
        // When: the file is imported
        // Then: host1.example.com is a trusted plain entry, not an alias of the
        //       CA entry (so strict-mode checks still trust it)
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(
            &openssh_path,
            format!(
                "@cert-authority *.example.com {openssh_key}\nhost1.example.com {openssh_key}\n"
            ),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        let ca_entry = manager
            .entries
            .get(&entry_key("*.example.com", 22))
            .unwrap();
        assert_eq!(ca_entry.marker, Some(KnownHostMarker::CertAuthority));
        assert!(ca_entry.aliases.is_empty());

        assert_eq!(
            manager.check_host_key("host1.example.com", 22, &key, true),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn merge_openssh_on_connect_missing_file_is_noop() {
        // Given: merge enabled and a missing OpenSSH file
        // When: merge_openssh_on_connect is called
        // Then: zero is returned without error
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let mut manager = KnownHostsManager::load(&path).unwrap();
        let config = AppConfig {
            openssh_known_hosts_path: dir.path().join("missing_known_hosts"),
            merge_openssh_known_hosts_on_connect: true,
            ..AppConfig::default()
        };

        let merged = manager.merge_openssh_on_connect(&config).unwrap();
        assert_eq!(merged.merged, 0);
        assert_eq!(merged.skipped, 0);
    }

    #[test]
    fn merge_openssh_on_connect_disabled_skips_import() {
        // Given: merge disabled and an existing OpenSSH file
        // When: merge_openssh_on_connect is called
        // Then: zero is returned and nothing is imported
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(&openssh_path, format!("example.com {openssh_key}\n"));

        let mut manager = KnownHostsManager::load(&path).unwrap();
        let config = AppConfig {
            known_hosts_path: path.clone(),
            openssh_known_hosts_path: openssh_path,
            merge_openssh_known_hosts_on_connect: false,
            ..AppConfig::default()
        };

        let merged = manager.merge_openssh_on_connect(&config).unwrap();
        assert_eq!(merged.merged, 0);
        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn revoked_hashed_entry_rejects_matching_key() {
        // Given: a revoked hashed OpenSSH entry
        // When: check_host_key matches host and fingerprint
        // Then: Reject is returned
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let host = "revoked-hashed.example.com";
        let salt = b"revoked-salt!!!!";
        let hash = openssh_hostname_hash(salt, host, 22);
        let openssh_path = dir.path().join("known_hosts");
        let salt_b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, salt);
        let hash_b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, hash);
        write_test_file_mode_0600(
            &openssh_path,
            format!("@revoked |1|{salt_b64}|{hash_b64} {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.import_openssh(&openssh_path).unwrap();

        assert_eq!(
            manager.check_host_key(host, 22, &key, false),
            HostKeyCheckResult::Reject
        );
    }

    #[test]
    fn merge_openssh_on_connect_imports_plain_entries() {
        // Given: merge enabled and a plain OpenSSH entry
        // When: merge_openssh_on_connect is called
        // Then: the host is trusted without manual import
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();

        write_test_file_mode_0600(&openssh_path, format!("example.com {openssh_key}\n"));

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let config = AppConfig {
            openssh_known_hosts_path: openssh_path,
            merge_openssh_known_hosts_on_connect: true,
            ..AppConfig::default()
        };

        let merged = manager.merge_openssh_on_connect(&config).unwrap();
        assert_eq!(merged.merged, 1);
        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn accept_host_key_replaces_mismatched_fingerprint() {
        // Given: a trusted host with an old key
        // When: accept_host_key is called with a new key for the same host
        // Then: the new fingerprint is trusted
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let first = test_public_key();
        let second = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.accept_host_key("example.com", 22, &first).unwrap();
        manager.accept_host_key("example.com", 22, &second).unwrap();

        assert_eq!(
            manager.check_host_key("example.com", 22, &second, false),
            HostKeyCheckResult::Trust
        );
        match manager.check_host_key("example.com", 22, &first, false) {
            HostKeyCheckResult::Mismatch { .. } => {}
            other => panic!("expected mismatch, got {other:?}"),
        }
    }

    #[test]
    fn strict_mode_rejects_fingerprint_alias_without_exact_host() {
        // Given: a trusted host and strict mode enabled
        // When: the same key is presented under a different hostname
        // Then: Unknown is returned instead of fingerprint alias trust
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.accept_host_key("example.com", 22, &key).unwrap();

        assert_eq!(
            manager.check_host_key("203.0.113.1", 22, &key, false),
            HostKeyCheckResult::Trust
        );
        assert_eq!(
            manager.check_host_key("203.0.113.1", 22, &key, true),
            HostKeyCheckResult::Unknown
        );
    }

    #[test]
    fn merge_openssh_on_connect_skips_unparseable_lines_and_continues() {
        // Given: merge enabled, an OpenSSH file with one unparseable line
        //        (tab-separated, which ssh-key rejects) plus one valid line
        // When: merge_openssh_on_connect is called
        // Then: the valid line is imported, the bad line is counted as skipped,
        //       and no error is returned
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(
            &openssh_path,
            format!("bad.line\t{openssh_key}\nexample.com {openssh_key}\n"),
        );

        let mut manager = KnownHostsManager::load(&path).unwrap();
        let config = AppConfig {
            openssh_known_hosts_path: openssh_path.clone(),
            merge_openssh_known_hosts_on_connect: true,
            fail_connect_on_openssh_merge_error: true,
            ..AppConfig::default()
        };

        let summary = manager.merge_openssh_on_connect(&config).unwrap();
        assert_eq!(summary.merged, 1);
        assert_eq!(summary.skipped, 1);
        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
        // The skipped line must not have created an entry for the unparseable host.
        assert!(manager.find_entry("bad.line", 22).is_none());
    }

    #[test]
    fn merge_openssh_on_connect_unparseable_only_file_skips_all_but_succeeds() {
        // Given: merge enabled and a file whose only line is unparseable
        // When: merge_openssh_on_connect is called with abort-on-failure enabled
        // Then: the line is skipped and no error is returned (line-level tolerance)
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(&openssh_path, "this is not a valid known_hosts line\n");

        let mut manager = KnownHostsManager::load(&path).unwrap();
        let config = AppConfig {
            openssh_known_hosts_path: openssh_path,
            merge_openssh_known_hosts_on_connect: true,
            fail_connect_on_openssh_merge_error: true,
            ..AppConfig::default()
        };

        let summary = manager.merge_openssh_on_connect(&config).unwrap();
        assert_eq!(summary.merged, 0);
        assert_eq!(summary.skipped, 1);
    }

    #[test]
    fn import_openssh_empty_file_imports_nothing() {
        // Given: an empty OpenSSH known_hosts file
        // When: it is imported
        // Then: the summary is empty (merged == 0, skipped == 0)
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(&openssh_path, "");

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let summary = manager.import_openssh(&openssh_path).unwrap();
        assert_eq!(summary.merged, 0);
        assert_eq!(summary.skipped, 0);
        assert!(summary.is_empty());
    }

    #[test]
    fn import_openssh_comment_only_file_is_not_skipped() {
        // Given: a known_hosts file with only comment lines
        // When: it is imported
        // Then: comments are not counted as skipped or merged
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(&openssh_path, "# comment line 1\n# another comment\n");

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let summary = manager.import_openssh(&openssh_path).unwrap();
        assert_eq!(summary.merged, 0);
        assert_eq!(summary.skipped, 0);
        assert!(summary.is_empty());
    }

    #[test]
    fn import_openssh_blank_line_file_is_not_skipped() {
        // Given: a known_hosts file with only blank lines
        // When: it is imported
        // Then: blank lines are not counted as skipped or merged
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        write_test_file_mode_0600(&openssh_path, "\n\n\n");

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let summary = manager.import_openssh(&openssh_path).unwrap();
        assert_eq!(summary.merged, 0);
        assert_eq!(summary.skipped, 0);
        assert!(summary.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn merge_openssh_on_connect_file_level_failure_aborts_when_configured() {
        // Given: merge enabled, a file with insecure (world-writable) permissions,
        //        and abort-on-failure config
        // When: merge_openssh_on_connect is called
        // Then: the file-level read error is returned (fail_connect applies at file level)
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        fs::write(&openssh_path, format!("example.com {openssh_key}\n")).unwrap();
        set_test_file_mode(&openssh_path, 0o666);

        let mut manager = KnownHostsManager::load(&path).unwrap();
        let config = AppConfig {
            openssh_known_hosts_path: openssh_path,
            merge_openssh_known_hosts_on_connect: true,
            fail_connect_on_openssh_merge_error: true,
            ..AppConfig::default()
        };

        let err = manager.merge_openssh_on_connect(&config).unwrap_err();
        assert!(matches!(err, SecurityError::KnownHostsReadFailed { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn merge_openssh_on_connect_file_level_failure_skips_when_not_configured() {
        // Given: merge enabled, a file with insecure permissions, and abort disabled
        // When: merge_openssh_on_connect is called
        // Then: no error is returned (the empty summary) so connection can continue
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        let openssh_path = dir.path().join("known_hosts");
        fs::write(&openssh_path, format!("example.com {openssh_key}\n")).unwrap();
        set_test_file_mode(&openssh_path, 0o666);

        let mut manager = KnownHostsManager::load(&path).unwrap();
        let config = AppConfig {
            openssh_known_hosts_path: openssh_path,
            merge_openssh_known_hosts_on_connect: true,
            fail_connect_on_openssh_merge_error: false,
            ..AppConfig::default()
        };

        let summary = manager.merge_openssh_on_connect(&config).unwrap();
        assert_eq!(summary.merged, 0);
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

        let parent_mode = fs::metadata(path.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(parent_mode, 0o700);
    }

    #[cfg(unix)]
    #[test]
    fn write_file_mode_0600_does_not_modify_symlink_target() {
        // Given: the destination path is a symlink to a secret file
        // When: write_file_mode_0600 persists new contents
        // Then: the symlink target is not truncated or overwritten
        let dir = tempdir().unwrap();
        let secret = dir.path().join("secret.txt");
        fs::write(&secret, b"untouched").unwrap();
        let path = dir.path().join("known_hosts.json");
        std::os::unix::fs::symlink(&secret, &path).unwrap();

        write_file_mode_0600(&path, br#"{"entries":[],"hashed_entries":[]}"#).unwrap();

        assert_eq!(fs::read(&secret).unwrap(), b"untouched");
        assert!(!path.is_symlink());
    }

    #[cfg(unix)]
    #[test]
    fn load_accepts_read_only_0400_permissions() {
        // Given: a store file with mode 0400 and correct owner
        // When: load is called
        // Then: the store loads successfully
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        write_test_file_mode_0600(&path, r#"{"entries":[],"hashed_entries":[]}"#);
        set_test_file_mode(&path, 0o400);

        let manager = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            manager.check_host_key("localhost", 22, &test_public_key(), false),
            HostKeyCheckResult::Unknown
        );
    }

    #[cfg(unix)]
    #[test]
    fn load_rejects_insecure_permissions_0664() {
        // Given: a store file with group-readable permissions
        // When: load is called
        // Then: KnownHostsReadFailed is returned
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        write_test_file_mode_0600(&path, r#"{"entries":[],"hashed_entries":[]}"#);
        set_test_file_mode(&path, 0o664);

        let err = KnownHostsManager::load(&path).unwrap_err();
        assert!(matches!(err, SecurityError::KnownHostsReadFailed { .. }));
        if let SecurityError::KnownHostsReadFailed { message, .. } = err {
            assert!(message.contains("insecure permissions"));
        }
    }

    #[cfg(unix)]
    #[test]
    fn load_rejects_insecure_permissions_0666() {
        // Given: a world-writable store file
        // When: load is called
        // Then: KnownHostsReadFailed is returned
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        write_test_file_mode_0600(&path, r#"{"entries":[],"hashed_entries":[]}"#);
        set_test_file_mode(&path, 0o666);

        let err = KnownHostsManager::load(&path).unwrap_err();
        assert!(matches!(err, SecurityError::KnownHostsReadFailed { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn load_rejects_symlink_to_valid_file() {
        // Given: the store path is a symlink to a valid store file
        // When: load is called
        // Then: KnownHostsReadFailed is returned
        let dir = tempdir().unwrap();
        let secret = dir.path().join("secret.json");
        write_test_file_mode_0600(&secret, r#"{"entries":[],"hashed_entries":[]}"#);
        let path = dir.path().join("known_hosts.json");
        std::os::unix::fs::symlink(&secret, &path).unwrap();

        let err = KnownHostsManager::load(&path).unwrap_err();
        assert!(matches!(err, SecurityError::KnownHostsReadFailed { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn import_openssh_accepts_0644_permissions() {
        // Given: an OpenSSH known_hosts file with standard 0644 permissions
        // When: import_openssh is called
        // Then: the entry is merged successfully
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        fs::write(&openssh_path, format!("example.com {openssh_key}\n")).unwrap();
        set_test_file_mode(&openssh_path, 0o644);

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let summary = manager.import_openssh(&openssh_path).unwrap();
        assert_eq!(summary.merged, 1);
        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
    }

    #[cfg(unix)]
    #[test]
    fn import_openssh_rejects_world_writable_permissions() {
        // Given: an OpenSSH known_hosts file with mode 0666
        // When: import_openssh is called
        // Then: KnownHostsReadFailed is returned
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        fs::write(&openssh_path, format!("example.com {openssh_key}\n")).unwrap();
        set_test_file_mode(&openssh_path, 0o666);

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let err = manager.import_openssh(&openssh_path).unwrap_err();
        assert!(matches!(err, SecurityError::KnownHostsReadFailed { .. }));
        if let SecurityError::KnownHostsReadFailed { message, .. } = err {
            assert!(message.contains("group/other write"));
        }
    }

    #[cfg(unix)]
    #[test]
    fn import_openssh_rejects_group_writable_permissions() {
        // Given: an OpenSSH known_hosts file with mode 0664
        // When: import_openssh is called
        // Then: KnownHostsReadFailed is returned
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();
        fs::write(&openssh_path, format!("example.com {openssh_key}\n")).unwrap();
        set_test_file_mode(&openssh_path, 0o664);

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let err = manager.import_openssh(&openssh_path).unwrap_err();
        assert!(matches!(err, SecurityError::KnownHostsReadFailed { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn load_rejects_file_with_wrong_owner_when_chown_available() {
        // Given: a store file owned by another uid (requires root to set up)
        // When: load is called
        // Then: KnownHostsReadFailed is returned
        if unsafe { libc::geteuid() } != 0 {
            return;
        }

        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        write_test_file_mode_0600(&path, r#"{"entries":[],"hashed_entries":[]}"#);
        let target_uid = 1_u32;
        std::os::unix::fs::chown(&path, Some(target_uid), None).expect("chown failed");

        let err = KnownHostsManager::load(&path).unwrap_err();
        assert!(matches!(err, SecurityError::KnownHostsReadFailed { .. }));
        if let SecurityError::KnownHostsReadFailed { message, .. } = err {
            assert!(message.contains("owner uid"));
        }
    }

    #[test]
    fn persist_leaves_no_partial_files_after_success() {
        // Given: an empty known hosts store
        // When: accept_host_key persists the store
        // Then: no .dockbridge-*.partial files remain in the parent directory
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.accept_host_key("localhost", 22, &key).unwrap();

        let partials = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.file_name())
            .filter(|name| {
                name.to_string_lossy().starts_with(".dockbridge-")
                    && name.to_string_lossy().ends_with(".partial")
            })
            .collect::<Vec<_>>();
        assert!(
            partials.is_empty(),
            "partial files left behind: {partials:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn open_exclusive_local_file_sync_rejects_symlink_path() {
        use std::io::ErrorKind;

        // Given: a symlink path for a partial file
        // When: open_exclusive_local_file_sync tries to create it
        // Then: AlreadyExists is returned without following the symlink
        let dir = tempdir().unwrap();
        let target = dir.path().join("target.txt");
        fs::write(&target, b"secret").unwrap();
        let link = dir.path().join(".dockbridge-link.partial");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let err = open_exclusive_local_file_sync(&link).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::AlreadyExists);
    }

    #[test]
    fn fingerprints_match_handles_equal_and_unequal_strings() {
        assert!(fingerprints_match("SHA256:abc", "SHA256:abc"));
        assert!(!fingerprints_match("SHA256:abc", "SHA256:abd"));
        assert!(!fingerprints_match("SHA256:abc", "SHA256:ab"));
        assert!(fingerprints_match("", ""));
    }
    #[test]
    fn host_matching_is_case_insensitive() {
        // Given: a trusted host stored in mixed case
        // When: checked with different casing
        // Then: the same entry matches regardless of case
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();

        let mut manager = KnownHostsManager::load(&path).unwrap();
        manager.accept_host_key("Example.COM", 22, &key).unwrap();

        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
        assert_eq!(
            manager.check_host_key("EXAMPLE.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
        assert_eq!(
            manager.check_host_key("Example.Com", 22, &key, true),
            HostKeyCheckResult::Trust
        );

        // The stored entry is normalized to lowercase.
        let entry = manager.find_entry("EXAMPLE.com", 22).unwrap();
        assert_eq!(entry.host, "example.com");
    }

    #[test]
    fn loaded_store_migrates_mixed_case_entries() {
        // Given: a store file written with a mixed-case host
        // When: loaded
        // Then: the entry is normalized to lowercase and still matches
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts.json");
        let key = test_public_key();
        let fingerprint = fingerprint_sha256(&key);
        let openssh_key = key.to_openssh().unwrap();

        write_test_file_mode_0600(
            &path,
            format!(
                r#"{{"entries":[{{"host":"Example.COM","port":22,"fingerprint_sha256":"{fingerprint}","algorithm":"Ed25519","aliases":[],"excluded_aliases":[],"public_key_openssh":"{openssh_key}"}}],"hashed_entries":[]}}"#
            ),
        );

        let manager = KnownHostsManager::load(&path).unwrap();
        assert_eq!(
            manager.check_host_key("example.com", 22, &key, false),
            HostKeyCheckResult::Trust
        );
        assert_eq!(
            manager.check_host_key("EXAMPLE.COM", 22, &key, false),
            HostKeyCheckResult::Trust
        );
    }

    #[test]
    fn import_openssh_skips_wildcard_plain_patterns() {
        // Given: an OpenSSH line with a non-CA wildcard pattern
        // When: imported
        // Then: the wildcard host is skipped (no dead entry) without aborting
        let dir = tempdir().unwrap();
        let json_path = dir.path().join("known_hosts.json");
        let openssh_path = dir.path().join("known_hosts");
        let key = test_public_key();
        let openssh_key = key.to_openssh().unwrap();

        write_test_file_mode_0600(&openssh_path, format!("*.example.com {openssh_key}\n"));

        let mut manager = KnownHostsManager::load(&json_path).unwrap();
        let merged = manager.import_openssh(&openssh_path).unwrap();
        assert_eq!(merged.merged, 0);

        assert_eq!(
            manager.check_host_key("host.example.com", 22, &key, false),
            HostKeyCheckResult::Unknown
        );
    }

    #[cfg(unix)]
    #[test]
    fn read_known_hosts_rejects_oversized_file() {
        // Given: an OpenSSH known_hosts file larger than the size limit
        // When: read_secure_known_hosts_file is called
        // Then: a "file too large" error is returned instead of reading it all
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        write_test_file_mode_0600(&path, vec![b' '; (MAX_KNOWN_HOSTS_FILE_BYTES as usize) + 1]);

        let err =
            read_secure_known_hosts_file(&path, KnownHostsReadPolicy::OpenSshImport).unwrap_err();
        assert!(
            matches!(err, SecurityError::KnownHostsReadFailed { ref message, .. } if message.contains("too large")),
            "unexpected error: {err:?}"
        );
    }
}
