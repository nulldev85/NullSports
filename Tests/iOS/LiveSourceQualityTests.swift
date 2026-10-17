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
        XCTAssertEqual(paths, ["/hd", "/fhd", "/hd"])
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
            return LiveSourceQuality(width: url.path == "/hd" ? 1280 : 1920,
                height: url.path == "/hd" ? 720 : 1080, frameRate: 60)
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
}
