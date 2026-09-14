use std::io;

use zeroize::Zeroizing;

#[cfg(not(feature = "disable-cli-password"))]
mod insecure_password {
    use std::sync::OnceLock;

    const INSECURE_PASSWORD_WARNING: &str = "\
warning: --password exposes credentials in argv, shell history, and process \
listings (CWE-214). Prefer --password-stdin for scripts and production use.";

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(super) struct InsecurePasswordContext {
        pub(super) ci: bool,
        pub(super) release: bool,
    }

    fn env_is_truthy(name: &str) -> bool {
        std::env::var(name).ok().is_some_and(|value| {
            matches!(value.to_ascii_lowercase().as_str(), "1" | "true" | "yes")
        })
    }

    fn insecure_password_context() -> InsecurePasswordContext {
        InsecurePasswordContext {
            ci: env_is_truthy("CI"),
            release: !cfg!(debug_assertions),
        }
    }

    pub(super) fn should_warn_insecure_password(ctx: InsecurePasswordContext) -> bool {
        if env_is_truthy("DOCKBRIDGE_SUPPRESS_PASSWORD_WARNING") {
            return false;
        }

        ctx.ci || ctx.release
    }

    pub(super) fn warn_insecure_password_flag() {
        static WARN_ONCE: OnceLock<()> = OnceLock::new();
        let ctx = insecure_password_context();
        if should_warn_insecure_password(ctx) {
            WARN_ONCE.get_or_init(|| {
                eprintln!("{INSECURE_PASSWORD_WARNING}");
            });
        }
    }
}

fn trim_trailing_line_endings(value: &mut String) {
    while value.ends_with('\n') || value.ends_with('\r') {
        value.pop();
    }
}

/// Reads a single secret line (password or passphrase) from a buffered reader
/// into a zeroized buffer, trimming trailing line endings.
///
/// Shared by `--password-stdin` and `--passphrase-stdin` so both credentials
/// are handled with the same zeroize discipline.
fn read_secret_line<R: io::BufRead>(
    mut reader: R,
    label: &str,
) -> anyhow::Result<Zeroizing<String>> {
    let mut buffer = Zeroizing::new(String::new());
    reader
        .read_line(&mut buffer)
        .map_err(|err| anyhow::anyhow!("failed to read {label} from stdin: {err}"))?;
    trim_trailing_line_endings(&mut buffer);
    if buffer.is_empty() {
        anyhow::bail!("{label} read from stdin was empty");
    }
    Ok(buffer)
}

/// Reads a secret from standard input into a zeroized buffer.
pub fn read_secret_from_stdin(label: &str) -> anyhow::Result<Zeroizing<String>> {
    read_secret_line(io::stdin().lock(), label)
}

pub fn resolve_password(
    #[cfg(not(feature = "disable-cli-password"))] password: Option<String>,
    password_stdin: bool,
) -> anyhow::Result<Zeroizing<String>> {
    if password_stdin {
        return read_secret_from_stdin("password");
    }

    #[cfg(feature = "disable-cli-password")]
    {
        anyhow::bail!("--password-stdin is required for password authentication");
    }

    #[cfg(not(feature = "disable-cli-password"))]
    {
        if password.is_some() {
            insecure_password::warn_insecure_password_flag();
        }

        let password = password
            .ok_or_else(|| anyhow::anyhow!("either --password or --password-stdin is required"))?;
        Ok(Zeroizing::new(password))
    }
}

pub fn resolve_passphrase(passphrase_stdin: bool) -> Option<anyhow::Result<Zeroizing<String>>> {
    passphrase_stdin.then(|| read_secret_from_stdin("passphrase"))
}

#[cfg(test)]
mod tests {
    use super::{io, read_secret_line, trim_trailing_line_endings};

    #[test]
    fn trim_trailing_line_endings_removes_unix_newline() {
        // Given: a password line with a trailing LF
        let mut value = String::from("pass\n");
        // When: trailing line endings are trimmed
        trim_trailing_line_endings(&mut value);
        // Then: only the password remains
        assert_eq!(value, "pass");
    }

    #[test]
    fn trim_trailing_line_endings_removes_crlf() {
        // Given: a password line with a trailing CRLF
        let mut value = String::from("pass\r\n");
        // When: trailing line endings are trimmed
        trim_trailing_line_endings(&mut value);
        // Then: only the password remains
        assert_eq!(value, "pass");
    }

    #[test]
    fn trim_trailing_line_endings_leaves_password_without_newline() {
        // Given: a password without trailing line endings
        let mut value = String::from("pass");
        // When: trailing line endings are trimmed
        trim_trailing_line_endings(&mut value);
        // Then: the password is unchanged
        assert_eq!(value, "pass");
    }

    #[test]
    fn trim_trailing_line_endings_clears_newline_only_input() {
        // Given: input that contains only line endings
        let mut value = String::from("\r\n");
        // When: trailing line endings are trimmed
        trim_trailing_line_endings(&mut value);
        // Then: the value is empty
        assert!(value.is_empty());
    }

    #[test]
    fn trim_trailing_line_endings_clears_empty_input() {
        // Given: an empty password buffer
        let mut value = String::new();
        // When: trailing line endings are trimmed
        trim_trailing_line_endings(&mut value);
        // Then: the value remains empty
        assert!(value.is_empty());
    }

    #[test]
    fn read_secret_line_trims_newline() {
        // Given: a secret line with a trailing LF
        let mut cursor = io::Cursor::new(String::from("secret\n"));
        // When: the line is read
        let secret = read_secret_line(&mut cursor, "password").expect("read secret");
        // Then: only the secret remains
        assert_eq!(secret.as_str(), "secret");
    }

    #[test]
    fn read_secret_line_trims_crlf() {
        // Given: a secret line with a trailing CRLF
        let mut cursor = io::Cursor::new(String::from("secret\r\n"));
        // When: the line is read
        let secret = read_secret_line(&mut cursor, "passphrase").expect("read secret");
        // Then: only the secret remains
        assert_eq!(secret.as_str(), "secret");
    }

    #[test]
    fn read_secret_line_rejects_empty_input() {
        // Given: only a line ending on stdin
        let mut cursor = io::Cursor::new(String::from("\n"));
        // When: the line is read
        let err = read_secret_line(&mut cursor, "password").expect_err("expected error");
        // Then: an explanatory error is returned
        assert!(err
            .to_string()
            .contains("password read from stdin was empty"));
    }
}

#[cfg(all(test, not(feature = "disable-cli-password")))]
mod insecure_password_tests {
    use super::insecure_password::{should_warn_insecure_password, InsecurePasswordContext};

    #[test]
    fn warns_in_ci_or_release_but_not_debug_local() {
        assert!(should_warn_insecure_password(InsecurePasswordContext {
            ci: true,
            release: false,
        }));
        assert!(should_warn_insecure_password(InsecurePasswordContext {
            ci: false,
            release: true,
        }));
        assert!(!should_warn_insecure_password(InsecurePasswordContext {
            ci: false,
            release: false,
        }));
    }
}
