use std::io::{self, Read};

use zeroize::Zeroizing;

fn max_secret_len() -> anyhow::Result<usize> {
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct CliSettings {
        max_secret_len: usize,
    }
    let settings: CliSettings = serde_json::from_str(include_str!("../../../config/cli.json"))?;
    anyhow::ensure!(
        settings.max_secret_len > 0,
        "max_secret_len must be positive"
    );
    anyhow::ensure!(
        settings.max_secret_len.checked_add(3).is_some(),
        "max_secret_len is too large"
    );
    Ok(settings.max_secret_len)
}

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

/// Reads one secret line without requesting bytes beyond its newline.
/// The caller must supply an unbuffered reader so it cannot retain secret copies.
/// Shared by `--password-stdin` and `--passphrase-stdin`.
fn read_secret_line<R: Read>(mut reader: R, label: &str) -> anyhow::Result<Zeroizing<String>> {
    // Allow CRLF plus one excess-byte probe, reserving the entire read limit
    // so even rejected input cannot reallocate and leave unzeroed copies on
    // the heap (issue #649). Guard raw bytes as well, including on I/O errors
    // and invalid UTF-8; converting an owned Vec with String::from_utf8 would
    // otherwise leave rejected bytes in an unzeroized error value.
    let max_secret_len = max_secret_len()?;
    let read_limit = max_secret_len + 3;
    let mut bytes = Zeroizing::new(Vec::with_capacity(read_limit));
    let mut byte = Zeroizing::new([0u8; 1]);
    while bytes.len() < read_limit {
        match reader.read(&mut *byte) {
            Ok(0) => break,
            Ok(_) => {
                bytes.push(byte[0]);
                if byte[0] == b'\n' {
                    break;
                }
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => anyhow::bail!("failed to read {label} from stdin: {err}"),
        }
    }
    let value = std::str::from_utf8(&bytes).map_err(|err| {
        anyhow::anyhow!("failed to read {label} from stdin: invalid UTF-8: {err}")
    })?;
    let mut buffer = Zeroizing::new(value.to_owned());
    let reached_read_limit = buffer.len() == read_limit;
    trim_trailing_line_endings(&mut buffer);
    if reached_read_limit || buffer.len() > max_secret_len {
        anyhow::bail!("{label} from stdin exceeded {max_secret_len} bytes");
    }
    if buffer.is_empty() {
        anyhow::bail!("{label} read from stdin was empty");
    }
    Ok(buffer)
}

fn unbuffered_stdin() -> io::Result<std::fs::File> {
    // Duplicate the OS descriptor/handle, not Stdin's process-global BufReader.
    // Dropping the File only closes the duplicate, leaving stdin usable.
    #[cfg(unix)]
    let handle = {
        use std::os::fd::AsFd;
        io::stdin().as_fd().try_clone_to_owned()?
    };
    #[cfg(windows)]
    let handle = {
        use std::os::windows::io::AsHandle;
        io::stdin().as_handle().try_clone_to_owned()?
    };
    Ok(std::fs::File::from(handle))
}

/// Reads a secret from standard input without retaining an unzeroized read buffer.
pub fn read_secret_from_stdin(label: &str) -> anyhow::Result<Zeroizing<String>> {
    let stdin = unbuffered_stdin()
        .map_err(|err| anyhow::anyhow!("failed to read {label} from stdin: {err}"))?;
    read_secret_line(stdin, label)
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

pub fn resolve_passphrase(passphrase_stdin: bool) -> anyhow::Result<Option<Zeroizing<String>>> {
    if passphrase_stdin {
        Ok(Some(read_secret_from_stdin("passphrase")?))
    } else {
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        io, max_secret_len, read_secret_from_stdin, read_secret_line, trim_trailing_line_endings,
        unbuffered_stdin,
    };
    use std::io::{Read, Seek, Write};
    use std::process::{Command, Stdio};

    #[test]
    fn read_secret_from_stdin_does_not_prefetch_or_close_stdin() {
        const CHILD_ENV: &str = "DOCKBRIDGE_TEST_UNBUFFERED_SECRET_STDIN";
        const CHILD_SUCCESS: &str = "unbuffered stdin assertions passed";
        const INPUT: &[u8] = b"first\nsecond\nthird";
        if std::env::var_os(CHILD_ENV).is_some() {
            assert_eq!(
                read_secret_from_stdin("password").unwrap().as_str(),
                "first"
            );

            // Read directly from the OS after the secret read. StdinLock would
            // prefetch this line into its unzeroized global buffer instead.
            let mut raw_stdin = unbuffered_stdin().unwrap();
            let mut next_line = [0u8; 7];
            raw_stdin.read_exact(&mut next_line).unwrap();
            assert_eq!(&next_line, b"second\n");
            drop(raw_stdin);

            assert_eq!(
                read_secret_from_stdin("passphrase").unwrap().as_str(),
                "third"
            );
            assert!(read_secret_from_stdin("password").is_err());
            println!("{CHILD_SUCCESS}");
            return;
        }

        // Isolate process-global stdin from the parallel test harness, and
        // exercise both redirection sources without replacing the parent's fd.
        for use_file in [false, true] {
            let stdin = if use_file {
                let mut file = tempfile::tempfile().unwrap();
                file.write_all(INPUT).unwrap();
                file.rewind().unwrap();
                Stdio::from(file)
            } else {
                Stdio::piped()
            };
            let mut child = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "password::tests::read_secret_from_stdin_does_not_prefetch_or_close_stdin",
                    "--nocapture",
                ])
                .env(CHILD_ENV, "1")
                .stdin(stdin)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            if let Some(mut pipe) = child.stdin.take() {
                pipe.write_all(INPUT).unwrap();
            }
            let output = child.wait_with_output().unwrap();
            assert!(
                output.status.success(),
                "child failed (file stdin: {use_file}): {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(String::from_utf8_lossy(&output.stdout).contains(CHILD_SUCCESS));
        }
    }

    #[test]
    fn read_secret_line_leaves_following_secret_unread() {
        let mut reader = io::Cursor::new(b"password\npassphrase\r\n".as_slice());
        assert_eq!(
            read_secret_line(&mut reader, "password").unwrap().as_str(),
            "password"
        );
        assert_eq!(reader.position(), 9);
        assert_eq!(
            read_secret_line(&mut reader, "passphrase")
                .unwrap()
                .as_str(),
            "passphrase"
        );
    }

    struct ErrorAfterPrefix {
        input: io::Cursor<Vec<u8>>,
        error: Option<io::ErrorKind>,
    }

    impl Read for ErrorAfterPrefix {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            // The production reader must never request read-ahead bytes.
            assert_eq!(buffer.len(), 1);
            if self.input.position() == 3 {
                if let Some(kind) = self.error.take() {
                    return Err(io::Error::from(kind));
                }
            }
            self.input.read(buffer)
        }
    }

    #[test]
    fn read_secret_line_retries_interrupted_reads() {
        let reader = ErrorAfterPrefix {
            input: io::Cursor::new(b"secret\n".to_vec()),
            error: Some(io::ErrorKind::Interrupted),
        };
        assert_eq!(
            read_secret_line(reader, "password").unwrap().as_str(),
            "secret"
        );
    }

    #[test]
    fn read_secret_line_reports_io_error_after_partial_input() {
        let reader = ErrorAfterPrefix {
            input: io::Cursor::new(b"secret\n".to_vec()),
            error: Some(io::ErrorKind::PermissionDenied),
        };
        let err = read_secret_line(reader, "passphrase").unwrap_err();
        assert!(err
            .to_string()
            .contains("failed to read passphrase from stdin"));
        assert!(!err.to_string().contains("secret"));
    }

    #[test]
    fn read_secret_line_rejects_invalid_utf8_without_exposing_input() {
        let mut reader = io::Cursor::new(b"secret\xff\nnext\n".as_slice());
        let err = read_secret_line(&mut reader, "password").unwrap_err();
        assert!(err.to_string().contains("invalid UTF-8"));
        assert!(!err.to_string().contains("secret"));
        assert_eq!(reader.position(), 8);
        assert_eq!(
            read_secret_line(&mut reader, "password").unwrap().as_str(),
            "next"
        );
    }

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
    fn read_secret_line_applies_byte_limit_independently_of_line_ending() {
        let max_secret_len = max_secret_len().unwrap();
        for length in [max_secret_len - 1, max_secret_len, max_secret_len + 1] {
            for ending in ["", "\n", "\r\n"] {
                let input = format!("{}{ending}", "x".repeat(length));
                let mut reader = io::Cursor::new(input);
                let result = read_secret_line(&mut reader, "password");
                assert!(reader.position() <= (max_secret_len + 3) as u64);
                if length <= max_secret_len {
                    assert_eq!(result.unwrap().as_str(), "x".repeat(length));
                } else {
                    assert!(result.unwrap_err().to_string().contains("exceeded"));
                }
            }
        }
    }

    #[test]
    fn read_secret_line_accepts_utf8_at_byte_limit() {
        let max_secret_len = max_secret_len().unwrap();
        let input = format!("{}\r\n", "é".repeat(max_secret_len / 2));
        let secret = read_secret_line(io::Cursor::new(input), "passphrase").unwrap();
        assert_eq!(secret.len(), max_secret_len);
        assert_eq!(secret.as_str(), "é".repeat(max_secret_len / 2));
    }

    #[test]
    fn read_secret_line_rejects_truncated_input_even_when_suffix_is_cr() {
        let max_secret_len = max_secret_len().unwrap();
        let input = format!("{}{}hidden", "x".repeat(max_secret_len), "\r".repeat(8));
        let mut reader = io::Cursor::new(input);
        let err = read_secret_line(&mut reader, "password").unwrap_err();
        assert!(err.to_string().contains("exceeded"));
        assert_eq!(reader.position(), (max_secret_len + 3) as u64);
    }

    #[test]
    fn read_secret_line_rejects_empty_input() {
        for input in ["", "\n", "\r\n"] {
            let mut cursor = io::Cursor::new(input);
            let err = read_secret_line(&mut cursor, "password").expect_err("expected error");
            assert!(err
                .to_string()
                .contains("password read from stdin was empty"));
        }
    }
}

#[cfg(test)]
mod passphrase_tests {
    use super::resolve_passphrase;

    #[test]
    fn resolve_passphrase_none_when_not_requested() {
        // When --passphrase-stdin is not given, no passphrase is read.
        let resolved = resolve_passphrase(false).expect("no error");
        assert!(resolved.is_none());
    }

    #[test]
    fn resolve_passphrase_false_never_reads_stdin() {
        // Guard that the flag governs the read (false => Ok(None), no stdin).
        assert!(resolve_passphrase(false).unwrap().is_none());
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
