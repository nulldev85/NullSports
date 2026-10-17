import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class LiveSourceQualityTests: XCTestCase {
    func testSelectsExactMeasuredURLAndKeepsExistingLanguagePriority() async {
        let recorder = Recorder()
        let verifier = LiveQualityVerifier(defaults: nil) { url, _ in await recorder.measure(url) }
        let first = LiveQualityVerifier.Candidate(id: 1,
            urls: [URL(string: "https://example.test/hd")!, URL(string: "https://example.test/fhd")!], context: "event")
        let second = LiveQualityVerifier.Candidate(id: 2,
            urls: [URL(string: "https://example.test/hd")!], context: "event")
        let chosen = await verifier.best([first, second], fallback: 2)
        XCTAssertEqual(chosen.streamID, 1)
        XCTAssertEqual(chosen.urlIndex, 1, "Playback must use the measured TS/HLS variant, not just the channel's first URL")
        let cached = await verifier.best([first, second], fallback: 2)
        XCTAssertEqual(cached, chosen)
        let paths = await recorder.paths
        XCTAssertEqual(paths, ["/hd", "/fhd"], "Duplicate event/source URLs are measured once")
        var foreign = first
        foreign.languageRank = 1
        let english = await verifier.best([foreign, second], fallback: 2)
        XCTAssertEqual(english.streamID, 2, "Quality ranking does not discard the viewer's existing language policy")
    }

    func testMeasurementsSurviveRelaunchAndExpiredRecordsAreRechecked() async throws {
        let suite = "LiveSourceQualityTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        let candidates = [LiveQualityVerifier.Candidate(id: 1,
            urls: [URL(string: "https://example.test/fhd")!], context: "provider|event")]
        let first = LiveQualityVerifier(defaults: defaults) { url, _ in await recorder.measure(url) }
        _ = await first.best(candidates, fallback: 1)
        let reopened = LiveQualityVerifier(defaults: defaults) { url, _ in await recorder.measure(url) }
        _ = await reopened.best(candidates, fallback: 1)
        let beforeExpiry = await recorder.paths
        XCTAssertEqual(beforeExpiry.count, 1)
        let expired = [LiveQualityVerifier.key(candidates[0]): LiveQualityVerifier.Entry(
            quality: LiveSourceQuality(width: 1280, height: 720, frameRate: 30), expires: Date(timeIntervalSinceNow: -1))]
        defaults.set(try JSONEncoder().encode(expired), forKey: "lineup.live-source-quality.v1")
        let stale = LiveQualityVerifier(defaults: defaults) { url, _ in await recorder.measure(url) }
        _ = await stale.best(candidates, fallback: 1)
        let afterExpiry = await recorder.paths
        XCTAssertEqual(afterExpiry.count, 2)
    }

    actor Recorder {
        var paths: [String] = []
        func measure(_ url: URL) -> LiveSourceQuality {
            paths.append(url.path)
            return LiveSourceQuality(width: url.path.hasPrefix("/hd") ? 1280 : 1920,
                height: url.path.hasPrefix("/hd") ? 720 : 1080, frameRate: 60)
        }
    }

    func testMeasuresRatherThanTrustingProviderOrderAndReusesCache() async throws {
        let recorder = Recorder()
        let verifier = LiveQualityVerifier(defaults: nil) { url, _ in await recorder.measure(url) }
        let candidates = [
            LiveQualityVerifier.Candidate(id: 1, urls: [URL(string: "https://example.test/hd")!], context: "event-1"),
            LiveQualityVerifier.Candidate(id: 2, urls: [URL(string: "https://example.test/fhd")!], context: "event-1")
        ]
        let first = await verifier.best(candidates, fallback: 1)
        let second = await verifier.best(candidates, fallback: 1)
        XCTAssertEqual(first.streamID, 2)
        XCTAssertEqual(second.streamID, 2)
        let paths = await recorder.paths
        XCTAssertEqual(paths, ["/hd", "/fhd"], "A second start reuses measured results")
        let changed = candidates.map { LiveQualityVerifier.Candidate(id: $0.id, urls: $0.urls, context: "event-2") }
        _ = await verifier.best(changed, fallback: 1)
        let afterEvent = await recorder.paths
        XCTAssertEqual(afterEvent.count, 4, "Measurements do not bleed into the next event")
    }

    func testFailureIsUnknownAndNeverBeatsMeasuredQuality() async {
        let verifier = LiveQualityVerifier(defaults: nil) { url, _ in
            if url.path == "/fail" { throw URLError(.timedOut) }
            return LiveSourceQuality(width: 1280, height: 720, frameRate: 60)
        }
        let candidates = [
            LiveQualityVerifier.Candidate(id: 1, urls: [URL(string: "https://example.test/fail")!], context: "event"),
            LiveQualityVerifier.Candidate(id: 2, urls: [URL(string: "https://example.test/works")!], context: "event")
        ]
        let best = await verifier.best(candidates, fallback: 1)
        XCTAssertEqual(best.streamID, 2)
        let failed = await verifier.best([candidates[0]], fallback: 1)
        XCTAssertEqual(failed.streamID, 1, "No measurement preserves the existing verified-match fallback")
        XCTAssertFalse(LiveSourceQuality(width: 0, height: 1080, frameRate: nil).isValid)
    }

    func testCacheIdentityIncludesProviderSourceAndCredentialsWithoutPersistingThem() {
        let first = LiveQualityVerifier.Candidate(id: 1, urls: [URL(string: "https://example.test/live?token=secret")!], context: "provider-1|event")
        let second = LiveQualityVerifier.Candidate(id: 1, urls: first.urls, context: "provider-2|event")
        XCTAssertNotEqual(LiveQualityVerifier.key(first), LiveQualityVerifier.key(second))
        XCTAssertFalse(LiveQualityVerifier.key(first).contains("secret"))
        XCTAssertEqual(LiveQualityVerifier.key(first).count, 64)
        XCTAssertTrue(LiveSourceQuality(width: 1920, height: 1080, frameRate: 60)
            .outranks(LiveSourceQuality(width: 1920, height: 1080, frameRate: 30)))
    }

    func testOneBudgetCoversAllChannelsAndComparesChannelsBeforeAlternateURLs() async {
        let clock = QualityTestClock()
        let recorder = BudgetRecorder(clock: clock)
        let verifier = LiveQualityVerifier(defaults: nil, uptime: { clock.now }) { url, timeout in
            await recorder.measure(url, timeout: timeout)
        }
        let candidates = (1...3).map { id in
            LiveQualityVerifier.Candidate(id: id, urls: [
                URL(string: "https://example.test/\(id)-first")!,
                URL(string: "https://example.test/\(id)-alternate")!
            ], context: "event")
        }
        let chosen = await verifier.best(candidates, fallback: 1)
        let paths = await recorder.paths
        let timeouts = await recorder.timeouts
        XCTAssertEqual(Array(paths.prefix(3)), ["/1-first", "/2-first", "/3-first"])
        XCTAssertEqual(chosen.streamID, 2)
        XCTAssertEqual(clock.now, LiveQualityVerifier.startupBudget, accuracy: 0.0001)
        XCTAssertTrue(timeouts.allSatisfy { $0 <= LiveQualityVerifier.perURLBudget })
        XCTAssertEqual(paths.count, 5, "The last URL only gets the remaining budget, not another full timeout")
    }

    func testReadsLaterCachedQualityEvenWhenTheFirstCandidateHasNoTimeLeft() async {
        let recorder = Recorder()
        let verifier = LiveQualityVerifier(defaults: nil) { url, _ in await recorder.measure(url) }
        let cached = LiveQualityVerifier.Candidate(id: 2, urls: [URL(string: "https://example.test/fhd")!], context: "event")
        _ = await verifier.best([cached], fallback: 2)
        let cold = LiveQualityVerifier.Candidate(id: 1, urls: [URL(string: "https://example.test/cold")!], context: "event")
        let chosen = await verifier.best([cold, cached], fallback: 1, budget: 0)
        XCTAssertEqual(chosen.streamID, 2)
        let paths = await recorder.paths
        XCTAssertEqual(paths, ["/fhd"], "Reading cached candidates never needs another socket")
    }

    func testPartialURLResultsSurviveRelaunchWithoutRepeatingFinishedMeasurements() async throws {
        let suite = "PartialQuality.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = QualityTestClock()
        let recorder = BudgetRecorder(clock: clock)
        let candidate = LiveQualityVerifier.Candidate(id: 1,
            urls: [URL(string: "https://example.test/hd")!, URL(string: "https://example.test/fhd")!], context: "event")
        let first = LiveQualityVerifier(defaults: defaults, uptime: { clock.now }) { url, timeout in
            await recorder.measure(url, timeout: timeout)
        }
        _ = await first.best([candidate], fallback: 1, budget: 0.5)
        let reopened = LiveQualityVerifier(defaults: defaults, uptime: { clock.now }) { url, timeout in
            await recorder.measure(url, timeout: timeout)
        }
        let chosen = await reopened.best([candidate], fallback: 1)
        XCTAssertEqual(chosen.urlIndex, 1)
        let paths = await recorder.paths
        XCTAssertEqual(paths, ["/hd", "/fhd"])
    }

    func testDirectTSIsCheckedFirstButHigherQualityHLSIsStillMeasuredAndSelectable() async {
        let recorder = Recorder()
        let verifier = LiveQualityVerifier(defaults: nil) { url, _ in await recorder.measure(url) }
        let candidate = LiveQualityVerifier.Candidate(id: 1, urls: [
            URL(string: "https://example.test/fhd.m3u8")!, URL(string: "https://example.test/hd.ts")!
        ], context: "event")
        let chosen = await verifier.best([candidate], fallback: 1)
        let paths = await recorder.paths
        XCTAssertEqual(paths, ["/hd.ts", "/fhd.m3u8"])
        XCTAssertEqual(chosen.urlIndex, 0, "Alternate transport quality remains eligible")
    }

    #if os(iOS)
    func testLowerQualityTSDoesNotUseWholeBudgetBeforeSameChannelsFullHDHLS() async {
        let clock = QualityTestClock()
        let recorder = BudgetRecorder(clock: clock)
        let verifier = LiveQualityVerifier(defaults: nil, uptime: { clock.now }) { url, timeout in
            await recorder.measure(url, timeout: timeout)
        }
        let channels = (1...5).map { id in
            LiveQualityVerifier.Candidate(id: id, urls: [
                URL(string: "https://example.test/fhd-\(id).m3u8")!,
                URL(string: "https://example.test/hd-\(id).ts")!
            ], context: "ohio-state-event", advertisedHeight: 1080)
        }
        let selected = await verifier.best(channels, fallback: 5)
        let paths = await recorder.paths
        XCTAssertEqual(Array(paths.prefix(2)), ["/hd-1.ts", "/fhd-1.m3u8"])
        XCTAssertEqual(selected.streamID, 1)
        XCTAssertEqual(selected.urlIndex, 0)
        XCTAssertEqual(selected.quality?.height, 1080)
        XCTAssertLessThanOrEqual(clock.now, LiveQualityVerifier.startupBudget)
    }

    func testCachedPartial720pStillChecksUnmeasured1080pAlternateAfterRelaunch() async throws {
        let suite = "PartialTransportQuality.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = QualityTestClock()
        let recorder = BudgetRecorder(clock: clock)
        let channel = LiveQualityVerifier.Candidate(id: 1, urls: [
            URL(string: "https://example.test/fhd.m3u8")!, URL(string: "https://example.test/hd.ts")!
        ], context: "event", advertisedHeight: 1080)
        let first = LiveQualityVerifier(defaults: defaults, uptime: { clock.now }) { url, timeout in
            await recorder.measure(url, timeout: timeout)
        }
        let partial = await first.best([channel], fallback: 1, budget: 0.9)
        XCTAssertEqual(partial.quality?.height, 720)
        let reopened = LiveQualityVerifier(defaults: defaults, uptime: { clock.now }) { url, timeout in
            await recorder.measure(url, timeout: timeout)
        }
        let selected = await reopened.best([channel], fallback: 1)
        let paths = await recorder.paths
        XCTAssertEqual(paths, ["/hd.ts", "/fhd.m3u8"], "Do not repeat measured TS or freeze a partial 720p result")
        XCTAssertEqual(selected.urlIndex, 0)
        XCTAssertEqual(selected.quality?.height, 1080)
    }

    func testHigherQualityHLSGetsTimeForPlaylistAndMediaWithoutExtendingStartupBudget() async {
        let clock = QualityTestClock()
        let verifier = LiveQualityVerifier(defaults: nil, uptime: { clock.now }) { url, timeout in
            let hls = url.pathExtension == "m3u8"
            let needs: TimeInterval = hls ? 1.6 : 0.4
            clock.advance(min(needs, timeout))
            guard timeout >= needs else { throw URLError(.timedOut) }
            return .init(width: hls ? 1920 : 1280, height: hls ? 1080 : 720, frameRate: 60)
        }
        let channel = LiveQualityVerifier.Candidate(id: 1, urls: [
            URL(string: "https://example.test/source.m3u8")!, URL(string: "https://example.test/source.ts")!
        ], context: "event", advertisedHeight: 1080)
        let selected = await verifier.best([channel], fallback: 1)
        XCTAssertEqual(selected.urlIndex, 0)
        XCTAssertEqual(selected.quality?.height, 1080)
        XCTAssertEqual(clock.now, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(clock.now, LiveQualityVerifier.startupBudget)
    }

    func testAdvertisedFHDStillReportsOnly720pWhenBothTransportsActuallyMeasure720p() async {
        let verifier = LiveQualityVerifier(defaults: nil) { _, _ in
            .init(width: 1280, height: 720, frameRate: 60)
        }
        let channel = LiveQualityVerifier.Candidate(id: 1, urls: [
            URL(string: "https://example.test/source.m3u8")!, URL(string: "https://example.test/source.ts")!
        ], context: "event", advertisedHeight: 1080)
        let selected = await verifier.best([channel], fallback: 1)
        XCTAssertEqual(selected.quality?.height, 720, "Provider labels may prioritize checks but cannot invent quality")
    }
    #endif

    func testNewSelectionCancelsOldProbeAndWaitsForItsCloseBeforeOpeningAnother() async {
        await checkSupersession(expireWhileClosing: false)
    }

    func testForeignProbesDoNotDelayAnAlreadyMeasuredPreferredLanguage() async {
        let recorder = Recorder()
        let verifier = LiveQualityVerifier(defaults: nil) { url, _ in await recorder.measure(url) }
        let english = LiveQualityVerifier.Candidate(id: 1,
            urls: [URL(string: "https://example.test/hd")!], context: "event")
        let foreign = LiveQualityVerifier.Candidate(id: 2,
            urls: [URL(string: "https://example.test/fhd")!], context: "event", languageRank: 1)
        let chosen = await verifier.best([foreign, english], fallback: 2)
        XCTAssertEqual(chosen.streamID, 1)
        let paths = await recorder.paths
        XCTAssertEqual(paths, ["/hd"])
    }

    func testQueueCleanupConsumesTheNewRequestsBudgetInsteadOfStartingAnotherFullScan() async {
        await checkSupersession(expireWhileClosing: true)
    }

    private func checkSupersession(expireWhileClosing: Bool) async {
        let started = expectation(description: "old source opened")
        let cancelled = expectation(description: "old source received cancellation")
        let clock = QualityTestClock()
        let gate = CancellationGate(started: started, cancelled: cancelled)
        let verifier = LiveQualityVerifier(defaults: nil, uptime: { clock.now }) { url, _ in
            try await gate.measure(url)
        }
        let oldCandidate = LiveQualityVerifier.Candidate(id: 1,
            urls: [URL(string: "https://example.test/old")!], context: "event")
        let newCandidate = LiveQualityVerifier.Candidate(id: 2,
            urls: [URL(string: "https://example.test/new")!], context: "event")
        let old = Task { await verifier.best([oldCandidate], fallback: 1) }
        await fulfillment(of: [started], timeout: 5)
        let current = Task { await verifier.best([newCandidate], fallback: 2) }
        await fulfillment(of: [cancelled], timeout: 5)
        let pathsBeforeClose = await gate.paths
        XCTAssertEqual(pathsBeforeClose, ["/old"], "The next source cannot overlap native cleanup")
        if expireWhileClosing { clock.advance(5) }
        await gate.closeOld()
        let oldSelection = await old.value
        let newSelection = await current.value
        XCTAssertTrue(oldSelection.wasCancelled)
        XCTAssertFalse(newSelection.wasCancelled)
        XCTAssertEqual(newSelection.streamID, 2)
        let paths = await gate.paths
        let highWater = await gate.highWater
        XCTAssertEqual(paths, expireWhileClosing ? ["/old"] : ["/old", "/new"])
        XCTAssertEqual(highWater, 1)
    }

    actor BudgetRecorder {
        let clock: QualityTestClock
        var paths: [String] = []
        var timeouts: [TimeInterval] = []
        init(clock: QualityTestClock) { self.clock = clock }
        func measure(_ url: URL, timeout: TimeInterval) -> LiveSourceQuality {
            paths.append(url.path)
            timeouts.append(timeout)
            clock.advance(min(0.9, timeout))
            let fhd = url.path.contains("2-") || url.path.contains("fhd")
            return .init(width: fhd ? 1920 : 1280, height: fhd ? 1080 : 720, frameRate: 60)
        }
    }

    actor CancellationGate {
        let started: XCTestExpectation
        let cancelled: XCTestExpectation
        var release: CheckedContinuation<Void, Never>?
        var shouldClose = false
        var paths: [String] = []
        var active = 0
        var highWater = 0
        init(started: XCTestExpectation, cancelled: XCTestExpectation) {
            self.started = started
            self.cancelled = cancelled
        }
        func measure(_ url: URL) async throws -> LiveSourceQuality {
            paths.append(url.path)
            active += 1
            highWater = max(highWater, active)
            defer { active -= 1 }
            if url.path == "/old" {
                let cancelled = self.cancelled
                await withTaskCancellationHandler(operation: {
                    await withCheckedContinuation { continuation in
                        if shouldClose { continuation.resume() }
                        else { release = continuation }
                        started.fulfill()
                    }
                }, onCancel: { cancelled.fulfill() })
                try Task.checkCancellation()
            }
            return .init(width: 1920, height: 1080, frameRate: 60)
        }
        func closeOld() { shouldClose = true; release?.resume(); release = nil }
    }
}

final class QualityTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return seconds }
    func advance(_ value: TimeInterval) { lock.lock(); seconds += value; lock.unlock() }
}
