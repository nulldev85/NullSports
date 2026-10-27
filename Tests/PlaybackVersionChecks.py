"""Keep the displayed engine versions in sync with the shared SPM pins."""
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def package_version(project, package):
    match = re.search(
        rf"(?m)^  {re.escape(package)}:\s*\n    url: [^\n]+\n    exactVersion: ([^\n]+)",
        project,
    )
    if not match:
        raise AssertionError(f"Missing exact package version for {package}")
    return match.group(1).strip().strip('"')


def main():
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    source = (ROOT / "Lineup/Models/PlaybackEngineVersions.swift").read_text(encoding="utf-8")
    displayed = dict(re.findall(r'static let (aether|vlc|mpv) = "([^"]+)"', source))
    expected = {
        "AetherEngine": "aether",
        "VLCKitSPM": "vlc",
        "MPVKit": "mpv",
    }
    for package, key in expected.items():
        pin = package_version(project, package)
        if displayed.get(key) != pin:
            raise AssertionError(f"{package} pin {pin} does not match displayed version {displayed.get(key)!r}")

    if package_version(project, "AetherEngine") != "7.49.0":
        raise AssertionError("Both app targets must stay on the requested AetherEngine release")
    if package_version(project, "FFmpegBuild") != "3.10.1":
        raise AssertionError("AetherEngine 7.49.0 requires the aligned FFmpegBuild 3.10.1 pin")
    print("Playback package pins match the engine versions displayed in Settings.")


if __name__ == "__main__":
    main()
