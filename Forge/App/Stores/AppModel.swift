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

    init(database: AppDatabase, catalog: ExerciseCatalog) {
        self.database = database
        let feedback = Feedback()
        let cues = CuePlayer()
        let notifier = Notifier()
        let settings = SettingsStore(database: database, feedback: feedback)
        let library = LibraryStore(database: database, catalog: catalog, feedback: feedback)
        let routines = RoutineStore(database: database, feedback: feedback)
        let history = HistoryStore(database: database, feedback: feedback)
        self.feedback = feedback
        self.cues = cues
        self.notifier = notifier
        self.settings = settings
        self.library = library
        self.routines = routines
        self.history = history
        self.session = WorkoutSession(database: database, feedback: feedback, settings: settings, library: library, routines: routines, history: history, cues: cues, notifier: notifier)
        self.timers = TimerStore(database: database, feedback: feedback, settings: settings, history: history, cues: cues, notifier: notifier)
        self.measurements = MeasurementStore(database: database, feedback: feedback)
        self.dataSafety = DataSafetyStore(database: database, feedback: feedback, settings: settings)

        dataSafety.onDataReplaced = { [weak self] in self?.reloadAll() }
        history.onChange = { [weak self] in self?.dataSafety.needsExport = true }
        launchNotice = Self.notice(for: database.report)

        purgeExpiredDeletions()
        session.restoreIfNeeded()
        timers.restoreIfNeeded()
    }

    private static func notice(for report: OpenReport) -> String? {
        if let recovery = report.recovery {
            switch recovery {
            case .restoredFromBackup(let date):
                return "Forge found a problem with its data file and restored your automatic backup from \(date.formatted(date: .abbreviated, time: .shortened)). The damaged file was kept aside, not deleted."
            case .startedFresh:
                return "Forge couldn't read its data file and no backup was available, so it started fresh. The damaged file was kept aside. If you have an exported backup, import it from Settings › Backups."
            }
        }
        if let newer = report.newerSchemaVersion {
            return "This data was last used by a newer version of Forge (data version \(newer)). Update the app to make sure nothing is missed."
        }
        return nil
    }

    /// Items in Recently Deleted are kept for 30 days.
    private func purgeExpiredDeletions() {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        _ = try? database.routines.purgeDeleted(before: cutoff)
        _ = try? database.workouts.purgeDeleted(before: cutoff)
    }

    /// After a restore or import replaced the database contents.
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
            session.saveNow()
            let database = database
            let snapshots = settings.value.autoBackupEnabled
            BackgroundWork.run("Forge maintenance") {
                database.checkpoint()
                if snapshots {
                    database.performAutomaticBackupIfDue()
                }
            }
            dataSafety.exportIfDue()
        case .active:
            if settings.value.autoBackupEnabled {
                let database = database
                BackgroundWork.run("Forge snapshot") {
                    database.performAutomaticBackupIfDue()
                }
            }
        case .inactive:
            session.saveNow()
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
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(AppDatabase, ExerciseCatalog), Error> in
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
                    var settings = try database.meta.loadSettings(default: .defaults(usesMetric: Locale.current.measurementSystem != .us))
                    settings.appearance = .dark
                    try database.meta.saveSettings(settings)
                }
                return .success((database, catalog))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let (database, catalog)):
            state = .ready(AppModel(database: database, catalog: catalog))
        case .failure(let error):
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            state = .failed(detail)
        }
    }
}
