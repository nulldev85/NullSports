import SwiftUI

/// Drives one timer run: ticks the display, fires cues, keeps the screen
/// awake and the audio session alive. All timing comes from `TimerRun`
/// (wall clock), so pauses in ticking — backgrounding, a slow frame — never
/// drift the time.
@MainActor
@Observable
final class TimerController: Identifiable {
    struct Movement: Hashable {
        var name: String
        var detail: String?
    }

    let id = UUID()
    let title: String
    let program: TimerProgram
    private(set) var run: TimerRun
    private(set) var snapshot: TimerSnapshot
    /// The clock as displayed, changed only when the text changes, for
    /// small views (like the workout bar) that shouldn't redraw every tick.
    private(set) var clockText: String
    var extraReps = 0
    var movements: [Movement] = []
    /// Called whenever the run's state changes (not on every tick), so it
    /// can be persisted.
    var onChange: ((TimerRun) -> Void)?

    private let cues: CuePlayer
    private let settings: SettingsStore
    private let notifier: Notifier
    private var ticker: Timer?
    private var lastSnapshot: TimerSnapshot?
    private var holdsAudio = false
    private var keepAlive = false
    private var awakeReason: String { "timer-\(id.uuidString)" }

    init(config: TimerConfig, title: String, run: TimerRun? = nil, cues: CuePlayer, settings: SettingsStore, notifier: Notifier) {
        let program = TimerProgram(config: run?.config ?? config)
        self.program = program
        self.title = title
        let initialRun = run ?? TimerRun(config: program.config, startedAt: Date())
        self.run = initialRun
        let initialSnapshot = program.snapshot(for: initialRun, at: Date())
        self.snapshot = initialSnapshot
        self.clockText = initialSnapshot.clockText
        self.cues = cues
        self.settings = settings
        self.notifier = notifier
    }

    var isFinished: Bool { run.isFinished || snapshot.isFinished }
    var isPaused: Bool { run.isPaused }

    /// Starts ticking (the run itself may already be in progress).
    func start() {
        guard ticker == nil, !run.isFinished else {
            refresh()
            return
        }
        if !holdsAudio {
            keepAlive = settings.value.timerBackgroundAudio
            cues.acquire(keepAlive: keepAlive)
            holdsAudio = true
        }
        if settings.value.keepScreenOn {
            ScreenAwake.hold(awakeReason)
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        lastSnapshot = nil
        tick()
        scheduleEndNotification()
    }

    /// Stops ticking and releases audio/screen; the run state is kept.
    func stop() {
        ticker?.invalidate()
        ticker = nil
        if holdsAudio {
            cues.release(keepAlive: keepAlive)
            holdsAudio = false
        }
        ScreenAwake.release(awakeReason)
        notifier.cancelTimerEnd()
    }

    private func tick() {
        let now = Date()
        let next = program.snapshot(for: run, at: now)
        let fired = TimerCueDetector.cues(from: lastSnapshot, to: next)
        lastSnapshot = next
        snapshot = next
        if clockText != next.clockText { clockText = next.clockText }
        for cue in fired {
            cues.perform(cue, config: program.config, settings: settings.value)
        }
        if next.isFinished, !run.isFinished {
            run.finish(at: now, program: program)
            snapshot = program.snapshot(for: run, at: now)
            onChange?(run)
            ticker?.invalidate()
            ticker = nil
            ScreenAwake.release(awakeReason)
            notifier.cancelTimerEnd()
        }
    }

    private func refresh() {
        snapshot = program.snapshot(for: run, at: Date())
        if clockText != snapshot.clockText { clockText = snapshot.clockText }
    }

    private func changed() {
        refresh()
        lastSnapshot = snapshot
        onChange?(run)
        scheduleEndNotification()
    }

    private func scheduleEndNotification() {
        notifier.cancelTimerEnd()
        guard !run.isPaused, !run.isFinished, let remaining = snapshot.totalRemaining, remaining > 5 else { return }
        notifier.requestAuthorizationIfNeeded()
        notifier.scheduleTimerEnd(at: Date().addingTimeInterval(remaining), title: title)
    }

    // MARK: Controls

    func togglePause() {
        let now = Date()
        if run.isPaused {
            run.resume(at: now)
            if settings.value.timerHaptics { cues.haptic(.light) }
        } else {
            run.pause(at: now)
            if settings.value.timerHaptics { cues.haptic(.light) }
        }
        changed()
    }

    func skip() {
        run.skipPhase(at: Date(), program: program)
        lastSnapshot = nil
        changed()
        if run.isFinished { tick() }
    }

    func back() {
        run.previousPhase(at: Date(), program: program)
        lastSnapshot = nil
        changed()
    }

    func markRound() {
        guard !run.isFinished else { return }
        run.markRound(at: Date(), program: program)
        if settings.value.timerBeeps { cues.play(.round) }
        if settings.value.timerHaptics { cues.haptic(.medium) }
        changed()
    }

    func undoRound() {
        run.undoRound()
        changed()
    }

    /// Corrects the round count after the fact (e.g. a missed tap).
    func setRounds(_ count: Int) {
        let target = max(0, count)
        while run.roundSplits.count > target { run.roundSplits.removeLast() }
        while run.roundSplits.count < target { run.roundSplits.append(snapshot.workElapsed) }
        onChange?(run)
        refresh()
    }

    /// Ends the run now (athlete tapped Done/Stop).
    func finishNow() {
        guard !run.isFinished else { return }
        run.finish(at: Date(), program: program)
        refresh()
        onChange?(run)
        ticker?.invalidate()
        ticker = nil
        ScreenAwake.release(awakeReason)
        notifier.cancelTimerEnd()
        if settings.value.timerBeeps { cues.play(.finish) }
        if settings.value.timerHaptics { cues.haptic(.success) }
    }

    func result() -> BlockResult {
        program.result(for: run, at: Date(), extraReps: extraReps)
    }

    /// Round splits as lap durations.
    var laps: [Double] {
        var previous = 0.0
        return run.roundSplits.map { split in
            defer { previous = split }
            return split - previous
        }
    }
}
