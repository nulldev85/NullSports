import XCTest
@testable import LineupiOS

final class SubtitleTrackTests: XCTestCase {
    func testVLCTracksAlwaysHaveOneOffChoiceAndSkipItsSyntheticTrack() {
        let tracks = PlaybackSubtitleTrack.vlcTracks(
            names: ["Disabled", "English", "Español"],
            indexes: [-1, 4, 8]
        )

        XCTAssertEqual(tracks.map(\.title), ["Off", "English", "Español"])
        XCTAssertEqual(tracks.map(\.engineIndex), [nil, 4, 8])
    }

    func testVLCTracksStayAlignedWhenAContainerReportsDuplicates() {
        let tracks = PlaybackSubtitleTrack.vlcTracks(
            names: ["Off", "English", "English duplicate"],
            indexes: [-1, 2, 2]
        )

        XCTAssertEqual(tracks.map(\.id), ["off", "vlc-2"])
    }

    func testUntitledTrackStillGetsAUsefulNativeLabel() {
        let tracks = PlaybackSubtitleTrack.vlcTracks(names: ["", "French"], indexes: [3, 7])

        XCTAssertEqual(tracks[1].title, "Subtitle 1")
        XCTAssertEqual(tracks[2].title, "French")
    }
}
