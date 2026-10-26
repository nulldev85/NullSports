import Foundation
import Observation

@MainActor @Observable
final class SeerrStore {
    struct Connection: Codable, Sendable {
        let name: String
        let address: String
    }
    private(set) var connection: Connection?
    private(set) var user: SeerrUser?
    private(set) var isConnecting = false
    private(set) var connectionID = UUID()
    var error: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var api: SeerrClient?
    @ObservationIgnored private var generation = UUID()
    nonisolated static let key = "Lineup.seerr.connection.v1"
    /// The Keychain entry its sign-in is kept under, beside the media servers'.
    nonisolated static let credentialID = UUID(uuidString: "5F82A083-E2DF-48CF-BF68-E4A128E7D921")!

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if case let (saved, client)? = Self.saved(in: defaults) {
            connection = saved
            api = client
        }
    }

    private static func saved(in defaults: UserDefaults) -> (Connection, SeerrClient)? {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(Connection.self, from: data),
              let secret = MediaKeychainStore.token(profileID: credentialID),
              let bytes = secret.data(using: .utf8),
              let credential = try? JSONDecoder().decode(SeerrCredential.self, from: bytes),
              let client = try? SeerrClient(address: saved.address, credential: credential) else { return nil }
        return (saved, client)
    }

    /// Reads the connection again, as at launch: another device has just
    /// written one here. Nothing changes if there is none.
    func restore() {
        guard case let (saved, client)? = Self.saved(in: defaults) else { return }
        generation = UUID()
        connection = saved
        api = client
        user = nil
        error = nil
        connectionID = UUID()
    }

    var isConnected: Bool { connection != nil && api != nil }
    func client() throws -> SeerrClient {
        guard let api else { throw MediaIntegrationError.disconnected }
        return api
    }

    func connect(name: String, address: String, apiKey: String, email: String, password: String,
                 method: SeerrSignInMethod = .local, plexToken: String? = nil) async -> Bool {
        guard !isConnecting else { return false }
        let request = UUID(); generation = request
        isConnecting = true; error = nil
        defer { if generation == request { isConnecting = false } }
        do {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            var credential = SeerrCredential(apiKey: key.isEmpty ? nil : key)
            let client = try SeerrClient(address: address, credential: credential)
            let configuration = try await client.publicSettings()
            guard configuration.initialized else {
                throw MediaIntegrationError.unavailable("Finish configuring Seerr in its web app first, then connect it to Lineup.")
            }
            let account: SeerrUser
            if !key.isEmpty { account = try await client.me() }
            else {
                let result: (SeerrUser, SeerrCredential)
                switch method {
                case .jellyfin, .emby:
                    result = try await client.signInMediaServer(username: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, emby: method == .emby)
                case .plex:
                    guard let plexToken else { throw MediaIntegrationError.invalidResponse }
                    result = try await client.signInPlex(token: plexToken)
                case .local, .apiKey:
                    result = try await client.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                }
                account = result.0; credential = result.1
            }
            guard generation == request, !Task.isCancelled else { await client.signOut(); return false }
            let saved = Connection(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Seerr" : name,
                                   address: client.http.base.absoluteString)
            let encoded = try JSONEncoder().encode(credential)
            guard let secret = String(data: encoded, encoding: .utf8) else { throw MediaIntegrationError.invalidResponse }
            try MediaKeychainStore.save(token: secret, profileID: Self.credentialID)
            defaults.set(try JSONEncoder().encode(saved), forKey: Self.key)
            let old = api
            connection = saved; user = account; api = client; connectionID = UUID()
            Task { await old?.signOut() }
            return true
        } catch {
            if generation == request, !(error is CancellationError) { self.error = error.localizedDescription }
            return false
        }
    }

    func refreshAccount() async {
        guard let api else { return }
        let request = generation
        do {
            let account = try await api.me()
            guard generation == request else { return }
            user = account; error = nil
        } catch {
            if generation == request, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func disconnect() {
        let old = api
        generation = UUID(); api = nil; connection = nil; user = nil; isConnecting = false; error = nil
        connectionID = UUID()
        MediaKeychainStore.delete(profileID: Self.credentialID)
        defaults.removeObject(forKey: Self.key)
        Task { await old?.signOut() }
    }
}
