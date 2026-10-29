/// Strips quoted path-like segments before disconnect heuristics so a path
/// containing a phrase cannot falsely indicate connection loss (issue #662).
fn strip_quoted_paths(message: &str) -> String {
    // First expose Debug error payloads, then remove paths nested inside them.
    // Two bounded passes avoid recursively parsing server-controlled text.
    strip_quoted_segments(&strip_quoted_segments(message, true), false)
}

fn strip_quoted_segments(message: &str, preserve_error_text: bool) -> String {
    let mut result = String::with_capacity(message.len());
    let mut rest = message;
    while let Some(start) = rest.find(['\'', '"']) {
        let quote = rest[start..].chars().next().unwrap();
        let after_open = &rest[start + quote.len_utf8()..];
        let mut escaped = false;
        let end = after_open.char_indices().find_map(|(index, character)| {
            if escaped {
                escaped = false;
                None
            } else if character == '\\' {
                escaped = true;
                None
            } else {
                (character == quote).then_some(index)
            }
        });
        if let Some(end) = end {
            result.push_str(&rest[..start]);
            // Debug formatting quotes error text as well as paths. Keep
            // error fields and the SFTP IO wrapper visible to the classifier.
            let prefix = rest[..start].trim_end().to_lowercase();
            if preserve_error_text
                && (prefix.ends_with("message:")
                    || prefix.ends_with("error:")
                    || prefix.ends_with("io("))
            {
                // Debug escapes nested double quotes. Expose them to the
                // second pass so quoted filenames are still removed.
                result.push_str(&after_open[..end].replace("\\\"", "\""));
            } else {
                result.push_str(" \"path\" ");
            }
            rest = &after_open[end + quote.len_utf8()..];
        } else {
            break;
        }
    }
    result.push_str(rest);
    result
}

/// Returns `true` when an error message indicates the SSH/SFTP session is no longer usable.
///
/// Matching is deliberately *not* a raw substring scan for `"eof"`, because
/// user-controlled remote paths routinely contain that substring (e.g.
/// `geoffrey`, `thereof.txt`) and would cause live sessions to be torn down.
/// "EOF" is only matched as a standalone token. Additional messages that the
/// underlying libraries actually produce when a channel/session dies are
/// covered as well.
pub fn is_connection_lost_message(message: &str) -> bool {
    // User-controlled paths may contain disconnect phrases (e.g. a file named
    // "eof.txt" or "session closed"). Remove quoted paths before matching
    // (issue #662).
    let stripped = strip_quoted_paths(message);
    let lower = stripped.to_lowercase();
    if lower.contains("session closed")
        || lower.contains("connection reset")
        || lower.contains("broken pipe")
        || lower.contains("connection refused")
        || lower.contains("sender dropped")
        || lower.contains("channel closed")
        || lower.contains("recv error")
        || lower.contains("connection closed by the remote side")
    {
        return true;
    }
    // Quoted paths have been removed. Keep path separators and extensions
    // inside tokens so unquoted `/eof` and `eof.txt` are not bare EOF errors.
    lower
        .split(|character: char| {
            !character.is_alphanumeric() && !matches!(character, '.' | '/' | '\\' | '_' | '-')
        })
        .any(|token| matches!(token, "eof" | "disconnected"))
        && !lower.contains("permission denied")
        && !lower.contains("no such file")
        && !lower.contains("not found")
}

#[cfg(test)]
mod tests {
    use super::is_connection_lost_message;

    #[test]
    fn detects_session_closed() {
        // Given: a typical SFTP session closed message
        // When: checked for connection loss
        // Then: it is treated as disconnected
        assert!(is_connection_lost_message(
            "failed to upload: session closed"
        ));
    }

    #[test]
    fn detects_connection_reset_case_insensitively() {
        assert!(is_connection_lost_message("Connection Reset by peer"));
    }

    #[test]
    fn ignores_unrelated_errors() {
        assert!(!is_connection_lost_message("permission denied"));
        assert!(!is_connection_lost_message("no such file"));
    }

    #[test]
    fn ignores_eof_substring_inside_path() {
        // Given: an error that embeds a user-controlled path containing "eof"
        // When: checked for connection loss
        // Then: it is NOT treated as disconnected (would drop a live session)
        assert!(!is_connection_lost_message(
            "failed to delete '/home/geoffrey/thereof.txt': Permission denied"
        ));
        assert!(!is_connection_lost_message(
            "failed to upload 'geoff.txt': no such file"
        ));
    }

    #[test]
    fn detects_standalone_eof_token() {
        // Given: a genuine EOF token (not embedded in a path)
        // When: checked for connection loss
        // Then: it is treated as disconnected
        assert!(is_connection_lost_message("unexpected eof"));
        assert!(is_connection_lost_message("connection closed: eof"));
    }

    #[test]
    fn detects_underlying_library_messages() {
        // Given: messages the SSH/SFTP libraries actually emit on teardown
        // When: checked for connection loss
        // Then: they are treated as disconnected
        assert!(is_connection_lost_message("sender dropped"));
        assert!(is_connection_lost_message("write channel closed"));
        assert!(is_connection_lost_message("RecvError: channel closed"));
    }

    #[test]
    fn detects_bare_and_io_eof_messages() {
        for message in ["EOF", "read: EOF", "I/O: EOF", "early eof"] {
            assert!(is_connection_lost_message(message), "{message}");
        }
    }

    #[test]
    fn detects_debug_formatted_error_messages() {
        let error = std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "Connection reset by peer",
        );
        assert!(is_connection_lost_message(&format!("{error:?}")));
        let sftp_error = russh_sftp::client::error::Error::IO("Connection reset by peer".into());
        assert!(is_connection_lost_message(&format!("{sftp_error:?}")));
        assert!(is_connection_lost_message(
            "failed to download '/tmp/file': IO { message: \"unexpected eof\" }"
        ));
    }

    #[test]
    fn detects_russh_disconnect_displays() {
        for error in [russh::Error::Disconnect, russh::Error::HUP] {
            assert!(is_connection_lost_message(&error.to_string()), "{error}");
        }
    }

    #[test]
    fn ignores_disconnect_phrases_in_quoted_basenames_and_paths() {
        for path in [
            "eof",
            "eof.txt",
            "EOF.bin",
            "session closed",
            "broken pipe",
            "/download/connection reset",
            "/download/unexpected eof",
        ] {
            for quote in ['\'', '"'] {
                let message = format!("failed to delete {quote}{path}{quote}: failure");
                assert!(!is_connection_lost_message(&message), "{message}");
            }
        }
    }

    #[test]
    fn ignores_paths_inside_debug_formatted_error_messages() {
        for path in ["session closed", "broken pipe", "unexpected eof"] {
            for quote in ['\'', '"'] {
                let error = russh_sftp::client::error::Error::IO(format!(
                    "failed to delete {quote}{path}{quote}: failure"
                ));
                assert!(
                    !is_connection_lost_message(&format!("{error:?}")),
                    "{error:?}"
                );
            }
        }
    }

    #[test]
    fn ignores_unquoted_eof_paths() {
        for path in ["eof.txt", "/eof", "eof/file", "eof.bin"] {
            let message = format!("failed to delete {path}: failure");
            assert!(!is_connection_lost_message(&message), "{message}");
        }
    }

    #[test]
    fn detects_connection_refused() {
        assert!(is_connection_lost_message("connection refused"));
    }
}
