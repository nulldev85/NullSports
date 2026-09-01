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
    var professionalStreams: [XtreamStream] {
        let categoryNames = categories.reduce(into: [String: String]()) { $0[$1.id] = $1.categoryName }
        streams.filter { stream in
            let category = categoryNames[stream.categoryID ?? ""] ?? ""
            guard !isExcluded(stream, categoryName: category) else { return false }
            let program = program(for: stream).map { "\($0.title) \($0.detail)" } ?? ""
            let searchable = "\(stream.name) \(category) \(program)"
            return SportsLeague.allCases.contains { $0.matches(searchable) }
        }
    }

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
        let categoryNames = categories.reduce(into: [String: String]()) { $0[$1.id] = $1.categoryName }
        return professionalStreams.filter { stream in
            league.matches(stream.name) || league.matches(categoryNames[stream.categoryID ?? ""] ?? "")
        }
    }

    func liveStreams(for league: SportsLeague) -> [XtreamStream] {
        professionalStreams.filter { stream in
            guard let channelID = stream.epgChannelID,
                  let program = currentPrograms[channelID]
            else { return false }
            let listing = "\(program.title) \(program.detail)"
            let looksLikeGame = listing.localizedCaseInsensitiveContains(" vs ")
                || listing.localizedCaseInsensitiveContains(" vs. ")
                || listing.localizedCaseInsensitiveContains(" at ")
            return league.matchesProfessionalGame(listing) && looksLikeGame
        }
    }

    func program(for stream: XtreamStream) -> CurrentProgram? {
        stream.epgChannelID.flatMap { currentPrograms[$0] }
    }

    func playbackURLs(for stream: XtreamStream) -> [URL] {
        guard let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return [] }
        return XtreamClient(profile: profile, password: password).playbackURLs(for: stream)
    }

    private func isExcluded(_ stream: XtreamStream, categoryName: String) -> Bool {
        let value = "\(stream.name) \(categoryName)".lowercased()
        let blocked = ["nfhs", "high school", "ncaa", "ncaaf", "ncaab", "college", "university", "wnba", "acc network", "sec network", "big ten network", "big 12", "pac-12"]
        return blocked.contains { value.contains($0) }
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
