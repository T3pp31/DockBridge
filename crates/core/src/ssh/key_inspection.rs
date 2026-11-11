//! Private key algorithm inspection for security warnings.

use std::path::Path;

use ssh_key::Algorithm;

use super::key_file::load_private_key;
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
    // The loader zeroizes file buffers on success, read/UTF-8/decode errors,
    // and buffer growth. ssh-key zeroizes the decoded key material on drop.
    let private_key = load_private_key(key_path, passphrase)?;
    let algorithm = private_key.algorithm();
    // Explicitly drop the decoded key so its zeroize-on-drop runs before
    // the function returns.
    drop(private_key);
    Ok(map_algorithm(algorithm))
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
    fn inspect_non_utf8_key_returns_load_failed() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("binary_key");
        // Include enough data to grow the guarded buffer before validation fails.
        let mut contents = vec![b's'; 20_000];
        contents.push(0xff);
        fs::write(&path, contents).expect("write binary key");

        let err = inspect_private_key_algorithm(&path, None).expect_err("invalid UTF-8");
        match err {
            AuthError::PrivateKeyLoadFailed {
                path: error_path,
                message,
            } => {
                assert_eq!(error_path, path.display().to_string());
                assert_eq!(message, "stream did not contain valid UTF-8");
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn inspect_malformed_key_returns_load_failed() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("malformed_key");
        fs::write(&path, "not a private key").expect("write malformed key");

        let err = inspect_private_key_algorithm(&path, None).expect_err("invalid key");
        assert!(matches!(
            err,
            AuthError::PrivateKeyLoadFailed { path: error_path, .. }
                if error_path == path.display().to_string()
        ));
    }

    #[test]
    fn inspect_missing_key_returns_load_failed() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("missing");

        let err = inspect_private_key_algorithm(&path, None).expect_err("expected error");
        assert!(matches!(err, AuthError::PrivateKeyLoadFailed { .. }));
    }
}
