# CI/CD Security Audit

- Audited path: repository root (`.github/workflows`)
- Audit date: 2026-09-20
- Focus: GitHub Actions trust boundaries, permissions, external action pinning, OIDC, caches, artifacts, and release provenance
- Auditor notes: Static review of the four repository workflows after the hardening changes in PR #518. Repository-side environment protection settings were not available for inspection.

## Summary

| Metric | Count |
|--------|------:|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Needs further investigation | 1 |

### Status breakdown

| Status | Count |
|--------|------:|
| CONFIRMED | 0 |
| NEEDS_VERIFICATION | 0 |
| NOT_AFFECTED | 0 |
| SECURITY_HARDENING | 0 |
| FALSE_POSITIVE | 0 |

- Detected CI platform: GitHub Actions
- Workflows: 4 (`ci.yml`, `pages.yml`, `release.yml`, `security-audit.yml`)
- Reusable/composite workflows: none
- Classic anti-pattern (`pull_request_target` + untrusted checkout + write token/secrets): not present
- Self-hosted runners: none
- External actions: all references are pinned to 40-character commit SHAs
- SLSA/provenance: release artifacts receive GitHub build-provenance attestations before publication; no SLSA level is claimed
- Needs further investigation: the `github-pages` environment protection rules are repository settings and could not be confirmed from source
- Handoff: dependency completeness, SBOM contents, lockfile integrity, and package-level provenance remain in scope for `dependency-supply-chain-audit`; known-CVE reachability remains in scope for `vulnerability-cve-audit`

## Findings

No open CI/CD security findings remain in the audited workflow definitions.

During this review, the following hardening was applied directly:

- Pinned every external action in all workflows to a verified commit SHA.
- Disabled persisted checkout credentials where repository writes are unnecessary.
- Scoped release write/OIDC/attestation permissions to the release job.
- Passed the manual release version through an environment variable instead of interpolating user-controlled input into shell source.
- Scoped scheduled-audit `issues: write` permission to the job that creates advisory issues.
- Generated provenance before publishing release assets, preventing publication when attestation fails.

## Control observations

- Pull-request CI runs with read-only repository access except for the dedicated audit job permissions; there is no `pull_request_target` or privileged follow-up workflow.
- Cache keys are derived from runner OS and a repository-controlled tool version; no privileged job downloads or executes PR-produced artifacts.
- OIDC permissions are limited to GitHub Pages deployment and release provenance generation.
- Release publication is reachable only from version tags or an explicitly dispatched run, and the requested version must match both `Cargo.toml` and `config/release.toml`.

## References

- [GitHub Docs: Secure use of GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions) (retrieved 2026-09-20)
- [GitHub Docs: Workflow permissions](https://docs.github.com/en/actions/using-jobs/assigning-permissions-to-jobs) (retrieved 2026-09-20)
- [GitHub Docs: Using OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect) (retrieved 2026-09-20)
- [GitHub Docs: Artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations) (retrieved 2026-09-20)
- [SLSA specification 1.2](https://slsa.dev/spec/v1.2/) (retrieved 2026-09-20)
