import XCTest
@testable import LineupiOS

/// A game's channel that would not start is tried after the others for a
/// few hours, and forgiven as soon as it shows a picture.
@MainActor
final class ChannelHealthTests: XCTestCase {
    private func stream(_ id: Int, _ name: String) throws -> XtreamStream {
        let json = #"{"stream_id":\#(id),"name":"\#(name)","epg_channel_id":"\#(name.lowercased()).us"}"#
        return try JSONDecoder().decode(XtreamStream.self, from: Data(json.utf8))
    }

    func testAChannelThatFailedIsTriedLastUntilItPlaysOrTimePasses() throws {
        let defaults = UserDefaults(suiteName: "ChannelHealthTests-\(UUID().uuidString)")!
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let health = ChannelHealth(defaults: defaults, clock: { now })
        let peacock = try stream(1, "Peacock 05"), usa = try stream(2, "USA Network"), nbc = try stream(3, "NBC")
        let channels = [peacock, usa, nbc]
        XCTAssertEqual(health.ordered(channels, stream: { $0 }).map(\.id), [1, 2, 3])

        health.failed(peacock)
        health.failed(usa)
        health.failed(usa)
        XCTAssertEqual(health.ordered(channels, stream: { $0 }).map(\.id), [3, 1, 2],
                       "Failed channels go last, the one that failed more often after the other")

        health.played(usa)
        XCTAssertEqual(health.ordered(channels, stream: { $0 }).map(\.id), [2, 3, 1], "A picture forgives at once")

        now = now.addingTimeInterval(ChannelHealth.memory + 1)
        XCTAssertFalse(health.isSuspect(peacock), "A failure counts for a few hours, not for good")
        XCTAssertEqual(ChannelHealth(defaults: defaults, clock: { now }).ordered(channels, stream: { $0 }).map(\.id), [1, 2, 3])
    }

    func testWhatWasLearnedIsKeptBetweenLaunches() throws {
        let defaults = UserDefaults(suiteName: "ChannelHealthTests-\(UUID().uuidString)")!
        let now = Date()
        let dead = try stream(9, "ESPN 2")
        ChannelHealth(defaults: defaults, clock: { now }).failed(dead)
        XCTAssertTrue(ChannelHealth(defaults: defaults, clock: { now }).isSuspect(dead))
    }
}
