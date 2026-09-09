import Foundation

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var profiles: [MediaServerProfile] = []
    @Published private(set) var activeProfile: MediaServerProfile?
    @Published private(set) var roots: [MediaItem] = []
    @Published private(set) var catalogs: [MediaCatalog] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let profilesKey = "NullSports.mediaServers"
    private let activeKey = "NullSports.activeMediaServer"
    private let deviceKey = "NullSports.mediaDeviceID"
    private var loadID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: profilesKey),
           let saved = try? JSONDecoder().decode([MediaServerProfile].self, from: data) {
            profiles = saved
        }
        let activeID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        activeProfile = profiles.first { $0.id == activeID } ?? profiles.first
    }

    var hasProfile: Bool { activeProfile != nil }

    func addServer(name: String, serverURL: String, username: String, password: String) async -> Bool {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your media server username and password."
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let client = try JellyfinClient(serverURL: serverURL, deviceID: deviceID)
            let authentication = try await client.authenticate(username: cleanUsername, password: password)
            let profile = MediaServerProfile(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Media" : name,
                serverURL: client.serverURL.absoluteString,
                username: authentication.user.name,
                userID: authentication.user.id
            )
            try MediaKeychainStore.save(token: authentication.accessToken, profileID: profile.id)
            profiles.append(profile)
            activeProfile = profile
            persist()
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func select(_ profile: MediaServerProfile) async {
        loadID = UUID()
        activeProfile = profile
        roots = []
        catalogs = []
        persist()
        await reload()
    }

    func remove(_ profile: MediaServerProfile) {
        loadID = UUID()
        MediaKeychainStore.delete(profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        if activeProfile?.id == profile.id {
            activeProfile = profiles.first
            roots = []
            catalogs = []
        }
        isLoading = false
        persist()
        if activeProfile != nil { Task { await reload() } }
    }

    func reload() async {
        guard let profile = activeProfile else { roots = []; catalogs = []; isLoading = false; return }
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        errorMessage = nil
        do {
            let source = try client(for: profile)
            let loaded = try await source.views(userID: profile.userID)
            let loadedCatalogs = await withTaskGroup(of: MediaCatalog.self) { group in
                for root in loaded {
                    group.addTask {
                        let items = (try? await source.items(userID: profile.userID, parentID: root.id)) ?? []
                        return MediaCatalog(root: root, items: items)
                    }
                }
                var result: [MediaCatalog] = []
                for await catalog in group { result.append(catalog) }
                return result.sorted { left, right in
                    let leftIndex = loaded.firstIndex { $0.id == left.id } ?? .max
                    let rightIndex = loaded.firstIndex { $0.id == right.id } ?? .max
                    return leftIndex < rightIndex
                }
            }
            guard loadID == requestID, activeProfile?.id == profile.id else { return }
            roots = loaded
            catalogs = loadedCatalogs
            errorMessage = nil
        } catch {
            guard loadID == requestID, activeProfile?.id == profile.id else { return }
            errorMessage = error.localizedDescription
        }
        if loadID == requestID { isLoading = false }
    }

    func items(in parent: MediaItem) async throws -> [MediaItem] {
        guard let profile = activeProfile else { return [] }
        return try await client(for: profile).items(userID: profile.userID, parentID: parent.id)
    }

    func search(_ query: String) async throws -> [MediaItem] {
        guard let profile = activeProfile else { return [] }
        return try await client(for: profile).search(userID: profile.userID, query: query)
    }

    func imageURL(for item: MediaItem, width: Int = 600) -> URL? {
        guard let profile = activeProfile else { return nil }
        return try? client(for: profile).imageURL(itemID: item.id, maxWidth: width)
    }

    func playbackURL(for item: MediaItem) -> URL? {
        guard let profile = activeProfile else { return nil }
        return try? client(for: profile).playbackURL(itemID: item.id)
    }

    private var deviceID: String {
        if let existing = defaults.string(forKey: deviceKey) { return existing }
        let value = UUID().uuidString
        defaults.set(value, forKey: deviceKey)
        return value
    }

    private func client(for profile: MediaServerProfile) throws -> JellyfinClient {
        guard let token = MediaKeychainStore.token(profileID: profile.id) else {
            throw JellyfinError.authenticationFailed
        }
        return try JellyfinClient(serverURL: profile.serverURL, accessToken: token, deviceID: deviceID)
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: profilesKey)
        defaults.set(activeProfile?.id.uuidString, forKey: activeKey)
    }
}
