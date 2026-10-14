"""Packaging regressions run on Windows too; Mach-O output is supplied below."""
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "aether_bundle", Path(__file__).resolve().parents[1] / "Tools/check-aether-bundle.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class AetherBundleChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Lineup.app"
        self.app.mkdir()
        for name in ("LineupAetherPlayback", *bundle.RUNTIME_FRAMEWORKS):
            path = self.app / "Frameworks" / f"{name}.framework" / name
            path.parent.mkdir(parents=True)
            path.write_bytes(b"fixture")
        notice = self.app / "Frameworks/LineupAetherPlayback.framework/AetherLicenses/AetherEngine.txt"
        notice.parent.mkdir()
        notice.write_text("fixture", encoding="utf-8")
        resource = self.app / "AetherEngine_AetherEngine.bundle/silent-atmos.mp4"
        resource.parent.mkdir()
        resource.write_bytes(b"fixture")
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"MinimumOSVersion": "18.0"}))

    def test_successful_link_does_not_hide_missing_runtime_framework(self):
        (self.app / "Frameworks/AetherLibavcodec.framework/AetherLibavcodec").unlink()
        with self.assertRaisesRegex(ValueError, "Missing packaged Aether files:.*\\n  Frameworks/AetherLibavcodec"):
            bundle.bundled_files(self.app)

    def test_resource_bundle_must_contain_the_engine_asset(self):
        (self.app / "AetherEngine_AetherEngine.bundle/silent-atmos.mp4").unlink()
        with self.assertRaisesRegex(ValueError, "silent-atmos.mp4"):
            bundle.bundled_files(self.app)

    def test_rejects_a_vlc_ffmpeg_binding_and_an_unresolved_dylib(self):
        images = bundle.bundled_files(self.app)
        with self.assertRaisesRegex(ValueError, "not bound"):
            bundle.inspect_macho(self.app, images, run=lambda *args, **kwargs:
                "(undefined) external _avcodec_open2 (from TVVLCKit)")

        def output(command, **kwargs):
            if command[0] == "nm":
                return "(undefined) external _avcodec_open2 (from AetherLibavcodec)"
            return command[-1] + ":\n\t@rpath/AetherMissing.framework/AetherMissing (compatibility version 1.0.0)\n"
        with self.assertRaisesRegex(ValueError, "AetherMissing"):
            bundle.inspect_macho(self.app, images, run=output)

    def test_complete_bundle_has_no_unresolved_frameworks(self):
        images = bundle.bundled_files(self.app)
        def output(command, **kwargs):
            if command[0] == "nm":
                return "(undefined) external _avcodec_open2 (from AetherLibavcodec)"
            return command[-1] + ":\n\t@rpath/AetherLibavutil.framework/AetherLibavutil (compatibility version 60.0.0)\n"
        self.assertIn("from AetherLibavcodec", bundle.inspect_macho(self.app, images, run=output))


if __name__ == "__main__":
    unittest.main()
