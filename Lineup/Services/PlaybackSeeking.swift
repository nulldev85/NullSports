import Foundation

enum PlaybackSeekPolicy {
    static let remoteTapSkip = 15.0

    static func remoteCommandTarget(from seconds: Double, direction: Double, duration: Double) -> Double {
        let step = direction < 0 ? -remoteTapSkip : remoteTapSkip
        return clamped(seconds + step, duration: duration)
    }

    static func clamped(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(seconds, 0), max(duration - 1, 0))
    }

    static func position(x: Double, width: Double, duration: Double) -> Double {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return clamped(min(max(x / width, 0), 1) * duration, duration: duration)
    }

    /// A held remote press accelerates continuously, independent of the
    /// operating system's discrete focus-repeat cadence. Short presses use
    /// `remoteTapSkip` instead.
    static func rate(heldFor seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0.35 else { return 0 }
        return min(240, 20 + (seconds - 0.35) * 40)
    }
}

/// Decoder samples may still describe the old picture immediately after a
/// seek. Keep the committed destination until it lands or a bounded timeout.
struct PlaybackSeekLanding {
    private var target: Double?
    private var deadline: Double = 0

    mutating func expect(_ target: Double, now: Double) {
        self.target = target
        deadline = now + 4
    }

    mutating func accepts(_ position: Double, now: Double) -> Bool {
        guard isWaiting(now: now), let target else { return true }
        guard position.isFinite else { return false }
        guard abs(position - target) <= 2 else { return false }
        self.target = nil
        return true
    }

    mutating func isWaiting(now: Double) -> Bool {
        if now >= deadline { target = nil }
        return target != nil
    }

    mutating func reset() { target = nil }
}

/// The UI moves at display speed; decoder previews are capped and keep only
/// the newest destination. Releasing commits immediately and cancels old work.
@MainActor
final class PlaybackSeekCoalescer {
    private let interval: Double
    private let now: () -> Double
    private var lastSent = -Double.infinity
    private var pending: Double?
    private var lastTarget: Double?
    private var previewing = false
    private var task: Task<Void, Never>?

    init(interval: Double = 0.18, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval
        self.now = now
    }

    func preview(_ target: Double, seek: @escaping (Double) -> Void) {
        guard target.isFinite else { return }
        if previewing, pending == target || (pending == nil && lastTarget == target) { return }
        previewing = true
        pending = target
        let delay = max(0, interval - (now() - lastSent))
        if task == nil, delay == 0 {
            pending = nil
            lastSent = now()
            lastTarget = target
            seek(target)
        } else if task == nil {
            task = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.task = nil
                guard let latest = self.pending else { return }
                self.pending = nil
                self.lastSent = self.now()
                self.lastTarget = latest
                seek(latest)
            }
        }
    }

    func commit(_ target: Double, seek: (Double) -> Void) {
        let alreadySent = previewing && pending == nil && lastTarget == target
        cancel()
        guard target.isFinite else { return }
        lastSent = now()
        if !alreadySent { seek(target) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
        lastTarget = nil
        previewing = false
        lastSent = -Double.infinity
    }

    deinit { task?.cancel() }
}
