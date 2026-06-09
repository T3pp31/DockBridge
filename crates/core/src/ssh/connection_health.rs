/// Returns `true` when an error message indicates the SSH/SFTP session is no longer usable.
pub fn is_connection_lost_message(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.contains("session closed")
        || lower.contains("connection reset")
        || lower.contains("broken pipe")
        || lower.contains("connection refused")
        || lower.contains("eof")
}

#[cfg(test)]
mod tests {
    use super::is_connection_lost_message;

    #[test]
    fn detects_session_closed() {
        // Given: a typical SFTP session closed message
        // When: checked for connection loss
        // Then: it is treated as disconnected
        assert!(is_connection_lost_message("failed to upload: session closed"));
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
}
