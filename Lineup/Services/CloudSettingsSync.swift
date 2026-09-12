import CloudKit
import Foundation

/// Syncs user-authored Lineup settings through the user's private iCloud database.
/// Schedule, guide, and stream caches remain local because they are fetched again.
@MainActor
final class CloudSettingsSync: ObservableObject {
    static let shared = CloudSettingsSync()
    static let imported = Notification.Name("Lineup.cloudSettingsImported")

    @Published private(set) var status = "Not synced"

    private let defaults = UserDefaults.standard
    private let database = CKContainer(identifier: "iCloud.com.nulldev85.Lineup").privateCloudDatabase
    private let recordID = CKRecord.ID(recordName: "lineup-settings-v1")
    private let syncedKeys = [
        "NullSports.profiles", "NullSports.activeProfile", "NullSports.mediaServers",
        "NullSports.activeMediaServer", "NullSports.mediaShelves", "NullSports.favoriteStreams",
        "lineup.appearance.theme", "Lineup.followedTeams", "Lineup.manualGameReminders",
        "Lineup.reminderLeadMinutes", "Lineup.morningDigest"
    ]
    private var isApplying = false
    private var syncInFlight = false
    private var needsSync = false

    private struct Snapshot: Codable {
        var updatedAt: Date
        var values: [String: Data]
        var providerPasswords: [String: String]
        var mediaTokens: [String: String]
    }

    private init() {}

    func sync() async {
        guard !isApplying else { return }
        if syncInFlight { needsSync = true; return }
        syncInFlight = true
        defer {
            syncInFlight = false
            if needsSync {
                needsSync = false
                Task { await sync() }
            }
        }
        do {
            let remote = try? await database.record(for: recordID)
            let local = capture()
            let incoming = remote.flatMap { $0.encryptedValues["payload"] as? Data }
                .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
            if let incoming, incoming.updatedAt > local.updatedAt {
                apply(incoming)
                status = "Synced with iCloud"
                return
            }
            if incoming == nil || local.updatedAt > (incoming?.updatedAt ?? .distantPast) {
                try await upload(local, existing: remote)
            }
            status = "Synced with iCloud"
        } catch {
            if let cloudError = error as? CKError, cloudError.code == .serverRecordChanged { needsSync = true }
            status = "Sync unavailable: \(error.localizedDescription)"
        }
    }

    func localSettingsChanged() {
        guard !isApplying else { return }
        defaults.set(Date(), forKey: "Lineup.cloudSettingsUpdatedAt")
        Task { await sync() }
    }

    private func capture() -> Snapshot {
        var values: [String: Data] = [:]
        for key in syncedKeys {
            if let value = defaults.object(forKey: key),
               let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
                values[key] = data
            }
        }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("NullSports.favoriteStreams.") {
            if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
                values[key] = data
            }
        }
        let providerIDs = (try? JSONDecoder().decode([XtreamProfile].self, from: defaults.data(forKey: "NullSports.profiles") ?? Data()))?.map(\.id) ?? []
        let mediaIDs = (try? JSONDecoder().decode([MediaServerProfile].self, from: defaults.data(forKey: "NullSports.mediaServers") ?? Data()))?.map(\.id) ?? []
        return Snapshot(
            updatedAt: defaults.object(forKey: "Lineup.cloudSettingsUpdatedAt") as? Date ?? .distantPast,
            values: values,
            providerPasswords: Dictionary(uniqueKeysWithValues: providerIDs.compactMap { id in
                KeychainStore.password(profileID: id).map { (id.uuidString, $0) }
            }),
            mediaTokens: Dictionary(uniqueKeysWithValues: mediaIDs.compactMap { id in
                MediaKeychainStore.token(profileID: id).map { (id.uuidString, $0) }
            })
        )
    }

    private func apply(_ snapshot: Snapshot) {
        isApplying = true
        defer { isApplying = false }
        for key in syncedKeys where snapshot.values[key] == nil { defaults.removeObject(forKey: key) }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NullSports.favoriteStreams.") && snapshot.values[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, data) in snapshot.values {
            guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { continue }
            defaults.set(value, forKey: key)
        }
        for (key, password) in snapshot.providerPasswords {
            if let id = UUID(uuidString: key) { try? KeychainStore.save(password: password, profileID: id) }
        }
        for (key, token) in snapshot.mediaTokens {
            if let id = UUID(uuidString: key) { try? MediaKeychainStore.save(token: token, profileID: id) }
        }
        defaults.set(snapshot.updatedAt, forKey: "Lineup.cloudSettingsUpdatedAt")
        NotificationCenter.default.post(name: Self.imported, object: nil)
    }

    private func upload(_ snapshot: Snapshot, existing: CKRecord?) async throws {
        let record = existing ?? CKRecord(recordType: "LineupSettings", recordID: recordID)
        let payload = try JSONEncoder().encode(snapshot)
        record.encryptedValues["payload"] = payload as NSData
        _ = try await database.save(record)
    }
}
