# Security Policy

DockBridge is an SSH/SFTP client, so the trustworthiness of the connection, the
host-key store, and the credential handling is security-critical.

## Reporting a vulnerability

Please report vulnerabilities through **GitHub Private Vulnerability
Reporting** (Security tab → "Report a vulnerability") rather than opening a
public issue. This keeps the report private until a fix is available.

- Report target: <https://github.com/T3pp31/DockBridge/security/advisories/new>
- If PVR is unavailable for your account, open a **private** issue or contact
  the maintainer through the GitHub profile page, and do not include secrets or
  passwords in the report.

Please include (when applicable):

- Affected version (macOS app version, CLI `dockbridge --version`, or commit)
- macOS version and architecture
- SSH/SFTP server type and version (OpenSSH, Dropbear, etc.)
- Steps to reproduce, ideally minimal
- Whether the issue involves a host-key store, keychain, path handling, or
  network trust

## Response targets

- Initial acknowledgment: within 72 hours of a valid report
- Triage / severity assessment: within 1 week
- Fix target: within 90 days from confirmation (critical issues may ship faster)

We will keep you informed of progress and coordinate disclosure timing.

## Supported versions

Security fixes are provided for the **latest minor release** and, when a fix is
back-portable, the release currently being prepared. Older versions are not
supported.

## Security posture (summary)

Full details live in [`docs/security.md`](docs/security.md).

- Host keys are verified against a DockBridge store (and optionally merged from
  OpenSSH `known_hosts`). Key changes must be explicitly accepted per host.
- Credentials are stored in the macOS Keychain and zeroized in memory.
- Current public DMGs are **unsigned / not notarized**; do not disable
  Gatekeeper checks for downloads from untrusted sources. Signed and notarized
  builds are planned.
- Release artifacts are attested with GitHub provenance and published with a
  CycloneDX SBOM.

## Known constraints

- `known_hosts.json` is owner-only (`0600`); a drifted permission prevents the
  app from trusting hosts until repaired from Settings.
- Early releases are unsigned; see the download site and `docs/security.md` for
  verification steps.
