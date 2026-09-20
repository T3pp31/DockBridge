/// Returns `true` when an error message indicates the SSH/SFTP session is no longer usable.
///
/// Matching is deliberately *not* a raw substring scan for `"eof"`, because
/// user-controlled remote paths routinely contain that substring (e.g.
/// `geoffrey`, `thereof.txt`) and would cause live sessions to be torn down.
/// "EOF" is only matched as a standalone token. Additional messages that the
/// underlying libraries actually produce when a channel/session dies are
/// covered as well.
pub fn is_connection_lost_message(message: &str) -> bool {
    let lower = message.to_lowercase();
    if lower.contains("session closed")
        || lower.contains("connection reset")
        || lower.contains("broken pipe")
        || lower.contains("connection refused")
        || lower.contains("sender dropped")
        || lower.contains("channel closed")
        || lower.contains("recv error")
    {
        return true;
    }
    // "eof" only as its own word, not inside a user-controlled path segment
    // (e.g. "unexpected eof", "eof, ..."), so `geoffrey` / `thereof` are safe.
    lower
        .split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
        .any(|token| token == "eof" || token == "eof,")
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
    fn detects_connection_refused() {
        assert!(is_connection_lost_message("connection refused"));
    }
}
