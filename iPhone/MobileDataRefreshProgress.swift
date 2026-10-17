import Combine
import Foundation

/// The iPhone indicator follows the work producing the current channel/guide
/// results. It never extrapolates a percentage from elapsed or historical time.
@MainActor
final class DataRefreshProgress: ObservableObject {
    enum Step: Int, Comparable, Sendable {
        case channels, channelReading, guide, guideReading, indexing, matching, applying

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .channels: "Loading Channels"
            case .channelReading: "Reading Channels"
            case .guide: "Loading TV Guide"
            case .guideReading: "Reading TV Guide"
            case .indexing: "Preparing Channels"
            case .matching: "Matching Games"
            case .applying: "Updating Channels"
            }
        }
    }

    struct Status: Equatable {
        let step: Step
        let percent: Int?
        var completed = false

        var detail: String {
            if completed { return "Up to Date · 100%" }
            return step.title + (percent.map { " · \($0)%" } ?? "")
        }
    }

    /// Each callback belongs to one operation. Finishing an older matching
    /// pass cannot finish, restart or hold open the pass that replaced it.
    struct Work: Equatable, Sendable {
        fileprivate let id = UUID()
        fileprivate let lane: Step
    }

    private struct Activity {
        let work: Work
        var step: Step
        var percent: Int?
        var fraction: Double = 0
    }

    @Published private(set) var status: Status?
    /// One stable bar for the whole refresh. Only measured bytes, completed
    /// games and installed phases move it; unknown work holds its last value.
    @Published private(set) var fraction: Double = 0
    private let showAfter: TimeInterval
    private var profileID: UUID?
    private var beganAt: Date?
    private var activities: [Step: Activity] = [:]
    private var planned: Set<Step> = []
    private var done: Set<Step> = []
    private var completed = false
    private var failed = false
    private var showing: Task<Void, Never>?
    private var ending: Task<Void, Never>?

    init(showAfter: TimeInterval = 0.6) {
        self.showAfter = showAfter
    }

    func plan(_ steps: [Step], profile: UUID) {
        if let profileID, profileID != profile { cancel() }
        if beganAt == nil || completed {
            ending?.cancel()
            ending = nil
            completed = false
            failed = false
            beganAt = Date()
            profileID = profile
            status = nil
            fraction = 0
            planned = []
            done = []
            showing?.cancel()
            showing = Task { [weak self, showAfter] in
                do { try await Task.sleep(for: .seconds(max(0, showAfter))) } catch { return }
                self?.publish()
            }
        }
        for step in steps {
            switch step {
            case .channelReading: planned.insert(.channels)
            case .guideReading: planned.insert(.guide)
            case .applying: planned.insert(.matching)
            default: planned.insert(step)
            }
        }
        if planned.contains(.matching) { planned.insert(.indexing) }
        // A cached index may already be matching when the network refresh
        // starts. Its current operation is retained; a score poll alone does
        // not call plan and therefore never opens a refresh indicator.
        publish()
    }

    @discardableResult
    func start(_ step: Step) -> Work {
        if !completed {
            ending?.cancel()
            ending = nil
        }
        if step == .indexing {
            // A new index replaces the input used by an older match pass.
            activities[.matching] = nil
            done.remove(.matching)
        }
        done.remove(step)
        if beganAt != nil, !completed { planned.insert(step) }
        let work = Work(lane: step)
        activities[step] = Activity(work: work, step: step)
        publish()
        return work
    }

    func download(_ work: Work, _ update: XtreamDownloadUpdate) {
        guard var activity = current(work) else { return }
        if update.finished {
            // Downloaded bytes are not decoded data. Name the actual next
            // phase rather than displaying 99% while parsing/comparing it.
            activity.step = work.lane == .guide ? .guideReading : .channelReading
            activity.percent = nil
            activity.fraction = work.lane == .guide ? 0.75 : 0.95
        } else if let expected = update.expected, expected > 0 {
            activity.percent = min(100, Int(max(0, min(1, Double(update.received) / Double(expected))) * 100))
            activity.fraction = Double(activity.percent ?? 0) / 100 * (work.lane == .guide ? 0.75 : 0.95)
        } else {
            // Chunked/compressed responses and playlists need not have a
            // trustworthy length. A spinner is honest; last run's size isn't.
            activity.percent = nil
        }
        activities[work.lane] = activity
        publish()
    }

    func advance(_ work: Work, completed count: Int, total: Int) {
        guard var activity = current(work), total > 0 else { return }
        if count >= total {
            // The loop is finished, but the result still has to pass its
            // generation check and be installed/promoted on the main actor.
            activity.step = .applying
            activity.percent = nil
        } else {
            activity.percent = Int(Double(max(0, count)) / Double(total) * 100)
        }
        activity.fraction = min(1, Double(max(0, count)) / Double(total))
        activities[work.lane] = activity
        publish()
    }

    func finish(_ work: Work) {
        guard current(work) != nil else { return }
        activities[work.lane] = nil
        done.insert(work.lane)
        publish()
        settle()
    }

    func fail(_ work: Work) {
        guard current(work) != nil else { return }
        failed = true
        finish(work)
    }

    func settle() {
        guard beganAt != nil, activities.isEmpty, ending == nil, !completed else { return }
        ending = Task { [weak self] in
            // Coalesce the synchronous handoff from installing new input to
            // preparing its index/matches, without counting obsolete tasks.
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self, !Task.isCancelled, self.activities.isEmpty else { return }
            self.complete()
        }
    }

    func cancel() {
        showing?.cancel()
        showing = nil
        ending?.cancel()
        ending = nil
        beganAt = nil
        profileID = nil
        activities = [:]
        planned = []
        done = []
        fraction = 0
        completed = false
        failed = false
        status = nil
    }

    private func current(_ work: Work) -> Activity? {
        guard let activity = activities[work.lane], activity.work == work else { return nil }
        return activity
    }

    private func publish() {
        guard let beganAt, !completed else { return }
        func weight(_ step: Step) -> Double {
            switch step {
            case .channels: 0.2
            case .guide: 0.6
            default: 0.1
            }
        }
        let total = planned.reduce(0) { $0 + weight($1) }
        if total > 0 {
            let reached = planned.reduce(0) { result, step in
                result + weight(step) * (done.contains(step) ? 1 : (activities[step]?.fraction ?? 0))
            }
            fraction = max(fraction, min(reached / total, 0.99))
        }
        guard Date().timeIntervalSince(beganAt) >= showAfter,
              let activity = activities.values.min(by: { $0.step < $1.step }) else { return }
        let next = Status(step: activity.step, percent: activity.percent)
        if status != next { status = next }
    }

    private func complete() {
        ending = nil
        showing?.cancel()
        showing = nil
        guard !failed, let status else { cancel(); return }
        completed = true
        fraction = 1
        self.status = Status(step: status.step, percent: 100, completed: true)
        ending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }
}
