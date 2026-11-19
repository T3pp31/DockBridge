#!/usr/bin/env python3
"""Verify the scheduled security audit grants rustsec/audit-check its
required permissions.

Run from the repository root: python3 scripts/test-security-audit-workflow.py
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "security-audit.yml"
CI = ROOT / ".github" / "workflows" / "ci.yml"


def job_block(text, job_name):
    """Return the literal YAML block for a job, without a YAML dependency.

    Job keys sit at two-space indentation; the block ends at the next line
    that starts a new top-level job.
    """
    marker = f"\n  {job_name}:\n"
    start = text.index(marker) + len(marker)
    lines = []
    for line in text[start:].splitlines(keepends=True):
        if line.startswith("  ") and not line.startswith("   "):
            break
        lines.append(line)
    return "".join(lines)


class SecurityAuditWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_audit_job_can_write_checks(self):
        # rustsec/audit-check creates a check run; without checks: write the
        # job fails with "Not Found" from the checks API (issue #1361).
        audit = job_block(self.text, "audit")
        self.assertIn("checks: write", audit)
        self.assertIn("issues: write", audit)

    def test_audit_job_matches_ci_permissions(self):
        ci_audit = job_block(CI.read_text(encoding="utf-8"), "security-audit")
        audit = job_block(self.text, "audit")
        for permission in ("contents: read", "checks: write", "issues: write"):
            with self.subTest(permission=permission):
                self.assertIn(permission, ci_audit)
                self.assertIn(permission, audit)

    def test_expiring_exceptions_job_stays_read_only(self):
        job = job_block(self.text, "expiring-exceptions")
        self.assertNotIn("checks: write", job)
        self.assertNotIn("issues: write", job)


if __name__ == "__main__":
    unittest.main()
