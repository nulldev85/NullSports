import Foundation

/// How far the app is through bringing its data up to date, for the pop-up
/// that says so: "Refreshing Data", the step under way, and how far through
/// the whole refresh it is.
///
/// Its own object rather than more of the library's state. The library is
/// watched by nearly every screen, and a percentage that moves four times a
/// second has to redraw the pop-up, not the Guide.
///
/// A download is measured by its bytes, against the size the server gives
/// or, when it gives none, the size the same download came to last time.
/// Everything else -- reading the guide, matching games to channels -- is
/// paced by how long it took the last time it ran.
@MainActor
final class DataRefreshProgress: ObservableObject {
    /// The parts of a refresh, in the order they are named.
    enum Step: Int, CaseIterable, Comparable, Sendable {
        case channels, guide, guideReading, matching

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .channels: "Loading Channels"
            case .guide: "Loading TV Guide"
            case .guideReading: "Reading TV Guide"
            case .matching: "Matching Games"
            }
        }

        /// Its share of the whole. The guide is the bulk of any refresh.
        var weight: Double {
            switch self {
            case .channels: 0.2
            case .guide: 0.45
            case .guideReading: 0.15
            case .matching: 0.2
            }
        }

        /// How long it takes when there is nothing better to go on: no size
        /// from the server and no earlier refresh to remember.
        var usualSeconds: TimeInterval {
            switch self {
            case .channels: 4
            case .guide: 15
            case .guideReading: 6
            case .matching: 8
            }
        }
    }

    /// What the pop-up says.
    struct Status: Equatable {
        let step: Step
        /// Through the whole refresh. It never goes backwards.
        let percent: Int
    }

    /// Nil while there is nothing to say.
    @Published private(set) var status: Status?

    /// A gap this short between one step and the next is still one refresh.
    private static let settleFor: Duration = .milliseconds(700)
    /// How long a finished refresh says 100% before the pop-up goes.
    private static let lingerFor: Duration = .milliseconds(900)

    private let defaults: UserDefaults
    /// A refresh over sooner than this would only flicker past, unread.
    private let showAfter: TimeInterval
    private var profileKey = ""
    private var beganAt: Date?
    private var completed = false
    private var planned: Set<Step> = []
    private var running: Set<Step> = []
    private var done: Set<Step> = []
    private var startedAt: [Step: Date] = [:]
    /// How far a download is, by its bytes, when its size is known.
    private var measured: [Step: Double] = [:]
    private var lastStep: Step = .channels
    private var shownPercent = 0
    private var ticker: Task<Void, Never>?
    private var ending: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, showAfter: TimeInterval = 0.6) {
        self.defaults = defaults
        self.showAfter = showAfter
    }

    /// The steps a refresh means to take, said before it takes them so the
    /// percentage is of the whole from the start. A refresh already under
    /// way takes them on.
    func plan(_ steps: [Step], profile: UUID) {
        resume()
        if beganAt == nil {
            beganAt = Date()
            profileKey = profile.uuidString
            startTicking()
        }
        for step in steps where !done.contains(step) { planned.insert(step) }
        publish()
    }

    /// A step under way, when a refresh is. One already finished stays
    /// finished -- except matching, which one refresh can set off twice, once
    /// for the channel list and once for the guide.
    func start(_ step: Step) {
        resume()
        guard beganAt != nil else { return }
        if done.contains(step) {
            guard step == .matching else { return }
            done.remove(step)
        }
        planned.insert(step)
        running.insert(step)
        startedAt[step] = Date()
        measured[step] = nil
        lastStep = step
        publish()
    }

    /// How much of a step's download has arrived. The size it came to is kept
    /// for the next refresh, in case that server does not say.
    func download(_ step: Step, _ update: XtreamDownloadUpdate) {
        guard running.contains(step) else { return }
        if update.finished {
            if update.received > 0 { defaults.set(Int(update.received), forKey: key("bytes", step)) }
            measured[step] = 1
        } else if let size = update.expected.map({ Double($0) }) ?? sizeFromBefore(step), size > 0 {
            measured[step] = min(Double(update.received) / size, 0.99)
        }
        publish()
    }

    /// A step done. How long it took paces the same step next time.
    func finish(_ step: Step) {
        guard running.remove(step) != nil else { return }
        if let began = startedAt[step] {
            defaults.set(Date().timeIntervalSince(began), forKey: key("seconds", step))
        }
        done.insert(step)
        publish()
        settle()
    }

    /// A step that had nothing to do -- a guide that had not changed has
    /// nothing to read -- done without teaching the clock that it is instant.
    func skip(_ step: Step) {
        guard beganAt != nil, !done.contains(step) else { return }
        running.remove(step)
        planned.insert(step)
        done.insert(step)
        publish()
        settle()
    }

    /// Ends the refresh once nothing is left running and nothing new starts
    /// for a moment.
    func settle() {
        guard beganAt != nil, running.isEmpty, ending == nil, !completed else { return }
        ending = Task { [weak self] in
            do { try await Task.sleep(for: Self.settleFor) } catch { return }
            guard !Task.isCancelled, let self, self.running.isEmpty, !self.completed else { return }
            self.complete()
        }
    }

    /// Where a step probably is by the clock: steadily to nine tenths over the
    /// time it usually takes, then ever more slowly, never quite there until
    /// it is.
    nonisolated static func estimate(elapsed: TimeInterval, usual: TimeInterval) -> Double {
        guard usual > 0 else { return 0.9 }
        let elapsed = max(0, elapsed)
        if elapsed <= usual { return 0.9 * elapsed / usual }
        return 0.9 + 0.09 * (1 - exp(-(elapsed - usual) / usual))
    }

    // MARK: - Keeping the pop-up current

    /// New work while the refresh was ending: one still settling goes on, one
    /// that has already said 100% gives way to a new one.
    private func resume() {
        guard let ending else { return }
        ending.cancel()
        self.ending = nil
        if completed { reset() }
    }

    private func complete() {
        completed = true
        ending = nil
        done.formUnion(planned)
        // Too short to have been shown, so it goes as quietly as it came.
        guard status != nil else {
            reset()
            return
        }
        ticker?.cancel()
        ticker = nil
        shownPercent = 100
        status = Status(step: lastStep, percent: 100)
        ending = Task { [weak self] in
            do { try await Task.sleep(for: Self.lingerFor) } catch { return }
            self?.reset()
        }
    }

    private func reset() {
        ticker?.cancel()
        ticker = nil
        ending = nil
        beganAt = nil
        completed = false
        planned = []
        running = []
        done = []
        startedAt = [:]
        measured = [:]
        shownPercent = 0
        status = nil
    }

    /// The clock-paced steps move on their own, so the pop-up is redrawn
    /// a few times a second while a refresh runs.
    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.publish()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    private func publish() {
        guard let beganAt, !completed else { return }
        let now = Date()
        let total = planned.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return }
        let reached = planned.reduce(0) { $0 + $1.weight * fraction(of: $1, now: now) }
        shownPercent = max(shownPercent, min(Int((reached / total * 100).rounded(.down)), 99))
        if let current = running.min() { lastStep = current }
        guard now.timeIntervalSince(beganAt) >= showAfter else { return }
        let next = Status(step: lastStep, percent: shownPercent)
        if status != next { status = next }
    }

    private func fraction(of step: Step, now: Date) -> Double {
        if done.contains(step) { return 1 }
        guard running.contains(step), let began = startedAt[step] else { return 0 }
        if let measured = measured[step] { return measured }
        let before = defaults.double(forKey: key("seconds", step))
        return Self.estimate(elapsed: now.timeIntervalSince(began),
                             usual: before > 0 ? before : step.usualSeconds)
    }

    private func sizeFromBefore(_ step: Step) -> Double? {
        let bytes = defaults.integer(forKey: key("bytes", step))
        return bytes > 0 ? Double(bytes) : nil
    }

    /// Per provider: one provider's guide can be ten times another's.
    private func key(_ kind: String, _ step: Step) -> String {
        "DataRefresh.\(kind).\(step.rawValue).\(profileKey)"
    }
}
