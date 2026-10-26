import Foundation
import Observation
import CryptoKit

struct MDBListTrackingAccount: Codable {
    let userID: Int
    let keyDigest: String
    static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A single serialized, account-scoped writer. Neither network failures nor
/// authentication work are awaited by a player callback.
@MainActor @Observable
final class MDBListTrackingService {
    private(set) var status = "Off"
    private(set) var pendingCount = 0
    private(set) var lastSynced: Date?
    private(set) var records: [MDBListTrackingRecord] = []
    private(set) var hasSnapshot = false
    @ObservationIgnored var onSnapshot: (([MDBListTrackingRecord]) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var account: Int?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var queue: [MDBListTrackingWrite] = []
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var syncWork: Task<Void, Never>?
    @ObservationIgnored private var pendingSyncForce: Bool?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var lastSnapshot: Date?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var needsAuthentication = false
    @ObservationIgnored private var rejected = 0
    private func queueKey(_ account: Int) -> String { "Lineup.tracking.mdblistOutbox.v1.\(account)" }
    private func snapshotKey(_ account: Int) -> String { "Lineup.tracking.mdblistSnapshot.v1.\(account)" }
    private func retryKey(_ account: Int) -> String { "Lineup.tracking.mdblistRetry.v1.\(account)" }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults; self.session = session
    }

    func configure(accountID: Int?, apiKey: String?, enabled: Bool) {
        let next = enabled ? accountID : nil
        guard next != account || (next != nil && apiKey != key) else {
            if enabled && next == nil { status = "Connect MDBList to enable tracking" }
            return
        }
        generation = UUID()
        work?.cancel(); work = nil
        syncWork?.cancel(); syncWork = nil
        pendingSyncForce = nil
        retry?.cancel(); retry = nil
        if let old = account, old != next { defaults.removeObject(forKey: queueKey(old)) }
        account = next; key = next == nil ? nil : apiKey
        queue = []; records = []; hasSnapshot = false; pendingCount = 0
        retryAt = nil; failures = 0; rejected = 0; needsAuthentication = false; lastSnapshot = nil; lastSynced = nil
        guard let account, apiKey?.isEmpty == false else {
            status = enabled ? "Connect MDBList to enable tracking" : "Off"
            return
        }
        if let data = defaults.data(forKey: queueKey(account)),
           let saved = try? JSONDecoder().decode([MDBListTrackingWrite].self, from: data) { queue = saved }
        if let data = defaults.data(forKey: snapshotKey(account)),
           let saved = try? JSONDecoder().decode([MDBListTrackingRecord].self, from: data) { records = saved; hasSnapshot = true }
        pendingCount = queue.count
        retryAt = defaults.object(forKey: retryKey(account)) as? Date
        status = "Ready"
        flush()
    }

    func enqueue(_ event: MDBListTrackingWrite) {
        guard account != nil, key != nil, event.target.valid, event.progress.isFinite else { return }
        revision += 1
        if syncWork != nil { pendingSyncForce = true }
        // An earlier read is no longer an authoritative snapshot after a
        // local write. Keep the working Library cache until a fresh full read.
        hasSnapshot = false
        if let account { defaults.removeObject(forKey: snapshotKey(account)) }
        // A stopped/paused session supersedes stale heartbeats for that session.
        // Explicit marks also retire queued progress so an offline sample cannot
        // undo the user's newer watched/unwatched choice.
        queue.removeAll { previous in
            let sameShow = event.target.kind == .show && previous.target.kind == .episode
                && event.target.ids.contains { previous.target.ids[$0.key] == $0.value }
            guard previous.target.key == event.target.key || sameShow else { return false }
            if event.action == .watched || event.action == .unwatched || event.action == .clear { return true }
            return previous.sessionID == event.sessionID && ![.watched, .unwatched].contains(previous.action)
        }
        queue.append(event)
        persistQueue()
        flush()
    }

    func unavailableIdentity() {
        rejected += 1
        if account != nil, work == nil { status = "Some titles need a verified movie or episode ID" }
    }

    func credentialsValidated() {
        guard let account else { return }
        needsAuthentication = false
        status = "Ready"
        if failures == 0 { defaults.removeObject(forKey: retryKey(account)); retryAt = nil }
        flush()
    }

    func flush() {
        guard work == nil, let key, account != nil, !queue.isEmpty, !needsAuthentication else { return }
        if let retryAt, retryAt > Date() { scheduleRetry(at: retryAt); return }
        let token = generation
        let client = MDBListTrackingClient(apiKey: key, session: session)
        work = Task { [weak self] in
            guard let self else { return }
            while self.generation == token, !Task.isCancelled, let event = self.queue.first {
                // Do not resurrect an old "now playing" session after an outage.
                if event.action == .start, Date().timeIntervalSince(event.occurredAt) > 300 {
                    self.queue.removeAll { $0.id == event.id }; self.persistQueue(); continue
                }
                self.status = "Syncing viewing activity…"
                do {
                    try await client.write(event)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.queue.removeAll { $0.id == event.id }
                    self.failures = 0; self.retryAt = nil; self.lastSynced = Date()
                    if let account = self.account { self.defaults.removeObject(forKey: self.retryKey(account)) }
                    self.persistQueue()
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    if case MDBListTrackingFailure.unavailable = error {
                        self.queue.removeAll { $0.id == event.id }
                        self.persistQueue()
                        self.rejected += 1
                        self.status = "MDBList could not match a title"
                        continue
                    }
                    self.handle(error)
                    self.work = nil
                    return
                }
            }
            guard self.generation == token else { return }
            self.work = nil
            if self.queue.isEmpty { self.status = self.rejected > 0 ? "Some titles could not be matched" : "Up to date" }
            if let force = self.pendingSyncForce { self.synchronize(force: force) }
        }
    }

    func synchronize(force: Bool = false) {
        guard account != nil, key != nil, !needsAuthentication else { return }
        let force = force || pendingSyncForce == true
        if syncWork != nil || work != nil || !queue.isEmpty {
            pendingSyncForce = force
            flush()
            return
        }
        flush()
        guard syncWork == nil, work == nil, queue.isEmpty, let key, let account, !needsAuthentication else { return }
        if let retryAt, retryAt > Date() { pendingSyncForce = force; scheduleRetry(at: retryAt); return }
        if !force, let lastSnapshot, Date().timeIntervalSince(lastSnapshot) < 60 { pendingSyncForce = nil; return }
        pendingSyncForce = nil
        let token = generation, revision = revision
        syncWork = Task { [weak self] in
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.status = "Reading watch history…"
            do {
                let records = try await MDBListTrackingClient(apiKey: key, session: self.session).snapshot()
                guard self.generation == token, !Task.isCancelled else { return }
                if self.revision == revision, self.queue.isEmpty {
                    self.records = records
                    self.hasSnapshot = true
                    if let data = try? JSONEncoder().encode(records) { self.defaults.set(data, forKey: self.snapshotKey(account)) }
                    self.lastSnapshot = Date(); self.lastSynced = Date(); self.status = "Up to date"
                    self.onSnapshot?(records)
                }
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.handle(error)
            }
            if self.generation == token {
                self.syncWork = nil
                if let force = self.pendingSyncForce { self.synchronize(force: force) }
            }
        }
    }

    private func handle(_ error: Error) {
        if case MDBListTrackingFailure.credentials = error {
            needsAuthentication = true
            status = "Reconnect MDBList to resume tracking"
            return
        }
        failures += 1
        let next: Date
        if case MDBListTrackingFailure.rateLimited(let date) = error { next = date }
        else { next = Date().addingTimeInterval(min(3600, 15 * pow(2, Double(min(failures, 8))))) }
        retryAt = next
        if let account { defaults.set(next, forKey: retryKey(account)) }
        status = pendingCount > 0 ? "Viewing activity saved; waiting to retry" : "MDBList unavailable; using saved history"
        scheduleRetry(at: next)
    }
    private func scheduleRetry(at date: Date) {
        guard retry == nil else { return }
        let token = generation
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow))) } catch { return }
            guard let self, self.generation == token else { return }
            self.retry = nil
            if self.queue.isEmpty { self.synchronize(force: true) } else { self.flush() }
        }
    }
    private func persistQueue() {
        pendingCount = queue.count
        guard let account else { return }
        if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: queueKey(account)) }
    }
}
