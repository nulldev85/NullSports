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
    struct ActiveRecord: Codable {
        var title: String
        var run: TimerRun
        var extraReps: Int
    }

    init(database: AppDatabase, feedback: Feedback, settings: SettingsStore, history: HistoryStore, cues: CuePlayer, notifier: Notifier) {
        self.database = database
        self.feedback = feedback
        self.settings = settings
        self.history = history
        self.cues = cues
        self.notifier = notifier
        reloadPresets()
    }

    func reloadPresets() {
        do {
            presets = try database.timerPresets.all()
        } catch {
            feedback.report(error, while: "load your timers")
        }
        onPresetsChange?()
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

    private func persist(_ controller: TimerController) {
        let record = ActiveRecord(title: controller.title, run: controller.run, extraReps: controller.extraReps)
        try? database.meta.setJSON(MetaRepository.Key.activeTimer, record)
    }

    /// Resumes a timer that was running when the app closed.
    func restoreIfNeeded() {
        guard active == nil,
              let record = try? database.meta.getJSON(MetaRepository.Key.activeTimer, as: ActiveRecord.self) else { return }
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
        do {
            try database.workouts.saveVerified(workout)
            feedback.show("\(controller.title) saved to History", style: .success)
            history.reload()
            history.markChanged()
            close()
        } catch {
            feedback.report(error, while: "save the timer session")
        }
    }

    func close() {
        active?.stop()
        active = nil
        isPresented = false
        try? database.meta.set(MetaRepository.Key.activeTimer, value: nil)
    }

    // MARK: Presets

    func savePreset(name: String, config: TimerConfig, id: UUID? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var preset = presets.first { $0.id == id } ?? TimerPreset(name: trimmed, config: config, sortOrder: Double(presets.count + 1))
        preset.name = trimmed.isEmpty ? config.kind.displayName : trimmed
        preset.config = config
        preset.updatedAt = Date()
        do {
            try database.timerPresets.save(preset)
            reloadPresets()
            feedback.show("Saved “\(preset.name)”", style: .success)
        } catch {
            feedback.report(error, while: "save the timer")
        }
    }

    func deletePreset(_ id: UUID) {
        do {
            try database.timerPresets.delete(id: id)
            reloadPresets()
        } catch {
            feedback.report(error, while: "delete the timer")
        }
    }

    func movePresets(from source: IndexSet, to destination: Int) {
        var reordered = presets
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, var preset) in reordered.enumerated() {
            preset.sortOrder = Double(index + 1)
            try? database.timerPresets.save(preset)
        }
        reloadPresets()
    }
}
