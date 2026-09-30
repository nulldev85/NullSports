import SwiftUI

/// Everything that protects the athlete's data beyond the live database:
/// on-device snapshots, automatic backup files, JSON/CSV exports, copies
/// saved off the iPhone (e.g. iCloud Drive) that survive deleting the app,
/// imports, integrity checks, and finding data that went missing.
@MainActor
@Observable
final class DataSafetyStore {
    private(set) var snapshots: [BackupManager.Snapshot] = []
    /// Counts inside each snapshot, read in the background.
    private(set) var snapshotSummaries: [URL: BackupManager.SnapshotSummary] = [:]
    private(set) var exportFolderName: String?
    private(set) var lastExportDate: Date?
    private(set) var isExporting = false
    /// A snapshot restore or an import is replacing the data.
    private(set) var isReplacingData = false
    private(set) var folderSuggestionSnoozedUntil: Date?
    /// When a backup copy was last saved off the iPhone (through the save
    /// picker), and the name of the folder it went to.
    private(set) var lastOffDeviceSave: Date?
    private(set) var offDeviceFolderName: String?
    /// A backup file is being prepared for the save picker.
    private(set) var isPreparingCopy = false
    /// The last full integrity check of the data file.
    private(set) var integrity = AppDatabase.IntegrityStatus(checkedAt: nil, problems: [])
    /// Set when saved data changes, so the next export writes a new file.
    var needsExport = false
    /// Called after a restore/import replaced or added data.
    var onDataReplaced: (() -> Void)?

    // Finding missing data.
    struct ScanProgress: Equatable {
        var done: Int
        var total: Int
    }

    /// Non-nil while a scan runs.
    private(set) var scanProgress: ScanProgress?
    /// The result of the last scan, until it's restored or dismissed.
    private(set) var recoveryReport: RecoveryService.Report?
    /// Bumped each time a scan finishes.
    private(set) var scanCount = 0
    private(set) var isRestoringFound = false

    private let database: AppDatabase
    private let feedback: Feedback
    private let settings: SettingsStore
    @ObservationIgnored private var exportDebounce: Task<Void, Never>?
    @ObservationIgnored private var warnedAboutIntegrity = false
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var summariesTask: Task<Void, Never>?

    /// Everything the Backups screen shows, gathered off the main thread
    /// (listing files and resolving the backup folder can take a moment).
    struct Loaded: Sendable {
        var snapshots: [BackupManager.Snapshot] = []
        var lastExportDate: Date?
        var exportFolderName: String?
        var folderSuggestionSnoozedUntil: Date?
        var lastOffDeviceSave: Date?
        var offDeviceFolderName: String?
        var integrity = AppDatabase.IntegrityStatus(checkedAt: nil, problems: [])
    }

    nonisolated static func load(from database: AppDatabase) -> Loaded {
        var loaded = Loaded()
        loaded.snapshots = database.backups.snapshots()
        let exportedText: String? = try? database.meta.get(MetaRepository.Key.lastAutoExport)
        loaded.lastExportDate = exportedText.flatMap(ISO8601.date(from:))
        loaded.exportFolderName = resolveExportFolder(database)?.lastPathComponent
        let snoozedText: String? = try? database.meta.get(MetaRepository.Key.folderSuggestionSnoozedUntil)
        loaded.folderSuggestionSnoozedUntil = snoozedText.flatMap(ISO8601.date(from:))
        let savedText: String? = try? database.meta.get(MetaRepository.Key.offDeviceSavedAt)
        loaded.lastOffDeviceSave = savedText.flatMap(ISO8601.date(from:))
        loaded.offDeviceFolderName = try? database.meta.get(MetaRepository.Key.offDeviceFolder)
        loaded.integrity = database.integrityStatus
        return loaded
    }

    init(database: AppDatabase, feedback: Feedback, settings: SettingsStore, loaded: Loaded) {
        self.database = database
        self.feedback = feedback
        self.settings = settings
        apply(loaded)
    }

    private func apply(_ loaded: Loaded) {
        if snapshots != loaded.snapshots { snapshots = loaded.snapshots }
        if lastExportDate != loaded.lastExportDate { lastExportDate = loaded.lastExportDate }
        if exportFolderName != loaded.exportFolderName { exportFolderName = loaded.exportFolderName }
        if folderSuggestionSnoozedUntil != loaded.folderSuggestionSnoozedUntil { folderSuggestionSnoozedUntil = loaded.folderSuggestionSnoozedUntil }
        if lastOffDeviceSave != loaded.lastOffDeviceSave { lastOffDeviceSave = loaded.lastOffDeviceSave }
        if offDeviceFolderName != loaded.offDeviceFolderName { offDeviceFolderName = loaded.offDeviceFolderName }
        applyIntegrity(loaded.integrity)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    nonisolated static var documentsBackupFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Backups", isDirectory: true)
    }

    var documentsBackupFolder: URL { Self.documentsBackupFolder }

    /// Re-reads everything the Backups screen shows, in the background.
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let database = database
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(from: database) }.value
            guard generation == refreshGeneration else { return }
            withAnimation(Motion.smooth) { apply(loaded) }
            loadSnapshotSummaries()
        }
    }

    /// Reads the counts inside each snapshot that doesn't have them yet,
    /// off the main thread; rows fill in as they arrive.
    func loadSnapshotSummaries() {
        let missing = snapshots.filter { snapshotSummaries[$0.url] == nil }
        guard !missing.isEmpty else { return }
        let backups = database.backups
        summariesTask?.cancel()
        summariesTask = Task {
            let found = await Task.detached(priority: .utility) { () -> [URL: BackupManager.SnapshotSummary] in
                var result: [URL: BackupManager.SnapshotSummary] = [:]
                for snapshot in missing {
                    if Task.isCancelled { break }
                    if let summary = backups.summary(of: snapshot) { result[snapshot.url] = summary }
                }
                return result
            }.value
            guard !Task.isCancelled, !found.isEmpty else { return }
            withAnimation(Motion.smooth) {
                snapshotSummaries.merge(found) { _, new in new }
            }
        }
    }

    /// Backups on the iPhone go if the app is deleted, so suggest saving a
    /// copy elsewhere (iCloud Drive), and a fresh one once the last copy is
    /// a week old and there's been a workout since.
    func shouldSuggestOffDeviceCopy(newestWorkout: Date?, now: Date = Date()) -> Bool {
        // A folder that already gets every backup needs no reminders.
        guard exportFolderName == nil else { return false }
        if let until = folderSuggestionSnoozedUntil, until > now { return false }
        guard let last = lastOffDeviceSave else { return true }
        return now.timeIntervalSince(last) > Self.offDeviceCopyMaxAge && (newestWorkout ?? .distantPast) > last
    }

    /// When a copy off the iPhone counts as old.
    static let offDeviceCopyMaxAge: TimeInterval = 7 * 86_400

    /// Whether `url` is inside the app's own container (deleted with it).
    nonisolated static func isInsideApp(_ url: URL) -> Bool {
        func path(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        let item = path(url)
        let home = path(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        return item == home || item.hasPrefix(home + "/")
    }

    /// Saves a complete backup file wherever the athlete chooses in the
    /// save picker (iCloud Drive, typically). It's a copy made by iOS, so it
    /// works however Forge was installed; Forge remembers when and where.
    func saveCopyOffDevice() {
        guard !isPreparingCopy else { return }
        withAnimation(Motion.snappy) { isPreparingCopy = true }
        Task {
            let file: URL
            do {
                file = try await makeExportFile()
            } catch {
                withAnimation(Motion.snappy) { isPreparingCopy = false }
                feedback.report(error, while: "prepare the backup")
                return
            }
            withAnimation(Motion.snappy) { isPreparingCopy = false }
            DocumentPicker.shared.saveCopy(of: file) { [weak self] destination in
                try? FileManager.default.removeItem(at: file)
                guard let self, let destination else { return }
                // The save screen starts in Forge's own folder, which goes
                // when the app does: a copy there protects nothing.
                if Self.isInsideApp(destination) {
                    try? FileManager.default.removeItem(at: destination)
                    self.feedback.show("That's Forge's own folder on this iPhone, which is deleted along with the app. Save again and pick iCloud Drive: tap the back arrow at the top left.", style: .warning, duration: 7)
                    return
                }
                let folder = destination.deletingLastPathComponent().lastPathComponent
                let now = Date()
                withAnimation(Motion.smooth) {
                    self.lastOffDeviceSave = now
                    self.offDeviceFolderName = folder
                }
                self.feedback.show("Backup saved to “\(folder)”. You'll get a reminder when it's time for a fresh one.", style: .success, duration: 4)
                self.database.writeInBackground({ database in
                    try database.meta.set(MetaRepository.Key.offDeviceSavedAt, value: ISO8601.string(from: now))
                    try database.meta.set(MetaRepository.Key.offDeviceFolder, value: folder)
                })
            }
        }
    }

    func snoozeFolderSuggestion(days: Double = 7) {
        let until = Date().addingTimeInterval(days * 86_400)
        folderSuggestionSnoozedUntil = until
        database.writeInBackground({ try $0.meta.set(MetaRepository.Key.folderSuggestionSnoozedUntil, value: ISO8601.string(from: until)) })
    }

    // MARK: Integrity

    /// Reads the result of the last full check (which runs every few days
    /// in the background) and warns once if it found damage.
    func refreshIntegrity() {
        let database = database
        Task {
            let status = await Task.detached(priority: .utility) { database.integrityStatus }.value
            applyIntegrity(status)
        }
    }

    private func applyIntegrity(_ status: AppDatabase.IntegrityStatus) {
        if integrity != status { integrity = status }
        if !status.problems.isEmpty, !warnedAboutIntegrity {
            warnedAboutIntegrity = true
            feedback.show("Forge found damage in its data file. Open Settings › Backups to export a copy or restore a snapshot.", style: .warning, duration: 6)
        }
    }

    // MARK: Snapshots

    func createSnapshot() {
        let database = database
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try database.backups.createSnapshot(from: database.queue, reason: .manual)
                    // Only the newest is kept.
                    database.backups.prune()
                }
            }.value
            switch result {
            case .success:
                refresh()
                feedback.show("Snapshot saved", style: .success)
            case .failure(let error):
                feedback.report(error, while: "create a snapshot")
            }
        }
    }

    func summary(of snapshot: BackupManager.Snapshot) -> BackupManager.SnapshotSummary? {
        snapshotSummaries[snapshot.url]
    }

    /// Replaces all data with the snapshot (after snapshotting the current
    /// data), off the main thread.
    func restore(_ snapshot: BackupManager.Snapshot) {
        guard !isReplacingData else { return }
        isReplacingData = true
        let database = database
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try database.restore(from: snapshot) }
            }.value
            isReplacingData = false
            switch result {
            case .success:
                refresh()
                onDataReplaced?()
                noteDataChanged()
                feedback.show("Restored the snapshot from \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). Your previous data was saved as a snapshot too.", style: .success, duration: 5)
            case .failure(let error):
                feedback.report(error, while: "restore that snapshot")
            }
        }
    }

    func delete(_ snapshot: BackupManager.Snapshot) {
        snapshots.removeAll { $0.url == snapshot.url }
        let backups = database.backups
        Task {
            let result = await Task.detached(priority: .utility) { Result { try backups.delete(snapshot) } }.value
            if case .failure(let error) = result {
                feedback.report(error, while: "delete that snapshot")
                refresh()
            }
        }
    }

    // MARK: Export

    /// A complete JSON export in a temporary file, ready to share or save.
    func makeExportFile() async throws -> URL {
        let version = Self.appVersion
        return try await database.readInBackground { database in
            let data = try ArchiveService.exportData(from: database, appVersion: version)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(ArchiveService.suggestedFileName())
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    func makeCSVFile() async throws -> URL {
        let units = settings.units
        return try await database.readInBackground { database in
            let workouts = try database.workouts.completedWorkouts()
            let csv = CSVExporter.sets(workouts, units: units)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Forge-Sets-\(formatter.string(from: Date())).csv")
            try Data(csv.utf8).write(to: url, options: .atomic)
            return url
        }
    }

    // MARK: Import

    /// Reads and checks a backup file off the main thread.
    func readArchive(at url: URL) async throws -> BackupArchive {
        try await Task.detached(priority: .userInitiated) {
            try ArchiveService.decode(try Self.readFile(at: url, scopedBy: url))
        }.value
    }

    /// Replaces all data with the archive (after snapshotting the current
    /// data), off the main thread.
    func applyImport(_ archive: BackupArchive) {
        guard !isReplacingData else { return }
        isReplacingData = true
        let database = database
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ArchiveService.restore(archive, into: database) }
            }.value
            isReplacingData = false
            switch result {
            case .success:
                refresh()
                onDataReplaced?()
                noteDataChanged()
                feedback.show("Imported \(archive.completedWorkoutCount) workouts and \(archive.activeRoutineCount) routines. Your previous data was saved as a snapshot.", style: .success, duration: 5)
            case .failure(let error):
                feedback.report(error, while: "import that backup")
            }
        }
    }

    // MARK: Automatic export

    func clearExportFolder() {
        exportFolderName = nil
        database.writeInBackground({ try $0.meta.set(MetaRepository.Key.autoExportBookmark, value: nil) })
    }

    /// The chosen backup folder. Resolving the bookmark can touch iCloud,
    /// so this only ever runs off the main thread.
    nonisolated static func resolveExportFolder(_ database: AppDatabase) -> URL? {
        guard let text = try? database.meta.get(MetaRepository.Key.autoExportBookmark),
              let data = Data(base64Encoded: text) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? database.meta.set(MetaRepository.Key.autoExportBookmark, value: fresh.base64EncodedString())
        }
        return url
    }

    /// Something the athlete saved changed: write a fresh backup file
    /// shortly. A burst of edits makes one export, and leaving the app
    /// exports right away.
    func noteDataChanged() {
        needsExport = true
        guard settings.value.autoExportEnabled else { return }
        exportDebounce?.cancel()
        exportDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.needsExport else { return }
            self.exportNow(quiet: true)
        }
    }

    /// Daily (and after any change) export to Files › Forge › Backups and
    /// to the chosen folder.
    func exportIfDue() {
        guard settings.value.autoExportEnabled else { return }
        let due = lastExportDate.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? true
        guard due || needsExport else { return }
        exportNow(quiet: true, onlyWithData: true)
    }

    /// Writes a backup file now. Automatic (`quiet`) exports skip writing
    /// when nothing changed since the last file; asking for one always
    /// writes it.
    func exportNow(quiet: Bool = false, onlyWithData: Bool = false) {
        guard !isExporting else { return }
        isExporting = true
        needsExport = false
        exportDebounce?.cancel()
        let database = database
        let local = documentsBackupFolder
        let version = Self.appVersion
        // Ask iOS for time to finish if this starts as the app goes to the
        // background.
        let backgroundTask = BackgroundTaskToken(name: "Forge backup export")
        Task {
            defer { backgroundTask.end() }
            let outcome = await Task.detached(priority: .utility) { () -> Result<String?, Error> in
                do {
                    if onlyWithData, !database.hasUserData() { return .failure(NothingToExport()) }
                    let external = Self.resolveExportFolder(database)
                    let lastFingerprint: String? = quiet ? (try? database.meta.get(MetaRepository.Key.lastExportFingerprint)) : nil
                    let archive = try ArchiveService.makeArchive(from: database, appVersion: version)
                    let fingerprint = try archive.contentFingerprint()
                    if let lastFingerprint, lastFingerprint == fingerprint,
                       Self.hasBackupFile(in: local, accessScoped: false),
                       external.map({ Self.hasBackupFile(in: $0, accessScoped: true) }) ?? true {
                        // The newest files already hold exactly this.
                        return .success(nil)
                    }
                    let data = try ArchiveService.encode(archive)
                    try Self.writeBackupFile(data, into: local, accessScoped: false)
                    var warning: String?
                    if let external {
                        do {
                            try Self.writeBackupFile(data, into: external, accessScoped: true)
                        } catch {
                            warning = error.localizedDescription
                        }
                    }
                    // Only a complete export counts, so a failed folder
                    // write is retried next time.
                    try? database.meta.set(MetaRepository.Key.lastExportFingerprint, value: warning == nil ? fingerprint : nil)
                    return .success(warning)
                } catch {
                    return .failure(error)
                }
            }.value
            isExporting = false
            switch outcome {
            case .success(let warning):
                let now = Date()
                lastExportDate = now
                database.writeInBackground({ try $0.meta.set(MetaRepository.Key.lastAutoExport, value: ISO8601.string(from: now)) })
                if let warning {
                    feedback.show("Backed up on this iPhone, but the backup folder couldn't be written: \(warning)", style: .warning, duration: 5)
                } else if !quiet {
                    feedback.show("Backup file saved", style: .success)
                }
            case .failure(let error) where error is NothingToExport:
                break
            case .failure(let error):
                needsExport = true
                if !quiet { feedback.report(error, while: "export a backup") }
            }
            // Changes made while this export ran get their own.
            if needsExport, settings.value.autoExportEnabled { noteDataChanged() }
        }
    }

    /// Writes the backup as a new dated file, reads it back to make sure
    /// it's intact, and only then deletes every older backup file in the
    /// folder, so there's always exactly one, and never a moment with no
    /// good copy. Files with other names are never touched.
    nonisolated static func writeBackupFile(_ data: Data, into folder: URL, accessScoped: Bool, now: Date = Date()) throws {
        let accessing = accessScoped ? folder.startAccessingSecurityScopedResource() : false
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = ArchiveService.suggestedFileName(now: now)
        let target = folder.appendingPathComponent(name)
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }

        // The older copies go only once this one reads back exactly as
        // written.
        let names = datedBackups(in: folder).map(\.name) + (hasFile(named: BackupRetention.legacyLatestName, in: folder) ? [BackupRetention.legacyLatestName] : [])
        guard (try? readFile(at: target, scopedBy: nil)) == data else {
            // A bad copy doesn't stay next to the good one it would replace.
            if !BackupRetention.filesToRemove(names, keeping: name).isEmpty {
                try? fileManager.removeItem(at: target)
            }
            throw BackupError.invalidArchive("The new backup file didn't read back correctly, so the previous one was kept.")
        }
        for old in BackupRetention.filesToRemove(names, keeping: name) {
            var deleteError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(old), options: .forDeleting, error: &deleteError) { url in
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Whether a file is in the folder (an iCloud file not downloaded yet
    /// counts).
    nonisolated static func hasFile(named name: String, in folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { realName($0) == name }
    }

    /// Dated backup files in a folder, newest first. iCloud files that
    /// aren't downloaded yet are listed under their real names.
    nonisolated static func datedBackups(in folder: URL) -> [(name: String, date: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var seen = Set<String>()
        var result: [(name: String, date: Date)] = []
        for raw in names {
            let name = realName(raw)
            guard let date = BackupRetention.date(fromBackupName: name), seen.insert(name).inserted else { continue }
            result.append((name, date))
        }
        return result.sorted { $0.date > $1.date }
    }

    /// ".Forge-Backup-….json.icloud" (an iCloud file not on the device yet)
    /// is "Forge-Backup-….json".
    nonisolated static func realName(_ name: String) -> String {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return name }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Whether the folder holds a dated backup file.
    nonisolated static func hasBackupFile(in folder: URL, accessScoped: Bool) -> Bool {
        let accessing = accessScoped ? folder.startAccessingSecurityScopedResource() : false
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        return !datedBackups(in: folder).isEmpty
    }

    /// Reads a file through the file coordinator (which also downloads it
    /// from iCloud if needed). `scope` is the security-scoped URL that
    /// grants access: the file itself, or the folder it's in.
    nonisolated static func readFile(at url: URL, scopedBy scope: URL?) throws -> Data {
        let accessing = scope?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { scope?.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var data: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            do {
                data = try Data(contentsOf: readURL)
            } catch {
                readError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        guard let data, !data.isEmpty else { throw BackupError.invalidArchive("The file is empty.") }
        return data
    }

    // MARK: Finding missing data

    /// Looks through every snapshot, set-aside data file and backup file
    /// Forge can reach (plus `file`, if given) for workouts, routines and
    /// other items the live data is missing. Nothing changes until the
    /// athlete restores what was found.
    func scanForMissingData(including file: URL? = nil) {
        guard scanProgress == nil else { return }
        scanProgress = ScanProgress(done: 0, total: 0)
        recoveryReport = nil
        let database = database
        let local = documentsBackupFolder
        let externalName = exportFolderName ?? "Backup folder"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<RecoveryService.Report, Error> in
                let external = Self.resolveExportFolder(database)
                let seen = SeenFiles()
                var sources: [RecoveryService.Source] = []
                if let file {
                    sources.append(RecoveryService.Source(kind: .backupFile, label: file.lastPathComponent, date: nil) {
                        let data = try Self.readFile(at: file, scopedBy: file)
                        guard seen.isFirstRead(of: data) else { return .empty }
                        return try ArchiveService.decode(data)
                    })
                }
                sources += RecoveryService.deviceSources(for: database)
                sources += Self.backupFileSources(in: local, label: "Backup file", accessScoped: false, seen: seen)
                if let external {
                    sources += Self.backupFileSources(in: external, label: externalName, accessScoped: true, seen: seen)
                }
                return Result {
                    try RecoveryService.scan(database, sources: sources) { done, total in
                        Task { @MainActor [weak self] in
                            // Late updates from a finished scan are ignored.
                            guard self?.scanProgress != nil else { return }
                            self?.scanProgress = ScanProgress(done: done, total: total)
                        }
                    }
                }
            }.value
            scanProgress = nil
            switch result {
            case .success(let report):
                recoveryReport = report
                scanCount += 1
            case .failure(let error):
                feedback.report(error, while: "look through your backups")
            }
        }
    }

    func dismissRecoveryReport() {
        recoveryReport = nil
    }

    /// Adds the chosen items back. A snapshot is taken first, so this can
    /// be undone. Returns whether it worked.
    func restoreFound(_ report: RecoveryService.Report) async -> Bool {
        guard !isRestoringFound, report.itemCount > 0 else { return false }
        isRestoringFound = true
        let database = database
        let result = await Task.detached(priority: .userInitiated) {
            Result { try RecoveryService.restore(report, into: database) }
        }.value
        isRestoringFound = false
        switch result {
        case .success:
            recoveryReport = nil
            refresh()
            onDataReplaced?()
            noteDataChanged()
            let count = report.itemCount
            feedback.show("Restored \(count) \(count == 1 ? "item" : "items"). A snapshot from just before was saved too.", style: .success, duration: 4)
            return true
        case .failure(let error):
            feedback.report(error, while: "restore those items")
            return false
        }
    }

    /// Every JSON file in a backup folder, newest first. A file identical
    /// to one already read is skipped.
    nonisolated static func backupFileSources(in folder: URL, label: String, accessScoped: Bool, seen: SeenFiles) -> [RecoveryService.Source] {
        let accessing = accessScoped ? folder.startAccessingSecurityScopedResource() : false
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        var files: [(url: URL, date: Date?)] = []
        var listed = Set<String>()
        for raw in names {
            let name = realName(raw)
            guard name.lowercased().hasSuffix(".json"), listed.insert(name).inserted else { continue }
            let url = folder.appendingPathComponent(name)
            var date = BackupRetention.date(fromBackupName: name)
            if date == nil {
                let attributes = try? fileManager.attributesOfItem(atPath: folder.appendingPathComponent(raw).path)
                date = attributes?[.modificationDate] as? Date
            }
            files.append((url, date))
        }
        files.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let scope: URL? = accessScoped ? folder : nil
        return files.map { file in
            let stamp = file.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? file.url.lastPathComponent
            return RecoveryService.Source(kind: .backupFile, label: "\(label) · \(stamp)", date: file.date) {
                let data = try readFile(at: file.url, scopedBy: scope)
                guard seen.isFirstRead(of: data) else { return .empty }
                return try ArchiveService.decode(data)
            }
        }
    }
}

/// An automatic export found no data worth backing up yet.
private struct NothingToExport: Error {}

/// Remembers which file contents a scan has already read, so the same
/// backup saved in two places is only decoded once.
final class SeenFiles: @unchecked Sendable {
    private var hashes = Set<Int>()
    private let lock = NSLock()

    /// False if identical data was already read.
    func isFirstRead(of data: Data) -> Bool {
        let key = data.withUnsafeBytes { buffer -> Int in
            var hasher = Hasher()
            hasher.combine(buffer.count)
            hasher.combine(bytes: buffer)
            return hasher.finalize()
        }
        lock.lock()
        defer { lock.unlock() }
        return hashes.insert(key).inserted
    }
}
