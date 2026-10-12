import XCTest
@testable import LineupiOS

/// Catch-up: which channels the provider records, how a recording is
/// addressed, and what the provider's own table of past programmes says.
final class CatchUpTests: XCTestCase {
    /// 19:30 UTC on 9 March 2024.
    private let evening = Date(timeIntervalSince1970: 1_710_012_600)

    func testAChannelSaysItIsRecordedHoweverThePanelWritesIt() throws {
        let json = """
        [{"num":1,"name":"Sports","stream_type":"live","stream_id":42,"stream_icon":null,
          "epg_channel_id":"sports.us","category_id":"7","tv_archive":"1","tv_archive_duration":"7"},
         {"num":2,"name":"Numbers","stream_type":"live","stream_id":43,"stream_icon":"",
          "epg_channel_id":null,"category_id":"7","tv_archive":1,"tv_archive_duration":3},
         {"num":3,"name":"Plain","stream_type":"live","stream_id":44,"stream_icon":"",
          "epg_channel_id":null,"category_id":"7"}]
        """
        let streams = try JSONDecoder().decode([XtreamStream].self, from: Data(json.utf8))
        XCTAssertEqual(streams.map(\.hasCatchUp), [true, true, false])
        XCTAssertEqual(streams.map(\.archiveDays), [7, 3, 0])
        // And reads back the same from the app's own cache.
        let again = try JSONDecoder().decode([XtreamStream].self, from: JSONEncoder().encode(streams))
        XCTAssertEqual(again, streams)
    }

    func testARecordingIsAddressedInTheServersOwnTime() {
        let zone = TimeZone(secondsFromGMT: 3600)!
        XCTAssertEqual(CatchUpPolicy.addressStamp(evening, in: zone), "2024-03-09:20-30")
        XCTAssertEqual(CatchUpPolicy.addressStamp(evening, in: TimeZone(secondsFromGMT: 0)!), "2024-03-09:19-30")
    }

    func testARecordingIsAskedForInWholeMinutesWithAMinutesGrace() {
        let start = evening.addingTimeInterval(40)
        XCTAssertEqual(CatchUpPolicy.minute(start), evening)
        XCTAssertEqual(CatchUpPolicy.minutes(from: evening, to: evening.addingTimeInterval(90 * 60)), 91)
        XCTAssertEqual(CatchUpPolicy.minutes(from: start, to: evening.addingTimeInterval(60)), 2)
    }

    func testTheRecordingsPathFormIsTriedFirstAndTheScriptFormAfter() throws {
        let client = XtreamClient(profile: XtreamProfile(name: "Provider", serverURL: "http://tv.example:8080",
                                                         username: "user"), password: "secret")
        let stream = XtreamStream(num: nil, name: "Sports", streamType: "live", streamID: 42, streamIcon: nil,
                                  epgChannelID: nil, categoryID: nil, tvArchive: true, archiveDays: 7)
        let urls = client.catchUpURLs(for: stream, from: evening, minutes: 91,
                                      serverTimeZone: TimeZone(secondsFromGMT: 3600)!)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].host, "tv.example")
        XCTAssertEqual(urls[0].path, "/timeshift/user/secret/91/2024-03-09:20-30/42.ts")
        let script = try XCTUnwrap(URLComponents(url: urls[1], resolvingAgainstBaseURL: false))
        XCTAssertEqual(script.path, "/streaming/timeshift.php")
        let query = Dictionary(uniqueKeysWithValues: (script.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["stream"], "42")
        XCTAssertEqual(query["start"], "2024-03-09:20-30")
        XCTAssertEqual(query["duration"], "91")
        XCTAssertEqual(query["username"], "user")
    }

    func testThePastProgrammesTableReadsEncodedTitlesAndBothClocks() throws {
        let json = """
        {"epg_listings":[
          {"id":"1","title":"R2FtZSBEYXk=","description":"UHJldmlldw==","start":"2024-03-09 20:30:00",
           "end":"2024-03-09 22:00:00","start_timestamp":"1710012600","stop_timestamp":"1710018000","has_archive":1},
          {"title":"Plain title","description":"","start_timestamp":1710018000,"stop_timestamp":1710021600,
           "has_archive":"0"},
          {"title":"No times at all"}
        ]}
        """
        let table = try JSONDecoder().decode(XtreamArchiveTable.self, from: Data(json.utf8))
        XCTAssertEqual(table.listings.count, 2)
        XCTAssertEqual(table.listings[0].title, "Game Day")
        XCTAssertEqual(table.listings[0].detail, "Preview")
        XCTAssertEqual(table.listings[0].start, evening)
        XCTAssertTrue(table.listings[0].hasArchive)
        XCTAssertEqual(table.listings[1].title, "Plain title")
        XCTAssertFalse(table.listings[1].hasArchive)
        // 20:30 on the server's clock at 19:30 UTC: an hour ahead.
        XCTAssertEqual(table.serverTimeZone?.secondsFromGMT(for: evening), 3600)
    }

    func testTheServersTimeZoneIsReadByNameOrWorkedOutFromItsClock() {
        let named = XtreamServerInfo(timezone: "Europe/London", timestampNow: nil, timeNow: nil)
        XCTAssertEqual(named.timeZone?.identifier, "Europe/London")
        // 14:30 on the server's clock at 19:30 UTC: five hours behind.
        let clocked = XtreamServerInfo(timezone: "Nowhere/Zone", timestampNow: 1_710_012_600,
                                       timeNow: "2024-03-09 14:30:00")
        XCTAssertEqual(clocked.timeZone?.secondsFromGMT(for: evening), -5 * 3600)
        XCTAssertNil(XtreamServerInfo(timezone: nil, timestampNow: nil, timeNow: nil).timeZone)
    }

    func testARecordingsPlaceIsTheMinuteItStartsFromPlusWhatHasPlayed() {
        let timeline = CatchUpTimeline(programmeStart: evening, programmeEnd: evening.addingTimeInterval(3600),
                                       title: "Game Day", streamStart: evening.addingTimeInterval(600))
        XCTAssertEqual(timeline.position(playedSeconds: 90), evening.addingTimeInterval(690))
        XCTAssertEqual(timeline.fraction(at: evening.addingTimeInterval(1800)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(timeline.fraction(at: evening.addingTimeInterval(-60)), 0)
    }
}
