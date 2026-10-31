import XCTest
#if os(iOS)
@testable import LineupiOS
#else
@testable import Lineup
#endif

@MainActor
final class AudioSessionResponsivenessTests: XCTestCase {
    func testBlockedAudioHardwareYieldsTheUIAndPreservesOrderingAcrossReplacementPlayers() async throws {
        let entered = expectation(description: "Hardware is deliberately blocked")
        let probe = AudioSessionProbe()
        defer { probe.release.signal() }
        let work = MobileAudioSessionWork(activate: {
            let first = probe.record("activate") == 1
            if first { entered.fulfill(); _ = probe.release.wait(timeout: .now() + 3) }
        }, deactivate: { _ = probe.record("deactivate") })
        let old = NSObject(), next = NSObject()
        let first = Task { try await work.activate(for: old) }
        await fulfillment(of: [entered], timeout: 2)
        // This test and a replacement request must still run while hardware
        // is blocked. A queue.sync on the UI actor prevents reaching here.
        work.deactivate(for: old)
        let second = Task { try await work.activate(for: next) }
        try await waitForHolders(work, count: 1)
        XCTAssertEqual(probe.events, ["activate"])
        probe.release.signal()
        try await first.value
        try await second.value
        work.deactivate(for: next)
        await work.drain()
        XCTAssertEqual(probe.events, ["activate", "deactivate", "activate", "deactivate"])
        XCTAssertTrue(probe.hardwareWasAlwaysOffMain)
    }

    func testOlderFailedActivationCannotRemoveTheSamePlayersNewLease() async throws {
        let entered = expectation(description: "First activation entered")
        let probe = AudioSessionProbe()
        defer { probe.release.signal() }
        let work = MobileAudioSessionWork(activate: {
            if probe.record("activate") == 1 {
                entered.fulfill()
                _ = probe.release.wait(timeout: .now() + 3)
                throw URLError(.cannotConnectToHost)
            }
        }, deactivate: { _ = probe.record("deactivate") })
        let player = NSObject()
        let stale = Task { try await work.activate(for: player) }
        await fulfillment(of: [entered], timeout: 2)
        work.deactivate(for: player)
        let current = Task { try await work.activate(for: player) }
        try await waitForHolders(work, count: 1)
        probe.release.signal()
        do { try await stale.value; XCTFail("The deliberately failed activation must fail") } catch {}
        try await current.value
        work.deactivate(for: player)
        await work.drain()
        XCTAssertEqual(probe.events, ["activate", "deactivate", "activate", "deactivate"],
            "An obsolete completion must not remove the replacement's audio lease")
    }

    func testFailedActivationCleansUpAnotherRequestThatWasCanceledWhileQueued() async throws {
        let entered = expectation(description: "First activation is blocked")
        let probe = AudioSessionProbe()
        defer { probe.release.signal() }
        let work = MobileAudioSessionWork(activate: {
            if probe.record("activate") == 1 {
                entered.fulfill()
                _ = probe.release.wait(timeout: .now() + 3)
                throw URLError(.cannotConnectToHost)
            }
        }, deactivate: { _ = probe.record("deactivate") })
        let firstPlayer = NSObject(), secondPlayer = NSObject()
        let first = Task { try await work.activate(for: firstPlayer) }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await work.activate(for: secondPlayer) }
        try await waitForHolders(work, count: 2)
        work.deactivate(for: secondPlayer)
        probe.release.signal()
        do { try await first.value; XCTFail("The first activation must fail") } catch {}
        try await second.value
        await work.drain()
        XCTAssertEqual(work.holderCount, 0)
        XCTAssertEqual(probe.events.last, "deactivate", "No stopped player may leave an orphan audio session")
    }

    #if os(iOS)
    func testStoppingDuringAudioActivationCannotOpenADecoderAfterLeavingTheTab() async throws {
        let entered = expectation(description: "Activation started")
        let probe = AudioSessionProbe()
        let work = MobileAudioSessionWork(activate: {
            _ = probe.record("activate")
            entered.fulfill()
            _ = probe.release.wait(timeout: .now() + 3)
        }, deactivate: { _ = probe.record("deactivate") })
        let controller = MobilePlaybackController(audioSession: work)
        defer { controller.shutdown(); probe.release.signal() }
        let began = ProcessInfo.processInfo.systemUptime
        controller.start(urls: [try XCTUnwrap(URL(string: "https://audio-test.invalid/live.m3u8"))])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5,
            "Start must return control before audio hardware is ready")
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(controller.loading)
        controller.shutdown()
        probe.release.signal()
        await work.drain()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.aetherSession)
        XCTAssertNil(controller.mpvSession)
        XCTAssertNil(controller.systemPlayer.currentItem)
        XCTAssertNil(controller.player.media)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.loading)
        XCTAssertEqual(probe.events, ["activate", "deactivate"])
    }

    func testPauseIntentWhileAudioIsWaitingPreventsOpeningADecoder() async throws {
        let entered = expectation(description: "Activation started")
        let probe = AudioSessionProbe()
        let work = MobileAudioSessionWork(activate: {
            _ = probe.record("activate")
            entered.fulfill()
            _ = probe.release.wait(timeout: .now() + 3)
        }, deactivate: { _ = probe.record("deactivate") })
        let controller = MobilePlaybackController(audioSession: work)
        defer { controller.shutdown(); probe.release.signal() }
        controller.start(urls: [try XCTUnwrap(URL(string: "https://audio-test.invalid/live.m3u8"))])
        await fulfillment(of: [entered], timeout: 2)
        controller.toggle()
        probe.release.signal()
        await work.drain()
        try await Task.sleep(for: .milliseconds(50))
        controller.handleScenePhase(active: false)
        controller.handleScenePhase(active: true)
        XCTAssertNil(controller.aetherSession)
        XCTAssertNil(controller.mpvSession)
        XCTAssertNil(controller.systemPlayer.currentItem)
        XCTAssertNil(controller.player.media)
        XCTAssertFalse(controller.isPlaying, "A delayed audio completion or return to the app must preserve Pause")
    }
    #endif

    private func waitForHolders(_ work: MobileAudioSessionWork, count: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while work.holderCount != count, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(work.holderCount, count)
        if work.holderCount != count { throw URLError(.timedOut) }
    }
}

private final class AudioSessionProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recorded: [String] = []
    private var offMain = true
    var events: [String] { lock.withLock { recorded } }
    var hardwareWasAlwaysOffMain: Bool { lock.withLock { offMain } }
    func record(_ event: String) -> Int {
        lock.withLock {
            recorded.append(event)
            offMain = offMain && !Thread.isMainThread
            return recorded.filter { $0 == "activate" }.count
        }
    }
}
