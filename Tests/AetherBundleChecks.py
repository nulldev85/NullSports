"""Packaging regressions run on Windows too; Mach-O output is supplied below."""
import copy
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
        for name in ("LineupAetherPlayback", "LineupMPVPlayback", *bundle.RUNTIME_FRAMEWORKS):
            path = self.app / "Frameworks" / f"{name}.framework" / name
            path.parent.mkdir(parents=True)
            path.write_bytes(b"fixture")
        notice = self.app / "Frameworks/LineupAetherPlayback.framework/AetherLicenses/AetherEngine.txt"
        notice.parent.mkdir()
        notice.write_text("fixture", encoding="utf-8")
        mpv_license = self.app / "Frameworks/LineupMPVPlayback.framework/MPVLicenses/LGPL-3.0.txt"
        mpv_license.parent.mkdir()
        mpv_license.write_text("fixture", encoding="utf-8")
        resource = self.app / "AetherEngine_AetherEngine.bundle/silent-atmos.mp4"
        resource.parent.mkdir()
        resource.write_bytes(b"fixture")
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"MinimumOSVersion": "18.0"}))

    def test_successful_link_does_not_hide_missing_runtime_framework(self):
        (self.app / "Frameworks/AetherLibavcodec.framework/AetherLibavcodec").unlink()
        with self.assertRaisesRegex(ValueError, "Frameworks/AetherLibavcodec.framework/AetherLibavcodec"):
            bundle.bundled_files(self.app)

    def test_mpv_bridge_and_license_must_be_packaged(self):
        bridge = self.app / "Frameworks/LineupMPVPlayback.framework/LineupMPVPlayback"
        bridge.unlink()
        with self.assertRaisesRegex(ValueError, "Frameworks/LineupMPVPlayback.framework/LineupMPVPlayback"):
            bundle.bundled_files(self.app)

        bridge.write_bytes(b"fixture")
        license_file = self.app / "Frameworks/LineupMPVPlayback.framework/MPVLicenses/LGPL-3.0.txt"
        license_file.unlink()
        with self.assertRaisesRegex(ValueError, "Frameworks/LineupMPVPlayback.framework/MPVLicenses/LGPL-3.0.txt"):
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


class AetherProjectChecks(unittest.TestCase):
    def setUp(self):
        objects = {}
        for name in bundle.RUNTIME_FRAMEWORKS:
            objects[name] = {"isa": "PBXFileReference", "path": f"{name}.framework",
                             "sourceTree": "BUILT_PRODUCTS_DIR"}
            objects[name + "-copy"] = {"isa": "PBXBuildFile", "fileRef": name,
                                      "settings": {"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]}}
        for name in ("Lineup", "LineupiOS"):
            objects[name] = {"isa": "PBXNativeTarget", "name": name,
                             "buildPhases": [name + "-embed", name + "-link"]}
            objects[name + "-embed"] = {"isa": "PBXCopyFilesBuildPhase", "dstSubfolderSpec": 10,
                                        "files": [item + "-copy" for item in bundle.RUNTIME_FRAMEWORKS]}
            objects[name + "-link"] = {"isa": "PBXFrameworksBuildPhase", "files": []}
            product_ref = name + "-mpv-product"
            objects[product_ref] = {
                "isa": "PBXReferenceProxy",
                "name": "LineupMPVPlayback.framework",
                "path": "LineupMPVPlayback.framework",
                "productName": "LineupMPVPlayback",
            }
            objects[name + "-mpv-link"] = {"isa": "PBXBuildFile", "productRef": product_ref}
            objects[name + "-mpv-copy"] = {
                "isa": "PBXBuildFile",
                "productRef": product_ref,
                "settings": {"ATTRIBUTES": ["CodeSignOnCopy"]},
            }
            objects[name + "-link"]["files"].append(name + "-mpv-link")
            objects[name + "-embed"]["files"].append(name + "-mpv-copy")
        self.project = {"objects": objects}

    def test_real_framework_copies_pass_for_both_apps(self):
        self.assertIn("both app targets", bundle.inspect_project(self.project))

    def test_package_product_copy_is_rejected_before_build(self):
        objects = self.project["objects"]
        objects["package-product"] = {"isa": "XCSwiftPackageProductDependency", "productName": "AetherLibzvbi"}
        objects["AetherLibzvbi-copy"] = {"isa": "PBXBuildFile", "productRef": "package-product"}
        with self.assertRaisesRegex(ValueError, "package product AetherLibzvbi"):
            bundle.inspect_project(self.project)

    def test_duplicate_or_missing_runtime_copies_are_rejected(self):
        for invalid_files in (["AetherLibzvbi-copy"], []):
            with self.subTest(invalid_files=invalid_files):
                project = copy.deepcopy(self.project)
                files = project["objects"]["LineupiOS-embed"]["files"]
                if invalid_files:
                    files.extend(invalid_files)
                else:
                    files.remove("AetherLibzvbi-copy")
                with self.assertRaisesRegex(ValueError, "LineupiOS: incorrect runtime copies"):
                    bundle.inspect_project(project)

    def test_mpv_bridge_must_be_linked_and_embedded_once(self):
        for phase, file_id in (("Lineup-link", "Lineup-mpv-link"),
                               ("Lineup-embed", "Lineup-mpv-copy")):
            with self.subTest(phase=phase):
                project = copy.deepcopy(self.project)
                project["objects"][phase]["files"].remove(file_id)
                with self.assertRaisesRegex(ValueError, "Lineup: MPV playback bridge"):
                    bundle.inspect_project(project)

    def test_mpv_bridge_must_be_signed_when_embedded(self):
        project = copy.deepcopy(self.project)
        project["objects"]["Lineup-mpv-copy"]["settings"]["ATTRIBUTES"].remove("CodeSignOnCopy")
        with self.assertRaisesRegex(ValueError, "Lineup: LineupMPVPlayback.framework must be signed"):
            bundle.inspect_project(project)

    def test_linking_a_runtime_or_copying_from_the_wrong_root_is_rejected(self):
        with self.subTest(problem="linkage"):
            project = copy.deepcopy(self.project)
            project["objects"]["Lineup-link"]["files"].append("AetherLibavcodec-copy")
            with self.assertRaisesRegex(ValueError, "without app linkage"):
                bundle.inspect_project(project)
        with self.subTest(problem="path"):
            project = copy.deepcopy(self.project)
            project["objects"]["AetherLibavcodec"]["sourceTree"] = "SOURCE_ROOT"
            with self.assertRaisesRegex(ValueError, "BUILT_PRODUCTS_DIR"):
                bundle.inspect_project(project)

    def test_explicit_resource_copy_is_rejected(self):
        objects = self.project["objects"]
        objects["resource"] = {"isa": "PBXFileReference", "path": "AetherEngine_AetherEngine.bundle"}
        objects["resource-copy"] = {"isa": "PBXBuildFile", "fileRef": "resource"}
        objects["Lineup-embed"]["files"].append("resource-copy")
        with self.assertRaisesRegex(ValueError, "duplicates Xcode's automatic task"):
            bundle.inspect_project(self.project)


if __name__ == "__main__":
    unittest.main()
