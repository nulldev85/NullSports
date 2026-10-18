import XCTest
@testable import LineupiOS

final class MobileSportsCatchUpTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnyMatchedArchiveChannelCanOfferCatchUpEvenWhenTheTopFeedCannot() {
        let liveOnly = stream(1, archive: false)
        let archive = stream(2, archive: true)
        let otherArchive = stream(3, archive: true)
        let entries = [entry(liveOnly), entry(archive), entry(archive), entry(otherArchive)]
        XCTAssertEqual(MobileSportsCatchUpPolicy.channels(entries, live: true, playlist: false).map(\.id), [2, 3])
        XCTAssertTrue(MobileSportsCatchUpPolicy.channels([entry(liveOnly)], live: true, playlist: false).isEmpty)
        XCTAssertTrue(MobileSportsCatchUpPolicy.channels(entries, live: false, playlist: false).isEmpty)
        XCTAssertTrue(MobileSportsCatchUpPolicy.channels(entries, live: true, playlist: true).isEmpty)
        XCTAssertTrue(MobileSportsCatchUpPolicy.channels([], live: true, playlist: false).isEmpty)
    }

    func testStrictEventEvidenceStillExcludesUnrelatedArchiveChannelsAcrossSports() {
        for (league, away, home, awayCode, homeCode) in [
            (SportsLeague.nba, "Orlando Magic", "Miami Heat", "ORL", "MIA"),
            (.nfl, "San Francisco 49ers", "Seattle Seahawks", "SF", "SEA"),
            (.soccer, "Chelsea", "Everton", "CHE", "EVE")
        ] {
            let game = SportsGame(id: league.rawValue, league: league, start: now.addingTimeInterval(-1200),
                awayTeam: away, homeTeam: home, awayAbbreviation: awayCode, homeAbbreviation: homeCode,
                awayLogo: "", homeLogo: "", awayScore: "1", homeScore: "1", awayColor: nil, homeColor: nil,
                awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Live", state: "in",
                broadcast: "ESPN", eventName: nil)
            let channels = [stream(1, archive: false), stream(2, archive: true), stream(3, archive: true, epg: "unrelated")]
            let program = CurrentProgram(channelID: "game", title: "\(away) at \(home)", detail: "",
                start: now.addingTimeInterval(-1500), end: now.addingTimeInterval(6000))
            let unrelated = CurrentProgram(channelID: "unrelated", title: "News and highlights", detail: "",
                start: program.start, end: program.end)
            let matched = SportsLibrary.matchingEventChannels(for: game, candidates: channels,
                programs: ["game": [program], "unrelated": [unrelated]], categories: [], now: now)
            XCTAssertEqual(Set(matched.map(\.id)), [1, 2], league.rawValue)
            XCTAssertEqual(MobileSportsCatchUpPolicy.channels(matched, live: game.isLive, playlist: false).map(\.id), [2], league.rawValue)
        }
    }

    func testChannelSelectionPreservesAccountProgramAndOngoingCatchUpSemantics() throws {
        let profile = UUID()
        let channel = MobileSportsCatchUpChannel(profileID: profile, stream: stream(2, archive: true))
        let ongoing = CatchUpProgramme(streamID: 2, title: "Game in progress", detail: "",
            start: now.addingTimeInterval(-1200), end: now.addingTimeInterval(6000))
        let selection = try XCTUnwrap(channel.selection(for: ongoing))
        XCTAssertEqual(selection.profileID, profile)
        XCTAssertEqual(selection.recording.stream.id, 2)
        XCTAssertEqual(selection.recording.program, ongoing)
        XCTAssertTrue(selection.usesChannelCatchUp, "Sports Catch Up uses the same current/past catalog as Guide")
        XCTAssertFalse(MobileGameReplaySelection(profileID: profile, recording: selection.recording).usesChannelCatchUp,
            "The My Teams completed NFL replay policy remains strict")
        let wrongChannel = CatchUpProgramme(streamID: 1, title: ongoing.title, detail: "", start: ongoing.start, end: ongoing.end)
        XCTAssertNil(channel.selection(for: wrongChannel))
        XCTAssertNil(MobileSportsCatchUpChannel(profileID: profile, stream: stream(2, archive: false)).selection(for: ongoing))
    }

    @MainActor
    func testCapabilityResultOnlyUpdatesItsOriginalMenuAndKeepsTheExistingActions() throws {
        let menu = MobileHoldMenu()
        var watchCount = 0
        let watch = MobileMenuItem("Watch") { watchCount += 1 }
        menu.present("First event", symbol: "sportscourt", message: nil, items: [watch, .init("Channels")])
        let first = try XCTUnwrap(menu.request?.id)
        var updated = try XCTUnwrap(menu.request?.items)
        updated.insert(.init("Catch Up"), at: 2)
        menu.updateItems(updated, requestID: first)
        XCTAssertEqual(menu.request?.id, first)
        XCTAssertEqual(menu.request?.items.map(\.title), ["Watch", "Channels", "Catch Up"])
        menu.request?.items.first?.action()
        XCTAssertEqual(watchCount, 1)
        // Even another event with the same displayed title is a new request.
        menu.present("First event", symbol: "sportscourt", message: nil, items: [.init("New event action")])
        menu.updateItems(updated, requestID: first)
        XCTAssertEqual(menu.request?.items.map(\.title), ["New event action"])
        menu.request = nil
        menu.updateItems(updated, requestID: first)
        XCTAssertNil(menu.request, "A late capability result cannot reopen a dismissed menu")
    }

    private func stream(_ id: Int, archive: Bool, epg: String = "game") -> XtreamStream {
        .init(num: id, name: "US: ESPN FHD", streamType: "live", streamID: id, streamIcon: nil,
            epgChannelID: epg, categoryID: nil, tvArchive: archive, archiveDays: 7)
    }
    private func entry(_ stream: XtreamStream) -> LiveEventChannel {
        .init(stream: stream, program: nil, evidence: 10, quality: .init(name: stream.name))
    }
}
