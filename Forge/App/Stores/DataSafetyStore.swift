import SwiftUI

/// Everything that protects the athlete's data beyond the live database:
/// on-device snapshots, JSON/CSV exports, imports, automatic exports to a
/// folder of their choice (e.g. iCloud Drive) that survive deleting the app,
/// integrity checks, and finding data that went missing.
@MainActor
@Observable
final class DataSafetyStore {
    private(set) var snapshots: [BackupManager.Snapshot] = []
    private(set) var exportFolderName: String?
    private(set) var lastExportDate: Date?
    private(set) var isExporting = false
    private(set) var folderSuggestionSnoozedUntil: Date?
    /// The last full integrity check of the data file.
    private(set) var integrity = AppDatabase.IntegrityStatus(checkedAt: nil, problems: [])
    /// Dated backup files in Files › On My iPhone › Forge › Backups.
    private(set) var localBackupFileCount = 0
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

    init(database: AppDatabase, feedback: Feedback, settings: SettingsStore) {
        self.database = database
        self.feedback = feedback
        self.settings = settings
        refresh()
        refreshIntegrity()
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var documentsBackupFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Backups", isDirectory: true)
    }

    func refresh() {
        snapshots = database.backups.snapshots()
        if let text = try? database.meta.get(MetaRepository.Key.lastAutoExport) {
            lastExportDate = ISO8601.date(from: text)
        }
        exportFolderName = resolveExportFolder()?.lastPathComponent
        if let text = try? database.meta.get(MetaRepository.Key.folderSuggestionSnoozedUntil) {
            folderSuggestionSnoozedUntil = ISO8601.date(from: text)
        }
        localBackupFileCount = Self.datedBackups(in: documentsBackupFolder).count
    }

    /// Backup files in the app's own folder are removed if the app is
    /// deleted, so suggest a folder outside it (e.g. iCloud Drive).
    var shouldSuggestExternalFolder: Bool {
        guard settings.value.autoExportEnabled, exportFolderName == nil else { return false }
        if let until = folderSuggestionSnoozedUntil, until > Date() { return false }
        return true
    }

    func snoozeFolderSuggestion(days: Double = 7) {
        let until = Date().addingTimeInterval(days * 86_400)
        folderSuggestionSnoozedUntil = until
        try? database.meta.set(MetaRepository.Key.folderSuggestionSnoozedUntil, value: ISO8601.string(from: until))
    }

    // MARK: Integrity

    /// Reads the result of the last full check (which runs every few days
    /// in the background) and warns once if it found damage.
    func refreshIntegrity() {
        let database = database
        Task {
            let status = await Task.detached(priority: .utility) { database.integrityStatus }.value
            if integrity != status { integrity = status }
            if !status.problems.isEmpty, !warnedAboutIntegrity {
                warnedAboutIntegrity = true
                feedback.show("Forge found damage in its data file. Open Settings › Backups to export a copy or restore a snapshot.", style: .warning, duration: 6)
            }
        }
    }

    // MARK: Snapshots

    func createSnapshot() {
        do {
            try database.backups.createSnapshot(from: database.queue, reason: .manual)
            refresh()
            feedback.show("Snapshot saved", style: .success)
        } catch {
            feedback.report(error, while: "create a snapshot")
        }
    }

    func summary(of snapshot: BackupManager.Snapshot) -> BackupManager.SnapshotSummary? {
        database.backups.summary(of: snapshot)
    }

    func restore(_ snapshot: BackupManager.Snapshot) {
        do {
            try database.restore(from: snapshot)
            refresh()
            onDataReplaced?()
            noteDataChanged()
            feedback.show("Restored the snapshot from \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). Your previous data was saved as a snapshot too.", style: .success, duration: 5)
        } catch {
            feedback.report(error, while: "restore that snapshot")
        }
    }

    func delete(_ snapshot: BackupManager.Snapshot) {
        do {
            try database.backups.delete(snapshot)
            refresh()
        } catch {
            feedback.report(error, while: "delete that snapshot")
        }
    }

    // MARK: Export

    /// A complete JSON export in a temporary file, ready to share or save.
    func makeExportFile() throws -> URL {
        let data = try ArchiveService.exportData(from: database, appVersion: Self.appVersion)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(ArchiveService.suggestedFileName())
        try data.write(to: url, options: .atomic)
        return url
    }

    func makeCSVFile() throws -> URL {
        let workouts = try database.workouts.completedWorkouts()
        let csv = CSVExporter.sets(workouts, units: settings.units)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Forge-Sets-\(formatter.string(from: Date())).csv")
        try Data(csv.utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: Import

    func readArchive(at url: URL) throws -> BackupArchive {
        try ArchiveService.decode(try Self.readFile(at: url, scopedBy: url))
    }

    func applyImport(_ archive: BackupArchive) {
        do {
            try ArchiveService.restore(archive, into: database)
            settings.reload()
            refresh()
            onDataReplaced?()
            noteDataChanged()
            feedback.show("Imported \(archive.completedWorkoutCount) workouts and \(archive.activeRoutineCount) routines. Your previous data was saved as a snapshot.", style: .success, duration: 5)
        } catch {
            feedback.report(error, while: "import that backup")
        }
    }

    // MARK: Automatic export

    func setExportFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try database.meta.set(MetaRepository.Key.autoExportBookmark, value: bookmark.base64EncodedString())
            refresh()
            exportNow()
        } catch {
            feedback.report(error, while: "use that folder")
        }
    }

    func clearExportFolder() {
        try? database.meta.set(MetaRepository.Key.autoExportBookmark, value: nil)
        refresh()
    }

    private func resolveExportFolder() -> URL? {
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
        guard settings.value.autoExportEnabled, database.hasUserData() else { return }
        let due = lastExportDate.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? true
        guard due || needsExport else { return }
        exportNow(quiet: true)
    }

    /// Writes a backup file now. Automatic (`quiet`) exports skip writing
    /// when nothing changed since the last file; asking for one always
    /// writes it.
    func exportNow(quiet: Bool = false) {
        guard !isExporting else { return }
        isExporting = true
        needsExport = false
        exportDebounce?.cancel()
        let database = database
        let local = documentsBackupFolder
        let external = resolveExportFolder()
        let version = Self.appVersion
        let lastFingerprint: String? = quiet ? (try? database.meta.get(MetaRepository.Key.lastExportFingerprint)) : nil
        // Ask iOS for time to finish if this starts as the app goes to the
        // background.
        let backgroundTask = BackgroundTaskToken(name: "Forge backup export")
        Task {
            defer { backgroundTask.end() }
            let outcome = await Task.detached(priority: .utility) { () -> Result<String?, Error> in
                do {
                    let archive = try ArchiveService.makeArchive(from: database, appVersion: version)
                    let fingerprint = try archive.contentFingerprint()
                    if let lastFingerprint, lastFingerprint == fingerprint,
                       Self.latestExists(in: local, accessScoped: false),
                       external.map({ Self.latestExists(in: $0, accessScoped: true) }) ?? true {
                        // The newest files already hold exactly this.
                        return .success(nil)
                    }
                    let data = try ArchiveService.encode(archive)
                    try Self.writeRotating(data, into: local, accessScoped: false)
                    var warning: String?
                    if let external {
                        do {
                            try Self.writeRotating(data, into: external, accessScoped: true)
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
                try? database.meta.set(MetaRepository.Key.lastAutoExport, value: ISO8601.string(from: now))
                localBackupFileCount = Self.datedBackups(in: local).count
                if let warning {
                    feedback.show("Backed up on this iPhone, but the backup folder couldn't be written: \(warning)", style: .warning, duration: 5)
                } else if !quiet {
                    feedback.show("Backup file saved", style: .success)
                }
            case .failure(let error):
                needsExport = true
                if !quiet { feedback.report(error, while: "export a backup") }
            }
            // Changes made while this export ran get their own.
            if needsExport, settings.value.autoExportEnabled { noteDataChanged() }
        }
    }

    /// Writes `Forge-Backup-latest.json` plus a dated copy, then thins out
    /// older dated copies: the newest few are kept, then one a day for a
    /// month and one a week for half a year. Files with other names are
    /// never touched.
    nonisolated static func writeRotating(_ data: Data, into folder: URL, accessScoped: Bool, now: Date = Date()) throws {
        let accessing = accessScoped ? folder.startAccessingSecurityScopedResource() : false
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let dated = folder.appendingPathComponent(ArchiveService.suggestedFileName(now: now))
        let latest = folder.appendingPathComponent(latestName)
        for target in [dated, latest] {
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
        }
        let files = datedBackups(in: folder).map { BackupRetention.File(name: $0.name, date: $0.date) }
        for name in BackupRetention.filesToRemove(files, now: now) {
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(name), options: .forDeleting, error: &coordinatorError) { url in
                try? fileManager.removeItem(at: url)
            }
        }
    }

    nonisolated static let latestName = "Forge-Backup-latest.json"

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

    nonisolated static func latestExists(in folder: URL, accessScoped: Bool) -> Bool {
        let accessing = accessScoped ? folder.startAccessingSecurityScopedResource() : false
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { realName($0) == latestName }
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
        let external = resolveExportFolder()
        let externalName = exportFolderName ?? "Backup folder"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<RecoveryService.Report, Error> in
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
