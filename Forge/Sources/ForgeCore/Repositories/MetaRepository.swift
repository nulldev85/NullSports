import Foundation

/// Key/value storage inside the database, so settings and drafts are part
/// of every backup and export.
public final class MetaRepository: @unchecked Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public enum Key {
        public static let settings = "settings"
        public static let routineDraft = "draft.routine"
        public static let activeTimer = "timer.active"
        public static let autoExportBookmark = "export.folder_bookmark"
        public static let lastAutoExport = "export.last_at"
        public static let folderSuggestionSnoozedUntil = "export.folder_suggestion_snoozed_until"
        public static let catalogVersion = "catalog.version"
        /// The build that last opened this data (to snapshot before updates).
        public static let lastBuild = "app.last_build"
        public static let integrityCheckedAt = "integrity.checked_at"
        /// Empty when the last full check found nothing wrong.
        public static let integrityProblems = "integrity.problems"
        /// Fingerprint of the last exported content, to skip identical exports.
        public static let lastExportFingerprint = "export.last_fingerprint"
        /// When the athlete last saved a backup copy off the iPhone (to iCloud
        /// Drive, say), and the name of the folder it went to.
        public static let offDeviceSavedAt = "export.off_device_saved_at"
        public static let offDeviceFolder = "export.off_device_folder"
    }

    public func get(_ key: String) throws -> String? {
        try queue.read { db in
            try db.queryOne("SELECT value FROM meta WHERE key = ?", [key])?.string("value")
        }
    }

    public func set(_ key: String, value: String?) throws {
        try queue.write { db in
            if let value {
                try db.run(
                    "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [key, value]
                )
            } else {
                try db.run("DELETE FROM meta WHERE key = ?", [key])
            }
        }
    }

    public func setIfMissing(_ key: String, value: String) throws {
        try queue.write { db in
            try db.run("INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)", [key, value])
        }
    }

    public func getJSON<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        guard let text = try get(key) else { return nil }
        return try? JSONCoding.decode(type, from: text)
    }

    public func setJSON<T: Encodable>(_ key: String, _ value: T?) throws {
        if let value {
            try set(key, value: try JSONCoding.encodeString(value))
        } else {
            try set(key, value: nil)
        }
    }

    public func loadSettings(default defaults: AppSettings) throws -> AppSettings {
        try getJSON(Key.settings, as: AppSettings.self) ?? defaults
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try setJSON(Key.settings, settings)
    }

    public func allValues() throws -> [String: String] {
        try queue.read { db in
            var values: [String: String] = [:]
            for row in try db.query("SELECT key, value FROM meta") {
                if let key = row.string("key"), let value = row.string("value") {
                    values[key] = value
                }
            }
            return values
        }
    }
}
