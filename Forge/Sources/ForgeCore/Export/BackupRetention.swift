import Foundation

/// Which backup files to keep: only the newest. Each automatic backup is
/// written as a new dated file, read back and checked, and only then are
/// the older ones deleted, so the folder always holds exactly one good copy.
public enum BackupRetention {
    /// The file older versions of Forge kept next to the dated copies.
    public static let legacyLatestName = "Forge-Backup-latest.json"

    /// A file Forge wrote as a backup: a dated copy, or the old "latest".
    public static func isBackupFileName(_ name: String) -> Bool {
        name == legacyLatestName || date(fromBackupName: name) != nil
    }

    /// The backup files to delete once `newest` has been written and
    /// checked: every other Forge backup in the folder. Files with other
    /// names are never touched.
    public static func filesToRemove(_ names: [String], keeping newest: String) -> [String] {
        var seen = Set<String>()
        return names.filter { name in
            name != newest && isBackupFileName(name) && seen.insert(name).inserted
        }
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
