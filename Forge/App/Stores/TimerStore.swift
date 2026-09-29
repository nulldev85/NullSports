import SwiftUI

/// Standalone interval timers (the Timers tab) and saved presets.
@MainActor
@Observable
final class TimerStore {
    private(set) var presets: [TimerPreset] = []
    private(set) var active: TimerController?
    var isPresented = false

    private let database: AppDatabase
    private let feedback: Feedback
    private let settings: SettingsStore
    private let history: HistoryStore
    private let cues: CuePlayer
    private let notifier: Notifier
    /// Called after saved timers change on disk.
    @ObservationIgnored var onPresetsChange: (() -> Void)?

    /// What gets persisted so a running timer survives the app being closed.
    struct ActiveRecord: Codable, Sendable {
        var title: String
        var run: TimerRun
        var extraReps: Int
    }

    /// What the store starts with, loaded off the main thread.
    struct Loaded: Sendable {
        var presets: [TimerPreset] = []
        /// A timer that was running when the app last closed.
        var active: ActiveRecord?
    }

    nonisolated static func load(from database: AppDatabase) -> Loaded {
        Loaded(
            presets: (try? database.timerPresets.all()) ?? [],
            active: try? database.meta.getJSON(MetaRepository.Key.activeTimer, as: ActiveRecord.self)
        )
    }

    @ObservationIgnored private var savedActive: ActiveRecord?
    @ObservationIgnored private var reloadGeneration = 0

    init(database: AppDatabase, feedback: Feedback, settings: SettingsStore, history: HistoryStore, cues: CuePlayer, notifier: Notifier, loaded: Loaded) {
        self.database = database
        self.feedback = feedback
        self.settings = settings
        self.history = history
        self.cues = cues
        self.notifier = notifier
        presets = loaded.presets
        savedActive = loaded.active
    }

    /// After a restore or import replaced the data, or a save failed.
    func reloadPresets() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let database = database
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { (try? database.timerPresets.all()) ?? [] }.value
            guard generation == reloadGeneration else { return }
            if presets != loaded {
                withAnimation(Motion.smooth) { presets = loaded }
            }
            onPresetsChange?()
        }
    }

    private func savePresets(_ action: String, _ work: @escaping @Sendable (AppDatabase) throws -> Void) {
        onPresetsChange?()
        database.writeInBackground(work) { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            self.feedback.report(error, while: action)
            self.reloadPresets()
        }
    }

    // MARK: Running

    func start(_ config: TimerConfig, title: String) {
        if let active, !active.isFinished {
            isPresented = true
            return
        }
        active?.stop()
        let controller = makeController(config: config, title: title, run: nil)
        active = controller
        persist(controller)
        controller.start()
        isPresented = true
    }

    private func makeController(config: TimerConfig, title: String, run: TimerRun?) -> TimerController {
        let controller = TimerController(config: config, title: title, run: run, cues: cues, settings: settings, notifier: notifier)
        controller.onChange = { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.persist(controller)
        }
        return controller
    }

    /// Saved in the background, so pausing or skipping never makes the
    /// ring stutter.
    private func persist(_ controller: TimerController) {
        let record = ActiveRecord(title: controller.title, run: controller.run, extraReps: controller.extraReps)
        database.writeInBackground({ try $0.meta.setJSON(MetaRepository.Key.activeTimer, record) })
    }

    /// Resumes a timer that was running when the app closed.
    func restoreIfNeeded() {
        guard active == nil, let record = savedActive else { return }
        savedActive = nil
        let controller = makeController(config: record.run.config, title: record.title, run: record.run)
        controller.extraReps = record.extraReps
        active = controller
        if !controller.isFinished {
            controller.start()
        }
    }

    func saveResult(notes: String, extraReps: Int) {
        guard let controller = active else { return }
        controller.extraReps = extraReps
        if !controller.isFinished { controller.finishNow() }
        let result = controller.result()
        let startedAt = controller.run.startedAt.addingTimeInterval(controller.program.leadIn)
        let workout = WorkoutFactory.timerWorkout(
            config: controller.program.config,
            result: result,
            name: controller.title,
            startedAt: startedAt,
            endedAt: controller.run.finishedAt ?? Date(),
            notes: notes
        )
        guard !isSaving else { return }
        isSaving = true
        let title = controller.title
        // Checked on disk before the timer closes, so a failed save leaves
        // the result on screen.
        database.writeInBackground({ try $0.workouts.saveVerified(workout) }) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            switch result {
            case .success:
                self.feedback.show("\(title) saved to History", style: .success)
                self.history.reload()
                self.history.markChanged()
                self.close()
            case .failure(let error):
                self.feedback.report(error, while: "save the timer session")
            }
        }
    }

    /// True while a result is being saved.
    private(set) var isSaving = false

    func close() {
        active?.stop()
        active = nil
        isPresented = false
        database.writeInBackground({ try $0.meta.set(MetaRepository.Key.activeTimer, value: nil) })
    }

    // MARK: Presets

    func savePreset(name: String, config: TimerConfig, id: UUID? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var preset = presets.first { $0.id == id } ?? TimerPreset(name: trimmed, config: config, sortOrder: Double(presets.count + 1))
        preset.name = trimmed.isEmpty ? config.kind.displayName : trimmed
        preset.config = config
        preset.updatedAt = Date()
        withAnimation(Motion.smooth) {
            if let index = presets.firstIndex(where: { $0.id == preset.id }) {
                presets[index] = preset
            } else {
                presets.append(preset)
            }
        }
        feedback.show("Saved “\(preset.name)”", style: .success)
        let saved = preset
        savePresets("save the timer") { try $0.timerPresets.save(saved) }
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets("delete the timer") { try $0.timerPresets.delete(id: id) }
    }

    func movePresets(from source: IndexSet, to destination: Int) {
        var reordered = presets
        reordered.move(fromOffsets: source, toOffset: destination)
        for index in reordered.indices {
            reordered[index].sortOrder = Double(index + 1)
        }
        presets = reordered
        let saved = reordered
        savePresets("save the new order") { database in
            for preset in saved { try database.timerPresets.save(preset) }
        }
    }
}
