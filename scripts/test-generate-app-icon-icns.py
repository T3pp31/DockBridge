#!/usr/bin/env python3
"""Regression tests for icon staging; no macOS tools are required."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("generate-app-icon-icns.sh")


class AppIconTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="app icon test ")
        self.addCleanup(directory.cleanup)
        self.root = pathlib.Path(directory.name)
        self.script = self.root / "scripts" / SCRIPT.name
        self.script.parent.mkdir()
        shutil.copyfile(SCRIPT, self.script)
        self.source = self.root / "apps/macos/DockBridge/Resources/Assets.xcassets/AppIcon.appiconset"
        self.source.mkdir(parents=True)
        self.images = {
            f"icon_{size}x{size}{scale}.png": f"PNG {size}{scale}"
            for size in (16, 32, 128, 256, 512)
            for scale in ("", "@2x")
        }
        for name, content in self.images.items():
            (self.source / name).write_text(content)
        (self.source / "Contents.json").write_text("{}")
        (self.source / "nested").mkdir()
        (self.source / "nested/ignored.png").write_text("not a top-level PNG")
        self.output = self.root / "output with spaces" / "AppIcon.icns"
        self.log = self.root / "iconutil.json"
        self.tmp = self.root / "staging"
        self.tmp.mkdir()
        mock = self.root / "iconutil.py"
        shell_env = self.root / "bash-env.sh"
        # A shell function avoids requiring executable fixtures on noexec mounts.
        shell_env.write_text('iconutil() { "$ICON_TEST_PYTHON" "$ICON_TEST_MOCK" "$@"; }\n')
        self.env = dict(os.environ, TMPDIR=str(self.tmp), BASH_ENV=str(shell_env),
                        ICON_TEST_PYTHON=sys.executable, ICON_TEST_MOCK=str(mock),
                        ICONUTIL_LOG=str(self.log), FAIL_ICONUTIL="", LC_ALL="C")
        mock.write_text("""
import json
import os
import pathlib
import sys

assert sys.argv[1:3] == ['-c', 'icns'], sys.argv
assert sys.argv[4] == '-o', sys.argv
iconset = pathlib.Path(sys.argv[3])
assert iconset.name == 'AppIcon.iconset', iconset
images = {path.name: path.read_text() for path in iconset.iterdir()}
pathlib.Path(os.environ['ICONUTIL_LOG']).write_text(json.dumps(images))
if os.environ['FAIL_ICONUTIL']:
    print('iconutil: simulated conversion failure', file=sys.stderr)
    sys.exit(43)
pathlib.Path(sys.argv[5]).write_text('generated icns')
""")

    def generate(self):
        return subprocess.run(["bash", str(self.script), str(self.output)],
                              env=self.env, capture_output=True, text=True)

    def assert_staging_cleaned(self):
        self.assertEqual(list(self.tmp.iterdir()), [])

    def test_success_copies_only_top_level_pngs_before_conversion(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.log.read_text()), self.images)
        self.assertEqual(self.output.read_text(), "generated icns")
        self.assert_staging_cleaned()

    def test_copy_failure_stops_before_iconutil_and_preserves_output(self):
        # A directory named *.png makes real cp fail on both GNU and BSD systems,
        # independently of user privileges or available disk space.
        failing_source = self.source / "icon_32x32.png"
        failing_source.unlink()
        failing_source.mkdir()
        for existing_output in (False, True):
            with self.subTest(existing_output=existing_output):
                if existing_output:
                    self.output.parent.mkdir(parents=True, exist_ok=True)
                    self.output.write_text("previous icns")
                result = self.generate()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("cp:", result.stderr)
                self.assertIn("icon_32x32.png", result.stderr)
                self.assertFalse(self.log.exists(), "iconutil must not run after a copy failure")
                if existing_output:
                    self.assertEqual(self.output.read_text(), "previous icns")
                else:
                    self.assertFalse(self.output.exists())
                self.assert_staging_cleaned()

    def test_iconutil_failure_is_propagated_and_staging_is_cleaned(self):
        self.env["FAIL_ICONUTIL"] = "1"
        result = self.generate()
        self.assertEqual(result.returncode, 43, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.log.read_text()), self.images)
        self.assertIn("iconutil: simulated conversion failure", result.stderr)
        self.assertFalse(self.output.exists())
        self.assert_staging_cleaned()


if __name__ == "__main__":
    unittest.main()
