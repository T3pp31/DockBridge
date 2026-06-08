# DockBridge Product Design

DockBridge is a macOS-native SFTP client inspired by WinSCP.

## Concept

Mac users who are familiar with WinSCP should be able to transfer files over SFTP with a native two-pane experience, saved connections, transfer queue, and external editor integration (v0.2+).

## Target users

- Developers moving from WinSCP on Windows
- Web developers uploading to VPS or rental servers
- Users connecting with SSH private keys

## Technology

| Area | Stack |
|------|-------|
| UI | Swift / SwiftUI |
| Backend | Rust |
| Bridge | UniFFI |
| SFTP | russh + russh-sftp |
| Secrets | macOS Keychain |
| Profiles | Application Support JSON |

## v0.1 scope

- SFTP connection (password + private key)
- Two-pane local/remote browser
- Upload, download, delete, rename, mkdir
- Connection profiles
- Keychain for passwords and passphrases
- Transfer queue (sequential)
- Host key fingerprint verification (SHA256)
- Basic error display

SCP support may be considered after v1.0.

## Success criteria (v0.1)

- App launches on macOS 15+
- Connects via SFTP with password or private key
- Shows host key fingerprint on first connect
- Lists, uploads, and downloads files in a two-pane UI
- Transfer queue works
- Credentials stored in Keychain
