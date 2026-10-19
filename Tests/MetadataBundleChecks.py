"""Validate the shared resource and iPhone-only service requirements."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MetadataBundleChecks(unittest.TestCase):
    def check_resource(self, values, *flags):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "LineupMetadata.json").write_text(json.dumps(values), encoding="utf-8")
            return subprocess.run(
                [sys.executable, "-B", str(ROOT / "Tools/check-metadata-bundle.py"), str(path), *flags],
                capture_output=True, text=True)

    def test_tvos_keeps_intentionally_empty_iphone_services(self):
        result = self.check_resource({"tmdb": "", "tvdb": "", "opensubtitles": "", "fanart": ""})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_iphone_requires_both_injected_consumer_keys(self):
        values = {"tmdb": "", "tvdb": "", "opensubtitles": "fixture-subtitle-key", "fanart": "fixture-art-key"}
        flags = ("--require-online-subtitles", "--require-fanart")
        result = self.check_resource(values, *flags)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("fixture-", result.stdout + result.stderr)
        for name in ("opensubtitles", "fanart"):
            missing = dict(values, **{name: " "})
            rejected = self.check_resource(missing, *flags)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertNotIn("fixture-", rejected.stdout + rejected.stderr)

    def test_resource_shape_and_types_are_checked(self):
        for invalid in (
            {"tmdb": "", "tvdb": "", "opensubtitles": ""},
            {"tmdb": "", "tvdb": "", "opensubtitles": "", "fanart": False},
        ):
            self.assertNotEqual(self.check_resource(invalid).returncode, 0)

    def test_generator_includes_fanart_without_logging_its_value(self):
        # Run an isolated copy so no local credential resource is overwritten.
        with tempfile.TemporaryDirectory() as directory:
            import os
            import shutil
            path = Path(directory)
            (path / "Tools").mkdir()
            script = path / "Tools/configure-metadata.py"
            shutil.copyfile(ROOT / "Tools/configure-metadata.py", script)
            env = dict(os.environ, LINEUP_FANART_API_KEY="fixture-project-key")
            result = subprocess.run([sys.executable, "-B", str(script)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            values = json.loads((path / "Lineup/Resources/LineupMetadata.json").read_text(encoding="utf-8"))
            self.assertEqual(set(values), {"tmdb", "tvdb", "opensubtitles", "fanart"})
            self.assertEqual(values["fanart"], "fixture-project-key")
            self.assertNotIn("fixture-project-key", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
