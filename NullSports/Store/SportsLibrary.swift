import Foundation

@MainActor
final class SportsLibrary: ObservableObject {
    @Published private(set) var profiles: [XtreamProfile] = []
    @Published var activeProfile: XtreamProfile?
    @Published private(set) var categories: [XtreamCategory] = []
    @Published private(set) var streams: [XtreamStream] = []
    @Published private(set) var currentPrograms: [String: CurrentProgram] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let profilesKey = "NullSports.profiles"
    private let activeKey = "NullSports.activeProfile"

    init() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([XtreamProfile].self, from: data) {
            profiles = decoded
        }
        if let id = UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:)) {
            activeProfile = profiles.first { $0.id == id }
        } else {
            activeProfile = profiles.first
        }
    }

    var hasProfile: Bool { activeProfile != nil }

    func addProfile(name: String, serverURL: String, username: String, password: String) async -> Bool {
        let profile = XtreamProfile(name: name.isEmpty ? "My IPTV" : name, serverURL: serverURL, username: username)
        do {
            let client = XtreamClient(profile: profile, password: password)
            let envelope = try await client.authenticate()
            guard envelope.userInfo?.auth == 1 else { throw XtreamClient.XtreamError.unauthorized }
            try KeychainStore.save(password: password, profileID: profile.id)
            profiles.append(profile)
            activeProfile = profile
            persistProfiles()
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reload() async {
        guard let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let client = XtreamClient(profile: profile, password: password)
            async let loadedCategories = client.categories()
            async let loadedStreams = client.streams()
            async let loadedPrograms = client.currentPrograms()
            categories = try await loadedCategories
            streams = try await loadedStreams
            currentPrograms = (try? await loadedPrograms) ?? [:]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func streams(for league: SportsLeague) -> [XtreamStream] {
        let categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.categoryName) })
        return streams.filter { stream in
            league.matches(stream.name) || league.matches(categoryNames[stream.categoryID ?? ""] ?? "")
        }
    }

    func liveStreams(for league: SportsLeague) -> [XtreamStream] {
        streams.filter { stream in
            guard !isExcluded(stream),
                  let channelID = stream.epgChannelID,
                  let program = currentPrograms[channelID]
            else { return false }
            let listing = "\(program.title) \(program.detail)"
            let looksLikeGame = listing.localizedCaseInsensitiveContains(" vs ")
                || listing.localizedCaseInsensitiveContains(" vs. ")
                || listing.localizedCaseInsensitiveContains(" at ")
            return league.matches(listing) && looksLikeGame
        }
    }

    func program(for stream: XtreamStream) -> CurrentProgram? {
        stream.epgChannelID.flatMap { currentPrograms[$0] }
    }

    func playbackURLs(for stream: XtreamStream) -> [URL] {
        guard let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return [] }
        return XtreamClient(profile: profile, password: password).playbackURLs(for: stream)
    }

    private func isExcluded(_ stream: XtreamStream) -> Bool {
        let category = categories.first { $0.id == stream.categoryID }?.categoryName ?? ""
        return "\(stream.name) \(category)".localizedCaseInsensitiveContains("NFHS")
    }

    func removeActiveProfile() {
        guard let profile = activeProfile else { return }
        KeychainStore.delete(profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        activeProfile = profiles.first
        categories = []
        streams = []
        currentPrograms = [:]
        persistProfiles()
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(activeProfile?.id.uuidString, forKey: activeKey)
    }
}
