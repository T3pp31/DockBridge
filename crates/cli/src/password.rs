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

pub fn resolve_password(
    #[cfg(not(feature = "disable-cli-password"))] password: Option<String>,
    password_stdin: bool,
) -> anyhow::Result<Zeroizing<String>> {
    if password_stdin {
        let mut buffer = String::new();
        io::stdin()
            .read_line(&mut buffer)
            .map_err(|err| anyhow::anyhow!("failed to read password from stdin: {err}"))?;
        let trimmed = buffer.trim_end_matches(['\r', '\n']).to_string();
        if trimmed.is_empty() {
            anyhow::bail!("password read from stdin was empty");
        }
        return Ok(Zeroizing::new(trimmed));
    }

    #[cfg(feature = "disable-cli-password")]
    {
        anyhow::bail!("--password is disabled in this build; use --password-stdin instead");
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

#[cfg(all(test, not(feature = "disable-cli-password")))]
mod tests {
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
