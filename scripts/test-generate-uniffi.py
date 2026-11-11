#!/usr/bin/env python3
"""Exercise the real generation/build scripts with fake Cargo and bindgen only."""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent
CARGO = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import sys

args = sys.argv[1:]
with open(os.environ["MOCK_EVENTS"], "a") as events:
    events.write(json.dumps(["cargo", args]) + "\n")
if args[0] == "build":
    if os.environ.get("MOCK_BUILD_FAILURE") == "1":
        sys.exit("fixture build failed")
    directory = pathlib.Path(os.environ["CARGO_TARGET_DIR"])
    if "--target" in args:
        directory /= args[args.index("--target") + 1]
    directory /= "release" if "--release" in args else "debug"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "libdockbridge_uniffi.a").write_text(
        pathlib.Path("crates/uniffi/api.txt").read_text())
elif args[0] == "run":
    sys.exit(subprocess.run([os.environ["MOCK_BINDGEN"],
                             *args[args.index("--") + 1:]]).returncode)
else:
    sys.exit("unexpected cargo command")
'''
BINDGEN = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import sys

args = sys.argv[1:]
with open(os.environ["MOCK_EVENTS"], "a") as events:
    events.write(json.dumps(["bindgen", args]) + "\n")
library = pathlib.Path(args[args.index("--library") + 1])
out = pathlib.Path(args[args.index("--out-dir") + 1])
out.mkdir(parents=True, exist_ok=True)
(out / "DockBridgeUniffi.swift").write_text("// API: " + library.read_text() + "\n" + """    public static func lift(_ buf: RustBuffer) throws -> SwiftType {
        var reader = createReader(data: Data(rustBuffer: buf))
        let value = try read(from: &reader)
        if hasRemaining(reader) {
            throw UniffiInternalError.incompleteData
        }
        buf.deallocate()
        return value
    }""")
(out / "dockbridge_uniffiFFI.h").write_text("fixture header")
(out / "dockbridge_uniffiFFI.modulemap").write_text("fixture modulemap")
'''


class GenerateUniffiTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="generate uniffi ")
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name) / "repo"
        (self.root / "scripts").mkdir(parents=True)
        for script in ("generate-uniffi.sh", "build-rust.sh"):
            shutil.copy2(SCRIPTS / script, self.root / "scripts" / script)
        source = self.root / "crates/uniffi/api.txt"
        source.parent.mkdir(parents=True)
        source.write_text("current API")
        self.out = self.root / "apps/macos/DockBridge/Generated"
        self.events_path = self.root / "events.jsonl"
        self.env = os.environ.copy()
        self.env.pop("DOCKBRIDGE_SKIP_HOST_BUILD", None)
        self.env.update({
            "HOME": str(self.root / "home"),
            "CARGO_TARGET_DIR": str(self.root / "custom target"),
            "MOCK_EVENTS": str(self.events_path),
            "MOCK_BINDGEN": str(self.root / "fake-bindgen"),
        })
        self.executable(self.root / "home/.cargo/bin/cargo", CARGO)
        self.executable(self.root / "fake-bindgen", BINDGEN)

    def executable(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)

    @property
    def target_dir(self):
        return pathlib.Path(self.env.get("CARGO_TARGET_DIR", self.root / "target"))

    def library(self, target="", profile="release"):
        directory = "release" if profile == "release" else "debug"
        return self.target_dir / target / directory / "libdockbridge_uniffi.a"

    def seed_library(self, target="", profile="release", contents="stale API"):
        library = self.library(target, profile)
        library.parent.mkdir(parents=True, exist_ok=True)
        library.write_text(contents)
        return library

    def cache_bindgen(self, profile="release"):
        directory = "release" if profile == "release" else "debug"
        self.executable(self.target_dir / directory / "uniffi-bindgen", BINDGEN)

    def generate(self, *args):
        return subprocess.run(
            ["bash", str(self.root / "scripts/generate-uniffi.sh"), *args],
            env=self.env, capture_output=True, text=True, timeout=10)

    def events(self):
        if not self.events_path.exists():
            return []
        return [json.loads(line) for line in self.events_path.read_text().splitlines()]

    def assert_generated(self, result, target="", profile="release", api="current API"):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("// API: " + api, (self.out / "DockBridgeUniffi.swift").read_text())
        self.assertEqual(self.events()[-1], ["bindgen", [
            "generate", "--library", str(self.library(target, profile)),
            "--language", "swift", "--out-dir", str(self.out),
        ]])

    def test_existing_library_is_refreshed_before_cached_bindgen(self):
        for target in ("", "aarch64-apple-darwin"):
            for profile in ("release", "debug", "dev"):
                with self.subTest(target=target, profile=profile):
                    self.events_path.unlink(missing_ok=True)
                    self.seed_library(target, profile)
                    self.cache_bindgen(profile)
                    result = self.generate(target, profile)
                    self.assert_generated(result, target, profile)
                    flags = ["--release"] if profile == "release" else ["--profile", "dev"]
                    target_flags = ["--target", target] if target else []
                    self.assertEqual(self.events()[0], ["cargo", [
                        "build", "-p", "dockbridge-uniffi", *target_flags, *flags,
                    ]])
                    self.assertEqual(len(self.events()), 2)

    def test_changed_api_is_reflected_on_second_generation(self):
        self.cache_bindgen()
        self.assert_generated(self.generate())
        (self.root / "crates/uniffi/api.txt").write_text("updated API with new function")
        self.events_path.unlink()
        result = self.generate()
        self.assert_generated(result, api="updated API with new function")
        self.assertEqual(self.events()[0][1][0], "build")

    def test_missing_library_and_default_target_directory(self):
        self.env.pop("CARGO_TARGET_DIR")
        self.cache_bindgen()
        self.assert_generated(self.generate())
        self.assertEqual(self.events()[0][1], ["build", "-p", "dockbridge-uniffi", "--release"])

    def test_existing_library_is_refreshed_before_cargo_run_fallback(self):
        for profile in ("release", "debug", "dev"):
            with self.subTest(profile=profile):
                self.events_path.unlink(missing_ok=True)
                self.seed_library(profile=profile)
                result = self.generate("", profile)
                self.assert_generated(result, profile=profile)
                flags = ["--release"] if profile == "release" else ["--profile", "dev"]
                self.assertEqual(self.events()[0][1][0], "build")
                self.assertEqual(self.events()[1][1], [
                    "run", "-p", "dockbridge-uniffi", "--features", "cli",
                    "--bin", "uniffi-bindgen", *flags, "--", *self.events()[2][1],
                ])

    def test_failed_build_stops_before_generation_even_with_existing_library(self):
        self.seed_library()
        self.cache_bindgen()
        self.out.mkdir(parents=True)
        swift = self.out / "DockBridgeUniffi.swift"
        swift.write_text("previous bindings")
        self.env["MOCK_BUILD_FAILURE"] = "1"
        result = self.generate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("fixture build failed", result.stderr)
        self.assertEqual([event[1][0] for event in self.events()], ["build"])
        self.assertEqual(swift.read_text(), "previous bindings")

    def test_explicit_host_build_skip_preserves_prebuilt_universal_library(self):
        library = self.seed_library(contents="prebuilt universal API")
        self.cache_bindgen()
        self.env["DOCKBRIDGE_SKIP_HOST_BUILD"] = "1"
        result = self.generate()
        self.assert_generated(result, api="prebuilt universal API")
        self.assertEqual(library.read_text(), "prebuilt universal API")
        self.assertEqual(len(self.events()), 1)

    def test_host_build_skip_does_not_skip_explicit_target(self):
        target = "x86_64-apple-darwin"
        self.seed_library(target)
        self.cache_bindgen()
        self.env["DOCKBRIDGE_SKIP_HOST_BUILD"] = "1"
        result = self.generate(target)
        self.assert_generated(result, target)
        self.assertEqual(self.events()[0][1][0], "build")

    def test_unsupported_profile_fails_before_build_or_generation(self):
        result = self.generate("", "unsupported")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsupported profile", result.stderr)
        self.assertEqual(self.events(), [])


if __name__ == "__main__":
    unittest.main()
