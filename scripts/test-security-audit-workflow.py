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


def permissions_in(block, indent):
    """Parse the `permissions:` mapping that sits at `indent` spaces in a
    YAML block, ignoring comments. Returns None when there is no such key."""
    lines = [
        line
        for line in block.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    key = " " * indent + "permissions:"
    for i, line in enumerate(lines):
        if line.rstrip() != key:
            continue
        perms = {}
        for entry in lines[i + 1 :]:
            entry_indent = len(entry) - len(entry.lstrip())
            if entry_indent <= indent:
                break
            name, _, value = entry.strip().partition(":")
            perms[name.strip()] = value.split("#", 1)[0].strip()
        return perms
    return None


def workflow_permissions(text):
    """Workflow-level permissions (everything before `jobs:`)."""
    return permissions_in(text.split("\njobs:\n", 1)[0], 0)


def effective_permissions(text, job_name):
    """Job-level permissions replace the workflow-level ones entirely."""
    job = permissions_in(job_block(text, job_name), 4)
    return job if job is not None else workflow_permissions(text)


class SecurityAuditWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_audit_job_can_write_checks(self):
        # rustsec/audit-check creates a check run; without checks: write the
        # job fails with "Not Found" from the checks API (issue #1361).
        audit = effective_permissions(self.text, "audit")
        self.assertEqual(audit.get("checks"), "write")
        self.assertEqual(audit.get("issues"), "write")

    def test_audit_job_matches_ci_permissions(self):
        ci_audit = effective_permissions(
            CI.read_text(encoding="utf-8"), "security-audit"
        )
        audit = effective_permissions(self.text, "audit")
        expected = {"contents": "read", "checks": "write", "issues": "write"}
        self.assertEqual(ci_audit, expected)
        self.assertEqual(audit, expected)

    def test_expiring_exceptions_job_stays_read_only(self):
        # Allowlist the effective grant, including anything inherited from
        # the workflow-level permissions block.
        job = effective_permissions(self.text, "expiring-exceptions")
        self.assertEqual(job, {"contents": "read"})

    def test_parser_ignores_commented_permissions(self):
        text = (
            "jobs:\n"
            "  audit:\n"
            "    permissions:\n"
            "      contents: read\n"
            "      # checks: write\n"
        )
        self.assertEqual(effective_permissions(text, "audit"), {"contents": "read"})


if __name__ == "__main__":
    unittest.main()
