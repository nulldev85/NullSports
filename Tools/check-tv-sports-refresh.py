"""Run sports refresh/coverage regressions using real Foundation models.

No Apple SDK is needed. UI/store integration still runs in the tvOS suite.
The temporary package compiles the same helper and XCTest source as the app.
The helper's outer tvOS guard and the model's unused SwiftUI color convenience
are removed in the temporary host package; Foundation logic stays unchanged.
Host copies resolve bundled directories/fixtures through SwiftPM's resource
bundle and import FoundationNetworking on Linux. Phone checks also compile
the actual expanded-sports client, date parser, alert rules and scoring methods.
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
    "Lineup/Services/LivePreparationWork.swift",
    "Lineup/Services/GuideChannelList.swift",
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
    parser.add_argument("--phone", action="store_true", help="Also run iPhone catalog, tennis and persistence regressions")
    parser.add_argument("--identity-from", type=Path, help="Replay the tennis regression with a previous identity policy")
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
        for name in ("SportsTeams.json", "SportsCompetitions.json"):
            shutil.copyfile(ROOT / "Lineup/Resources" / name, source / name)
        for name in ("SportsTeamDirectory.swift", "SportsExpansionModels.swift"):
            path = source / name
            path.write_text(path.read_text(encoding="utf-8").replace("Bundle.main.url(forResource:",
                "Bundle.module.url(forResource:"), encoding="utf-8")
        fixture_directory = tests / "Fixtures"
        fixture_directory.mkdir()
        for path in (ROOT / "Tests/tvOS/Fixtures").glob("*.json"):
            shutil.copyfile(path, fixture_directory / path.name)
        if args.identity_from:
            pattern = r"(?ms)^    static func identity\(for game: SportsGame\).*?^    }"
            previous = re.search(pattern, args.identity_from.read_text(encoding="utf-8-sig"))[0]
            match_model = source / "PreparedLiveMatches.swift"
            text, count = re.subn(pattern, lambda _: previous, match_model.read_text(encoding="utf-8"))
            assert count == 1
            match_model.write_text(text, encoding="utf-8")
        if args.phone:
            for name in ("iPhone/MobileCombinedCatalog.swift", "iPhone/MobileAudioSessionWork.swift", "Lineup/Services/ExpandedSportsChannelMatcher.swift",
                         "Lineup/Services/EventChannelEvidence.swift", "Lineup/Services/ChannelLanguage.swift"):
                shutil.copyfile(ROOT / name, source / Path(name).name)
            expanded = (ROOT / "Lineup/Services/ExpandedSportsScheduleClient.swift").read_text(encoding="utf-8")
            (source / "ExpandedSportsScheduleClient.swift").write_text(
                expanded.replace("import Foundation", "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif", 1),
                encoding="utf-8")
            schedule = (ROOT / "Lineup/Services/SportsScheduleClient.swift").read_text(encoding="utf-8")
            snapshot = re.search(r"(?ms)^    struct Snapshot: Sendable \{.*?^    }", schedule)[0]
            dates = schedule[schedule.index("    private static let internetDate"):
                             schedule.index("    private static func path")]
            (source / "SportsScheduleClient.swift").write_text(
                "import Foundation\nstruct SportsScheduleClient {\n" + snapshot + "\n" + dates + "\n}", encoding="utf-8")
            alerts = (ROOT / "Lineup/Services/GameAlerts.swift").read_text(encoding="utf-8")
            (source / "GameAlertRules.swift").write_text(
                alerts[:alerts.index("@MainActor\nfinal class GameAlertCenter")], encoding="utf-8")
            expanded_tests = (ROOT / "Tests/iOS/ExpandedSportsTests.swift").read_text(encoding="utf-8")
            (tests / "ExpandedSportsTests.swift").write_text(
                expanded_tests.replace("@testable import LineupiOS", "@testable import Lineup")
                    .replace("Bundle(for: Self.self)", "Bundle.module"), encoding="utf-8")
            # Compile the actual pure scoring methods from the store, without
            # importing the UI, account stores or playback frameworks.
            library = (ROOT / "Lineup/Store/SportsLibrary.swift").read_text(encoding="utf-8")
            scoring = library[library.index("    nonisolated private static func collegeMatchup"):
                              library.index("    /// Match today's games to channels.")]
            tournament = library[library.index("    nonisolated static func isArchive"):
                                 library.index("    func games(for league:")]
            (source / "SportsLibraryScoring.swift").write_text(
                "import Foundation\nenum SportsLibrary {\n" + tournament + scoring + "\n}", encoding="utf-8")
            regression = (ROOT / "Tests/iOS/SportsRefreshRegressionTests.swift").read_text(encoding="utf-8")
            (tests / "SportsRefreshRegressionTests.swift").write_text(
                regression.replace("@testable import LineupiOS", "@testable import Lineup"), encoding="utf-8")
            shutil.copyfile(ROOT / "Tests/iOS/AudioSessionResponsivenessTests.swift", tests / "AudioSessionResponsivenessTests.swift")
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
    .target(name: "Lineup", resources: [.copy("SportsTeams.json"), .copy("SportsCompetitions.json")]),
    .testTarget(name: "LineupTests", dependencies: ["Lineup"], resources: [.copy("Fixtures")])
], swiftLanguageVersions: [.v5])
''', encoding="utf-8")
        env = os.environ.copy()
        env["SWIFTPM_BUILD_PARALLELISM"] = "2"
        subprocess.run([args.swift, "test", "--package-path", str(package), "--jobs", "2"],
                       env=env, check=True)


if __name__ == "__main__":
    main()
