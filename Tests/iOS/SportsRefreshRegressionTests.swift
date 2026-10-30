import XCTest
@testable import LineupiOS

@MainActor
final class SportsRefreshRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tournament(start: Date, round: String, name: String = "Rolex Paris Masters") -> SportsGame {
        SportsGame(id: "tennis-event-paris-atp", league: .atp, start: start,
            awayTeam: "", homeTeam: "", awayAbbreviation: "", homeAbbreviation: "",
            awayLogo: "", homeLogo: "", awayScore: "", homeScore: "", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: round, location: "Paris", status: "2 matches live",
            state: "in", broadcast: "Tennis Channel", eventName: name)
    }

    func testLiveTournamentProofSurvivesChangingCourtStartAndRoundButExpiresWithTheProgram() async {
        let first = tournament(start: now.addingTimeInterval(-3600), round: "Round of 16")
        let next = tournament(start: now.addingTimeInterval(-300), round: "Quarterfinal")
        let stream = XtreamStream(num: nil, name: "US: Tennis Channel 1 FHD", streamType: "live", streamID: 1,
            streamIcon: nil, epgChannelID: "tennis", categoryID: "sports")
        let program = CurrentProgram(channelID: "tennis", title: "ATP Paris Masters Tennis", detail: "Live",
            start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(3600))
        let match = PreparedLiveMatch(preparedAt: now.addingTimeInterval(-1200), eventStart: first.start,
            identity: PreparedLiveMatch.identity(for: first), primary: stream, alternatives: [],
            programs: ["tennis": [program]], categoryNames: ["sports": "Sports"])
        XCTAssertTrue(match.covers(next, now: now), "Court/round changes must not hide a continuing tournament broadcast")
        XCTAssertEqual(match.playbackCandidates(for: next, now: now).map(\.id), [1])
        XCTAssertFalse(match.covers(next, now: program.end))
        XCTAssertFalse(match.covers(tournament(start: next.start, round: "Quarterfinal", name: "Wuhan Open"), now: now))
    }

    func testAnUnrelatedFinishedOrChangedMatchDoesNotDiscardValidCompletedResults() async {
        let publication = PreparedMatchPublication(requested: ["tennis", "finished", "changed"],
            snapshot: ["tennis": ["Paris"], "finished": ["Sinner v Fritz"], "changed": ["old"]],
            current: ["tennis": ["Paris"], "changed": ["new"]])
        XCTAssertEqual(publication.accepted, ["tennis"])
        XCTAssertEqual(publication.rejected, ["finished", "changed"])
    }

    func testExistingTournamentCacheUpgradesLocallyWithoutRenewingItsAgeOrExpiry() async throws {
        let event = tournament(start: now.addingTimeInterval(-3600), round: "Round of 16")
        let stream = XtreamStream(num: nil, name: "Tennis Channel 2", streamType: "live", streamID: 2,
            streamIcon: nil, epgChannelID: "tennis", categoryID: nil)
        let program = CurrentProgram(channelID: "tennis", title: "ATP Paris Masters", detail: "",
            start: event.start, end: now.addingTimeInterval(600))
        let old = PreparedLiveMatch(preparedAt: now.addingTimeInterval(-1800), eventStart: event.start,
            identity: PreparedLiveMatch.previousPreparedIdentity(for: event), primary: stream, alternatives: [],
            programs: ["tennis": [program]], categoryNames: [:])
        let upgraded = try XCTUnwrap(old.restored(for: event, now: now))
        XCTAssertEqual(upgraded.preparedAt, old.preparedAt)
        XCTAssertEqual(upgraded.programs, old.programs)
        XCTAssertTrue(upgraded.covers(tournament(start: now, round: "Quarterfinal"), now: now))
        XCTAssertFalse(upgraded.covers(event, now: program.end))
        XCTAssertNil(old.restored(for: tournament(start: event.start, round: "Round of 16", name: "Wuhan"), now: now))
    }

    func testSavedEvidenceRetainsOnlyTheLiveOrScheduledProgramRatherThanAWholeGuideDay() async {
        let entries = (0..<96).map { index in
            let start = now.addingTimeInterval(Double(index - 48) * 1800)
            return CurrentProgram(channelID: "sports", title: "Program \(index)", detail: "Guide entry",
                start: start, end: start.addingTimeInterval(1800))
        }
        let live = PreparedLiveMatch.evidence(entries, eventStart: now.addingTimeInterval(-600), preparedAt: now)
        XCTAssertEqual(live, [entries[48]])
        let upcoming = PreparedLiveMatch.evidence(entries, eventStart: now.addingTimeInterval(3600), preparedAt: now)
        XCTAssertEqual(upcoming, [entries[50]])
        let previous = PreparedLiveMatch(preparedAt: now, eventStart: now.addingTimeInterval(-600),
            identity: ["saved"], primary: nil, alternatives: [], programs: ["sports": entries], categoryNames: [:])
        XCTAssertEqual(previous.compacted().programs["sports"], live)
        XCTAssertEqual(previous.compacted().preparedAt, previous.preparedAt)
    }

    func testSlowSnapshotWritesKeepOnlyTheLatestPendingValueForEachAccount() async {
        let queue = LatestSnapshotQueue<String, Int>()
        let journal = SnapshotJournal()
        let operation: @Sendable (Int) async -> Void = { value in await journal.write(value) }
        let first = queue.submit(key: "one", value: 0, operation: operation)
        await journal.started.wait()
        for value in 1...100 { _ = queue.submit(key: "one", value: value, operation: operation) }
        let last = queue.submit(key: "two", value: 200, operation: operation)
        journal.release.open()
        await first.value
        await last.value
        XCTAssertEqual(journal.values.first, 0)
        XCTAssertEqual(Set(journal.values), [0, 100, 200])
        XCTAssertEqual(journal.values.count, 3, "Intermediate score snapshots must not form a retained write backlog")
    }

    func testCatalogBuildKeepsOverlappingNativeIDsAndGuidesSeparateAndPreservesDisplayIDs() async throws {
        let a = XtreamProfile(name: "One", serverURL: "https://one.invalid", username: "viewer")
        let b = XtreamProfile(name: "Two", serverURL: "https://two.invalid", username: "viewer")
        let stream = XtreamStream(num: nil, name: "Sports FHD", streamType: "live", streamID: 1,
            streamIcon: nil, epgChannelID: "same", categoryID: "sports")
        let program = CurrentProgram(channelID: "same", title: "Live game", detail: "",
            start: now, end: now.addingTimeInterval(3600))
        let inputs = [a, b].map { profile in
            MobileCombinedCatalog.Provider(profile: profile,
                categories: [.init(categoryID: "sports", categoryName: "Sports")], streams: [stream], programs: ["same": [program]])
        }
        let built = try await Task.detached {
            try MobileCombinedCatalog.build(providers: inputs, registry: .init(ids: [:], next: -1))
        }.value
        XCTAssertEqual(Set(built.channels.map(\.id)).count, 2)
        XCTAssertTrue(built.channels.allSatisfy { $0.id < 0 })
        XCTAssertEqual(built.programs.count, 2)
        XCTAssertNotEqual(built.channels[0].epgChannelID, built.channels[1].epgChannelID)
        XCTAssertEqual(Set(built.sources.values.map(\.providerID)), [a.id, b.id])
        let reordered = try MobileCombinedCatalog.build(providers: Array(inputs.reversed()), registry: built.registry)
        XCTAssertEqual(reordered.registry.ids, built.registry.ids)
        XCTAssertEqual(reordered.channels.map(\.id), built.channels.reversed().map(\.id))
    }

    func testAlternativePassReusesPreparedChannelsAndRetainsStrictTennisEvidence() async {
        let game = tournament(start: now.addingTimeInterval(-600), round: "Round of 16")
        let channels = (1...3).map { id in
            XtreamStream(num: id, name: "US: Tennis Channel \(id) FHD", streamType: "live", streamID: id,
                streamIcon: nil, epgChannelID: "tennis\(id)", categoryID: "sports")
        }
        let entries = channels.map { stream in
            CurrentProgram(channelID: stream.epgChannelID!, title: stream.id == 3 ? "Classic Tennis" : "ATP Tennis",
                detail: "Paris Masters live coverage", start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(1800))
        }
        let programs = Dictionary(uniqueKeysWithValues: entries.map { ($0.channelID, [$0]) })
        let expected = SportsLibrary.matchingEventChannels(for: game, candidates: channels,
            programs: programs, categories: [], now: now)
        XCTAssertEqual(Set(expected.map(\.id)), [1, 2], "Archived tennis must remain excluded")
        var cache: [Int: ProfessionalChannelMatcher.PreparedChannel] = [:]
        var builds = 0
        for _ in 0..<5 {
            let actual = SportsLibrary.matchingEventChannels(for: game, candidates: channels,
                programs: programs, categories: [], now: now, preparedChannel: { stream in
                    if let found = cache[stream.id] { return found }
                    builds += 1
                    let prepared = ProfessionalChannelMatcher.prepare(channel: stream.name,
                        listings: ProfessionalChannelMatcher.prepare((programs[stream.epgChannelID ?? ""] ?? []).map {
                            .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end)
                        }))
                    cache[stream.id] = prepared
                    return prepared
                })
            XCTAssertEqual(actual.map(\.id), expected.map(\.id))
            XCTAssertEqual(actual.map(\.evidence), expected.map(\.evidence))
        }
        XCTAssertEqual(builds, channels.count)
    }
}

@MainActor
private final class SnapshotGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class SnapshotJournal {
    let started = SnapshotGate(), release = SnapshotGate()
    var values: [Int] = []
    func write(_ value: Int) async {
        values.append(value)
        if value == 0 { started.open(); await release.wait() }
    }
}
