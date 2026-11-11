#!/usr/bin/env python3
"""Source-level regression guards for Settings scene state ownership (#1177).

These checks deliberately do not emulate SwiftUI: lifecycle/rendering behavior
still needs the macOS build and UI verification. They guard the production
wiring that previously reloaded settings during scene construction.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = (ROOT / "apps/macos/DockBridge/App/DockBridgeApp.swift").read_text()
EDITOR = (ROOT / "apps/macos/DockBridge/Views/Settings/SettingsView.swift").read_text()


def block_after(source, marker):
    """Extract one of the simple, balanced Swift blocks checked below."""
    start = source.index("{", source.index(marker))
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1:index]
    raise AssertionError(f"Unclosed block after {marker!r}")


class SettingsSceneSourceTests(unittest.TestCase):
    def test_scene_uses_startup_snapshot_without_reloading(self):
        startup = block_after(APP, "init()")
        scene = block_after(APP, "Settings {")
        self.assertEqual(startup.count("AppSettingsService.shared.loadConfig()"), 1)
        self.assertIn("_settingsConfig = State(initialValue: config)", startup)
        self.assertRegex(scene, r"SettingsView\(\s*config:\s*settingsConfig\s*\)")
        self.assertNotIn("loadConfig(", block_after(APP, "var body:"))

    def test_both_window_roots_refresh_from_valid_notification_payloads(self):
        # The main window may be closed while Settings remains open (or vice versa).
        for marker in ("WindowGroup {", "Settings {"):
            with self.subTest(root=marker):
                root = block_after(APP, marker)
                receiver = block_after(root, ".onReceive(")
                self.assertIn("publisher(for: .appConfigDidChange)", root)
                self.assertRegex(
                    receiver,
                    r"guard let config = notification\.object as\? AppConfig else \{ return \}"
                    r"\s*settingsConfig = config",
                )
                self.assertNotIn("loadConfig(", receiver)

    def test_scene_save_keeps_persistence_and_cached_state_in_sync(self):
        scene = block_after(APP, "Settings {")
        self.assertRegex(
            scene,
            r"AppSettingsService\.shared\.saveConfig\(config\)\s*settingsConfig = config",
        )

    def test_editor_tracks_saved_input_separately_from_unsaved_draft(self):
        self.assertIn("@State private var config: AppConfig", EDITOR)
        self.assertIn("private let savedConfig: AppConfig", EDITOR)
        initializer = block_after(EDITOR, "init(config:")
        self.assertIn("_config = State(initialValue: config)", initializer)
        self.assertIn("savedConfig = config", initializer)
        # A redraw with the same saved input must not reset unsaved edits.
        changed = block_after(EDITOR, ".onChange(of: savedConfig)")
        self.assertRegex(changed, r"_, newConfig in")
        self.assertIn("config = newConfig", changed)
        self.assertNotIn("onSave(", changed)
        self.assertNotIn("loadConfig(", EDITOR)

    def test_reopen_discards_cancelled_draft_without_saving(self):
        appear = block_after(EDITOR, ".onAppear")
        self.assertIn("config = savedConfig", appear)
        cancel = block_after(EDITOR, 'Button(String(localized: "Cancel")')
        self.assertIn("dismiss()", cancel)
        self.assertNotIn("onSave(", cancel)
        save = block_after(EDITOR, 'Button(String(localized: "Save")')
        self.assertRegex(save, r"onSave\(config\)\s*dismiss\(\)")
        self.assertEqual(EDITOR.count("onSave(config)"), 1)


if __name__ == "__main__":
    unittest.main()
