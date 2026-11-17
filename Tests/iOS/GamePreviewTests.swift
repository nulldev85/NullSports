import XCTest
@testable import LineupiOS

/// The page a game still to come opens: its day, and each side's form.
final class GamePreviewTests: XCTestCase {
    private func game(_ day: Int, _ state: String, _ outcome: TeamPageGame.Outcome?) -> TeamPageGame {
        TeamPageGame(id: "\(day)", date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                     opponent: "Them", opponentAbbreviation: "THM", opponentLogo: nil, isHome: true,
                     state: state, teamScore: nil, opponentScore: nil, outcome: outcome, status: "",
                     broadcast: nil, label: nil)
    }

    func testFormIsTheLastFiveGamesPlayedOldestFirst() {
        let games = [game(7, "post", .win), game(1, "post", .loss), game(3, "post", .win), game(2, "post", .win),
                     game(5, "post", .loss), game(6, "post", .win), game(9, "pre", nil), game(4, "post", .tie)]
        XCTAssertEqual(MobileGamePreview.lastResults(games), [.win, .tie, .loss, .win, .win])
        XCTAssertEqual(MobileGamePreview.lastResults(games).count, 5, "A game still to come is not form")
        XCTAssertEqual(MobileGamePreview.lastResults(games).last, .win, "The most recent is last")
        XCTAssertEqual(MobileGamePreview.lastResults([game(1, "post", .loss)]), [.loss])
    }

    func testTheDayIsSaidThePlainestWay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9)))
        func later(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
        XCTAssertEqual(MobileGamePreview.day(of: later(2), now: now, calendar: calendar), "Today")
        XCTAssertEqual(MobileGamePreview.day(of: later(26), now: now, calendar: calendar), "Tomorrow")
        XCTAssertNotEqual(MobileGamePreview.day(of: later(72), now: now, calendar: calendar), "Tomorrow")
    }
}

/// A playlist's feeds of the network a game is on, for when the guide does
/// not name the game yet.
final class NetworkChannelFallbackTests: XCTestCase {
    private func game(broadcast: String, startingIn hours: Double = 20) throws -> SportsGame {
        let payload: [String: Any] = [
            "id": "g", "league": "ncaab", "start": Date().addingTimeInterval(hours * 3600).timeIntervalSinceReferenceDate,
            "awayTeam": "Rutgers Scarlet Knights", "homeTeam": "Houston Cougars",
            "awayAbbreviation": "RUTG", "homeAbbreviation": "HOU", "awayLogo": "", "homeLogo": "",
            "awayScore": "0", "homeScore": "0", "status": "Scheduled", "state": "pre", "broadcast": broadcast
        ]
        return try JSONDecoder().decode(SportsGame.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func channel(_ id: Int, _ name: String, guide: String? = nil, type: String = "live") -> XtreamStream {
        XtreamStream(num: id, name: name, streamType: type, streamID: id, streamIcon: nil,
                     epgChannelID: guide, categoryID: nil)
    }

    func testTheNetworksFeedsAreOfferedAndOthersLeftOut() throws {
        let game = try game(broadcast: "ESPN")
        let streams = [channel(1, "US: ESPN FHD"), channel(2, "US: ESPN 4K"), channel(3, "US: ESPN2"),
                       channel(4, "US: FS1"), channel(5, "ESPN+ 23: Wilson vs Delaware"),
                       channel(6, "ESPN Radio", type: "radio_streams"), channel(7, "ESPN News"),
                       channel(8, "FR: ESPN")]
        let found = NetworkChannelFallback.channels(for: game, streams: streams, categories: [], programs: [:])
        XCTAssertEqual(Set(found.map(\.id)), [1, 2], "ESPN's own feeds, not ESPN2, another game's event feed, radio, news or another language")
        XCTAssertEqual(found.first?.id, 2, "The best quality first")
        XCTAssertTrue(NetworkChannelFallback.channels(for: game, streams: streams, categories: [], programs: [:],
                                                      excluding: [1, 2]).isEmpty, "A feed the guide confirmed is not offered twice")
    }

    func testAFeedShowingSomethingElseThenIsLeftOut() throws {
        let game = try game(broadcast: "ESPN2")
        func on(_ guide: String, _ title: String) -> CurrentProgram {
            CurrentProgram(channelID: guide, title: title, detail: "", start: game.start.addingTimeInterval(-600),
                           end: game.start.addingTimeInterval(7200))
        }
        let streams = [channel(1, "US: ESPN 2", guide: "a"), channel(2, "USA ESPN2 HD", guide: "b"),
                       channel(3, "ESPN2 East", guide: "c")]
        let programs = ["a": [on("a", "College Basketball")], "b": [on("b", "Rutgers vs. Houston")],
                        "c": [on("c", "NHL Hockey: Rangers at Bruins")]]
        let found = NetworkChannelFallback.channels(for: game, streams: streams, categories: [], programs: programs)
        XCTAssertEqual(Set(found.map(\.id)), [1, 2])
    }

    func testAGameWithNoNetworkHasNoFallback() throws {
        XCTAssertTrue(NetworkChannelFallback.channels(for: try game(broadcast: ""),
                      streams: [channel(1, "US: ESPN")], categories: [], programs: [:]).isEmpty)
    }
}
