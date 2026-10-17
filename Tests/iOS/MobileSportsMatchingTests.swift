import XCTest
@testable import LineupiOS

final class MobileSportsMatchingTests: XCTestCase {
    private let kickoff = Date(timeIntervalSince1970: 1_800_000_000)

    func testCollegePruningPreservesAllPositiveScoresIncludingPartialAndDelayedEvidence() throws {
        typealias Matcher = CollegeChannelMatcher
        let games = [
            ("SMU Mustangs", "Florida State Seminoles", "SMU", "FSU"),
            ("Washington State Cougars", "Washington Huskies", "WSU", "WASH"),
            ("Miami (OH) RedHawks", "Miami Hurricanes", "M-OH", "MIA"),
            ("Fresno State Bulldogs", "San Diego State Aztecs", "FRES", "SDSU")
        ].flatMap { pair in
            ["Live", "Weather Delay"].map {
                Matcher.Matchup(broadcast: "ESPN", away: pair.0, home: pair.1,
                    awayAbbreviation: pair.2, homeAbbreviation: pair.3,
                    kickoff: kickoff, isLive: true, status: $0)
            }
        }
        var candidates: [Matcher.Candidate] = []
        var guides: [String: [Matcher.Listing]] = [:]
        var channels: [MobileSportsCandidateIndex.Channel] = []
        for (gameIndex, game) in games.enumerated() {
            let texts = [
                ("\(game.away) at \(game.home)", ""),
                ("\(game.awayAbbreviation) vs \(game.homeAbbreviation)", ""),
                ("College Football", "\(game.away) faces \(game.home)"),
                (game.away, ""), ("College Football", ""), ("SportsCenter", ""),
                ("Alabama vs Georgia", ""), ("SMU vs Florida State Replay", "")
            ]
            // Two qualities share each EPG ID; no quality variant may be lost.
            for (slot, text) in texts.enumerated() {
                let guide = "\(gameIndex)-\(slot)"
                guides[guide] = [.init(title: text.0, detail: text.1,
                    start: kickoff, end: kickoff.addingTimeInterval(10800))]
                for quality in ["HD", "FHD"] {
                    for name in ["ESPN \(quality)", "Event \(game.away) vs \(game.home) \(quality)",
                                 "ESPN2 \(quality)", "Radio \(quality)"] {
                        let id = candidates.count
                        let candidate = Matcher.Candidate(id: id, name: name, listings: guides[guide]!)
                        candidates.append(candidate)
                        channels.append(.init(id: id, name: candidate.normalizedName, guideID: guide))
                    }
                }
            }
        }
        // Guide-free dedicated feeds and aliases with different punctuation.
        for name in ["NCAAF SMU vs FSU FHD", "FRES at SDSU", "Washington St at Washington",
                     "Fresnó State vs San Diego St", "ESPN", "ESPN SMU vs Florida State"] {
            let id = candidates.count
            let candidate = Matcher.Candidate(id: id, name: name, listings: [])
            candidates.append(candidate)
            channels.append(.init(id: id, name: candidate.normalizedName, guideID: "empty"))
        }
        let index = try MobileSportsCandidateIndex(channels: channels,
            aliases: games.flatMap { $0.awayAliases + $0.homeAliases }, listings: { (guides[$0] ?? []).map(\.text) })
        var scores: Set<Int> = []
        for game in games {
            let possible = try XCTUnwrap(index.candidates(for: game.awayAliases + game.homeAliases))
            for candidate in candidates {
                let score = Matcher.score(candidate: candidate, game: game,
                    now: kickoff.addingTimeInterval(3600), allowNetworkFallback: false)
                if let score {
                    scores.insert(score)
                    XCTAssertTrue(possible.contains(candidate.id), "Lost \(candidate.name), evidence \(score)")
                }
                let retained = possible.contains(candidate.id) ? score : nil
                XCTAssertEqual(retained, score, "Candidate hints must preserve EVERY qualifying channel")
            }
        }
        XCTAssertTrue(scores.isSuperset(of: [150, 200, 300, 400]), "Exercise partial, named-feed and full-guide evidence")
        XCTAssertEqual(index.guideChannelsRead, guides.count + 1, "Read shared HD/FHD guides once")
    }

    func testProfessionalPruningPreservesExactScoresAndUnknownQueriesFallBackToFullPool() throws {
        typealias Matcher = ProfessionalChannelMatcher
        let games = [
            ("Orlando Magic", "Miami Heat", "ORL", "MIA"),
            ("Portland Trail Blazers", "Golden State Warriors", "POR", "GSW"),
            ("Washington Capitals", "New York Rangers", "WSH", "NYR")
        ].map {
            Matcher.prepare(.init(away: $0.0, home: $0.1, awayAbbreviation: $0.2,
                homeAbbreviation: $0.3, start: kickoff, isLive: true))
        }
        let names = ["ABC", "NBA Magic vs Heat FHD", "POR @ GSW", "ESPN Radio", "NHL WSH vs NYR",
                     "NBA Trail Blazers at Warriors", "Movie channel", "NBA Replay", "Unknown"]
        let titles = ["NBA Basketball: Orlando Magic at Miami Heat", "Trail Blazers vs Warriors",
                      "Washington Capitals vs New York Rangers", "SportsCenter", "Basketball", ""]
        var prepared: [Int: Matcher.PreparedChannel] = [:]
        var guide: [String: [String]] = [:]
        var channels: [MobileSportsCandidateIndex.Channel] = []
        for (offset, name) in names.enumerated() {
            for (slot, title) in titles.enumerated() {
                let id = offset * titles.count + slot
                let listings = Matcher.prepare([.init(title: title, detail: "",
                    start: kickoff, end: kickoff.addingTimeInterval(10800))])
                let channel = Matcher.prepare(channel: name, listings: listings)
                prepared[id] = channel
                guide[String(slot)] = listings.map(\.text)
                channels.append(.init(id: id, name: channel.padded, guideID: String(slot)))
            }
        }
        let index = try MobileSportsCandidateIndex(channels: channels,
            aliases: games.flatMap { $0.away + $0.home }, listings: { guide[$0] ?? [] })
        for game in games {
            let possible = try XCTUnwrap(index.candidates(for: game.away + game.home))
            for (id, channel) in prepared {
                let score = Matcher.score(channel: channel, game: game, now: kickoff.addingTimeInterval(1200))
                XCTAssertEqual(possible.contains(id) ? score : nil, score)
            }
        }
        XCTAssertNil(index.candidates(for: ["newly added school"]), "A different slate must not use stale hints")
        XCTAssertEqual(index.guideChannelsRead, titles.count)
    }

    func testLargeProviderIndexesEachGuideOnceAndAvoidsTheCollegeCrossProduct() throws {
        let channels = (1...26_599).map {
            MobileSportsCandidateIndex.Channel(id: $0,
                name: $0 == 17 ? "school0 vs visitor0 fhd" : "channel \($0)", guideID: String($0 % 8269))
        }
        let aliases = (0..<49).flatMap { ["school\($0)", "visitor\($0)"] }
        var guideReads = 0
        let start = ProcessInfo.processInfo.systemUptime
        let index = try MobileSportsCandidateIndex(channels: channels, aliases: aliases, listings: {
            guideReads += 1
            return $0 == "3" ? ["school0 at visitor0"] : ["general entertainment unrelated to this slate"]
        })
        var scored = 0
        for game in 0..<49 {
            let possible = try XCTUnwrap(index.candidates(for: ["school\(game)", "visitor\(game)"]))
            scored += possible.count
            if game == 0 {
                let expected = Set(channels.filter { $0.guideID == "3" || $0.id == 17 }.map(\.id))
                XCTAssertEqual(possible, expected)
            } else { XCTAssertTrue(possible.isEmpty) }
        }
        XCTAssertEqual(guideReads, 8269)
        XCTAssertLessThan(scored, 10, "Avoid 1,303,351 full scores without losing matching feeds")
        print("26,599-channel / 49-game candidate fixture: \(scored) full-score candidates, \(ProcessInfo.processInfo.systemUptime - start)s")
    }

    func testSupersededCandidatePreparationStopsBeforeReadingAnotherGuide() async {
        let entered = expectation(description: "first guide entered")
        let gate = CandidatePreparationGate(entered: entered)
        let work = Task.detached {
            try MobileSportsCandidateIndex(channels: [
                .init(id: 1, name: "one", guideID: "one"), .init(id: 2, name: "two", guideID: "two")
            ], aliases: ["school"], listings: { gate.read($0) })
        }
        await fulfillment(of: [entered], timeout: 2)
        work.cancel()
        gate.open()
        switch await work.result {
        case .success: XCTFail("Cancelled preparation must stop")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(gate.reads, ["one"], "No remaining guide should be normalized after supersession")
    }
}

private final class CandidatePreparationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let entered: XCTestExpectation
    private var released = false
    private var recorded: [String] = []
    init(entered: XCTestExpectation) { self.entered = entered }
    var reads: [String] { condition.lock(); defer { condition.unlock() }; return recorded }
    func read(_ id: String) -> [String] {
        condition.lock()
        defer { condition.unlock() }
        recorded.append(id)
        entered.fulfill()
        let deadline = Date().addingTimeInterval(5)
        while !released, condition.wait(until: deadline) {}
        return ["school"]
    }
    func open() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

final class SportsIndexFactsTests: XCTestCase {
    private func listing(_ title: String, detail: String = "", at: TimeInterval = 0) -> CurrentProgram {
        .init(channelID: "guide", title: title, detail: detail,
            start: Date(timeIntervalSince1970: at), end: Date(timeIntervalSince1970: at + 3600))
    }

    func testUnchangedTextReusesFactsButTextChangesRecompute() {
        let cache = SportsIndexFacts(version: "test")
        var calls = 0
        func compute() -> Set<SportsLeague> { calls += 1; return calls == 1 ? [.nba] : [.soccer] }
        XCTAssertEqual(cache.leagues(channelID: "guide", listings: [listing("NBA")], compute: compute), [.nba])
        XCTAssertEqual(cache.leagues(channelID: "guide", listings: [listing("NBA", at: 5000)], compute: compute), [.nba])
        XCTAssertEqual(calls, 1, "Changed clocks do not change league words; matching still reads fresh clocks")
        XCTAssertEqual(cache.leagues(channelID: "guide", listings: [listing("NBA", detail: "Soccer")], compute: compute), [.soccer])
        XCTAssertEqual(calls, 2)
    }

    func testFactsSurviveSerializationAndAppBuildChangesInvalidateThem() throws {
        let first = SportsIndexFacts(version: "114")
        let entries = [listing("Fresno State at San Diego State")]
        _ = first.leagues(channelID: "guide", listings: entries) { [.ncaaf] }
        let saved = try JSONDecoder().decode([String: SportsIndexFacts.Fact].self,
            from: JSONEncoder().encode(first.snapshot()))
        let restored = SportsIndexFacts(version: "114")
        restored.restore(saved)
        XCTAssertEqual(restored.leagues(channelID: "guide", listings: entries) {
            XCTFail("Identical persisted guide facts should be reused"); return []
        }, [.ncaaf])
        let upgraded = SportsIndexFacts(version: "115")
        upgraded.restore(saved)
        XCTAssertEqual(upgraded.leagues(channelID: "guide", listings: entries) { [.nfl] }, [.nfl])
        restored.restore([:])
        XCTAssertTrue(restored.snapshot().isEmpty)
    }

    func testFieldBoundariesOrderAndRemovalCannotCollide() {
        let cache = SportsIndexFacts(version: "test")
        let sequences = [[listing("ab", detail: "c")], [listing("a", detail: "bc")],
                         [listing("x"), listing("y")], [listing("y"), listing("x")], [listing("y")], []]
        var calls = 0
        for entries in sequences {
            _ = cache.leagues(channelID: "guide", listings: entries) { calls += 1; return [.nba] }
        }
        XCTAssertEqual(calls, sequences.count)
    }
}

@MainActor
final class MobileSportsWorkTests: XCTestCase {
    func testNewIndexCancelsObsoleteMatchingAndStartsWithoutWaitingForItsFullPass() async throws {
        let coordinator = MobileSportsWork()
        let began = expectation(description: "old matching began")
        let newerBegan = expectation(description: "new index began")
        let old = Task.detached {
            began.fulfill()
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        let oldID = coordinator.replace(.matching, cancel: { old.cancel() })
        await fulfillment(of: [began], timeout: 2)
        let newer = Task.detached { newerBegan.fulfill(); return 2 }
        let indexID = coordinator.replace(.index, cancel: { newer.cancel() })
        await fulfillment(of: [newerBegan], timeout: 2)
        let newest = await newer.value
        XCTAssertEqual(newest, 2)
        switch await old.result {
        case .success: XCTFail("The obsolete full pass must stop")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        coordinator.finish(.matching, id: oldID)
        coordinator.finish(.index, id: indexID)
    }

    func testOldCompletionCannotRetireNewWorkAndProviderResetCancelsBothLanes() async {
        let coordinator = MobileSportsWork()
        let oldCancelled = expectation(description: "old work cancelled")
        let currentCancelled = expectation(description: "current matching cancelled")
        let indexCancelled = expectation(description: "current index cancelled")
        let oldID = coordinator.replace(.matching, cancel: { oldCancelled.fulfill() })
        _ = coordinator.replace(.index, cancel: { indexCancelled.fulfill() })
        _ = coordinator.replace(.matching, cancel: { currentCancelled.fulfill() })
        coordinator.finish(.matching, id: oldID)
        coordinator.cancel()
        coordinator.cancel()
        await fulfillment(of: [oldCancelled, currentCancelled, indexCancelled], timeout: 2)
    }
}
