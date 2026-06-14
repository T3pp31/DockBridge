//! Integration tests for SFTP path traversal defenses.

use std::path::Path;

use dockbridge_core::{
    ensure_local_path_within_root, normalize_remote_path, validate_remote_entry_name, SftpError,
};

#[test]
fn malicious_entry_names_are_rejected_before_local_join() {
    // Given: server-supplied directory entry names used in traversal
    // When: each name is validated
    // Then: traversal payloads never reach local path construction
    for name in ["..", "/etc/passwd", "", "nested\u{0}file"] {
        let err = validate_remote_entry_name(name).unwrap_err();
        assert!(
            matches!(err, SftpError::InvalidRemotePath { .. }),
            "expected InvalidRemotePath for {name:?}"
        );
    }
}

#[test]
fn download_paths_cannot_escape_local_root() {
    // Given: a local download root and relative paths that would escape it
    // When: ensure_local_path_within_root validates the joined path
    // Then: parent-directory traversal is rejected
    let root = Path::new("/tmp/safe-download");
    for relative in ["../outside.txt", "../../etc/passwd"] {
        let local_path = root.join(relative);
        let err = ensure_local_path_within_root(root, &local_path).unwrap_err();
        assert!(
            matches!(err, SftpError::InvalidRemotePath { .. }),
            "expected InvalidRemotePath for {relative:?}"
        );
    }
}

#[test]
fn remote_api_paths_reject_parent_segments() {
    // Given: remote paths containing parent-directory segments
    // When: normalize_remote_path is applied at the SFTP API boundary
    // Then: traversal attempts are rejected consistently
    for path in ["/foo/../etc", "../secret", "dir/sub/.."] {
        let err = normalize_remote_path(path).unwrap_err();
        assert!(
            matches!(err, SftpError::InvalidRemotePath { .. }),
            "expected InvalidRemotePath for {path:?}"
        );
    }
}
