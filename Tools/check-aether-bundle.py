#!/usr/bin/env python3
"""Validate the packaged Aether runtime, not just its successful link step."""
import json
import plistlib
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path


RUNTIME_FRAMEWORKS = (
    "AetherLibavcodec", "AetherLibavformat", "AetherLibavutil",
    "AetherLibswresample", "AetherLibswscale", "AetherLibavfilter",
    "AetherLibdav1d", "AetherLibzimg", "AetherLibzvbi",
)


def inspect_project(project):
    """Check XcodeGen's actual copy/link phases before the expensive build."""
    objects = project["objects"]
    expected = Counter(f"{name}.framework" for name in RUNTIME_FRAMEWORKS)
    checked = set()
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget" or target.get("name") not in ("Lineup", "LineupiOS"):
            continue
        name = target["name"]
        checked.add(name)
        copies = Counter()
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            for file_id in phase.get("files", []):
                build_file = objects[file_id]
                reference = objects.get(build_file.get("fileRef"), {})
                product = objects.get(build_file.get("productRef"), {}).get("productName", "")
                path = reference.get("path", "")
                if product.startswith("Aether"):
                    raise ValueError(f"{name}: Aether package product {product} must stay inside the bridge")
                if Path(path).name == "AetherEngine_AetherEngine.bundle":
                    raise ValueError(f"{name}: explicit Aether resource copy duplicates Xcode's automatic task")
                if Path(path).name not in expected:
                    continue
                if phase["isa"] == "PBXFrameworksBuildPhase":
                    raise ValueError(f"{name}: runtime {path} must be embedded without app linkage")
                if phase["isa"] != "PBXCopyFilesBuildPhase" or str(phase.get("dstSubfolderSpec")) != "10":
                    raise ValueError(f"{name}: {path} must be copied into Frameworks")
                if reference.get("sourceTree") != "BUILT_PRODUCTS_DIR" or path != Path(path).name:
                    raise ValueError(f"{name}: {path} must use the processed framework in BUILT_PRODUCTS_DIR")
                attributes = build_file.get("settings", {}).get("ATTRIBUTES", [])
                if "CodeSignOnCopy" not in attributes:
                    raise ValueError(f"{name}: {path} must be signed when embedding a signed app")
                copies[path] += 1
        if copies != expected:
            raise ValueError(f"{name}: incorrect runtime copies: missing={dict(expected - copies)}, duplicate={dict(copies - expected)}")
    if checked != {"Lineup", "LineupiOS"}:
        raise ValueError("Both app targets must be checked for Aether packaging")
    return "Aether project passed: both app targets copy nine real frameworks once, without app linkage."


def bundled_files(app):
    app = Path(app)
    images = [app / "Frameworks" / f"{name}.framework" / name
              for name in ("LineupAetherPlayback", *RUNTIME_FRAMEWORKS)]
    notices = app / "Frameworks/LineupAetherPlayback.framework/AetherLicenses/AetherEngine.txt"
    missing = [path.relative_to(app).as_posix() for path in [*images, notices] if not path.is_file()]
    bundles = list(app.rglob("AetherEngine_AetherEngine.bundle"))
    if not any((bundle / "silent-atmos.mp4").is_file() for bundle in bundles):
        missing.append("AetherEngine_AetherEngine.bundle/silent-atmos.mp4")
    if missing:
        raise ValueError("Missing packaged Aether files:\n  " + "\n  ".join(missing))
    with (app / "Info.plist").open("rb") as handle:
        minimum = str(plistlib.load(handle).get("MinimumOSVersion", ""))
    if minimum != "18.0":
        raise ValueError(f"Expected iOS/tvOS 18.0 minimum, found {minimum!r}")
    return images


def inspect_macho(app, images, run=subprocess.check_output):
    bridge = images[0]
    symbols = run(["nm", "-m", str(bridge)], text=True)
    binding = next((line.strip() for line in symbols.splitlines()
                    if re.search(r"_avcodec_open2\b.*\(from AetherLibavcodec\)", line)), None)
    if not binding:
        raise ValueError("Aether's avcodec_open2 is not bound to AetherLibavcodec")
    missing = set()
    for image in images:
        dependencies = run(["otool", "-L", str(image)], text=True)
        for line in dependencies.splitlines()[1:]:
            name = line.strip().split(" (", 1)[0]
            if name.startswith("@rpath/") and ".framework/" in name:
                relative = name.removeprefix("@rpath/")
                if not (Path(app) / "Frameworks" / relative).is_file():
                    missing.add(f"{image.name} requires {relative}")
    if missing:
        raise ValueError("Unresolved embedded framework dependencies:\n  " + "\n  ".join(sorted(missing)))
    return binding


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--project":
        data = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", sys.argv[2]], text=True)
        print(inspect_project(json.loads(data)))
        return
    if len(sys.argv) != 2:
        raise ValueError("Usage: check-aether-bundle.py path/to/Lineup.app | --project path/to/project.pbxproj")
    app = Path(sys.argv[1])
    images = bundled_files(app)
    print(inspect_macho(app, images))
    print(f"Aether bundle passed: {len(RUNTIME_FRAMEWORKS)} runtime frameworks, resources, notices, and OS minimum.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
