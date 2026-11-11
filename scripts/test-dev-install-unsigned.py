#!/usr/bin/env python3
"""Exercise the dev installer's permission gate and replacement in a sandbox."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("dev-install-unsigned.command")
SETTINGS = SCRIPT.with_name("dev-install-settings.conf")


class DevInstallTests(unittest.TestCase):
    def setUp(self):
        self.assertNotEqual(os.geteuid(), 0, "Run as a normal user to test -w permissions")
        self.temporary = tempfile.TemporaryDirectory(prefix="dockbridge install ")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.installed = self.applications / "DockBridge.app"
        self.installed.mkdir()
        self.source = self.root / "DockBridge.app"
        self.source.mkdir()
        (self.source / "new.txt").write_text("new build")
        self.log = self.root / "commands.log"
        self.log.touch()
        self.stubs = self.root / "commands.bash"
        self.stubs.touch()
        # Only redirect the fixed destination in a temporary copy. Production
        # settings and the permission/replacement logic remain unchanged.
        self.script = self.root / SCRIPT.name
        source = SCRIPT.read_text()
        self.assertEqual(source.count("/Applications"), 4,
                         "Installer destinations changed; review sandbox redirection")
        for destination in ('INSTALL_PATH="/Applications/', '[[ ! -w "/Applications" ]]',
                            'mktemp -d "/Applications/'):
            self.assertIn(destination, source)
        self.assertNotIn("/Applications", SETTINGS.read_text())
        self.script.write_text(source.replace("/Applications", str(self.applications)))
        shutil.copyfile(SETTINGS, self.root / SETTINGS.name)
        # Shell functions also work when the temporary filesystem is noexec.
        self.env = dict(os.environ, BASH_ENV=str(self.stubs),
                        INSTALL_TEST_LOG=str(self.log),
                        INSTALL_TEST_APPLICATIONS=str(self.applications),
                        INSTALL_TEST_FAILURE="")
        self.stub("osascript", 'printf "%s\\n" "$*" >> "$INSTALL_TEST_LOG"')
        self.stub("ditto", '''if [[ "$INSTALL_TEST_FAILURE" == preparation ]]; then
  return 1
fi
cp -R "$1" "$2"''')
        self.stub("xattr", "return 0")
        self.stub("pkill", "return 1")
        self.stub("pgrep", "return 1")
        self.stub("open", "return 0")
        self.stub("mv", f'''if [[ "$INSTALL_TEST_FAILURE" == backup &&
      "$1" == "$INSTALL_TEST_APPLICATIONS/DockBridge.app" ]]; then
  return 1
fi
if [[ "$INSTALL_TEST_FAILURE" == placement &&
      "$1" == */DockBridge.app &&
      "$2" == "$INSTALL_TEST_APPLICATIONS/DockBridge.app" ]]; then
  return 1
fi
"{shutil.which('mv')}" "$@"''')
        # Restore fixture modes before TemporaryDirectory removes its contents.
        self.addCleanup(self.restore_permissions)

    def stub(self, name, body):
        with self.stubs.open("a") as file:
            file.write(f'{name}() {{\nprintf "%s\\n" "{name}" >> "$INSTALL_TEST_LOG"\n{body}\n}}\n')

    def restore_permissions(self):
        self.applications.chmod(0o755)
        for directory, _, _ in os.walk(self.applications):
            pathlib.Path(directory).chmod(0o755)

    def install(self):
        return subprocess.run(["bash", str(self.script)], input="\n", text=True,
                              capture_output=True, env=self.env, timeout=10)

    def assert_no_staging(self):
        self.assertEqual(list(self.applications.glob(".DockBridge-install.*")), [])

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.installed / "new.txt").read_text(), "new build")
        self.assertIn("open", self.log.read_text().splitlines())
        self.assertIn("インストールが完了しました", self.log.read_text())
        self.assert_no_staging()

    def test_read_only_existing_bundle_passes_permission_gate(self):
        (self.installed / "old.txt").write_text("old build")
        self.installed.chmod(0o555)
        self.assertFalse(os.access(self.installed, os.W_OK))
        self.assertTrue(os.access(self.applications, os.W_OK))
        # Stop after the gate: Linux may require write access to the directory
        # itself when moving it to a different parent. Do not emulate macOS
        # rename semantics or claim to test a real root-owned macOS bundle here.
        self.env["INSTALL_TEST_FAILURE"] = "preparation"
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ditto", self.log.read_text().splitlines())
        self.assertIn("DockBridge.app の準備に失敗しました", self.log.read_text())
        self.assertNotIn("書き込み権限がありません", self.log.read_text())
        self.assertNotIn("mv", self.log.read_text().splitlines())
        self.assertNotIn("open", self.log.read_text().splitlines())
        self.assertEqual((self.installed / "old.txt").read_text(), "old build")
        self.assert_no_staging()

    def read_only_bundle(self):
        (self.installed / "old.txt").write_text("old build")
        self.installed.chmod(0o555)
        if sys.platform != "darwin":
            # Linux requires write permission for cross-parent directory rename.
            # Model only macOS rename here; cleanup still uses the real rm.
            self.stub("mv", """if [[ -d "$1" && ! -w "$1" ]]; then
  chmod u+w "$1"
  command mv "$@" || return $?
  chmod 0555 "$2"
else
  command mv "$@"
fi""")

    def test_read_only_bundle_is_replaced_with_cleanup_warning(self):
        self.read_only_bundle()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.installed / "new.txt").read_text(), "new build")
        self.assertFalse((self.installed / "old.txt").exists())
        self.assertIn("open", self.log.read_text().splitlines())
        self.assertIn("インストールが完了しました", self.log.read_text())
        backups = list(self.applications.glob(".DockBridge-install.*/previous.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "old.txt").read_text(), "old build")
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o555)
        self.assertIn("後片付けに失敗しました", result.stderr)
        self.assertIn(str(backups[0]), result.stderr)

    def test_cleanup_failure_preserves_install_failure_and_rollback(self):
        (self.installed / "old.txt").write_text("old build")
        self.env["INSTALL_TEST_FAILURE"] = "placement"
        self.stub("rm", "return 42")
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((self.installed / "old.txt").read_text(), "old build")
        self.assertFalse((self.installed / "new.txt").exists())
        self.assertNotIn("open", self.log.read_text().splitlines())
        self.assertNotIn("インストールが完了しました", self.log.read_text())
        self.assertIn("後片付けに失敗しました", result.stderr)
        stages = list(self.applications.glob(".DockBridge-install.*"))
        self.assertEqual(len(stages), 1)
        self.assertIn(str(stages[0]), result.stderr)
        self.assertFalse((stages[0] / "previous.app").exists())

    def test_failed_rollback_preserves_backup_and_failure(self):
        (self.installed / "old.txt").write_text("old build")
        self.stub("mv", """if [[ "$2" == "$INSTALL_TEST_APPLICATIONS/DockBridge.app" ]]; then
  return 1
fi
command mv "$@" """)
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(self.installed.exists())
        backups = list(self.applications.glob(".DockBridge-install.*/previous.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "old.txt").read_text(), "old build")
        self.assertIn(str(backups[0]), result.stderr)
        self.assertNotIn("rm", self.log.read_text().splitlines())
        self.assertNotIn("インストールが完了しました", self.log.read_text())

    def test_writable_existing_bundle_is_replaced_not_merged(self):
        (self.installed / "old.txt").write_text("old build")
        self.assert_success(self.install())
        self.assertFalse((self.installed / "old.txt").exists())

    def test_read_only_parent_is_rejected_before_preparation(self):
        (self.installed / "old.txt").write_text("old build")
        self.applications.chmod(0o555)
        self.assertFalse(os.access(self.applications, os.W_OK))
        self.assertTrue(os.access(self.installed, os.W_OK))
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("書き込み権限がありません", self.log.read_text())
        self.assertNotIn("ditto", self.log.read_text().splitlines())
        self.assertNotIn("open", self.log.read_text().splitlines())
        self.assertEqual((self.installed / "old.txt").read_text(), "old build")
        self.assert_no_staging()

    def test_backup_move_failure_preserves_existing_bundle(self):
        (self.installed / "old.txt").write_text("old build")
        self.env["INSTALL_TEST_FAILURE"] = "backup"
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("既存の DockBridge.app を移動できませんでした", self.log.read_text())
        self.assertNotIn("open", self.log.read_text().splitlines())
        self.assertEqual((self.installed / "old.txt").read_text(), "old build")
        self.assertFalse((self.installed / "new.txt").exists())
        self.assert_no_staging()

    def test_placement_failure_restores_existing_bundle(self):
        (self.installed / "old.txt").write_text("old build")
        self.env["INSTALL_TEST_FAILURE"] = "placement"
        result = self.install()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("元のアプリを復元します", self.log.read_text())
        self.assertNotIn("open", self.log.read_text().splitlines())
        self.assertEqual((self.installed / "old.txt").read_text(), "old build")
        self.assertFalse((self.installed / "new.txt").exists())
        self.assert_no_staging()


if __name__ == "__main__":
    unittest.main()
