import SwiftUI

/// The workout in progress. Every change is written to the database — set
/// completions and structural edits immediately, typing after a short pause —
/// so force-quitting, a crash, or a dead battery never loses a logged set.
@MainActor
@Observable
final class WorkoutSession {
    private(set) var workout: Workout?
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

    private var saveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var restTicker: Timer?
    private var restCueFired = false
    /// Drives the rest-timer display; bumped by the rest ticker.
    private(set) var clock = Date()

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
        var completeRemaining: Bool
        var updateRoutine: Bool
    }

    init(database: AppDatabase, feedback: Feedback, settings: SettingsStore, library: LibraryStore, routines: RoutineStore, history: HistoryStore, cues: CuePlayer, notifier: Notifier) {
        self.database = database
        self.feedback = feedback
        self.settings = settings
        self.library = library
        self.routines = routines
        self.history = history
        self.cues = cues
        self.notifier = notifier
    }

    var isActive: Bool { workout != nil }

    // MARK: Lifecycle

    /// Picks up a workout that was in progress when the app last closed.
    func restoreIfNeeded() {
        guard workout == nil else { return }
        do {
            guard let active = try database.workouts.activeWorkout() else { return }
            workout = active
            loadPrevious()
            if active.runtime.restTimer != nil { startRestTicker() }
            if let blockID = active.runtime.runningBlockID, let run = active.runtime.runningTimer, active.block(blockID) != nil {
                attachTimedRun(blockID: blockID, run: run)
            }
        } catch {
            feedback.report(error, while: "restore your workout")
        }
    }

    func start(from routine: Routine? = nil) {
        guard workout == nil else {
            isPresented = true
            return
        }
        var new = routine.map { WorkoutFactory.workout(from: $0, lookup: library.exercise) } ?? WorkoutFactory.emptyWorkout()
        new.bodyweight = try? database.measurements.bodyweight(onOrBefore: Date())
        workout = new
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
        workout = current
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

    /// Writes the current state synchronously.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let workout else { return }
        do {
            try database.workouts.save(workout)
            if saveFailed {
                saveFailed = false
                feedback.show("Workout saved", style: .success)
            }
        } catch {
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
        mutate(immediate: true) { $0.removeSet(setID) }
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

    var rest: RestTimerState? { workout?.runtime.restTimer }

    func startRest(seconds: Int, exerciseName: String) {
        let state = RestTimerState(startedAt: Date(), duration: Double(seconds), exerciseName: exerciseName)
        mutate(immediate: true) { $0.runtime.restTimer = state }
        restCueFired = false
        if settings.value.restTimerNotifications {
            notifier.requestAuthorizationIfNeeded()
            notifier.scheduleRestEnd(at: state.endsAt, exerciseName: exerciseName)
        }
        startRestTicker()
    }

    func adjustRest(by seconds: Double) {
        mutate(immediate: true) { $0.runtime.restTimer?.adjust(by: seconds, now: Date()) }
        restCueFired = false
        if let rest, settings.value.restTimerNotifications {
            notifier.scheduleRestEnd(at: rest.endsAt, exerciseName: rest.exerciseName)
        }
    }

    func skipRest() {
        mutate(immediate: true) { $0.runtime.restTimer = nil }
        notifier.cancelRestEnd()
        stopRestTicker()
    }

    private func startRestTicker() {
        restTicker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickRest() }
        }
        RunLoop.main.add(timer, forMode: .common)
        restTicker = timer
        tickRest()
    }

    private func stopRestTicker() {
        restTicker?.invalidate()
        restTicker = nil
    }

    private func tickRest() {
        let now = Date()
        clock = now
        guard let rest else {
            stopRestTicker()
            return
        }
        guard rest.remaining(at: now) <= 0 else { return }
        if !restCueFired {
            restCueFired = true
            if settings.value.restTimerSound { cues.play(.restDone) }
            if settings.value.restTimerHaptics { cues.haptic(.success) }
        }
        // Leave "rest over" on screen briefly, then clear it.
        if now.timeIntervalSince(rest.endsAt) > 4 {
            mutate { $0.runtime.restTimer = nil }
            stopRestTicker()
        }
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
        var finished = WorkoutFactory.finalize(current, completeRemaining: options.completeRemaining, now: options.endedAt)
        finished.duration = max(0, options.endedAt.timeIntervalSince(options.startedAt))
        let records = history.records.newRecords(in: finished)
        do {
            try database.workouts.save(finished)
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
        library.refreshUsage()
        // Let the workout screen finish dismissing before presenting the
        // summary on the tab view.
        let summary = FinishedWorkout(workout: finished, records: records)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.finishedSummary = summary
        }
        return true
    }

    /// Discards the workout. Anything already logged goes to Recently
    /// Deleted instead of vanishing.
    func discard() {
        guard let current = workout else { return }
        timedRun?.stop()
        do {
            if current.hasCompletedSets {
                var kept = WorkoutFactory.finalize(current, completeRemaining: false)
                kept.deletedAt = Date()
                try database.workouts.save(kept)
                feedback.show("Workout discarded. Logged sets are in Recently Deleted for 30 days.", style: .info, duration: 4)
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
        stopRestTicker()
        timedRun = nil
        timedBlockID = nil
        isTimedRunPresented = false
        workout = nil
        previous = [:]
        isPresented = false
        saveFailed = false
    }
}
