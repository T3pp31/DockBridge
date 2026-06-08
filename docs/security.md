# DockBridge Security

## v0.1 minimum security baseline

- First-connection host key fingerprint display (SHA256)
- User accept/reject for unknown host keys
- Trusted keys stored in DockBridge `known_hosts.json` (0600)
- Connection blocked on host key mismatch
- Passwords and key passphrases stored in Keychain only
- Private key files are referenced by path, never copied into the app bundle
- No passwords, keys, or passphrases in logs
- CLI `--password` is for development and testing only; prefer `--password-stdin` in scripts
- Rust secrets use `Debug` redaction and `zeroize` where applicable
- Delete confirmation for destructive operations
- Warning when connecting as root

## v0.2 planned

- OpenSSH `~/.ssh/known_hosts` compatibility
- Stricter host key change warnings
