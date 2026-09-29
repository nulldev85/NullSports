import Foundation

/// Which dated backup files to keep. The newest are all kept; older ones
/// thin out to one per day for a month, then one per week for half a year.
/// So if something goes missing and nobody notices for weeks, a backup from
/// before it happened is still there.
public enum BackupRetention {
    public struct File: Sendable, Hashable {
        public var name: String
        public var date: Date

        public init(name: String, date: Date) {
            self.name = name
            self.date = date
        }
    }

    /// The names to delete.
    public static func filesToRemove(
        _ files: [File],
        now: Date = Date(),
        keepRecent: Int = 10,
        dailyForDays: Int = 30,
        weeklyForWeeks: Int = 26,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [String] {
        let newestFirst = files.sorted { $0.date > $1.date }
        var keep = Set(newestFirst.prefix(keepRecent).map(\.name))
        var days = Set<String>()
        var weeks = Set<String>()
        for file in newestFirst {
            let age = now.timeIntervalSince(file.date)
            if age <= Double(dailyForDays) * 86_400 {
                let day = calendar.dateComponents([.year, .month, .day], from: file.date)
                let key = "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
                if days.insert(key).inserted { keep.insert(file.name) }
            } else if age <= Double(weeklyForWeeks) * 7 * 86_400 {
                let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: file.date)
                let key = "\(week.yearForWeekOfYear ?? 0)-\(week.weekOfYear ?? 0)"
                if weeks.insert(key).inserted { keep.insert(file.name) }
            }
        }
        return newestFirst.map(\.name).filter { !keep.contains($0) }
    }

    /// The date in a dated backup name ("Forge-Backup-2026-09-29-1802.json").
    public static func date(fromBackupName name: String) -> Date? {
        let prefix = "Forge-Backup-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let stamp = name.dropFirst(prefix.count).dropLast(".json".count)
        let parts = stamp.split(separator: "-").map(String.init)
        guard parts.count >= 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts[3].count == 4, let hour = Int(parts[3].prefix(2)), let minute = Int(parts[3].suffix(2)) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        // A second copy written in the same minute gets a suffix; order it
        // after the first.
        components.second = parts.count > 4 ? min(59, Int(parts[4]) ?? 0) : 0
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

extension BackupArchive {
    /// Identifies what's in the archive, ignoring when it was exported, so
    /// an export identical to the previous one can be skipped.
    public func contentFingerprint() throws -> String {
        var copy = self
        copy.exportedAt = Date(timeIntervalSince1970: 0)
        let data = try JSONCoding.encoder().encode(copy)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\(String(hash, radix: 16))-\(data.count)"
    }
}
