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


def permissions(block, indent):
    """Parse the ``permissions:`` mapping at ``indent`` spaces in ``block``.

    Comment lines and trailing comments are ignored, so a permission only
    counts when it is an actual key under ``permissions:``. Returns ``None``
    when the block has no ``permissions:`` key at that indentation.
    """
    lines = block.splitlines()
    header = " " * indent + "permissions:"
    for index, line in enumerate(lines):
        if line.rstrip() == header:
            break
    else:
        return None
    grants = {}
    for line in lines[index + 1 :]:
        stripped = line.split("#", 1)[0].rstrip()
        if not stripped.strip():
            continue
        if len(stripped) - len(stripped.lstrip()) <= indent:
            break
        key, _, value = stripped.strip().partition(":")
        grants[key.strip()] = value.strip()
    return grants


EXPECTED_AUDIT = {"contents": "read", "checks": "write", "issues": "write"}


class SecurityAuditWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_audit_job_can_write_checks(self):
        # rustsec/audit-check creates a check run; without checks: write the
        # job fails with "Not Found" from the checks API (issue #1361).
        audit = job_block(self.text, "audit")
        self.assertEqual(permissions(audit, 4), EXPECTED_AUDIT)

    def test_audit_job_matches_ci_permissions(self):
        ci_audit = job_block(CI.read_text(encoding="utf-8"), "security-audit")
        audit = job_block(self.text, "audit")
        self.assertEqual(permissions(ci_audit, 4), permissions(audit, 4))

    def test_expiring_exceptions_job_stays_read_only(self):
        # The job inherits the workflow-level grant, which must stay read-only.
        job = job_block(self.text, "expiring-exceptions")
        self.assertIsNone(permissions(job, 4))
        self.assertEqual(permissions(self.text, 0), {"contents": "read"})

    def test_permissions_parser_ignores_comments(self):
        block = (
            "    permissions:\n"
            "      contents: read\n"
            "      # checks: write (documented only)\n"
            "    steps:\n"
        )
        self.assertEqual(permissions(block, 4), {"contents": "read"})


if __name__ == "__main__":
    unittest.main()
