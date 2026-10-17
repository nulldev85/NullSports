#if os(tvOS)
import Foundation
import LineupAetherPlayback

/// VLC can keep its audio clock running after video output stops advancing.
/// Keep a checkpoint supported by real frame-counter movement, not that clock.
/// Unavailable counters never establish a frozen picture.
struct TVVideoProgressAnchor {
    private var frames: Int?
    private var at: TimeInterval?
    private var position: TimeInterval?

    init() {}

    mutating func reset() { self = TVVideoProgressAnchor() }

    mutating func observe(now: TimeInterval, position: TimeInterval, frames: Int?, playing: Bool, video: Bool) {
        guard let frames, frames > 0 else { reset(); return }
        guard now.isFinite, position.isFinite, position >= 0, playing, video else { return }
        if self.frames != frames {
            self.frames = frames
            self.at = now
            self.position = position
        }
    }

    func heldPosition(now: TimeInterval, clock: TimeInterval, expectedFrameRate: Double?) -> TimeInterval? {
        // A low-rate slideshow or an unknown cadence is not evidence of an
        // output freeze. The regular recovery policy still owns those sources.
        guard let rate = expectedFrameRate, rate.isFinite, rate >= 10,
              let at, let position, now - at >= 3, clock.isFinite, clock > position else { return nil }
        return position
    }

    func recoveryPosition(clock: TimeInterval, pictureStalled: Bool) -> TimeInterval {
        let candidate = pictureStalled ? min(position ?? clock, clock) : clock
        return max(0, candidate - 2)
    }
}

/// Low-frequency evidence in the existing on-device Playback Log. Values are
/// measurements or absent; a missing metric never becomes a confident zero.
struct TVPlaybackLogSampler {
    private var lastFormat: String?
    private var lastState: TVPlaybackState?
    private var nextSample: TimeInterval = 0
    private var lastSample: TimeInterval?

    init() {}

    mutating func reset() { self = TVPlaybackLogSampler() }

    mutating func lines(now: TimeInterval, engine: String, state: TVPlaybackState,
                        ready: Bool, height: Int, info: PlaybackMediaInfo,
                        position: TimeInterval, duration: TimeInterval,
                        diagnostics: PlaybackDiagnosticsSnapshot, clock: Double? = nil) -> [String] {
        var lines: [String] = []
        let format = ([engine] + (height > 0 ? ["\(height)p"] : []) + info.badges).joined(separator: " · ")
        if ready, height > 0 || !info.badges.isEmpty, format != lastFormat {
            lastFormat = format
            lines.append("Format: " + format)
        }
        let stateChanged = state != lastState
        guard ready, state == .playing || state == .buffering,
              now >= nextSample || (stateChanged && (lastSample.map { now - $0 >= 5 } ?? true)) else { return lines }
        lastState = state
        lastSample = now
        nextSample = now + 30
        var values = [engine, state == .buffering ? "buffering" : "playing",
                      clockLabel(position) + " / " + clockLabel(duration)]
        if let clock, clock.isFinite { values.append("player clock " + clockLabel(clock)) }
        if let route = safeName(diagnostics.route) { values.append("route " + route) }
        if let decoder = safeName(diagnostics.decoder) { values.append("decoder " + decoder) }
        if let bytes = diagnostics.bytesRead, bytes >= 0 { values.append("read \(bytes) B") }
        if let frames = diagnostics.displayedFrames, frames >= 0 { values.append("displayed \(frames) frames") }
        if let drops = diagnostics.droppedFrames, drops >= 0 { values.append("dropped \(drops) frames") }
        append(diagnostics.nativeBufferSeconds, name: "native buffer", unit: "s", to: &values)
        append(diagnostics.decodedVideoSeconds, name: "decoded video", unit: "s", to: &values)
        append(diagnostics.networkMbps, name: "source transfer", unit: "Mbps", to: &values)
        append(diagnostics.frameDelaySeconds, name: "frame delay total", unit: "s", to: &values)
        if let bytes = diagnostics.sourceWindowBytes, bytes >= 0 { values.append("source window \(bytes) B") }
        if diagnostics.nativeFrameRecoveryEnabled { values.append("native frame recovery configured") }
        lines.append("Playback: " + values.joined(separator: "; "))
        return lines
    }

    private func clockLabel(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) / 2 else { return "unknown" }
        return PlaybackJournal.clock(value)
    }

    private func append(_ value: Double?, name: String, unit: String, to values: inout [String]) {
        guard let value, value.isFinite, value >= 0 else { return }
        values.append(name + " " + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) + " " + unit)
    }

    private func safeName(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._()-")).contains($0) }) else { return nil }
        return name
    }
}
#endif
