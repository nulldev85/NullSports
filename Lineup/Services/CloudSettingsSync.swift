import CloudKit
import CryptoKit
import Foundation

/// Syncs user-authored Lineup settings through the user's private iCloud database.
/// Schedule, guide, and stream caches remain local because they are fetched again.
@MainActor
final class CloudSettingsSync: ObservableObject {
    static let shared = CloudSettingsSync()
    static let imported = Notification.Name("Lineup.cloudSettingsImported")

    @Published private(set) var status = "Not synced"

    private let defaults = UserDefaults.standard
    private var database: CKDatabase { CKContainer(identifier: "iCloud.com.nulldev85.Lineup").privateCloudDatabase }
    private let recordID = CKRecord.ID(recordName: "lineup-settings-v1")
    /// What follows the person from device to device. Setting up an Apple TV
    /// from the phone sends the same, with a little more (`DeviceSetup`).
    nonisolated static let syncedKeys = [
        "NullSports.profiles", "NullSports.activeProfile", "NullSports.mediaServers",
        "NullSports.activeMediaServer", "NullSports.mediaShelves", "Lineup.mediaHeroCatalog.v1", "NullSports.favoriteStreams",
        "Lineup.libraryShelfOrder.v1", "Lineup.mediaHeroSource.v1", "Lineup.trendingRows.hidden", "Lineup.libraryShelfNames.v1",
        "lineup.appearance.accent", "lineup.appearance.savedAccents", "Lineup.manualGameReminders",
        "Lineup.reminderLeadMinutes", "Lineup.morningDigest"
    ]
    /// Keys kept one per provider: its favorites, teams and channel choices.
    nonisolated static let syncedPrefixes = [
        "NullSports.favoriteStreams.", "NullSports.followedTeams.",
        "NullSports.teamChannelPreferences.", "NullSports.gameChannelSelections."
    ]
    private var isApplying = false
    private var syncInFlight = false
    private var needsSync = false

    private struct Snapshot: Codable {
        var updatedAt: Date
        var values: [String: Data]
        var providerPasswords: [String: String]
        var mediaTokens: [String: String]
        /// When each value last changed on the device that changed it. A
        /// snapshot from a build before this has none: its values all date
        /// from `updatedAt`.
        var changedAt: [String: Date]? = nil

        var side: CloudSettingsMerge.Side {
            CloudSettingsMerge.Side(values: values, changedAt: values.keys.reduce(into: [String: Date]()) { times, key in
                times[key] = changedAt?[key] ?? updatedAt
            })
        }
    }

    // This device's record of each synced value as last seen, as a digest, and
    // when it last changed: a value that no longer matches its digest has
    // changed here since.
    private let digestsKey = "Lineup.cloudSettingsDigests"
    private let changedAtKey = "Lineup.cloudSettingsChangedAt"

    private init() {}

    /// The app's root watches this, and the sync runs every few minutes:
    /// setting the same words again would redraw every screen that often.
    private func report(_ text: String) {
        if status != text { status = text }
    }

    func sync() async {
        #if LINEUP_UNSIGNED_BUILD
        report("iCloud sync requires a signed build with CloudKit enabled")
        #elseif targetEnvironment(simulator)
        report("iCloud sync requires a signed device build")
        #else
        await syncWithCloud()
        #endif
    }

    /// The sync itself, which only a signed device build can make.
    private func syncWithCloud() async {
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
            guard let incoming else {
                try await upload(local, existing: remote)
                report("Synced with iCloud")
                return
            }
            // Setting by setting: the more recent change wins, and a value
            // only one device has is kept. A favourite added on the television
            // is no longer undone by the phone's older copy of everything.
            let merge = CloudSettingsMerge(local: local.side, remote: incoming.side)
            let remoteNewer = incoming.updatedAt > local.updatedAt
            let passwords = CloudSettingsMerge.secrets(local: local.providerPasswords,
                                                       remote: incoming.providerPasswords, remoteNewer: remoteNewer)
            let tokens = CloudSettingsMerge.secrets(local: local.mediaTokens,
                                                    remote: incoming.mediaTokens, remoteNewer: remoteNewer)
            if !merge.taken.isEmpty || !passwords.taken.isEmpty || !tokens.taken.isEmpty {
                apply(merge.taken, changedAt: merge.merged.changedAt, passwords: passwords.taken, tokens: tokens.taken)
            }
            let merged = Snapshot(updatedAt: max(local.updatedAt, incoming.updatedAt), values: merge.merged.values,
                                  providerPasswords: passwords.merged, mediaTokens: tokens.merged,
                                  changedAt: merge.merged.changedAt)
            if merge.merged != incoming.side || passwords.merged != incoming.providerPasswords
                || tokens.merged != incoming.mediaTokens {
                try await upload(merged, existing: remote)
            }
            report("Synced with iCloud")
        } catch {
            if let cloudError = error as? CKError, cloudError.code == .serverRecordChanged { needsSync = true }
            report("Sync unavailable: \(error.localizedDescription)")
        }
    }

    func localSettingsChanged() {
        guard !isApplying else { return }
        defaults.set(Date(), forKey: "Lineup.cloudSettingsUpdatedAt")
        Task { await sync() }
    }

    private func capture() -> Snapshot {
        var values: [String: Data] = [:]
        for key in Self.syncedKeys {
            if let value = defaults.object(forKey: key),
               let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
                values[key] = data
            }
        }
        for (key, value) in defaults.dictionaryRepresentation()
        where Self.syncedPrefixes.contains(where: key.hasPrefix) {
            if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
                values[key] = data
            }
        }
        let providerIDs = (try? JSONDecoder().decode([XtreamProfile].self, from: defaults.data(forKey: "NullSports.profiles") ?? Data()))?.map(\.id) ?? []
        let mediaIDs = (try? JSONDecoder().decode([MediaServerProfile].self, from: defaults.data(forKey: "NullSports.mediaServers") ?? Data()))?.map(\.id) ?? []
        let updatedAt = defaults.object(forKey: "Lineup.cloudSettingsUpdatedAt") as? Date ?? .distantPast
        return Snapshot(
            updatedAt: updatedAt,
            values: values,
            providerPasswords: Dictionary(uniqueKeysWithValues: providerIDs.compactMap { id in
                KeychainStore.password(profileID: id).map { (id.uuidString, $0) }
            }),
            mediaTokens: Dictionary(uniqueKeysWithValues: mediaIDs.compactMap { id in
                MediaKeychainStore.token(profileID: id).map { (id.uuidString, $0) }
            }),
            changedAt: stampChanges(values, lastChange: updatedAt)
        )
    }

    /// When each value last changed here. One that no longer matches its
    /// digest has changed since it was last seen, at the last time the app
    /// said something changed, or now if that came before the value's own
    /// last change. The first time, before any digest was kept, every value
    /// dates from that last change, as the whole snapshot used to.
    private func stampChanges(_ values: [String: Data], lastChange: Date) -> [String: Date] {
        let saved = defaults.dictionary(forKey: digestsKey) as? [String: String]
        var digests = saved ?? [:]
        var times = defaults.dictionary(forKey: changedAtKey) as? [String: Date] ?? [:]
        for (key, data) in values {
            let digest = Self.digest(data)
            guard digests[key] != digest else { continue }
            digests[key] = digest
            let previous = times[key] ?? .distantPast
            times[key] = saved == nil || lastChange > previous ? lastChange : Date()
        }
        defaults.set(digests, forKey: digestsKey)
        defaults.set(times, forKey: changedAtKey)
        return times.filter { values[$0.key] != nil }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The values and sign-ins taken from another device. A snapshot is a set
    /// of values known to another device, not a deletion manifest. Treating an
    /// absent key as a tombstone erased a local IPTV profile and every
    /// per-profile favorite while unrelated addon keys survived. Only values
    /// the snapshot actually carries are written.
    private func apply(_ values: [String: Data], changedAt: [String: Date],
                       passwords: [String: String], tokens: [String: String]) {
        isApplying = true
        defer { isApplying = false }
        defaults.removeObject(forKey: "Lineup.followedTeams")
        var digests = defaults.dictionary(forKey: digestsKey) as? [String: String] ?? [:]
        var times = defaults.dictionary(forKey: changedAtKey) as? [String: Date] ?? [:]
        for (key, data) in values where key != "Lineup.followedTeams" {
            guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { continue }
            defaults.set(value, forKey: key)
            // Taken, not changed here, so it must not read as a local change.
            // The digest is of the value as this device writes it out again,
            // as `capture` will: a dictionary's keys may not come back in the
            // other device's order.
            let written = defaults.object(forKey: key).flatMap {
                try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
            }
            digests[key] = Self.digest(written ?? data)
            times[key] = changedAt[key]
        }
        defaults.set(digests, forKey: digestsKey)
        defaults.set(times, forKey: changedAtKey)
        for (key, password) in passwords {
            if let id = UUID(uuidString: key) { try? KeychainStore.save(password: password, profileID: id) }
        }
        for (key, token) in tokens {
            if let id = UUID(uuidString: key) { try? MediaKeychainStore.save(token: token, profileID: id) }
        }
        NotificationCenter.default.post(name: Self.imported, object: nil)
    }

    private func upload(_ snapshot: Snapshot, existing: CKRecord?) async throws {
        let record = existing ?? CKRecord(recordType: "LineupSettings", recordID: recordID)
        let payload = try JSONEncoder().encode(snapshot)
        record.encryptedValues["payload"] = payload as NSData
        _ = try await database.save(record)
    }
}

/// How two devices' settings come together: each value on its own, the one
/// changed more recently winning. A value only one device has is kept, and
/// nothing is ever deleted by a merge.
struct CloudSettingsMerge {
    struct Side: Equatable {
        var values: [String: Data]
        var changedAt: [String: Date]
    }

    /// The values this device takes from the other.
    let taken: [String: Data]
    /// What the two devices now share.
    let merged: Side

    init(local: Side, remote: Side) {
        var taken: [String: Data] = [:]
        var merged = local
        for (key, value) in remote.values {
            let theirs = remote.changedAt[key] ?? .distantPast
            if let mine = local.values[key] {
                let ours = local.changedAt[key] ?? .distantPast
                if mine == value { merged.changedAt[key] = max(ours, theirs); continue }
                // Changed at the same moment: both devices settle on the same
                // one, or each would keep its own and send it on every sync.
                guard theirs > ours || (theirs == ours && mine.lexicographicallyPrecedes(value)) else { continue }
            }
            taken[key] = value
            merged.values[key] = value
            merged.changedAt[key] = theirs
        }
        self.taken = taken
        self.merged = merged
    }

    /// Sign-ins, which carry no time of their own: one only a device has is
    /// kept, and where both have a different one the device whose settings
    /// changed last wins.
    static func secrets(local: [String: String], remote: [String: String],
                        remoteNewer: Bool) -> (taken: [String: String], merged: [String: String]) {
        let taken = remote.filter { key, value in local[key].map { $0 != value && remoteNewer } ?? true }
        return (taken, local.merging(taken) { _, theirs in theirs })
    }
}
