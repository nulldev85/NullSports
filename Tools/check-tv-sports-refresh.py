"""Run TV refresh/concurrency regressions using real Foundation models.

No Apple SDK is needed. UI/store integration still runs in the tvOS suite.
The temporary package compiles the same helper and XCTest source as the app.
The helper's outer tvOS guard and the model's unused SwiftUI color convenience
are removed in the temporary host package; Foundation logic stays unchanged.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "Lineup/Models/XtreamModels.swift", "Lineup/Models/SportsExpansionModels.swift",
    "Lineup/Models/CatchUp.swift", "Lineup/Models/LiveEventChannel.swift",
    "Lineup/Services/TeamChannelPreferences.swift", "Lineup/Services/FollowedTeams.swift",
    "Lineup/Services/SportsTeamDirectory.swift", "Lineup/Services/ProfessionalChannelMatcher.swift",
    "Lineup/Services/DailyGameMatches.swift", "Lineup/Services/LiveChannelQuality.swift",
    "Lineup/Services/CollegeChannelMatcher.swift", "Lineup/Services/PreparedLiveMatches.swift",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default=shutil.which("swift"))
    args = parser.parse_args()
    if not args.swift:
        parser.error("Swift is required; pass --swift /path/to/swift")
    # Keep generated packages outside the repository, including .build output.
    with tempfile.TemporaryDirectory(prefix="lineup-tv-refresh-") as scratch:
        package = Path(scratch)
        source = package / "Sources/Lineup"
        tests = package / "Tests/LineupTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        for name in SOURCES:
            shutil.copyfile(ROOT / name, source / Path(name).name)
        # A macOS host can import SwiftUI, but these Foundation checks do not
        # load the app's theme. Omit only the UI import/property from its copy.
        models = source / "XtreamModels.swift"
        text = models.read_text(encoding="utf-8")
        text, imports = re.subn(r"(?m)^#if canImport\(SwiftUI\)\nimport SwiftUI\n#endif\n", "", text)
        text, colors = re.subn(r"(?m)^    #if canImport\(SwiftUI\)\n    var color: Color.*?\n    #endif\n", "", text)
        assert imports == 1 and colors == 1
        models.write_text(text, encoding="utf-8")
        vod = (ROOT / "Lineup/Models/XtreamVODModels.swift").read_text(encoding="utf-8")
        helpers = "\n".join(re.search(pattern, vod, re.M | re.S)[0] for pattern in (
            r"^struct Lenient<.*?^}", r"^extension KeyedDecodingContainer \{.*?^}"))
        (source / "DecoderHelpers.swift").write_text("import Foundation\n" + helpers, encoding="utf-8")
        helper = (ROOT / "Lineup/Services/TVSportsRefreshWork.swift").read_text(encoding="utf-8")
        assert helper.startswith("#if os(tvOS)\n") and helper.endswith("#endif\n")
        (source / "TVSportsRefreshWork.swift").write_text(
            helper.removeprefix("#if os(tvOS)\n").removesuffix("#endif\n"), encoding="utf-8")
        shutil.copyfile(ROOT / "Tests/tvOS/TVSportsRefreshTests.swift", tests / "TVSportsRefreshTests.swift")
        (package / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LineupTVRefreshChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "Lineup"), .testTarget(name: "LineupTests", dependencies: ["Lineup"])
], swiftLanguageVersions: [.v5])
''', encoding="utf-8")
        env = os.environ.copy()
        env["SWIFTPM_BUILD_PARALLELISM"] = "2"
        subprocess.run([args.swift, "test", "--package-path", str(package), "--jobs", "2"],
                       env=env, check=True)


if __name__ == "__main__":
    main()
