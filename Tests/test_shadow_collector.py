"""Offline safety and response-shape checks for the one-shot Shadow helper."""

from pathlib import Path
import base64
import sys
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources" / "RenduBar"))
import shadow_collector as collector  # noqa: E402


class ShadowCollectorTests(unittest.TestCase):
    def test_only_safe_absolute_windows_paths(self):
        self.assertTrue(collector.valid_path("C:/renders/exports"))
        self.assertTrue(collector.valid_path(r"C:\renders\exports"))
        for value in ("exports", "../exports", "C:/exports/../private",
                      "C:/exports';Stop-Process", "C:/exports\nprivate", "C:/exports\tprivate", "C:/exports\x7fprivate"):
            with self.subTest(value=value):
                self.assertFalse(collector.valid_path(value))

    def test_single_file_and_missing_folder_are_normalized(self):
        payload = b'{"files":{"name":"x.png","path":"C:/exports/x.png"},"missing":"C:/missing"}'
        with patch.object(collector, "connection", return_value=("example.test", "render", Path("/tmp/test-key"))), \
             patch.object(collector, "ssh_base", return_value=[]), \
             patch.object(collector, "run", return_value=payload):
            result = collector.scan(["C:/exports", "C:/missing"])
        self.assertEqual(len(result["files"]), 1)
        self.assertEqual(result["missing"], ["C:/missing"])

    def test_preview_cannot_escape_configured_folder(self):
        with self.assertRaisesRegex(ValueError, "outside configured"):
            collector.preview("C:/private/frame.png", ["C:/exports"], Path("/tmp/unused.jpg"))

    def test_preview_rejects_unlisted_types_without_connection(self):
        for name in ("sound.wav", "clip.mp4", "frame.exr", "scene.blend"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "invalid preview"):
                collector.preview("C:/exports/" + name, ["C:/exports"], Path("/tmp/unused.jpg"))

    def test_scan_rejects_invalid_roots_before_ssh(self):
        for roots in (["relative"], ["C:/exports"] * 13):
            with self.assertRaises(ValueError):
                collector.scan(roots)

    def test_history_is_explicit_and_recent_scan_remains_bounded(self):
        captured = []
        def fake_run(argv, timeout):
            captured.append(base64.b64decode(argv[-1].split()[-1]).decode("utf-16-le"))
            return b'{"files":[],"missing":[]}'
        with patch.object(collector, "connection", return_value=("example.test", "render", Path("/tmp/test-key"))), \
             patch.object(collector, "ssh_base", return_value=[]), patch.object(collector, "run", side_effect=fake_run):
            collector.scan(["C:/neutral/exports"])
            collector.scan(["C:/neutral/exports"], history=True)
        self.assertIn("Select-Object -First 24", captured[0])
        self.assertNotIn("Select-Object -First 24", captured[1])
        self.assertIn("c:/neutral/exports", captured[1])
        self.assertNotIn("-Recurse", captured[1])

    def test_bounded_child_is_reaped(self):
        self.assertEqual(collector.run(["/bin/echo", "ok"], 2), b"ok\n")
        self.assertIsNone(collector.ACTIVE)
        with self.assertRaisesRegex(RuntimeError, "timeout"):
            collector.run([sys.executable, "-c", "import time; time.sleep(3)"], 1)
        self.assertIsNone(collector.ACTIVE)


if __name__ == "__main__":
    unittest.main()
