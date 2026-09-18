import Foundation
import Combine

/// Collects the playback event log, when the viewer has switched it on.
///
/// Off by default and off in every normal install: `record` returns immediately
/// unless enabled, so the instrumented paths cost a boolean read. Nothing here
/// influences playback — it only watches.
@MainActor
final class PlaybackDiagnostics: ObservableObject {
    static let shared = PlaybackDiagnostics()
    static let storageKey = "NullSports.playbackDiagnostics"

    @Published private(set) var log = PlaybackDiagnosticsLog()
    /// Live values sampled while a stream runs, keyed for display in order.
    @Published private(set) var snapshot: [(label: String, value: String)] = []

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.storageKey)
            if !isEnabled { clear() }
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.storageKey)
    }

    /// Monotonic: immune to clock and time-zone changes, like the health model.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func record(_ text: @autoclosure () -> String) {
        guard isEnabled else { return }
        log.append(text(), at: now)
    }

    /// Marks the start of a new stream so timings read from zero again.
    func beginSession(_ text: @autoclosure () -> String) {
        guard isEnabled else { return }
        log.reset()
        log.append(text(), at: now)
    }

    func update(snapshot values: [(label: String, value: String)]) {
        guard isEnabled else { return }
        snapshot = values
    }

    func clear() {
        log.reset()
        snapshot = []
    }

    /// What gets copied to the clipboard, log and live values together.
    var report: String {
        var parts: [String] = []
        if !snapshot.isEmpty {
            parts.append("STATE\n" + snapshot.map { "  \($0.label): \($0.value)" }.joined(separator: "\n"))
        }
        if !log.isEmpty {
            parts.append("TIMELINE (seconds from stream open)\n" + log.transcript())
        }
        return parts.isEmpty ? "No playback diagnostics recorded yet." : parts.joined(separator: "\n\n")
    }
}
