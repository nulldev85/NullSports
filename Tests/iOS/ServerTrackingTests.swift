import XCTest
@testable import LineupiOS

/// Progress kept with a Jellyfin, Emby or AIOStreams server: what Lineup
/// sends it, and what it reads back.
final class ServerTrackingTests: XCTestCase {
    func testAReportIsWhatJellyfinsSessionAPITakes() throws {
        let report = JellyfinClient.PlaybackReport(itemID: "episode-7", mediaSourceID: "source-1",
            playSessionID: "session", positionTicks: 12_345_000_000, isPaused: true, eventName: "Pause")
        let data = try JSONEncoder().encode(report)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["ItemId"] as? String, "episode-7")
        XCTAssertEqual(body["MediaSourceId"] as? String, "source-1")
        XCTAssertEqual(body["PlaySessionId"] as? String, "session")
        XCTAssertEqual((body["PositionTicks"] as? NSNumber)?.int64Value, 12_345_000_000)
        XCTAssertEqual(body["IsPaused"] as? Bool, true)
        XCTAssertEqual(body["EventName"] as? String, "Pause")
        XCTAssertEqual(body["CanSeek"] as? Bool, true)
        XCTAssertEqual(body["PlayMethod"] as? String, "DirectPlay")
    }

    func testAReportWithoutASourceOrEventLeavesThemOut() throws {
        let report = JellyfinClient.PlaybackReport(itemID: "film", mediaSourceID: nil,
            playSessionID: "session", positionTicks: 0, isPaused: false)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertNil(body["MediaSourceId"])
        XCTAssertNil(body["EventName"])
    }

    /// Jellyfin writes seven fractional digits, which ISO 8601 parsing
    /// refuses; the seconds are read regardless.
    func testTheServersLastPlayedDateIsRead() throws {
        let json = #"{"Played":false,"PlaybackPositionTicks":18000000000,"LastPlayedDate":"2026-11-04T21:15:42.1234567Z"}"#
        let data = try JSONDecoder().decode(MediaUserData.self, from: Data(json.utf8))
        XCTAssertEqual(data.playbackPositionTicks, 18_000_000_000)
        let expected = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                      year: 2026, month: 11, day: 4, hour: 21, minute: 15, second: 42).date
        XCTAssertEqual(data.lastPlayed, expected)
    }

    func testOlderRecordsWithoutTheNewFieldsStillDecode() throws {
        let json = #"{"Played":true,"IsFavorite":false,"PlayedPercentage":100}"#
        let data = try JSONDecoder().decode(MediaUserData.self, from: Data(json.utf8))
        XCTAssertNil(data.playbackPositionTicks)
        XCTAssertNil(data.lastPlayed)
    }
}
