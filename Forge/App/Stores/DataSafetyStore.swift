import SwiftUI

/// Everything that protects the athlete's data beyond the live database:
/// on-device snapshots, JSON/CSV exports, imports, and automatic exports to
/// a folder of their choice (e.g. iCloud Drive) that survive deleting the app.
@MainActor
@Observable
final class DataSafetyStore {
    private(set) var snapshots: [BackupManager.Snapshot] = []
    private(set) var exportFolderName: String?
    private(set) var lastExportDate: Date?
    private(set) var isExporting = false
    /// Set when history changes, so the next background event exports.
    var needsExport = false
    /// Called after a restore/import replaced the data.
    var onDataReplaced: (() -> Void)?

    private let database: AppDatabase
    private let feedback: Feedback
    private let settings: SettingsStore

    init(database: AppDatabase, feedback: Feedback, settings: SettingsStore) {
        self.database = database
        self.feedback = feedback
        self.settings = settings
        refresh()
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
    }

    // MARK: Snapshots

    func createSnapshot() {
        do {
            try database.backups.createSnapshot(from: database.queue, reason: .manual)
            refresh()
            feedback.show("Backup created", style: .success)
        } catch {
            feedback.report(error, while: "create a backup")
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
            feedback.show("Restored the backup from \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). Your previous data was saved as a backup too.", style: .success, duration: 5)
        } catch {
            feedback.report(error, while: "restore that backup")
        }
    }

    func delete(_ snapshot: BackupManager.Snapshot) {
        do {
            try database.backups.delete(snapshot)
            refresh()
        } catch {
            feedback.report(error, while: "delete that backup")
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
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
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
        guard let data else { throw BackupError.invalidArchive("The file is empty.") }
        return try ArchiveService.decode(data)
    }

    func applyImport(_ archive: BackupArchive) {
        do {
            try ArchiveService.restore(archive, into: database)
            settings.reload()
            refresh()
            onDataReplaced?()
            feedback.show("Imported \(archive.completedWorkoutCount) workouts and \(archive.activeRoutineCount) routines. Your previous data was saved as a backup.", style: .success, duration: 5)
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

    /// Daily (or after new workouts) export to Files › Forge › Backups and
    /// to the chosen folder.
    func exportIfDue() {
        guard settings.value.autoExportEnabled, database.hasUserData() else { return }
        let due = lastExportDate.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? true
        guard due || needsExport else { return }
        exportNow(quiet: true)
    }

    func exportNow(quiet: Bool = false) {
        guard !isExporting else { return }
        isExporting = true
        needsExport = false
        let database = database
        let local = documentsBackupFolder
        let external = resolveExportFolder()
        let version = Self.appVersion
        // Ask iOS for time to finish if this starts as the app goes to the
        // background.
        let backgroundTask = BackgroundTaskToken(name: "Forge backup export")
        Task {
            defer { backgroundTask.end() }
            let outcome = await Task.detached(priority: .utility) { () -> Result<String?, Error> in
                do {
                    let data = try ArchiveService.exportData(from: database, appVersion: version)
                    try Self.writeRotating(data, into: local, keep: 7, accessScoped: false)
                    var warning: String?
                    if let external {
                        do {
                            try Self.writeRotating(data, into: external, keep: 7, accessScoped: true)
                        } catch {
                            warning = error.localizedDescription
                        }
                    }
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
                if let warning {
                    feedback.show("Exported on this iPhone, but the backup folder couldn't be written: \(warning)", style: .warning, duration: 5)
                } else if !quiet {
                    feedback.show("Backup exported", style: .success)
                }
            case .failure(let error):
                if !quiet { feedback.report(error, while: "export a backup") }
            }
        }
    }

    /// Writes `Forge-Backup-latest.json` plus a dated copy, keeping the
    /// newest `keep` dated copies.
    nonisolated static func writeRotating(_ data: Data, into folder: URL, keep: Int, accessScoped: Bool) throws {
        let accessing = accessScoped ? folder.startAccessingSecurityScopedResource() : false
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let dated = folder.appendingPathComponent(ArchiveService.suggestedFileName())
        let latest = folder.appendingPathComponent("Forge-Backup-latest.json")
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
        let backups = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let datedCopies = backups
            .filter { $0.lastPathComponent.hasPrefix("Forge-Backup-") && $0.lastPathComponent != "Forge-Backup-latest.json" && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in datedCopies.dropFirst(keep) {
            try? fileManager.removeItem(at: old)
        }
    }
}
