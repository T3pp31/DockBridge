//! Private key algorithm inspection for security warnings.

use std::path::Path;

use russh::keys::decode_secret_key;
use ssh_key::Algorithm;
use zeroize::Zeroizing;

use crate::error::AuthError;

/// Classifies a private key algorithm for security policy decisions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrivateKeyAlgorithm {
    /// Ed25519 key.
    Ed25519,
    /// ECDSA key (any NIST curve).
    Ecdsa,
    /// RSA key.
    Rsa,
    /// Other or unknown algorithm.
    Other(String),
}

/// Loads a private key from disk and returns its algorithm classification.
pub fn inspect_private_key_algorithm(
    key_path: &Path,
    passphrase: Option<&str>,
) -> Result<PrivateKeyAlgorithm, AuthError> {
    let key_contents = Zeroizing::new(std::fs::read_to_string(key_path).map_err(|err| {
        AuthError::PrivateKeyLoadFailed {
            path: key_path.display().to_string(),
            message: err.to_string(),
        }
    })?);
    let private_key = decode_secret_key(key_contents.as_str(), passphrase).map_err(|err| {
        AuthError::PrivateKeyLoadFailed {
            path: key_path.display().to_string(),
            message: err.to_string(),
        }
    })?;
    Ok(map_algorithm(private_key.algorithm()))
}

fn map_algorithm(algorithm: Algorithm) -> PrivateKeyAlgorithm {
    match algorithm {
        Algorithm::Ed25519 => PrivateKeyAlgorithm::Ed25519,
        Algorithm::Ecdsa { .. } => PrivateKeyAlgorithm::Ecdsa,
        Algorithm::Rsa { .. } => PrivateKeyAlgorithm::Rsa,
        other => PrivateKeyAlgorithm::Other(format!("{other:?}")),
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use rand::rng;
    use russh::keys::PrivateKey;
    use ssh_key::{Algorithm, HashAlg, LineEnding};
    use tempfile::tempdir;

    use super::*;

    fn write_key(path: &Path, algorithm: Algorithm) {
        let key = PrivateKey::random(&mut rng(), algorithm).expect("failed to generate test key");
        let pem = key
            .to_openssh(LineEnding::LF)
            .expect("failed to encode test key")
            .to_string();
        fs::write(path, pem).expect("failed to write test key");
    }

    #[test]
    fn inspect_ed25519_private_key() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("id_ed25519");
        write_key(&path, Algorithm::Ed25519);

        let algorithm = inspect_private_key_algorithm(&path, None).expect("inspect key");
        assert_eq!(algorithm, PrivateKeyAlgorithm::Ed25519);
    }

    #[test]
    fn inspect_rsa_private_key() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("id_rsa");
        write_key(
            &path,
            Algorithm::Rsa {
                hash: Some(HashAlg::Sha256),
            },
        );

        let algorithm = inspect_private_key_algorithm(&path, None).expect("inspect key");
        assert_eq!(algorithm, PrivateKeyAlgorithm::Rsa);
    }

    #[test]
    fn inspect_missing_key_returns_load_failed() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("missing");

        let err = inspect_private_key_algorithm(&path, None).expect_err("expected error");
        assert!(matches!(err, AuthError::PrivateKeyLoadFailed { .. }));
    }
}
