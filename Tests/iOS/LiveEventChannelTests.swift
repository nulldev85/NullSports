import XCTest
#if os(tvOS)
@testable import Lineup
#else
import SwiftUI
@testable import LineupiOS
#endif

final class LiveEventChannelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func game(_ league: SportsLeague = .nba) -> SportsGame {
        let college = league == .ncaaf
        return SportsGame(id: "quality-event", league: league, start: now.addingTimeInterval(-1200),
            awayTeam: college ? "Fresno State Bulldogs" : "Orlando Magic",
            homeTeam: college ? "San Diego State Aztecs" : "Miami Heat",
            awayAbbreviation: college ? "FRES" : "ORL", homeAbbreviation: college ? "SDSU" : "MIA",
            awayLogo: "", homeLogo: "", awayScore: "70", homeScore: "65", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Live", state: "in",
            broadcast: college ? "CBSSN" : "ABC", eventName: nil)
    }

    private func stream(_ id: Int, _ name: String, epg: String? = "event", type: String = "live") -> XtreamStream {
        XtreamStream(num: id, name: name, streamType: type, streamID: id, streamIcon: nil, epgChannelID: epg, categoryID: nil)
    }

    private func program(_ title: String, id: String = "event") -> CurrentProgram {
        .init(channelID: id, title: title, detail: "", start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(6000))
    }

    func testExplicitProviderResolutionAndFrameRateAreRankedWithoutInventingFormats() {
        XCTAssertEqual(LiveChannelQuality(name: "US | ABC UHD 60FPS"), .init(height: 2160, frameRate: 60))
        XCTAssertEqual(LiveChannelQuality(name: "ABC 1080p50"), .init(height: 1080, frameRate: 50))
        XCTAssertEqual(LiveChannelQuality(name: "ABC 4K50"), .init(height: 2160, frameRate: 50))
        XCTAssertEqual(LiveChannelQuality(name: "ABC Full HD 60 fps"), .init(height: 1080, frameRate: 60))
        XCTAssertEqual(LiveChannelQuality(name: "ABC SD"), .init(height: 480, frameRate: 0))
        XCTAssertEqual(LiveChannelQuality(name: "ABC H265 HEVC RAW HDR Dolby Atmos"), .unknown)
        XCTAssertEqual(LiveChannelQuality(name: "Channel 2160 Special Event 60"), .unknown)
        XCTAssertEqual(LiveChannelQuality(name: "FHDream 4Kids HDHome"), .unknown)
        XCTAssertNil(LiveChannelQuality.unknown.label)
        XCTAssertEqual(LiveChannelQuality(name: "ABC HD").label, "HD", "A generic provider HD label is not a measured 720p claim")
        XCTAssertEqual(LiveChannelQuality(name: "ABC SD").label, "SD")
        XCTAssertGreaterThan(LiveChannelQuality(name: "4K"), LiveChannelQuality(name: "1080p60"))
        XCTAssertGreaterThan(LiveChannelQuality(name: "1080p60"), LiveChannelQuality(name: "1080p30"))
    }

    func testHighestQualityVerifiedGameFeedWinsAndUnrelatedEightKDoesNotQualify() {
        let candidates = [stream(1, "US: ABC Miami HD"), stream(90, "US: ABC Miami 4K 60FPS"),
            stream(2, "ESPN 8K", epg: "wrong"), stream(3, "ABC 4K Radio", type: "radio"),
            stream(4, "ABC 8K Replay"), stream(90, "US: ABC Miami 4K 60FPS")]
        let listings = ["event": [program("NBA Basketball: Orlando Magic at Miami Heat")],
            "wrong": [program("Boston Celtics vs Charlotte Hornets", id: "wrong")]]
        let channels = SportsLibrary.matchingEventChannels(for: game(), candidates: candidates,
            programs: listings, categories: [], now: now)
        XCTAssertEqual(channels.map(\.id), [90, 1], "Quality beats provider ID only after event verification")
        XCTAssertEqual(channels.first?.quality.label, "4K · 60 fps")
        XCTAssertEqual(channels.first?.program?.title, "NBA Basketball: Orlando Magic at Miami Heat")
    }

    func testCollegeChannelsUseStrictGameEvidenceAndFindGenericProviderChannels() {
        let candidates = [stream(1, "US: CBSSN HD"), stream(99, "US: CBSSN FHD 60FPS"),
            stream(2, "US: CBSSN 8K", epg: "wrong"), stream(3, "US: CBSSN 4K", epg: nil)]
        let channels = SportsLibrary.matchingEventChannels(for: game(.ncaaf), candidates: candidates,
            programs: ["event": [program("College Football: Fresno State at San Diego State")],
                       "wrong": [program("College Football: Air Force at New Mexico", id: "wrong")]],
            categories: [], now: now)
        XCTAssertEqual(channels.map(\.id), [99, 1])
    }

    func testLanguagePreferenceSurvivesQualityRankingAndEvidenceStillBreaksQualityTies() {
        let quality: [Int: LiveChannelQuality] = [1: .init(name: "4K"), 2: .init(name: "FHD")]
        XCTAssertTrue(SportsLibrary.ranksAhead((2, 300), of: (1, 400), foreign: [1], qualities: quality))
        XCTAssertTrue(SportsLibrary.ranksAhead((1, 300), of: (2, 400), foreign: [], qualities: quality))
        XCTAssertTrue(SportsLibrary.ranksAhead((2, 400), of: (1, 300), foreign: []))
    }

    func testRaceChannelsExcludeDifferentSessionsEvenWhenTheyAdvertiseHigherQuality() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "f1-weekend", withExtension: "json", subdirectory: "Fixtures"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var events = try XCTUnwrap(root["events"] as? [[String: Any]])
        var sessions = try XCTUnwrap(events[0]["competitions"] as? [[String: Any]])
        sessions[sessions.count - 1]["status"] = ["type": ["state": "in", "shortDetail": "Lap 1"]]
        events[0]["competitions"] = sessions; root["events"] = events
        let live = try JSONSerialization.data(withJSONObject: root)
        let race = try XCTUnwrap(ExpandedSportsScheduleClient.racingGames(data: live, league: .f1).last)
        let channels = SportsLibrary.matchingEventChannels(for: race,
            candidates: [stream(1, "F1 Austin Race 4K", epg: nil), stream(2, "F1 Austin Qualifying 8K", epg: nil),
                         stream(3, "F1 Austin Practice 1 8K", epg: nil), stream(4, "Sky Sports F1 8K", epg: nil)],
            programs: [:], categories: [], now: race.start)
        XCTAssertEqual(channels.map(\.id), [1])
    }

    #if !os(tvOS)
    @MainActor
    func testSoccerCompetitionChoicesKeepEveryOptionAndUpdateTheOriginalSelection() throws {
        var selected: String?
        let binding = Binding<String?>(get: { selected }, set: { selected = $0 })
        let choices = SoccerCompetitionFilter.choices(selection: binding)
        XCTAssertEqual(choices.count, SportsCompetitionCatalog.bundled.competitions.count + 1)
        XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
        XCTAssertTrue(try XCTUnwrap(choices.first { $0.id == "all" }).isSelected)
        try XCTUnwrap(choices.first { $0.id == "eng.1" }).action()
        XCTAssertEqual(selected, "eng.1")
        XCTAssertTrue(try XCTUnwrap(SoccerCompetitionFilter.choices(selection: binding).first { $0.id == "eng.1" }).isSelected)
        try XCTUnwrap(choices.first { $0.id == "all" }).action()
        XCTAssertNil(selected)
    }
    #endif
}
