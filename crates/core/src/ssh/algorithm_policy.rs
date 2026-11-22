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

use crate::config::AppConfig;

const ALLOWED_KEX: &[kex::Name] = &[
    // Post-quantum hybrid (ML-KEM-768 + X25519), preferred first so servers
    // that support it (OpenSSH 9.9+) gain harvest-now-decrypt-later resistance.
    kex::MLKEM768X25519_SHA256,
    kex::CURVE25519,
    kex::CURVE25519_PRE_RFC_8731,
    kex::DH_G16_SHA512,
    kex::DH_G14_SHA256,
    kex::EXTENSION_SUPPORT_AS_CLIENT,
    kex::EXTENSION_OPENSSH_STRICT_KEX_AS_CLIENT,
];

static ALLOWED_HOST_KEY: std::sync::LazyLock<Vec<Algorithm>> = std::sync::LazyLock::new(|| {
    vec![
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
        // OpenSSH host-certificate algorithms (issue #797). These come after raw
        // key types so servers that accept both prefer the simpler names.
        host_certificate_algorithm("ssh-ed25519-cert-v01@openssh.com"),
        host_certificate_algorithm("ecdsa-sha2-nistp256-cert-v01@openssh.com"),
        host_certificate_algorithm("ecdsa-sha2-nistp384-cert-v01@openssh.com"),
        host_certificate_algorithm("ecdsa-sha2-nistp521-cert-v01@openssh.com"),
        host_certificate_algorithm("rsa-sha2-512-cert-v01@openssh.com"),
        host_certificate_algorithm("rsa-sha2-256-cert-v01@openssh.com"),
    ]
});

/// Wraps an OpenSSH certificate name in `Algorithm::Other` so russh sends
/// the literal `*-cert-v01@openssh.com` string in KEXINIT (issue #797).
fn host_certificate_algorithm(id: &str) -> Algorithm {
    Algorithm::Other(ssh_key::AlgorithmName::new(id).expect("valid algorithm id"))
}

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
        key: Cow::Owned(ALLOWED_HOST_KEY.clone()),
        host_key_certificates: Cow::Borrowed(&[]),
        cipher: Cow::Borrowed(ALLOWED_CIPHER),
        mac: Cow::Borrowed(ALLOWED_MAC),
        compression: Cow::Borrowed(ALLOWED_COMPRESSION),
    }
}

/// Builds a russh client configuration with secure algorithm preferences,
/// a SSH-level keepalive, and an idle (`inactivity`) timeout that is
/// independent of the TCP/SSH connect timeout.
///
/// A keepalive interval of `0` explicitly disables SSH keep-alive packets
/// (russh would otherwise spin on a zero-length interval).
pub fn build_client_config(config: &AppConfig) -> client::Config {
    let keepalive_interval = (config.ssh_keepalive_interval_secs != 0)
        .then(|| Duration::from_secs(config.ssh_keepalive_interval_secs));
    // A 0-second inactivity timeout would disconnect immediately; treat it
    // like "disabled" (None) just as a 0 keepalive interval does.
    let inactivity_timeout = config
        .ssh_inactivity_timeout_secs
        .filter(|&secs| secs > 0)
        .map(Duration::from_secs);
    client::Config {
        preferred: secure_client_preferred(),
        inactivity_timeout,
        keepalive_interval,
        keepalive_max: 3,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use russh::server::Auth;
    use ssh_key::{Algorithm, PrivateKey};
    use tokio::net::TcpListener;

    const DISALLOWED_KEX: &[kex::Name] = &[kex::DH_G1_SHA1, kex::DH_G14_SHA1];

    // Deprecated ciphers referenced by name so the russh `des` feature (which
    // pulls in 3DES) never has to be enabled in release builds.
    const DISALLOWED_CIPHER_NAMES: &[&str] =
        &["3des-cbc", "aes128-cbc", "aes192-cbc", "aes256-cbc"];

    const DISALLOWED_MAC: &[mac::Name] = &[mac::HMAC_SHA1, mac::HMAC_SHA1_ETM];

    const DISALLOWED_HOST_KEY: &[Algorithm] = &[Algorithm::Rsa { hash: None }];

    struct PolicyTestServerHandler;

    impl russh::server::Handler for PolicyTestServerHandler {
        type Error = russh::Error;

        async fn auth_password(
            &mut self,
            _user: &str,
            _password: &str,
        ) -> Result<Auth, Self::Error> {
            Ok(Auth::Accept)
        }
    }

    struct PolicyTestClientHandler;

    impl russh::client::Handler for PolicyTestClientHandler {
        type Error = russh::Error;

        async fn check_server_key(
            &mut self,
            _server_public_key: &russh::keys::PublicKeyOrCertificate,
        ) -> Result<bool, Self::Error> {
            Ok(true)
        }
    }

    async fn negotiate_with_server(server_preferred: Preferred) -> Result<(), russh::Error> {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server_config = Arc::new(russh::server::Config {
            keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap()],
            preferred: server_preferred,
            auth_rejection_time: Duration::from_secs(0),
            auth_rejection_time_initial: Some(Duration::from_secs(0)),
            ..Default::default()
        });
        let server_task = tokio::spawn(async move {
            if let Ok((socket, _)) = listener.accept().await {
                let _ =
                    russh::server::run_stream(server_config, socket, PolicyTestServerHandler).await;
            }
        });

        let client_config = Arc::new(build_client_config(&AppConfig::default()));
        let result = tokio::time::timeout(
            Duration::from_secs(5),
            russh::client::connect(client_config, addr, PolicyTestClientHandler),
        )
        .await
        .expect("SSH handshake should not time out");
        server_task.abort();
        result.map(|_| ())
    }

    #[test]
    fn secure_client_preferred_includes_allowed_algorithms() {
        // Given: the DockBridge SSH client algorithm policy
        let preferred = secure_client_preferred();

        // Then: compare against independent expected algorithm names (issue #839 F31)
        let kex_names: Vec<&str> = preferred.kex.iter().map(AsRef::as_ref).collect();
        assert_eq!(
            kex_names,
            vec![
                "mlkem768x25519-sha256",
                "curve25519-sha256",
                "curve25519-sha256@libssh.org",
                "diffie-hellman-group16-sha512",
                "diffie-hellman-group14-sha256",
                "ext-info-c",
                "kex-strict-c-v00@openssh.com",
            ]
        );

        let cipher_names: Vec<&str> = preferred.cipher.iter().map(AsRef::as_ref).collect();
        assert_eq!(
            cipher_names,
            vec![
                "chacha20-poly1305@openssh.com",
                "aes256-gcm@openssh.com",
                "aes256-ctr",
                "aes192-ctr",
                "aes128-ctr",
            ]
        );

        let mac_names: Vec<&str> = preferred.mac.iter().map(AsRef::as_ref).collect();
        assert_eq!(
            mac_names,
            vec![
                "hmac-sha2-512-etm@openssh.com",
                "hmac-sha2-256-etm@openssh.com",
                "hmac-sha2-512",
                "hmac-sha2-256",
            ]
        );

        let host_key_names: Vec<String> = preferred.key.iter().map(ToString::to_string).collect();
        for expected in [
            "ssh-ed25519",
            "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
            "rsa-sha2-512",
            "rsa-sha2-256",
            "ssh-ed25519-cert-v01@openssh.com",
        ] {
            assert!(
                host_key_names.iter().any(|name| name == expected),
                "expected host key `{expected}`, got {host_key_names:?}"
            );
        }

        let compression_names: Vec<&str> =
            preferred.compression.iter().map(AsRef::as_ref).collect();
        assert_eq!(compression_names, vec!["none"]);
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

        // Each disallowed cipher (e.g. 3DES, CBC modes) must not appear in the
        // client's offer list.
        for cipher in DISALLOWED_CIPHER_NAMES {
            assert!(
                !preferred.cipher.iter().any(|c| c.as_ref() == *cipher),
                "weak cipher `{}` must not be allowed",
                cipher
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

    #[tokio::test]
    async fn negotiates_modern_and_post_quantum_server_algorithms() {
        // Modern server offering PQ + classic KEX negotiates via real russh handshake.
        let modern = Preferred {
            kex: Cow::Borrowed(&[kex::MLKEM768X25519_SHA256, kex::CURVE25519]),
            key: Cow::Owned(vec![Algorithm::Ed25519]),
            cipher: Cow::Borrowed(&[cipher::CHACHA20_POLY1305]),
            mac: Cow::Borrowed(&[mac::HMAC_SHA256_ETM]),
            compression: Cow::Borrowed(&[compression::NONE]),
            ..Preferred::default()
        };
        negotiate_with_server(modern)
            .await
            .expect("modern server must negotiate cleanly");

        // PQ-only server also negotiates cleanly.
        let pq_only = Preferred {
            kex: Cow::Borrowed(&[kex::MLKEM768X25519_SHA256]),
            key: Cow::Owned(vec![Algorithm::Ed25519]),
            cipher: Cow::Borrowed(&[cipher::AES_256_GCM]),
            mac: Cow::Borrowed(&[mac::HMAC_SHA512_ETM]),
            compression: Cow::Borrowed(&[compression::NONE]),
            ..Preferred::default()
        };
        negotiate_with_server(pq_only)
            .await
            .expect("PQ-only server must negotiate cleanly");
    }

    #[tokio::test]
    async fn kex_falls_back_when_server_lacks_post_quantum() {
        // Servers without ML-KEM fall back to classic allowed KEX via real russh handshake.
        for classic_kex in [kex::CURVE25519, kex::DH_G14_SHA256] {
            let server_pref = Preferred {
                kex: Cow::Owned(vec![classic_kex]),
                key: Cow::Owned(vec![Algorithm::Ed25519]),
                cipher: Cow::Borrowed(&[cipher::AES_256_CTR]),
                mac: Cow::Borrowed(&[mac::HMAC_SHA256]),
                compression: Cow::Borrowed(&[compression::NONE]),
                ..Preferred::default()
            };
            negotiate_with_server(server_pref)
                .await
                .unwrap_or_else(|err| {
                    panic!(
                        "classic KEX `{}` should negotiate: {err}",
                        classic_kex.as_ref()
                    )
                });
        }
    }

    #[tokio::test]
    async fn rejects_servers_offering_only_weak_algorithms() {
        // Weak KEX only -> real russh handshake fails.
        let weak_kex = Preferred {
            kex: Cow::Borrowed(&[kex::DH_G1_SHA1]),
            key: Cow::Owned(vec![Algorithm::Ed25519]),
            cipher: Cow::Borrowed(&[cipher::CHACHA20_POLY1305]),
            mac: Cow::Borrowed(&[mac::HMAC_SHA256_ETM]),
            compression: Cow::Borrowed(&[compression::NONE]),
            ..Preferred::default()
        };
        assert!(
            negotiate_with_server(weak_kex).await.is_err(),
            "weak SHA-1 KEX server must be rejected"
        );

        // Weak CBC cipher only -> real russh handshake fails.
        let weak_cipher = Preferred {
            kex: Cow::Borrowed(&[kex::CURVE25519]),
            key: Cow::Owned(vec![Algorithm::Ed25519]),
            cipher: Cow::Borrowed(&[cipher::AES_128_CBC]),
            mac: Cow::Borrowed(&[mac::HMAC_SHA256]),
            compression: Cow::Borrowed(&[compression::NONE]),
            ..Preferred::default()
        };
        assert!(
            negotiate_with_server(weak_cipher).await.is_err(),
            "weak CBC cipher server must be rejected"
        );

        // Weak SHA-1 MAC only (with non-AEAD cipher) -> real russh handshake fails.
        let weak_mac = Preferred {
            kex: Cow::Borrowed(&[kex::CURVE25519]),
            key: Cow::Owned(vec![Algorithm::Ed25519]),
            cipher: Cow::Borrowed(&[cipher::AES_256_CTR]),
            mac: Cow::Borrowed(&[mac::HMAC_SHA1]),
            compression: Cow::Borrowed(&[compression::NONE]),
            ..Preferred::default()
        };
        assert!(
            negotiate_with_server(weak_mac).await.is_err(),
            "weak SHA-1 MAC server must be rejected"
        );
    }

    #[test]
    fn build_client_config_sets_preferred_and_timeout() {
        // Given: a config with distinct connect and idle timeouts
        let app_config = AppConfig {
            ssh_inactivity_timeout_secs: Some(600),
            ssh_keepalive_interval_secs: 30,
            ..AppConfig::default()
        };
        let config = build_client_config(&app_config);

        // When: inspecting the russh client config
        // Then: secure preferences, idle timeout, and keepalive are applied
        assert_eq!(config.inactivity_timeout, Some(Duration::from_secs(600)));
        assert_eq!(config.keepalive_interval, Some(Duration::from_secs(30)));
        assert!(config.keepalive_max > 0);
        assert_eq!(config.preferred.kex.as_ref(), ALLOWED_KEX);
        assert_eq!(config.preferred.cipher.as_ref(), ALLOWED_CIPHER);
        assert_eq!(config.preferred.mac.as_ref(), ALLOWED_MAC);
    }

    #[test]
    fn build_client_config_disables_idle_timeout_when_unset() {
        // Given: a config with the idle timeout disabled
        let app_config = AppConfig {
            ssh_inactivity_timeout_secs: None,
            ..AppConfig::default()
        };
        let config = build_client_config(&app_config);

        // Then: inactivity_timeout is None and keepalive is still set
        assert_eq!(config.inactivity_timeout, None);
        assert!(config.keepalive_interval.is_some());
    }

    #[test]
    fn build_client_config_disables_keepalive_at_zero_interval() {
        // Given: a config with keepalive interval explicitly set to 0
        let app_config = AppConfig {
            ssh_keepalive_interval_secs: 0,
            ..AppConfig::default()
        };
        let config = build_client_config(&app_config);

        // Then: keepalive is disabled rather than spinning on a 0-length timer
        assert_eq!(config.keepalive_interval, None);
        assert_eq!(
            config.inactivity_timeout,
            Some(Duration::from_secs(
                app_config.ssh_inactivity_timeout_secs.unwrap_or_default()
            ))
        );
    }

    #[test]
    fn build_client_config_zero_keepalive_and_no_idle_timeout() {
        // Given: keepalive disabled and idle timeout unset
        let app_config = AppConfig {
            ssh_inactivity_timeout_secs: None,
            ssh_keepalive_interval_secs: 0,
            ..AppConfig::default()
        };
        let config = build_client_config(&app_config);

        // Then: both timers are off
        assert_eq!(config.keepalive_interval, None);
        assert_eq!(config.inactivity_timeout, None);
    }
}
