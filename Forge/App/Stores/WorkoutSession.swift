import SwiftUI

/// The workout in progress. Every change is written to the database — set
/// completions and structural edits immediately, typing after a short pause —
/// so force-quitting, a crash, or a dead battery never loses a logged set.
/// Writes happen on a background queue, so the screen never waits for the
/// disk; leaving the app waits until everything queued is on disk.
@MainActor
@Observable
final class WorkoutSession {
    /// The whole workout. Views that only need its name or the rest timer
    /// observe `header` and `rest`, which change far less often than this
    /// does while the athlete types.
    private(set) var workout: Workout?
    private(set) var header: Header?
    private(set) var rest: RestTimerState?
    var isPresented = false
    /// Last completed performance per exercise, for the "previous" column.
    private(set) var previous: [String: [WorkoutSet]] = [:]
    private(set) var saveFailed = false
    /// A timed block (AMRAP, EMOM…) currently running inside the workout.
    private(set) var timedRun: TimerController?
    private(set) var timedBlockID: UUID?
    var isTimedRunPresented = false
    /// Shown after finishing.
    var finishedSummary: FinishedWorkout?

    private let database: AppDatabase
    private let feedback: Feedback
    private let settings: SettingsStore
    private let library: LibraryStore
    private let routines: RoutineStore
    private let history: HistoryStore
    private let cues: CuePlayer
    private let notifier: Notifier

    private let writer: CoalescingWriter<Workout>
    private var saveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var restEndTimer: Timer?
    private var restClearTimer: Timer?

    struct Header: Equatable {
        var id: UUID
        var name: String
        var startedAt: Date
    }

    struct FinishedWorkout: Identifiable {
        let workout: Workout
        let records: [PersonalRecord]
        var id: UUID { workout.id }
    }

    struct FinishOptions {
        var name: String
        var notes: String
        var rating: Int?
        var startedAt: Date
        var endedAt: Date
        /// Log unticked sets that have numbers typed in (on by default).
        var keepEnteredSets: Bool = true
        /// Also log untouched sets from their targets.
        var completeRemaining: Bool
        var updateRoutine: Bool
    }

    /// Earlier unfinished workouts found at launch and saved to History.
    private(set) var recoveredAtLaunch: [Workout] = []

    init(database: AppDatabase, feedback: Feedback, settings: SettingsStore, library: LibraryStore, routines: RoutineStore, history: HistoryStore, cues: CuePlayer, notifier: Notifier) {
        self.database = database
        self.feedback = feedback
        self.settings = settings
        self.library = library
        self.routines = routines
        self.history = history
        self.cues = cues
        self.notifier = notifier
        let workouts = database.workouts
        writer = CoalescingWriter(label: "forge.workout-writer") { workout in
            try workouts.save(workout)
        }
        writer.onCompletion { [weak self] workout, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.writeFinished(workoutID: workout.id, error: error)
                }
            }
        }
    }

    var isActive: Bool { header != nil }

    /// Sets the workout and refreshes the lightweight mirrors, touching each
    /// only when its value actually changed.
    private func setWorkout(_ new: Workout?) {
        workout = new
        let newHeader = new.map { Header(id: $0.id, name: $0.name, startedAt: $0.startedAt) }
        if header != newHeader { header = newHeader }
        let newRest = new?.runtime.restTimer
        if rest != newRest { rest = newRest }
    }

    // MARK: Lifecycle

    /// Picks up a workout that was in progress when the app last closed.
    func restoreIfNeeded() {
        guard workout == nil else { return }
        do {
            // Never leave an older unfinished workout stranded where it
            // can't be seen: those are saved to History first.
            let outcome = try UnfinishedWorkouts.resolve(in: database)
            recoveredAtLaunch += outcome.recovered
            if !outcome.recovered.isEmpty {
                history.reload()
                history.markChanged()
            }
            guard let active = outcome.active else { return }
            setWorkout(active)
            loadPrevious()
            scheduleRestTimers()
            if let blockID = active.runtime.runningBlockID, let run = active.runtime.runningTimer, active.block(blockID) != nil {
                attachTimedRun(blockID: blockID, run: run)
            }
        } catch {
            feedback.report(error, while: "restore your workout")
        }
    }

    func start(from routine: Routine? = nil) {
        // A workout left open (and not yet loaded) is resumed, never
        // replaced by a new one.
        if workout == nil {
            restoreIfNeeded()
            if workout != nil {
                feedback.show("Picked up your unfinished workout", style: .info)
            }
        }
        guard workout == nil else {
            isPresented = true
            return
        }
        var new = routine.map { WorkoutFactory.workout(from: $0, lookup: library.exercise) } ?? WorkoutFactory.emptyWorkout()
        new.bodyweight = try? database.measurements.bodyweight(onOrBefore: Date())
        setWorkout(new)
        loadPrevious()
        saveNow()
        isPresented = true
    }

    private func loadPrevious() {
        guard let workout else { return }
        let ids = workout.allExercises.map(\.exerciseID)
        previous = history.lastPerformances(ids, excluding: workout.id)
    }

    // MARK: Saving

    func mutate(immediate: Bool = false, _ change: (inout Workout) -> Void) {
        guard var current = workout else { return }
        change(&current)
        current.updatedAt = Date()
        setWorkout(current)
        if immediate {
            saveNow()
        } else {
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Queues the current state for the background writer. It's on disk
    /// within milliseconds; versions queued in a burst are coalesced.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let workout else { return }
        writer.submit(workout)
    }

    /// Queues the current state and waits until everything is on disk. Used
    /// when the app leaves the foreground and before a final write.
    func flush() {
        saveNow()
        writer.flush()
    }

    private func writeFinished(workoutID: UUID, error: Error?) {
        // A write that finished after the workout was closed has nothing to report.
        guard workout?.id == workoutID else { return }
        if let error {
            if !saveFailed {
                feedback.report(error, while: "save your workout. It's still open and Forge will keep retrying")
            }
            saveFailed = true
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
        } else if saveFailed {
            saveFailed = false
            feedback.show("Workout saved", style: .success)
        }
    }

    // MARK: Sets

    func previousSet(for exercise: WorkoutExercise, index: Int) -> WorkoutSet? {
        previous[exercise.exerciseID]?[safe: index]
    }

    func toggleCompletion(of setID: UUID) {
        guard let workout, let location = workout.location(ofSet: setID) else { return }
        let block = workout.blocks[location.block]
        let exercise = block.exercises[location.exercise]
        var set = exercise.sets[location.set]
        if set.isCompleted {
            set.isCompleted = false
            set.completedAt = nil
        } else {
            set.fillEmptyFields(from: set.target, tracking: exercise.tracking)
            if let prior = previousSet(for: exercise, index: location.set) {
                set.fillEmptyFields(from: SetTarget(reps: prior.reps, weight: prior.weight, duration: prior.duration, distance: prior.distance), tracking: exercise.tracking)
            }
            set.isCompleted = true
            set.completedAt = Date()
        }
        let updated = set
        mutate(immediate: true) { $0.updateSet(setID) { $0 = updated } }
        guard updated.isCompleted else { return }

        if settings.value.restTimerHaptics { cues.haptic(.medium) }
        let isLastInBlock = location.exercise == block.exercises.count - 1
        if settings.value.autoStartRestTimer, !block.isTimed, isLastInBlock {
            let seconds = exercise.restSeconds ?? library.restSeconds(for: exercise.exerciseID) ?? settings.value.defaultRestSeconds
            if seconds > 0 {
                startRest(seconds: seconds, exerciseName: exercise.name)
            }
        }
    }

    func updateSet(_ setID: UUID, _ change: @escaping (inout WorkoutSet) -> Void) {
        mutate { $0.updateSet(setID, change) }
    }

    func setBinding(_ setID: UUID, fallback: WorkoutSet) -> Binding<WorkoutSet> {
        Binding(
            get: { self.workout?.set(setID) ?? fallback },
            set: { newValue in self.mutate { $0.updateSet(setID) { $0 = newValue } } }
        )
    }

    func addSet(to entryID: UUID) {
        mutate(immediate: true) { _ = $0.addSet(to: entryID) }
    }

    func removeSet(_ setID: UUID) {
        guard let workout, let location = workout.location(ofSet: setID) else { return }
        let entry = workout.blocks[location.block].exercises[location.exercise]
        let removed = entry.sets[location.set]
        mutate(immediate: true) { $0.removeSet(setID) }
        // A set with anything logged in it can be put back.
        if removed.isCompleted || removed.hasValues {
            feedback.show("Set deleted", style: .info, action: ToastAction(title: "Undo") { [weak self] in
                self?.restoreSet(removed, in: entry.id, at: location.set)
            })
        }
    }

    private func restoreSet(_ set: WorkoutSet, in entryID: UUID, at index: Int) {
        guard workout?.exercise(entryID) != nil else { return }
        withAnimation(Motion.smooth) {
            mutate(immediate: true) { workout in
                _ = workout.updateExercise(entryID) { exercise in
                    guard !exercise.sets.contains(where: { $0.id == set.id }) else { return }
                    exercise.sets.insert(set, at: min(index, exercise.sets.count))
                }
            }
        }
    }

    func setKind(_ kind: SetKind, for setID: UUID) {
        mutate(immediate: true) { $0.updateSet(setID) { $0.kind = kind } }
    }

    /// Inserts a warm-up ramp before the first working set.
    func addWarmups(to entryID: UUID) {
        guard let exercise = workout?.exercise(entryID), exercise.tracking == .weightReps else { return }
        let working = exercise.sets.first { $0.kind.isWorking }
        guard let top = working?.weight ?? working?.target?.weight ?? previous[exercise.exerciseID]?.map({ $0.weight ?? 0 }).max(), top > 0 else {
            feedback.show("Enter a working weight first, then add warm-ups.", style: .info)
            return
        }
        let unit = settings.value.weightUnit
        let bar = settings.value.barWeightInKilograms
        let increment = unit.toKilograms(unit.standardIncrement)
        let steps = WarmupCalculator.steps(workingWeight: top, bar: bar, increment: increment)
        guard !steps.isEmpty else {
            feedback.show("That weight is too light for warm-up sets.", style: .info)
            return
        }
        let sets = steps.map { WorkoutSet(kind: .warmup, target: SetTarget(reps: $0.reps, weight: $0.weight)) }
        mutate(immediate: true) { workout in
            workout.updateExercise(entryID) { exercise in
                exercise.sets.removeAll { $0.kind == .warmup && !$0.isCompleted }
                exercise.sets.insert(contentsOf: sets, at: 0)
            }
        }
    }

    // MARK: Exercises

    func addExercises(_ exercises: [Exercise], asSuperset: Bool) {
        guard !exercises.isEmpty else { return }
        let last = history.lastPerformances(exercises.map(\.id), excluding: workout?.id)
        previous.merge(last) { _, new in new }
        let entries = exercises.map { exercise in
            WorkoutFactory.entry(for: exercise, lastPerformance: last[exercise.id], restSeconds: library.restSeconds(for: exercise.id))
        }
        mutate(immediate: true) { workout in
            if asSuperset, entries.count > 1 {
                workout.blocks.append(WorkoutBlock(exercises: entries))
            } else {
                workout.blocks.append(contentsOf: entries.map { WorkoutBlock(exercises: [$0]) })
            }
        }
    }

    func addTimedBlock(config: TimerConfig, exercises: [Exercise]) {
        let entries = exercises.map { exercise in
            WorkoutExercise(exerciseID: exercise.id, name: exercise.name, tracking: exercise.tracking, sets: [WorkoutSet(target: SetTarget())])
        }
        mutate(immediate: true) { $0.blocks.append(WorkoutBlock(exercises: entries, timer: config)) }
    }

    func replaceExercise(_ entryID: UUID, with exercise: Exercise) {
        let last = history.lastPerformances([exercise.id], excluding: workout?.id)
        previous.merge(last) { _, new in new }
        mutate(immediate: true) { workout in
            workout.updateExercise(entryID) { entry in
                entry.exerciseID = exercise.id
                entry.name = exercise.name
                entry.tracking = exercise.tracking
                entry.sets = entry.sets.map { WorkoutSet(kind: $0.kind, target: nil) }
            }
        }
    }

    func removeExercise(_ entryID: UUID) {
        mutate(immediate: true) { $0.removeExercise(entryID) }
    }

    func moveBlock(_ blockID: UUID, by offset: Int) {
        mutate(immediate: true) { $0.moveBlock(blockID, by: offset) }
    }

    func mergeWithNext(_ blockID: UUID) {
        mutate(immediate: true) { $0.mergeWithNext(blockID) }
    }

    func splitBlock(_ blockID: UUID) {
        mutate(immediate: true) { $0.splitBlock(blockID) }
    }

    func setRestSeconds(_ seconds: Int?, for entryID: UUID) {
        mutate(immediate: true) { $0.updateExercise(entryID) { $0.restSeconds = seconds } }
    }

    // MARK: Rest timer

    func startRest(seconds: Int, exerciseName: String) {
        let state = RestTimerState(startedAt: Date(), duration: Double(seconds), exerciseName: exerciseName)
        mutate(immediate: true) { $0.runtime.restTimer = state }
        if settings.value.restTimerNotifications {
            notifier.requestAuthorizationIfNeeded()
            notifier.scheduleRestEnd(at: state.endsAt, exerciseName: exerciseName)
        }
        scheduleRestTimers()
    }

    func adjustRest(by seconds: Double) {
        mutate(immediate: true) { $0.runtime.restTimer?.adjust(by: seconds, now: Date()) }
        if let rest, settings.value.restTimerNotifications {
            notifier.scheduleRestEnd(at: rest.endsAt, exerciseName: rest.exerciseName)
        }
        scheduleRestTimers()
    }

    func skipRest() {
        mutate(immediate: true) { $0.runtime.restTimer = nil }
        notifier.cancelRestEnd()
        cancelRestTimers()
    }

    /// Two one-shot timers instead of a ticker: one plays the "rest over" cue
    /// the moment the countdown ends, one clears the finished bar a few
    /// seconds later. The countdown itself is drawn by the views.
    private func scheduleRestTimers() {
        cancelRestTimers()
        guard let rest else { return }
        let now = Date()
        if rest.endsAt > now {
            restEndTimer = Self.oneShot(at: rest.endsAt) { [weak self] in self?.restEnded() }
        }
        restClearTimer = Self.oneShot(at: max(now, rest.endsAt.addingTimeInterval(4))) { [weak self] in
            self?.clearFinishedRest()
        }
    }

    private func cancelRestTimers() {
        restEndTimer?.invalidate()
        restClearTimer?.invalidate()
        restEndTimer = nil
        restClearTimer = nil
    }

    private func restEnded() {
        guard let rest else { return }
        let remaining = rest.remaining(at: Date())
        guard remaining <= 0.02 else {
            scheduleRestTimers()
            return
        }
        // Firing late means the app was in the background, where the
        // notification already did the job.
        guard Date().timeIntervalSince(rest.endsAt) < 2 else { return }
        if settings.value.restTimerSound { cues.play(.restDone) }
        if settings.value.restTimerHaptics { cues.haptic(.success) }
    }

    private func clearFinishedRest() {
        guard let rest else { return }
        guard rest.remaining(at: Date()) <= 0 else {
            scheduleRestTimers()
            return
        }
        withAnimation(Motion.gentle) {
            mutate { $0.runtime.restTimer = nil }
        }
    }

    private static func oneShot(at date: Date, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Timed blocks

    func runTimedBlock(_ blockID: UUID) {
        guard timedRun == nil else {
            isTimedRunPresented = true
            return
        }
        guard let block = workout?.block(blockID), let config = block.timer else { return }
        var effective = config
        effective.leadIn = Double(settings.value.defaultLeadIn)
        let run = TimerRun(config: effective, startedAt: Date())
        attachTimedRun(blockID: blockID, run: run)
        mutate(immediate: true) { workout in
            workout.runtime.runningBlockID = blockID
            workout.runtime.runningTimer = run
        }
        skipRest()
        isTimedRunPresented = true
    }

    private func attachTimedRun(blockID: UUID, run: TimerRun) {
        guard let block = workout?.block(blockID) else { return }
        let controller = TimerController(
            config: run.config,
            title: block.timer?.kind.displayName ?? "Timer",
            run: run,
            cues: cues,
            settings: settings,
            notifier: notifier
        )
        controller.movements = block.exercises.map { exercise in
            let target = exercise.sets.first?.target
            let detail = target.map { settings.units.setDescription(weight: $0.weight, reps: $0.reps, duration: $0.duration, distance: $0.distance, tracking: exercise.tracking) }
            return TimerController.Movement(name: exercise.name, detail: detail == "—" ? nil : detail)
        }
        controller.onChange = { [weak self] run in
            self?.mutate(immediate: true) { $0.runtime.runningTimer = run }
        }
        timedRun = controller
        timedBlockID = blockID
        controller.start()
    }

    func completeTimedRun() {
        guard let controller = timedRun, let blockID = timedBlockID, let block = workout?.block(blockID) else { return }
        let result = controller.result()
        controller.stop()
        let updated = WorkoutFactory.applyResult(result, to: block, program: controller.program)
        mutate(immediate: true) { workout in
            workout.updateBlock(blockID) { $0 = updated }
            workout.runtime.runningBlockID = nil
            workout.runtime.runningTimer = nil
        }
        timedRun = nil
        timedBlockID = nil
        isTimedRunPresented = false
    }

    func cancelTimedRun() {
        timedRun?.stop()
        timedRun = nil
        timedBlockID = nil
        isTimedRunPresented = false
        mutate(immediate: true) { workout in
            workout.runtime.runningBlockID = nil
            workout.runtime.runningTimer = nil
        }
    }

    /// Log a timed block's result without running the timer.
    func logResult(_ result: BlockResult, for blockID: UUID) {
        guard let block = workout?.block(blockID), let config = block.timer else { return }
        let updated = WorkoutFactory.applyResult(result, to: block, program: TimerProgram(config: config))
        mutate(immediate: true) { $0.updateBlock(blockID) { $0 = updated } }
    }

    func clearResult(for blockID: UUID) {
        guard let block = workout?.block(blockID) else { return }
        let cleared = WorkoutFactory.clearResult(of: block)
        mutate(immediate: true) { $0.updateBlock(blockID) { $0 = cleared } }
    }

    func updateTimer(_ config: TimerConfig, for blockID: UUID) {
        mutate(immediate: true) { $0.updateBlock(blockID) { $0.timer = config } }
    }

    // MARK: Finish / discard

    func routineDiffers() -> Bool {
        guard let workout, let routine = routines.routine(workout.routineID) else { return false }
        let finished = WorkoutFactory.finalize(workout, completeRemaining: false)
        return WorkoutFactory.differsFromRoutine(finished, routine: routine)
    }

    @discardableResult
    func finish(_ options: FinishOptions) -> Bool {
        guard var current = workout else { return false }
        timedRun?.stop()
        current.name = options.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? current.name : options.name
        current.notes = options.notes
        current.rating = options.rating
        current.startedAt = options.startedAt
        var finished = WorkoutFactory.finalize(current, completeRemaining: options.completeRemaining, keepEnteredSets: options.keepEnteredSets, now: options.endedAt)
        finished.duration = max(0, options.endedAt.timeIntervalSince(options.startedAt))
        let records = history.currentRecords().newRecords(in: finished)
        // Anything still queued must land before the finished version, never after it.
        flush()
        do {
            // Read back and checked before the workout closes, so a failed
            // save is caught while everything is still on screen.
            try database.workouts.saveVerified(finished)
        } catch {
            feedback.report(error, while: "finish the workout. It's still open so nothing is lost")
            return false
        }
        if let routineID = finished.routineID {
            routines.markPerformed(routineID, at: finished.startedAt)
            if options.updateRoutine, let routine = routines.routine(routineID) {
                routines.save(WorkoutFactory.updatedRoutine(routine, from: finished))
            }
        }
        tearDown()
        history.reload()
        history.markChanged()
        library.refreshUsageInBackground()
        // A fresh snapshot, so the newest backup always includes this workout.
        let database = database
        BackgroundWork.run("Forge workout backup") {
            database.snapshotAfterWorkout()
        }
        // Let the workout screen finish dismissing before presenting the
        // summary on the tab view.
        let summary = FinishedWorkout(workout: finished, records: records)
        afterDelay(0.6) { [weak self] in
            self?.finishedSummary = summary
        }
        return true
    }

    /// Discards the workout. Anything already logged goes to Recently
    /// Deleted instead of vanishing.
    func discard() {
        guard let current = workout else { return }
        timedRun?.stop()
        // A queued write landing after the delete would bring the workout back.
        flush()
        do {
            // Anything typed in — even sets never ticked — goes to Recently
            // Deleted rather than disappearing.
            if current.hasUserInput {
                var kept = WorkoutFactory.finalize(current, completeRemaining: false, keepEnteredSets: true)
                kept.deletedAt = Date()
                try database.workouts.save(kept)
                feedback.show("Workout discarded. What you logged is in Recently Deleted for 30 days.", style: .info, duration: 5)
            } else {
                try database.workouts.purge(workoutID: current.id)
            }
        } catch {
            feedback.report(error, while: "discard the workout")
            return
        }
        tearDown()
        history.reload()
    }

    private func tearDown() {
        saveTask?.cancel()
        retryTask?.cancel()
        notifier.cancelRestEnd()
        cancelRestTimers()
        timedRun = nil
        timedBlockID = nil
        isTimedRunPresented = false
        setWorkout(nil)
        previous = [:]
        isPresented = false
        saveFailed = false
    }
}
