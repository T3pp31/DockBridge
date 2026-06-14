//! Integration tests for SFTP path traversal defenses.

use std::fs;

use dockbridge_core::{
    ensure_local_path_within_root, normalize_remote_path, validate_remote_entry_name,
    validated_remote_entry, SftpError,
};
use tempfile::tempdir;

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
fn validated_remote_entry_rejects_mismatched_server_path() {
    // Given: a benign entry name with a malicious server-reported path
    // When: validated_remote_entry is called
    // Then: the mismatch is rejected before any client-side join is trusted
    let err = validated_remote_entry("/remote/dir", "file.txt", "/etc/passwd").unwrap_err();
    assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
}

#[test]
fn validated_remote_entry_accepts_matching_server_path() {
    // Given: a benign entry name with a matching server-reported path
    // When: validated_remote_entry is called
    // Then: the client-built path is returned
    assert_eq!(
        validated_remote_entry("/remote/dir", "file.txt", "/remote/dir/file.txt").unwrap(),
        "/remote/dir/file.txt"
    );
}

#[test]
fn download_paths_cannot_escape_local_root() {
    // Given: a local download root and relative paths that would escape it
    // When: ensure_local_path_within_root validates the joined path
    // Then: parent-directory traversal is rejected
    let dir = tempdir().unwrap();
    let root = dir.path().join("safe-download");
    fs::create_dir(&root).unwrap();
    for relative in ["../outside.txt", "../../etc/passwd"] {
        let local_path = root.join(relative);
        let err = ensure_local_path_within_root(&root, &local_path).unwrap_err();
        assert!(
            matches!(err, SftpError::InvalidRemotePath { .. }),
            "expected InvalidRemotePath for {relative:?}"
        );
    }
}

#[cfg(unix)]
#[test]
fn download_paths_cannot_escape_via_symlink() {
    // Given: a local download root containing a symlink to an outside file
    // When: ensure_local_path_within_root validates a path through the symlink
    // Then: canonical resolution outside the root is rejected
    let dir = tempdir().unwrap();
    let root = dir.path().join("safe-download");
    fs::create_dir(&root).unwrap();
    let outside = tempdir().unwrap();
    fs::write(outside.path().join("secret.txt"), b"secret").unwrap();
    std::os::unix::fs::symlink(outside.path().join("secret.txt"), root.join("escape.txt")).unwrap();

    let escaped = root.join("escape.txt");
    let err = ensure_local_path_within_root(&root, &escaped).unwrap_err();
    assert!(matches!(err, SftpError::InvalidRemotePath { .. }));
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

#[test]
fn upload_download_boundaries_reject_parent_segments() {
    // Given: remote paths with parent-directory segments at transfer boundaries
    // When: normalize_remote_path is applied
    // Then: upload/download never receive unnormalized traversal paths
    for path in ["remote/../secret", "/nested/dir/.."] {
        let err = normalize_remote_path(path).unwrap_err();
        assert!(
            matches!(err, SftpError::InvalidRemotePath { .. }),
            "expected InvalidRemotePath for {path:?}"
        );
    }
}
