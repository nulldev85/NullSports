import XCTest
import LineupAetherPlayback
@testable import Lineup

final class TVPlaybackReliabilityTests: XCTestCase {
    func testFrozenVideoCannotAdvanceTheCheckpointWithTheAudioClock() {
        var anchor = TVVideoProgressAnchor()
        anchor.observe(now: 0, position: 599, frames: 100, playing: true, video: true)
        anchor.observe(now: 1, position: 600, frames: 124, playing: true, video: true)
        XCTAssertNil(anchor.heldPosition(now: 2, clock: 601, expectedFrameRate: 24), "Sparse frame-stat updates are allowed")
        XCTAssertNil(anchor.heldPosition(now: 30, clock: 630, expectedFrameRate: nil))
        XCTAssertNil(anchor.heldPosition(now: 30, clock: 630, expectedFrameRate: 0.1))
        for second in 4...61 {
            anchor.observe(now: Double(second), position: Double(599 + second), frames: 124, playing: true, video: true)
            XCTAssertEqual(anchor.heldPosition(now: Double(second), clock: Double(599 + second), expectedFrameRate: 24), 600)
        }
        XCTAssertEqual(anchor.recoveryPosition(clock: 660, pictureStalled: true), 598)
        XCTAssertEqual(anchor.recoveryPosition(clock: 660, pictureStalled: false), 658)
        anchor.observe(now: 62, position: 661, frames: 125, playing: true, video: true)
        XCTAssertNil(anchor.heldPosition(now: 62, clock: 661, expectedFrameRate: 24))
    }

    func testMissingOrResetFrameCountersNeverClaimAFrozenPicture() {
        var anchor = TVVideoProgressAnchor()
        for frames in [nil, 0, -1] as [Int?] {
            anchor.observe(now: 0, position: 600, frames: frames, playing: true, video: true)
            XCTAssertNil(anchor.heldPosition(now: 90, clock: 690, expectedFrameRate: 24))
        }
        anchor.observe(now: 100, position: 700, frames: 100, playing: true, video: true)
        anchor.reset() // seek, pause, track change or a new source
        XCTAssertNil(anchor.heldPosition(now: 200, clock: 1200, expectedFrameRate: 24))
        anchor.observe(now: 200, position: 1200, frames: 1, playing: true, video: true)
        XCTAssertNil(anchor.heldPosition(now: 201, clock: 1201, expectedFrameRate: 24))
    }

    @MainActor
    func testPlaybackLogRetainsMeasuredFormatsAndSeparatesBufferKinds() {
        var sampler = TVPlaybackLogSampler()
        let info = PlaybackMediaInfo(videoCodec: "h264", frameRate: 23.976, audioCodec: "dts", audioChannels: 6)
        let stats = PlaybackDiagnosticsSnapshot(route: "software", decoder: "h264",
            bytesRead: 20_000_000, droppedFrames: 8, decodedVideoSeconds: 0.25,
            sourceWindowBytes: 8_000_000, networkMbps: 18.5, frameDelaySeconds: 0.75)
        let first = sampler.lines(now: 100, engine: "AetherEngine", state: .playing, ready: true,
            height: 1080, info: info, position: 180, duration: 3600, diagnostics: stats, clock: 190)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first[0].contains("1080p"))
        XCTAssertTrue(first[0].contains("H.264"))
        XCTAssertTrue(first[0].contains("DTS"))
        XCTAssertTrue(first[1].contains("decoded video 0.25 s"))
        XCTAssertTrue(first[1].contains("source window 8000000 B"))
        XCTAssertTrue(first[1].contains("player clock 3:10"))
        XCTAssertFalse(first[1].contains("native buffer"), "Unknown native depth is absent, not zero")
        XCTAssertTrue(sampler.lines(now: 101, engine: "AetherEngine", state: .playing, ready: true,
            height: 1080, info: info, position: 181, duration: 3600, diagnostics: stats).isEmpty)
        XCTAssertEqual(sampler.lines(now: 130, engine: "AetherEngine", state: .playing, ready: true,
            height: 1080, info: info, position: 210, duration: 3600, diagnostics: stats).count, 1)
        sampler.reset()
        XCTAssertEqual(sampler.lines(now: 131, engine: "VLC", state: .playing, ready: true,
            height: 720, info: .init(audioCodec: "aac"), position: 0, duration: 3600,
            diagnostics: .init()).count, 2)
    }

    @MainActor
    func testPlaybackLogOmitsNonFiniteValuesAndPrivateAddressesAndBoundsFlickeringStates() {
        var sampler = TVPlaybackLogSampler()
        let privateValue = "https://secret.invalid/stream?api_key=private"
        let stats = PlaybackDiagnosticsSnapshot(route: privateValue, decoder: privateValue,
            nativeBufferSeconds: .nan, decodedVideoSeconds: -.infinity, networkMbps: .infinity)
        let first = sampler.lines(now: 100, engine: "VLC", state: .playing, ready: true,
            height: 720, info: .init(), position: .nan, duration: .infinity, diagnostics: stats).joined()
        XCTAssertFalse(first.contains("secret"))
        XCTAssertFalse(first.contains("NaN"))
        XCTAssertFalse(first.contains("native buffer"))
        XCTAssertTrue(first.contains("unknown"))
        for tick in 1...9 {
            XCTAssertTrue(sampler.lines(now: 100 + Double(tick) / 2, engine: "VLC",
                state: tick.isMultiple(of: 2) ? .playing : .buffering, ready: true, height: 720,
                info: .init(), position: 120, duration: 3600, diagnostics: stats).isEmpty)
        }
        XCTAssertEqual(sampler.lines(now: 105, engine: "VLC", state: .buffering, ready: true,
            height: 720, info: .init(), position: 120, duration: 3600, diagnostics: stats).count, 1)
    }
}
