import XCTest
@testable import LineupiOS

/// When opening the Media Servers tab starts a load.
///
/// The tab had two failure modes and this rule is where both are settled: a
/// spinner that never ended, and a library that was never fetched at all.
final class MediaShelfLoadTests: XCTestCase {
    private let server = UUID()
    private let other = UUID()

    func testAProviderWithNothingLoadedLoads() {
        XCTAssertTrue(MediaShelfLoad.shouldStart(profile: server, loaded: nil,
                                                 alreadyRunning: false, lastAttemptFailed: false))
    }

    // The case that made the tab feel slow: coming back to shelves that are
    // already on screen re-fetched every library and every catalog in it.
    func testShelvesAlreadyOnScreenAreLeftAlone() {
        XCTAssertFalse(MediaShelfLoad.shouldStart(profile: server, loaded: server,
                                                  alreadyRunning: false, lastAttemptFailed: false))
    }

    // The case that made it unreliable: an attempt that failed -- a server
    // asleep, a phone on the wrong network -- left the tab empty with nothing
    // that would ever try again.
    func testAFailedAttemptIsRetriedOnTheNextLook() {
        XCTAssertTrue(MediaShelfLoad.shouldStart(profile: server, loaded: server,
                                                 alreadyRunning: false, lastAttemptFailed: true))
    }

    // Including after a failure: a load in flight is the retry.
    func testNothingStartsOnTopOfALoadAlreadyRunning() {
        XCTAssertFalse(MediaShelfLoad.shouldStart(profile: server, loaded: nil,
                                                  alreadyRunning: true, lastAttemptFailed: false))
        XCTAssertFalse(MediaShelfLoad.shouldStart(profile: server, loaded: server,
                                                  alreadyRunning: true, lastAttemptFailed: true))
    }

    func testSwitchingProviderLoadsTheNewOne() {
        XCTAssertTrue(MediaShelfLoad.shouldStart(profile: other, loaded: server,
                                                 alreadyRunning: false, lastAttemptFailed: false))
    }
}

/// The size artwork is decoded at.
final class ArtSizeTests: XCTestCase {
    // Decoding to the drawn size is the whole saving, so the pixel count has
    // to follow the width it is given rather than the file the server sent.
    func testPixelsFollowTheDrawnWidth() {
        XCTAssertGreaterThan(LineupArt.pixels(for: 210), LineupArt.pixels(for: 44))
        XCTAssertGreaterThanOrEqual(LineupArt.pixels(for: 44), 44)
    }

    // A badge drawn at a handful of points still needs enough pixels to read.
    func testTinyArtStillGetsAFloor() {
        XCTAssertGreaterThanOrEqual(LineupArt.pixels(for: 1), 32)
    }
}
