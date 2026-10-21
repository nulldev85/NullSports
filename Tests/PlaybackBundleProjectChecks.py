"""Regression coverage for XcodeGen's tvOS and iOS playback bridge names."""
import importlib.util
from pathlib import Path


CHECKER_PATH = Path(__file__).resolve().parents[1] / "Tools" / "check-aether-bundle.py"
SPEC = importlib.util.spec_from_file_location("playback_bundle_checker", CHECKER_PATH)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def synthetic_project(ios_product_name):
    objects = {}
    expected_runtimes = CHECKER.RUNTIME_FRAMEWORKS
    for target_name, product_name in (
        ("Lineup", "LineupMPVPlayback"),
        ("LineupiOS", ios_product_name),
    ):
        link_phase_id = f"{target_name}-frameworks"
        copy_phase_id = f"{target_name}-copy"
        link_file_id = f"{target_name}-mpv-link"
        copy_file_id = f"{target_name}-mpv-copy"
        product_ref_id = f"{target_name}-mpv-product"
        objects[link_phase_id] = {"isa": "PBXFrameworksBuildPhase", "files": [link_file_id]}
        objects[copy_phase_id] = {
            "isa": "PBXCopyFilesBuildPhase",
            "dstSubfolderSpec": "10",
            "files": [copy_file_id],
        }
        objects[link_file_id] = {"isa": "PBXBuildFile", "productRef": product_ref_id}
        objects[copy_file_id] = {
            "isa": "PBXBuildFile",
            "productRef": product_ref_id,
            "settings": {"ATTRIBUTES": ["CodeSignOnCopy"]},
        }
        objects[product_ref_id] = {
            "isa": "PBXReferenceProxy",
            "name": f"{product_name}.framework",
            "path": "LineupMPVPlayback.framework",
            "productName": product_name,
        }

        for index, runtime in enumerate(expected_runtimes):
            reference_id = f"{target_name}-runtime-ref-{index}"
            file_id = f"{target_name}-runtime-file-{index}"
            objects[reference_id] = {
                "isa": "PBXFileReference",
                "path": f"{runtime}.framework",
                "sourceTree": "BUILT_PRODUCTS_DIR",
            }
            objects[file_id] = {
                "isa": "PBXBuildFile",
                "fileRef": reference_id,
                "settings": {"ATTRIBUTES": ["CodeSignOnCopy"]},
            }
            objects[copy_phase_id]["files"].append(file_id)

        target_id = f"{target_name}-target"
        objects[target_id] = {
            "isa": "PBXNativeTarget",
            "name": target_name,
            "buildPhases": [link_phase_id, copy_phase_id],
        }
    return {"objects": objects}


def main():
    # XcodeGen may expose the product name or the iOS-specific target name in
    # PBXReferenceProxy. Both must resolve to the same embedded framework.
    for ios_name in ("LineupMPVPlayback", "LineupMPVPlaybackiOS"):
        CHECKER.inspect_project(synthetic_project(ios_name))
    print("Playback project checker accepts both XcodeGen MPV bridge product names.")


if __name__ == "__main__":
    main()
