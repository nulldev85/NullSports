import Foundation
import Combine

/// Where a launch's time actually goes.
///
/// The load path has been reasoned about twice now -- which step is the
/// expensive one, what a cache split would buy, what skipping a parse would
/// buy -- and neither time was it measured. This measures it: every step a
/// launch takes before the screen settles, how long it took, and how much it
/// moved, so the next change is aimed at whatever is actually slow rather than
/// at whatever looks slow in the source.
///
/// It is always on. A launch records a dozen or so entries, each a string and
/// a pair of doubles, which is not worth a setting to switch off.
@MainActor
final class StartupTrace: ObservableObject {
    static let shared = StartupTrace()

    struct Step: Identifiable {
        let id = UUID()
        /// Seconds since the trace began, so the steps read as a timeline.
        let at: Double
        let seconds: Double
        let name: String
        let detail: String?
    }

    @Published private(set) var steps: [Step] = []
    private var origin = ProcessInfo.processInfo.systemUptime
    /// Monotonic, so a clock change mid-launch cannot produce a negative step.
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private init() {}

    /// Starts a fresh timeline. Called when a provider begins loading, so
    /// switching provider measures that rather than appending to the launch.
    func begin() {
        origin = now
        steps = []
    }

    /// Times `work` and records it.
    @discardableResult
    func measure<T>(_ name: String, detail: String? = nil,
                    _ work: () async throws -> T) async rethrows -> T {
        let start = now
        let value = try await work()
        append(name, seconds: now - start, detail: detail)
        return value
    }

    /// Records something that happened without timing it -- a size, a hit, a
    /// skip. The zero duration is honest: nothing was measured.
    func note(_ name: String, _ detail: String? = nil) {
        append(name, seconds: 0, detail: detail)
    }

    func append(_ name: String, seconds: Double, detail: String?) {
        // A launch that somehow keeps recording must not grow without bound.
        guard steps.count < 200 else { return }
        steps.append(Step(at: now - origin, seconds: seconds, name: name, detail: detail))
    }

    /// The whole timeline, for the clipboard.
    var report: String {
        guard !steps.isEmpty else { return "No launch recorded yet." }
        return steps.map { step in
            let at = String(format: "%6.2fs", step.at)
            let took = step.seconds > 0 ? String(format: " (%.2fs)", step.seconds) : ""
            return "\(at)  \(step.name)\(took)" + (step.detail.map { " — \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    /// Bytes, said the way a person reads them.
    nonisolated static func size(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}
