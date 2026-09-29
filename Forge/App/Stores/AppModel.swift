import SwiftUI

enum AppTab: Hashable {
    case train, timers, history, exercises, progress
}

/// Owns the database and every store; injected into the view hierarchy.
@MainActor
@Observable
final class AppModel {
    let database: AppDatabase
    let feedback: Feedback
    let settings: SettingsStore
    let library: LibraryStore
    let routines: RoutineStore
    let history: HistoryStore
    let session: WorkoutSession
    let timers: TimerStore
    let measurements: MeasurementStore
    let dataSafety: DataSafetyStore
    let cues: CuePlayer
    let notifier: Notifier

    var selectedTab: AppTab = .train
    /// A one-time notice about something that happened at launch (for
    /// example, recovery from a damaged database).
    var launchNotice: String?

    /// `launch` is everything loaded off the main thread at launch, so
    /// building the model touches no disk and the first frame is complete.
    init(database: AppDatabase, launch: LaunchData) {
        self.database = database
        let feedback = Feedback()
        let cues = CuePlayer()
        let notifier = Notifier()
        let settings = SettingsStore(database: database, feedback: feedback, value: launch.settings)
        let library = LibraryStore(database: database, catalog: launch.catalog, feedback: feedback, loaded: launch.library)
        let routines = RoutineStore(database: database, feedback: feedback, loaded: launch.routines)
        let history = HistoryStore(database: database, feedback: feedback, settings: settings, library: library, preloaded: launch.history)
        self.feedback = feedback
        self.cues = cues
        self.notifier = notifier
        self.settings = settings
        self.library = library
        self.routines = routines
        self.history = history
        self.session = WorkoutSession(database: database, feedback: feedback, settings: settings, library: library, routines: routines, history: history, cues: cues, notifier: notifier)
        self.timers = TimerStore(database: database, feedback: feedback, settings: settings, history: history, cues: cues, notifier: notifier, loaded: launch.timers)
        self.measurements = MeasurementStore(database: database, feedback: feedback, loaded: launch.measurements)
        self.dataSafety = DataSafetyStore(database: database, feedback: feedback, settings: settings, loaded: launch.safety)

        dataSafety.onDataReplaced = { [weak self] in self?.reloadAll() }
        // Any change to what the athlete has saved schedules a fresh backup
        // file (written a little later, off the main thread).
        let dataSafety = dataSafety
        history.onChange = { [weak dataSafety] in dataSafety?.noteDataChanged() }
        routines.onChange = { [weak dataSafety] in dataSafety?.noteDataChanged() }
        measurements.onChange = { [weak dataSafety] in dataSafety?.noteDataChanged() }
        timers.onPresetsChange = { [weak dataSafety] in dataSafety?.noteDataChanged() }
        library.onPreferencesSaved = { [weak dataSafety] in dataSafety?.noteDataChanged() }
        // History's numbers depend on the week's first day and on custom
        // exercises' muscles.
        settings.onChange = { [weak history, weak dataSafety] old, new in
            if old.calendar() != new.calendar() { history?.reload() }
            dataSafety?.noteDataChanged()
        }
        library.onChange = { [weak history, weak dataSafety] in
            history?.reload()
            dataSafety?.noteDataChanged()
        }
        launchNotice = Self.notice(for: database.report)
        if let problem = launch.problem {
            feedback.show(problem, style: .error, duration: 6)
        }

        if let unfinished = launch.unfinished {
            session.resume(unfinished, previous: launch.previous)
        }
        timers.restoreIfNeeded()
        let recovered = session.recoveredAtLaunch.count
        if recovered > 0 {
            let text = recovered == 1
                ? "Forge found an unfinished workout from an earlier session and saved it to History, with every set you'd entered."
                : "Forge found \(recovered) unfinished workouts from earlier sessions and saved them to History, with every set you'd entered."
            launchNotice = [launchNotice, text].compactMap { $0 }.joined(separator: "\n\n")
        }
        // One-time text formatting setup, off the main thread.
        Task.detached(priority: .utility) {
            FormatWarmUp.run()
        }
        // Timer and rest sounds are set up in the background once the first
        // screen is up, so the first beep plays without a delay.
        Task { [cues] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            cues.prepare()
        }
    }

    private static func notice(for report: OpenReport) -> String? {
        if let recovery = report.recovery {
            switch recovery {
            case .restoredFromBackup(let date, let salvaged):
                let extra = salvaged > 0 ? " \(salvaged) newer \(salvaged == 1 ? "item was" : "items were") recovered from the damaged file too." : ""
                return "Forge found a problem with its data file and restored your backup from \(date.formatted(date: .abbreviated, time: .shortened)).\(extra) The damaged file was kept aside, not deleted, and Settings › Backups › Find Missing Data can look through it again."
            case .startedFresh:
                return "Forge couldn't read its data file and no backup was available, so it started fresh. The damaged file was kept aside. If you have an exported backup, import it from Settings › Backups."
            }
        }
        if let newer = report.newerSchemaVersion {
            return "This data was last used by a newer version of Forge (data version \(newer)). Update the app to make sure nothing is missed."
        }
        return nil
    }

    /// Items in Recently Deleted are kept for 30 days. The record that
    /// they were deleted on purpose outlives any backup that has them.
    nonisolated static func purgeExpiredDeletions(in database: AppDatabase) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        _ = try? database.routines.purgeDeleted(before: cutoff)
        _ = try? database.workouts.purgeDeleted(before: cutoff)
        database.forgetTombstones(before: now.addingTimeInterval(-400 * 86_400))
    }

    /// After a restore or import replaced the database contents. Every
    /// store reloads in the background and animates in its new data.
    func reloadAll() {
        settings.reload()
        library.reload()
        routines.reload()
        history.reload()
        measurements.reload()
        timers.reloadPresets()
        session.restoreIfNeeded()
    }

    func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            session.flush()
            let database = database
            let snapshots = settings.value.autoBackupEnabled
            BackgroundWork.run("Forge maintenance") {
                database.checkpoint()
                if snapshots {
                    database.performAutomaticBackupIfDue()
                }
                // A thorough check every few days; launch only does a quick one.
                database.fullIntegrityCheckIfDue()
            }
            dataSafety.exportIfDue()
        case .active:
            if settings.value.autoBackupEnabled {
                let database = database
                BackgroundWork.run("Forge snapshot") {
                    database.performAutomaticBackupIfDue()
                }
            }
            dataSafety.refreshIntegrity()
        case .inactive:
            // The app switcher can close the app without a background step.
            session.flush()
        @unknown default:
            break
        }
    }
}

/// Opens the database off the main thread and builds the model.
@MainActor
@Observable
final class AppLauncher {
    enum State {
        case loading
        case ready(AppModel)
        case failed(String)
    }

    private(set) var state: State = .loading

    func launch() async {
        state = .loading
        let arguments = ProcessInfo.processInfo.arguments
        let isUITest = arguments.contains("-ForgeUITest")
        let seedDemo = arguments.contains("-ForgeSeedDemoData")
        // UI tests can start in dark mode to capture both appearances.
        let forceDark = isUITest && arguments.contains("-ForgeDarkMode")
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(AppDatabase, LaunchData), Error> in
            do {
                let location: StorageLocation
                if isUITest {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ForgeUITest", isDirectory: true)
                    try? FileManager.default.removeItem(at: directory)
                    location = StorageLocation(directory: directory)
                } else {
                    location = try StorageLocation.applicationSupport()
                }
                let database = try AppDatabase.open(at: location)
                // Before this build touches anything, keep a copy of the
                // data exactly as the previous build left it.
                if !isUITest {
                    database.snapshotIfNewBuild(AppBuild.fingerprint)
                }
                let catalog: ExerciseCatalog
                if let url = Bundle.main.url(forResource: "exercises", withExtension: "json") {
                    catalog = try ExerciseCatalog.load(contentsOf: url)
                } else {
                    catalog = ExerciseCatalog(version: 0, exercises: [])
                }
                if seedDemo {
                    try DemoData.seed(into: database, catalog: catalog, imperial: Locale.current.measurementSystem == .us)
                }
                if forceDark {
                    var settings = SettingsStore.load(from: database)
                    settings.appearance = .dark
                    try database.meta.saveSettings(settings)
                }
                return .success((database, LaunchData.load(from: database, catalog: catalog)))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let (database, launch)):
            let model = AppModel(database: database, launch: launch)
            withAnimation(Motion.gentle) {
                state = .ready(model)
            }
        case .failure(let error):
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            state = .failed(detail)
        }
    }
}

/// Everything the app shows at launch, read off the main thread in one go.
struct LaunchData: Sendable {
    var settings: AppSettings
    var catalog: ExerciseCatalog
    var library: LibraryStore.Loaded
    var routines: RoutineStore.Loaded
    var history: HistorySnapshot?
    var measurements: [BodyMeasurement]
    var timers: TimerStore.Loaded
    var safety: DataSafetyStore.Loaded
    /// A workout still in progress (and any older unfinished ones, now
    /// saved to History).
    var unfinished: UnfinishedWorkouts.Outcome?
    /// Last time's sets for the workout in progress.
    var previous: [String: [WorkoutSet]] = [:]
    /// Something that couldn't be loaded, to tell the athlete about.
    var problem: String?

    static func load(from database: AppDatabase, catalog: ExerciseCatalog) -> LaunchData {
        AppModel.purgeExpiredDeletions(in: database)
        var problem: String?
        // Unfinished workouts first, so any saved to History show up in it.
        var unfinished: UnfinishedWorkouts.Outcome?
        var previous: [String: [WorkoutSet]] = [:]
        do {
            let outcome = try UnfinishedWorkouts.resolve(in: database)
            unfinished = outcome
            if let active = outcome.active {
                previous = (try? database.workouts.lastPerformances(exerciseIDs: active.allExercises.map(\.exerciseID), excluding: active.id)) ?? [:]
            }
        } catch {
            problem = "Couldn't restore your workout. \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
        }
        let settings = SettingsStore.load(from: database)
        let library = LibraryStore.load(from: database, builtins: catalog.exercises)
        var exercises: [String: Exercise] = [:]
        for exercise in catalog.exercises { exercises[exercise.id] = exercise }
        for exercise in library.customs { exercises[exercise.id] = exercise }
        let routines = RoutineStore.load(from: database)
        if let error = routines.error, problem == nil {
            problem = "Couldn't load your routines. \(error)"
        }
        return LaunchData(
            settings: settings,
            catalog: catalog,
            library: library,
            routines: routines,
            history: try? HistorySnapshot.load(from: database, calendar: settings.calendar(), exercises: exercises),
            measurements: MeasurementStore.load(from: database),
            timers: TimerStore.load(from: database),
            safety: DataSafetyStore.load(from: database),
            unfinished: unfinished,
            previous: previous,
            problem: problem
        )
    }
}
