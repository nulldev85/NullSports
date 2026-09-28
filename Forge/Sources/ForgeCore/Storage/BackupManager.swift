import Foundation

public enum BackupError: Error, CustomStringConvertible {
    case invalidSnapshot(String)
    case invalidArchive(String)
    case newerArchive(Int)

    public var description: String {
        switch self {
        case .invalidSnapshot(let reason): return "This backup can't be used: \(reason)"
        case .invalidArchive(let reason): return "This file isn't a readable Forge backup: \(reason)"
        case .newerArchive(let version): return "This backup was made by a newer version of Forge (format \(version)). Update the app to restore it."
        }
    }
}

/// Point-in-time copies of the whole database, kept next to it. They are
/// made automatically (daily, before migrations, before restores) and can be
/// restored from Settings.
public final class BackupManager: @unchecked Sendable {
    public enum Reason: String, CaseIterable, Sendable {
        case automatic = "auto"
        case manual = "manual"
        case preMigration = "premigration"
        case preRestore = "prerestore"
        case preImport = "preimport"

        public var displayName: String {
            switch self {
            case .automatic: return "Automatic"
            case .manual: return "Manual"
            case .preMigration: return "Before update"
            case .preRestore: return "Before restore"
            case .preImport: return "Before import"
            }
        }
    }

    public struct Snapshot: Identifiable, Hashable, Sendable {
        public var url: URL
        public var date: Date
        public var reason: Reason
        public var byteCount: Int

        public var id: String { url.lastPathComponent }
    }

    public struct SnapshotSummary: Hashable, Sendable {
        public var workouts: Int
        public var routines: Int
        public var customExercises: Int
        public var lastWorkoutAt: Date?
    }

    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    private static let filePrefix = "forge-"
    private static let fileExtension = "sqlite"

    private func fileName(date: Date, reason: Reason) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return "\(Self.filePrefix)\(millis)-\(reason.rawValue).\(Self.fileExtension)"
    }

    private func parse(_ url: URL) -> Snapshot? {
        let name = url.lastPathComponent
        guard name.hasPrefix(Self.filePrefix), url.pathExtension == Self.fileExtension else { return nil }
        let core = name.dropFirst(Self.filePrefix.count).dropLast(Self.fileExtension.count + 1)
        let parts = core.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let millis = Int64(parts[0]), let reason = Reason(rawValue: parts[1]) else { return nil }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return Snapshot(url: url, date: Date(timeIntervalSince1970: Double(millis) / 1000), reason: reason, byteCount: size)
    }

    /// All snapshots, newest first.
    public func snapshots() -> [Snapshot] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap(parse).sorted { $0.date > $1.date }
    }

    /// Writes a consistent copy of the live database. The copy is built under
    /// a temporary name and only renamed into place once complete, so an
    /// interrupted backup never looks like a valid one.
    @discardableResult
    public func createSnapshot(from queue: DatabaseQueue, reason: Reason, now: Date = Date()) throws -> Snapshot {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var date = now
        var finalURL = directory.appendingPathComponent(fileName(date: date, reason: reason))
        while fileManager.fileExists(atPath: finalURL.path) {
            date = date.addingTimeInterval(0.001)
            finalURL = directory.appendingPathComponent(fileName(date: date, reason: reason))
        }
        let partialURL = finalURL.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partialURL)
        let escaped = partialURL.path.replacingOccurrences(of: "'", with: "''")
        do {
            try queue.read { db in
                try db.execute("VACUUM INTO '\(escaped)'")
            }
            try fileManager.moveItem(at: partialURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }
        guard let snapshot = parse(finalURL) else {
            throw BackupError.invalidSnapshot("Couldn't read the new backup file")
        }
        return snapshot
    }

    /// Opens the snapshot read-only and confirms it's an intact Forge
    /// database.
    public func validate(_ snapshot: Snapshot) -> Bool {
        guard let connection = try? Connection(path: snapshot.url.path, readOnly: true) else { return false }
        defer { connection.close() }
        guard let problems = try? connection.integrityProblems(), problems.isEmpty else { return false }
        guard let hasWorkouts = try? connection.tableExists("workout"), hasWorkouts else { return false }
        return true
    }

    public func summary(of snapshot: Snapshot) -> SnapshotSummary? {
        guard let connection = try? Connection(path: snapshot.url.path, readOnly: true) else { return nil }
        defer { connection.close() }
        do {
            let workouts = try connection.scalarInt("SELECT COUNT(*) FROM workout WHERE status = 'completed' AND deleted_at IS NULL")
            let routines = try connection.scalarInt("SELECT COUNT(*) FROM routine WHERE deleted_at IS NULL")
            let customs = try connection.scalarInt("SELECT COUNT(*) FROM custom_exercise")
            let last = try connection.queryOne("SELECT MAX(started_at) AS last FROM workout WHERE status = 'completed' AND deleted_at IS NULL")?.date("last")
            return SnapshotSummary(workouts: workouts, routines: routines, customExercises: customs, lastWorkoutAt: last)
        } catch {
            return nil
        }
    }

    public func latestValidSnapshot() -> Snapshot? {
        snapshots().first { validate($0) }
    }

    public func latestSnapshotDate(reason: Reason? = nil) -> Date? {
        snapshots().first { reason == nil || $0.reason == reason }?.date
    }

    public func isAutomaticBackupDue(now: Date = Date(), interval: TimeInterval = 20 * 3600) -> Bool {
        guard let last = latestSnapshotDate(reason: .automatic) else { return true }
        return now.timeIntervalSince(last) >= interval || last > now
    }

    /// Keeps the newest `keepAutomatic` automatic snapshots plus one per week
    /// for older weeks (up to `keepWeekly`), and the newest `keepOther` of
    /// each other kind. Manual snapshots are never removed automatically.
    public func prune(keepAutomatic: Int = 10, keepWeekly: Int = 8, keepOther: Int = 5, calendar: Calendar = Calendar(identifier: .gregorian)) {
        let all = snapshots()
        var remove: [Snapshot] = []

        let automatic = all.filter { $0.reason == .automatic }
        var weeklyKept = Set<String>()
        for (index, snapshot) in automatic.enumerated() {
            if index < keepAutomatic { continue }
            let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: snapshot.date)
            let key = "\(week.yearForWeekOfYear ?? 0)-\(week.weekOfYear ?? 0)"
            if weeklyKept.count < keepWeekly, !weeklyKept.contains(key) {
                weeklyKept.insert(key)
            } else {
                remove.append(snapshot)
            }
        }
        for reason in [Reason.preMigration, .preRestore, .preImport] {
            let ofKind = all.filter { $0.reason == reason }
            remove.append(contentsOf: ofKind.dropFirst(keepOther))
        }
        for snapshot in remove {
            try? fileManager.removeItem(at: snapshot.url)
        }
        // Clean up any interrupted backups.
        let leftovers = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in leftovers where url.pathExtension == "partial" {
            try? fileManager.removeItem(at: url)
        }
    }

    public func delete(_ snapshot: Snapshot) throws {
        try fileManager.removeItem(at: snapshot.url)
    }
}
