import XCTest
@testable import Lineup

@MainActor
final class TVSportsRefreshTests: XCTestCase {
    func testDailyPreparationUsesFreshLocalDataAndRetainsRealProviderRefreshes() async {
        for dailyDue in [false, true] {
            for libraryFresh in [false, true] {
                for guideFresh in [false, true] {
                    let plan = TVProviderRefreshPlan(topUp: false, libraryFresh: libraryFresh,
                        guideFresh: guideFresh, dailyDue: dailyDue, indexReady: true)
                    XCTAssertEqual(plan.channels, !libraryFresh)
                    XCTAssertEqual(plan.guide, !guideFresh)
                    XCTAssertEqual(plan.prepare, dailyDue)
                }
            }
        }
        let topUp = TVProviderRefreshPlan(topUp: true, libraryFresh: true,
            guideFresh: true, dailyDue: false, indexReady: true)
        XCTAssertTrue(topUp.channels)
        XCTAssertTrue(topUp.guide)
        let index = TVProviderRefreshPlan(topUp: false, libraryFresh: true,
            guideFresh: true, dailyDue: false, indexReady: false)
        XCTAssertTrue(index.prepare)
        XCTAssertFalse(index.channels || index.guide)
    }

    func testConcurrentMatchingRequestsShareOneWorkerAndOneLatestForcedFollowUp() async {
        let queue = TVSportsMatchingQueue()
        let started = RefreshGate(), release = RefreshGate()
        var active = 0, peak = 0
        var forces: [Bool] = []
        let operation: @MainActor (Bool) async -> Void = { force in
            active += 1
            peak = max(peak, active)
            forces.append(force)
            if forces.count == 1 {
                started.open()
                await release.wait()
            }
            active -= 1
        }
        let first = Task { await queue.run(force: false, operation: operation) }
        await started.wait()
        let joined = RefreshGate()
        var requests = 0
        let others = (0..<32).map { index in
            Task {
                requests += 1
                if requests == 32 { joined.open() }
                await queue.run(force: index == 17, operation: operation)
            }
        }
        await joined.wait()
        // All callers have entered run before their tasks suspend on its worker.
        release.open()
        await first.value
        for other in others { await other.value }
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(forces, [false, true])
    }

    func testProviderResetDoesNotLetAnOldTaskClearTheNewWorker() async {
        let queue = TVSportsMatchingQueue()
        let oldStarted = RefreshGate(), oldRelease = RefreshGate()
        let old = Task {
            await queue.run(force: false) { _ in
                oldStarted.open()
                await oldRelease.wait()
            }
        }
        await oldStarted.wait()
        queue.cancel()
        let newStarted = RefreshGate(), newRelease = RefreshGate()
        var calls = 0
        let operation: @MainActor (Bool) async -> Void = { _ in
            calls += 1
            if calls == 1 { newStarted.open(); await newRelease.wait() }
        }
        let current = Task { await queue.run(force: false, operation: operation) }
        await newStarted.wait()
        oldRelease.open()
        await old.value
        let joining = RefreshGate()
        let joined = Task {
            joining.open()
            await queue.run(force: false, operation: operation)
        }
        await joining.wait()
        XCTAssertEqual(calls, 1, "The canceled provider must not detach the new provider's worker")
        newRelease.open()
        await current.value
        await joined.value
        XCTAssertEqual(calls, 2)
    }

    func testBackgroundReconciliationRetiresOnlyChangedEvidenceAndPreservesAlternatives() async {
        let now = Date()
        let streams = (1...3).map { id in
            XtreamStream(num: nil, name: "Sports \(id)", streamType: "live", streamID: id,
                streamIcon: nil, epgChannelID: "epg\(id)", categoryID: "sports")
        }
        let categories = [XtreamCategory(categoryID: "sports", categoryName: "Sports")]
        let entries = streams.map { stream in
            CurrentProgram(channelID: stream.epgChannelID!, title: "Saved game", detail: "",
                start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        }
        let programs = Dictionary(uniqueKeysWithValues: entries.map { ($0.channelID, [$0]) })
        func saved(_ primary: XtreamStream, alternatives: [LiveEventChannel] = []) -> PreparedLiveMatch {
            .init(preparedAt: now.addingTimeInterval(-60), eventStart: now.addingTimeInterval(-600),
                identity: ["saved"], primary: primary, alternatives: alternatives,
                programs: programs, categoryNames: ["sports": "Sports"])
        }
        let backup = LiveEventChannel(stream: streams[1], program: entries[1], evidence: 400,
            quality: .init(name: streams[1].name))
        let matches = ["changed": saved(streams[0], alternatives: [backup]), "unrelated": saved(streams[2])]
        var fresh = programs
        fresh["epg1"] = [CurrentProgram(channelID: "epg1", title: "Another event", detail: "",
            start: entries[0].start, end: entries[0].end)]
        let freshPrograms = fresh
        let result = await Task.detached {
            TVPreparedReconciliation(matches: matches, streams: streams, categories: categories,
                programs: freshPrograms, checkGuide: true)
        }.value
        XCTAssertEqual(result.changedIDs, ["changed"])
        XCTAssertEqual(result.matches["changed"]?.primary?.id, 2)
        XCTAssertEqual(result.matches["unrelated"]?.primary?.id, 3)
        XCTAssertEqual(matches["changed"]?.primary?.id, 1, "Validation must leave the installed snapshot intact")
        let missing = TVPreparedReconciliation(matches: matches, streams: [], categories: categories,
            programs: programs, checkGuide: false)
        XCTAssertTrue(missing.matches.isEmpty)
        XCTAssertEqual(missing.changedIDs, ["changed", "unrelated"])
    }
}

@MainActor
private final class RefreshGate {
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
