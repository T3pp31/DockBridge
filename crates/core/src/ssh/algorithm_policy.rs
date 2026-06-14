//! Explicit SSH algorithm policy for DockBridge client connections.

use std::borrow::Cow;
use std::time::Duration;

use russh::cipher;
use russh::client;
use russh::compression;
use russh::kex;
use russh::mac;
use russh::Preferred;
use ssh_key::{Algorithm, EcdsaCurve, HashAlg};

const ALLOWED_KEX: &[kex::Name] = &[
    kex::CURVE25519,
    kex::CURVE25519_PRE_RFC_8731,
    kex::DH_G16_SHA512,
    kex::DH_G14_SHA256,
    kex::EXTENSION_SUPPORT_AS_CLIENT,
    kex::EXTENSION_OPENSSH_STRICT_KEX_AS_CLIENT,
];

const ALLOWED_HOST_KEY: &[Algorithm] = &[
    Algorithm::Ed25519,
    Algorithm::Ecdsa {
        curve: EcdsaCurve::NistP256,
    },
    Algorithm::Ecdsa {
        curve: EcdsaCurve::NistP384,
    },
    Algorithm::Ecdsa {
        curve: EcdsaCurve::NistP521,
    },
    // RSA with SHA-512/256 is retained for server compatibility. A future Ed25519/ECDSA-only
    // policy option could drop these entries for environments that do not host legacy RSA keys.
    Algorithm::Rsa {
        hash: Some(HashAlg::Sha512),
    },
    Algorithm::Rsa {
        hash: Some(HashAlg::Sha256),
    },
];

const ALLOWED_CIPHER: &[cipher::Name] = &[
    cipher::CHACHA20_POLY1305,
    cipher::AES_256_GCM,
    cipher::AES_256_CTR,
    cipher::AES_192_CTR,
    cipher::AES_128_CTR,
];

const ALLOWED_MAC: &[mac::Name] = &[
    mac::HMAC_SHA512_ETM,
    mac::HMAC_SHA256_ETM,
    mac::HMAC_SHA512,
    mac::HMAC_SHA256,
];

const ALLOWED_COMPRESSION: &[compression::Name] = &[compression::NONE];

/// Returns the explicitly configured algorithm preferences for SSH client connections.
pub fn secure_client_preferred() -> Preferred {
    Preferred {
        kex: Cow::Borrowed(ALLOWED_KEX),
        key: Cow::Borrowed(ALLOWED_HOST_KEY),
        cipher: Cow::Borrowed(ALLOWED_CIPHER),
        mac: Cow::Borrowed(ALLOWED_MAC),
        compression: Cow::Borrowed(ALLOWED_COMPRESSION),
    }
}

/// Builds a russh client configuration with secure algorithm preferences.
pub fn build_client_config(inactivity_timeout_secs: u64) -> client::Config {
    client::Config {
        preferred: secure_client_preferred(),
        inactivity_timeout: Some(Duration::from_secs(inactivity_timeout_secs)),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ssh_key::Algorithm;

    const DISALLOWED_KEX: &[kex::Name] = &[kex::DH_G1_SHA1, kex::DH_G14_SHA1];

    const DISALLOWED_CIPHER: &[cipher::Name] = &[
        cipher::TRIPLE_DES_CBC,
        cipher::AES_128_CBC,
        cipher::AES_192_CBC,
        cipher::AES_256_CBC,
    ];

    const DISALLOWED_MAC: &[mac::Name] = &[mac::HMAC_SHA1, mac::HMAC_SHA1_ETM];

    const DISALLOWED_HOST_KEY: &[Algorithm] = &[Algorithm::Rsa { hash: None }];

    /// Client-side algorithm selection mirroring russh negotiation order.
    fn select_preferred<'a, S: AsRef<str>>(
        client_list: &[S],
        server_list: &'a [&'a str],
    ) -> Option<&'a str> {
        for client in client_list {
            for server in server_list {
                if server == &client.as_ref() {
                    return Some(server);
                }
            }
        }
        None
    }

    #[test]
    fn secure_client_preferred_includes_allowed_algorithms() {
        // Given: the DockBridge SSH client algorithm policy
        let preferred = secure_client_preferred();

        // When: checking each allowed algorithm category
        // Then: modern algorithms are explicitly listed
        for kex in ALLOWED_KEX {
            assert!(
                preferred.kex.contains(kex),
                "expected allowed kex `{}`",
                kex.as_ref()
            );
        }

        for cipher in ALLOWED_CIPHER {
            assert!(
                preferred.cipher.contains(cipher),
                "expected allowed cipher `{}`",
                cipher.as_ref()
            );
        }

        for mac in ALLOWED_MAC {
            assert!(
                preferred.mac.contains(mac),
                "expected allowed mac `{}`",
                mac.as_ref()
            );
        }

        for host_key in ALLOWED_HOST_KEY {
            assert!(
                preferred.key.contains(host_key),
                "expected allowed host key `{host_key}`"
            );
        }

        assert_eq!(preferred.compression.as_ref(), ALLOWED_COMPRESSION);
    }

    #[test]
    fn secure_client_preferred_excludes_weak_algorithms() {
        // Given: the DockBridge SSH client algorithm policy
        let preferred = secure_client_preferred();

        // When: checking for deprecated algorithms
        // Then: weak algorithms are not offered to the server
        for kex in DISALLOWED_KEX {
            assert!(
                !preferred.kex.contains(kex),
                "weak kex `{}` must not be allowed",
                kex.as_ref()
            );
        }

        for cipher in DISALLOWED_CIPHER {
            assert!(
                !preferred.cipher.contains(cipher),
                "weak cipher `{}` must not be allowed",
                cipher.as_ref()
            );
        }

        for mac in DISALLOWED_MAC {
            assert!(
                !preferred.mac.contains(mac),
                "weak mac `{}` must not be allowed",
                mac.as_ref()
            );
        }

        for host_key in DISALLOWED_HOST_KEY {
            assert!(
                !preferred.key.contains(host_key),
                "weak host key `{host_key}` must not be allowed"
            );
        }
    }

    #[test]
    fn negotiates_modern_server_algorithms() {
        // Given: a server that offers modern algorithms
        let preferred = secure_client_preferred();
        let server_kex = ["curve25519-sha256"];
        let server_cipher = ["chacha20-poly1305@openssh.com"];
        let server_mac = ["hmac-sha2-256-etm@openssh.com"];
        let server_host_key = ["ssh-ed25519"];

        // When: performing client-side selection
        // Then: each category negotiates successfully
        assert_eq!(
            select_preferred(preferred.kex.as_ref(), &server_kex),
            Some("curve25519-sha256")
        );
        assert_eq!(
            select_preferred(preferred.cipher.as_ref(), &server_cipher),
            Some("chacha20-poly1305@openssh.com")
        );
        assert_eq!(
            select_preferred(preferred.mac.as_ref(), &server_mac),
            Some("hmac-sha2-256-etm@openssh.com")
        );
        assert_eq!(
            select_preferred(
                &preferred
                    .key
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>(),
                &server_host_key
            ),
            Some("ssh-ed25519")
        );
    }

    #[test]
    fn rejects_servers_offering_only_weak_algorithms() {
        // Given: a server that only offers deprecated algorithms
        let preferred = secure_client_preferred();
        let weak_kex = ["diffie-hellman-group1-sha1"];
        let weak_cipher = ["3des-cbc"];
        let weak_mac = ["hmac-sha1"];
        let weak_host_key = ["ssh-rsa"];

        // When: performing client-side selection
        // Then: no weak algorithm is accepted
        assert!(select_preferred(preferred.kex.as_ref(), &weak_kex).is_none());
        assert!(select_preferred(preferred.cipher.as_ref(), &weak_cipher).is_none());
        assert!(select_preferred(preferred.mac.as_ref(), &weak_mac).is_none());
        assert!(select_preferred(
            &preferred
                .key
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
            &weak_host_key
        )
        .is_none());
    }

    #[test]
    fn build_client_config_sets_preferred_and_timeout() {
        // Given: a connection timeout
        let config = build_client_config(42);

        // When: inspecting the russh client config
        // Then: secure preferences and inactivity timeout are applied
        assert_eq!(config.inactivity_timeout, Some(Duration::from_secs(42)));
        assert_eq!(config.preferred.kex.as_ref(), ALLOWED_KEX);
        assert_eq!(config.preferred.cipher.as_ref(), ALLOWED_CIPHER);
        assert_eq!(config.preferred.mac.as_ref(), ALLOWED_MAC);
    }
}
