"""Fast target-membership regressions; run on Windows and before SDK builds.

This checks the project's source-root declarations, not Swift type checking or
all XcodeGen options. The normal generated-project build remains required.
"""
import re
import json
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
SHARED = (
    "Lineup/Views/LiveQualityProgress.swift",
    "Lineup/Services/LiveSourceQuality.swift",
    "Lineup/Services/M3UPlaylist.swift",
    "Lineup/Services/MediaPlaybackRequest.swift",
    "Lineup/Services/SportsIndexFacts.swift",
    # IntroDB's skip prompts play on both: the phone's player and the TV's.
    "Lineup/Services/PlaybackSegments.swift",
    "Lineup/Services/IntroDB.swift",
    # Live stats and Auto Sync: beside the phone's picture and the TV's.
    "Lineup/Services/GameStatsFeed.swift",
    "Lineup/Services/GameStatsBoards.swift",
    "Lineup/Services/AutoSyncLogic.swift",
    "Lineup/Services/AutoSync.swift",
    "Lineup/Store/GameStats.swift",
    "Lineup/Design/GameStatsRows.swift",
    "Lineup/Design/GameStatsBoardViews.swift",
    # Team pages, Game Replays and Catch Up from a live game.
    "Lineup/Services/TeamPageFeed.swift",
    "Lineup/Services/TeamPageClient.swift",
    "Lineup/Services/TeamPageTarget.swift",
    "Lineup/Services/GameReplayPolicy.swift",
    "Lineup/Store/GameReplayStore.swift",
    "Lineup/Services/SportsCatchUp.swift",
    # Collections, BetterPosters, title logos.
    "Lineup/Models/LibraryCollection.swift",
    "Lineup/Services/BetterPosters.swift",
    "Lineup/Services/Fanart.swift",
    "Lineup/Services/FanartPolicy.swift",
    "Lineup/Models/MDBListTracking.swift",
    "Lineup/Services/MDBListTrackingClient.swift",
    "Lineup/Store/MDBListTrackingService.swift",
    "Lineup/Views/LibraryTrackingSettingsView.swift",
    # Subtitle settings, Find Subtitles Online, seek previews, per-show tracks.
    "Lineup/Services/SubtitlePreferences.swift",
    "Lineup/Services/TrackMemory.swift",
    "Lineup/Services/OpenSubtitles.swift",
    "Lineup/Services/SeekPreview.swift",
)


def source_roots(project, target):
    """Read this repository's two-space target/four-space property layout."""
    target_match = re.search(rf"^  {re.escape(target)}:\s*$", project, re.M)
    if target_match is None:
        raise ValueError(f"Missing target: {target}")
    following = project[target_match.end():]
    block = re.split(r"^  [^\s#][^\n]*:\s*$", following, maxsplit=1, flags=re.M)[0]
    sources = re.search(r"^    sources:\s*\n(.*?)(?=^    \S|\Z)", block, re.M | re.S)
    if sources is None:
        raise ValueError(f"Missing sources for target: {target}")
    return [PurePosixPath(value.strip().strip("\"'")) for value in re.findall(
        r"^      - (?:path: )?([^\n]+)", sources.group(1), re.M)]


def is_included(project, target, source):
    path = PurePosixPath(source)
    return any(root == path or root in path.parents for root in source_roots(project, target))


class SharedSourceMembershipChecks(unittest.TestCase):
    def test_search_genre_artwork_is_complete_on_both_platforms(self):
        source = (ROOT / "Lineup/Views/SearchViews.swift").read_text(encoding="utf-8")
        assets = re.findall(r'assetName: "(SearchGenre[^"]+)"', source)
        self.assertEqual(len(set(assets)), 18)
        for name in assets:
            copies = []
            for catalog in ("iPhone/Assets.xcassets", "Lineup/Assets.xcassets"):
                folder = ROOT / catalog / f"{name}.imageset"
                manifest = json.loads((folder / "Contents.json").read_text(encoding="utf-8"))
                image = (folder / manifest["images"][0]["filename"]).read_bytes()
                self.assertTrue(image.startswith(b"\xff\xd8"))
                self.assertGreater(len(image), 1000)
                copies.append(image)
            self.assertEqual(*copies, f"{name} must use the existing genre artwork on both devices")

    def test_mobile_library_rows_and_artwork_are_iphone_only(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        for source in ("iPhone/MobileLibraryShelf.swift", "iPhone/MobileLibraryArtwork.swift",
                       "iPhone/MobileLibraryCollections.swift",
                       "iPhone/MobileBetterPosters.swift", "iPhone/MobileGameReplaysView.swift",
                       "iPhone/MobileOnlineSubtitlesSheet.swift", "iPhone/MobileSubtitleSettings.swift",
                       "iPhone/MobileFanartTitle.swift", "iPhone/MobileWelcomeRowMotion.swift",
                       "iPhone/MobileWelcomePosterBackdrop.swift", "iPhone/MobileNavigationScrollObserver.swift",
                       "iPhone/MobileGuideDefaultCategory.swift"):
            self.assertTrue((ROOT / source).is_file())
            self.assertTrue(is_included(project, "LineupiOS", source))
            self.assertFalse(is_included(project, "Lineup", source))
        self.assertTrue(is_included(project, "LineupiOSTests", "Tests/iOS/MobileLibraryShelfTests.swift"))
        self.assertTrue(is_included(project, "LineupiOSTests", "Tests/iOS/MobileLibraryFeaturesTests.swift"))
        self.assertTrue(is_included(project, "LineupiOSTests", "Tests/iOS/MobileGameReplayTests.swift"))
        self.assertTrue(is_included(project, "LineupiOSTests", "Tests/iOS/MobileSportsCatchUpTests.swift"))
        self.assertTrue(is_included(project, "LineupiOSTests", "Tests/iOS/MobileOpenSubtitlesTests.swift"))
        self.assertTrue(is_included(project, "LineupiOSTests", "Tests/iOS/MobilePlayerPolishTests.swift"))
        self.assertTrue(is_included(project, "LineupiOSTests", "Tests/iOS/MobileReplaySeekingTests.swift"))
        self.assertTrue(is_included(project, "LineupiOSTests", "Tests/iOS/MobileSegmentAndFanartTests.swift"))

    def test_shared_compatibility_sources_belong_to_both_apps(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        for target in ("Lineup", "LineupiOS"):
            for source in SHARED:
                with self.subTest(target=target, source=source):
                    self.assertTrue((ROOT / source).is_file())
                    self.assertTrue(is_included(project, target, source), f"{target} omits {source}")

    def test_tracking_regressions_belong_to_both_test_suites(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        source = "Tests/iOS/MDBListTrackingTests.swift"
        self.assertTrue((ROOT / source).is_file())
        for target in ("LineupTests", "LineupiOSTests"):
            self.assertTrue(is_included(project, target, source))

    def test_both_frameworks_include_the_probe_implementation(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        for target in ("LineupAetherPlayback", "LineupAetherPlaybackiOS"):
            self.assertTrue(is_included(project, target, "AetherPlayback/AetherSourceProbe.swift"))

    def test_reproduces_iphone_109_missing_view(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        original = project.replace("      - Lineup/Views/LiveQualityProgress.swift\n", "")
        self.assertFalse(is_included(original, "LineupiOS", SHARED[0]))
        self.assertTrue(is_included(original, "Lineup", SHARED[0]))

    def test_a_similar_prefix_does_not_include_a_source(self):
        project = "targets:\n  App:\n    sources:\n      - Lineup/Views/Other.swift\n    dependencies: []\n"
        self.assertFalse(is_included(project, "App", SHARED[0]))
        self.assertTrue(is_included(project, "App", "Lineup/Views/Other.swift"))


if __name__ == "__main__":
    unittest.main()
