import XCTest
@testable import LineupiOS

/// The Search tab finds a query across the whole app, sorts it into Movies,
/// Shows, Live TV and VOD, and says where in the app each result is.
@MainActor
final class AppSearchTests: XCTestCase {
    private func channel(_ id: Int, _ name: String, guide: String? = nil, group: String? = "7",
                         type: String? = "live") -> XtreamStream {
        XtreamStream(num: id, name: name, streamType: type, streamID: id, streamIcon: nil,
                     epgChannelID: guide, categoryID: group)
    }

    private func program(_ guide: String, _ title: String, from start: Date, minutes: Double) -> CurrentProgram {
        CurrentProgram(channelID: guide, title: title, detail: "", start: start,
                       end: start.addingTimeInterval(minutes * 60))
    }

    private func game(_ id: String, away: String, home: String, state: String, start: Date) -> SportsGame {
        SportsGame(id: id, league: .nba, start: start, awayTeam: away, homeTeam: home,
                   awayAbbreviation: "AWY", homeAbbreviation: "HME", awayLogo: "", homeLogo: "",
                   awayScore: state == "in" ? "54" : "", homeScore: state == "in" ? "60" : "",
                   awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil, venue: nil,
                   location: nil, status: state == "in" ? "Q3" : "Scheduled", state: state,
                   broadcast: "ESPN", eventName: nil)
    }

    /// Each hit as a line, to compare a whole list at once.
    private func lines(_ hits: [AppSearchHit]) -> [String] {
        hits.map { hit in
            switch hit.kind {
            case .game(let game, _): "game: " + AppSearchFormat.matchup(game)
            case .channel(let channel, _, _): "channel: " + channel.name
            case .airing(let program, let channel, let more, _): "airing: \(program.title) on \(channel.name) +\(more)"
            case .title(let item, let servers): "title: \(item.name) on \(servers.joined(separator: ", "))"
            case .vod(let item, _): "vod: " + item.name
            }
        }
    }

    // Games first, then channels -- a name that starts with the query, then
    // one that holds it, then one that holds its words -- then the guide,
    // what is on now before what is to come, each programme once per channel
    // with a count of its later airings. A radio stream is no channel.
    func testLiveResultsAreGamesThenChannelsThenTheGuide() {
        let now = Date()
        let crime = channel(1, "24/7 Training Day", guide: "td")
        let mgm = channel(2, "US: MGM+ Marquee", guide: "mgm")
        let radio = channel(3, "Training Day Radio", type: "radio_streams")
        let words = channel(4, "Day of Training Network", guide: "dtn")
        let movies = channel(5, "Training Day Movies")
        let programs = [
            "td": [program("td", "Training Day 24/7", from: now.addingTimeInterval(-600), minutes: 60),
                   program("td", "Training Day 24/7", from: now.addingTimeInterval(3000), minutes: 60),
                   program("td", "Training Day 24/7", from: now.addingTimeInterval(7000), minutes: 60)],
            "mgm": [program("mgm", "Training Day", from: now.addingTimeInterval(2 * 86_400), minutes: 120),
                    program("mgm", "Paid Programming", from: now.addingTimeInterval(-60), minutes: 30)]
        ]
        let playing = game("g1", away: "Training Day FC", home: "Rivals", state: "in",
                           start: now.addingTimeInterval(-3600))
        let snapshot = AppSearch.LiveSnapshot(channels: [words, radio, mgm, crime, movies],
                                              groups: ["7": "24/7 Crime"], programs: programs,
                                              games: [(game: playing, channel: crime)])

        XCTAssertEqual(lines(AppSearch.live("training day", in: snapshot, now: now)), [
            "game: Training Day FC at Rivals",
            "channel: Training Day Movies",
            "channel: 24/7 Training Day",
            "channel: Day of Training Network",
            "airing: Training Day 24/7 on 24/7 Training Day +2",
            "airing: Training Day on US: MGM+ Marquee +0"
        ])
        XCTAssertTrue(AppSearch.live("   ", in: snapshot, now: now).isEmpty)
    }

    // A channel says what is on it now, and how far through that is.
    func testAChannelSaysWhatIsOnNow() throws {
        let now = Date()
        let crime = channel(1, "24/7 Training Day", guide: "td")
        let snapshot = AppSearch.LiveSnapshot(
            channels: [crime], groups: ["7": "24/7 Crime"],
            programs: ["td": [program("td", "Training Day 24/7", from: now.addingTimeInterval(-900), minutes: 60)]],
            games: [])
        let hit = try XCTUnwrap(AppSearch.live("24/7", in: snapshot, now: now).first)
        guard case .channel(_, let current, let group) = hit.kind else { return XCTFail("Not a channel") }
        XCTAssertEqual(current?.title, "Training Day 24/7")
        XCTAssertEqual(group, "24/7 Crime")
        XCTAssertEqual(try XCTUnwrap(AppSearchFormat.progress(of: hit, now: now)), 0.25, accuracy: 0.01)
        XCTAssertEqual(AppSearchFormat.place(of: hit).path, ["Guide", "24/7 Crime"])
    }

    // A film two servers have is one result naming both; a show is a show.
    func testATitleOnTwoServersIsListedOnceNamingBoth() {
        func item(_ id: String, _ type: String, year: Int, tmdb: String?) -> MediaItem {
            MediaItem(id: id, name: "Training Day", type: type, overview: nil, productionYear: year,
                      primaryImageAspectRatio: nil, childCount: nil, providerIDs: tmdb.map { ["Tmdb": $0] })
        }
        let groups = [
            MediaLibrary.SearchGroup(serverID: UUID(), serverName: "Null",
                                     items: [item("a", "Movie", year: 2001, tmdb: "2034"),
                                             item("c", "Series", year: 2017, tmdb: nil)]),
            MediaLibrary.SearchGroup(serverID: UUID(), serverName: "Matt",
                                     items: [item("b", "Movie", year: 2001, tmdb: "2034")])
        ]
        let hits = AppSearch.titles(from: groups)
        XCTAssertEqual(lines(hits), ["title: Training Day on Null, Matt", "title: Training Day on Null"])
        XCTAssertEqual(hits.map(\.category), [.movies, .shows])
        XCTAssertEqual(AppSearchFormat.place(of: hits[0]).path, ["Library", "Null · Matt"])
    }

    // Every kind of result names the tab it lives in.
    func testEveryResultSaysWhereItIs() {
        let film = MediaItem(id: "v", name: "Training Day", type: "Movie", overview: nil, productionYear: 2001,
                             primaryImageAspectRatio: nil, childCount: nil)
        let crime = channel(1, "24/7 Training Day", guide: "td")
        let now = Date()
        let upcoming = program("td", "Training Day", from: now.addingTimeInterval(3600), minutes: 60)
        let later = game("g2", away: "Lakers", home: "Celtics", state: "pre", start: now.addingTimeInterval(7200))

        XCTAssertEqual(AppSearchFormat.place(of: AppSearchHit(id: "1", kind: .vod(film, group: "Movies | 4K"))).path,
                       ["Library", "VOD", "Movies | 4K"])
        XCTAssertEqual(AppSearchFormat.place(of: AppSearchHit(
            id: "2", kind: .airing(upcoming, channel: crime, more: 0, group: nil))).path,
                       ["Guide", "24/7 Training Day"])
        XCTAssertEqual(AppSearchFormat.place(of: AppSearchHit(id: "3", kind: .game(later, channel: crime))).path,
                       ["Live", "NBA"])
        XCTAssertNil(AppSearchFormat.badge(of: AppSearchHit(
            id: "2", kind: .airing(upcoming, channel: crime, more: 0, group: nil)), now: now),
                     "Only what is on now says NOW")
        XCTAssertEqual(AppSearchFormat.badge(of: AppSearchHit(
            id: "4", kind: .game(game("g3", away: "A", home: "B", state: "in", start: now), channel: nil)))?.text,
                       "LIVE 54–60")
    }
}
