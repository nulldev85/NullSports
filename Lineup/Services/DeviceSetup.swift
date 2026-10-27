import CryptoKit
import Foundation

/// Setting up an Apple TV from the phone. The TV shows a code, the phone
/// reads it and sends the TV its sources, sign-ins and settings over the
/// local network (`DeviceSetupSender`, `DeviceSetupReceiver`).
///
/// The code carries a secret that never crosses the network. What the phone
/// sends is sealed with a key made from it, so nothing else on the network
/// can read the passwords inside, and the TV takes nothing that wasn't sealed
/// with the code it is showing.
enum DeviceSetup {
    static let providersKey = "NullSports.profiles"
    static let serversKey = "NullSports.mediaServers"

    /// Sent beside what iCloud carries: Seerr's connection, the Library's
    /// MDBList and IPTV shelves, and the subtitle languages.
    static let extraKeys = [
        SeerrStore.key, "Lineup.mdbListShelves.v1", "Lineup.providerShelves.v1",
        "Lineup.subtitles.language.v1", "Lineup.subtitle.preferredLanguage.v1"
    ]

    /// Whether a setting is one the phone sends as it is. Nothing else is read
    /// or written this way: not the device's own id or its caches. Watch
    /// history goes with the Library's choices, to be merged rather than
    /// written over the TV's.
    static func carries(_ key: String) -> Bool {
        CloudSettingsSync.syncedKeys.contains(key) || extraKeys.contains(key)
            || CloudSettingsSync.syncedPrefixes.contains(where: key.hasPrefix)
    }

    /// Where the sign-ins are kept. The apps use the Keychain; tests keep them
    /// in memory.
    struct Secrets: Sendable {
        var providerPassword: @Sendable (UUID) -> String?
        var saveProviderPassword: @Sendable (String, UUID) throws -> Void
        var mediaToken: @Sendable (UUID) -> String?
        var saveMediaToken: @Sendable (String, UUID) throws -> Void

        static let keychain = Secrets(
            providerPassword: { KeychainStore.password(profileID: $0) },
            saveProviderPassword: { try KeychainStore.save(password: $0, profileID: $1) },
            mediaToken: { MediaKeychainStore.token(profileID: $0) },
            saveMediaToken: { try MediaKeychainStore.save(token: $0, profileID: $1) })
    }

    /// How many providers and servers a setup brought.
    struct Applied: Equatable, Sendable {
        var providers: Int
        var servers: Int
    }

    /// Everything here another device should have.
    static func capture(defaults: UserDefaults = .standard, secrets: Secrets = .keychain,
                        library: DeviceSetupPayload.LibraryChoices) -> DeviceSetupPayload {
        var values: [String: Data] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where carries(key) {
            if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
                values[key] = data
            }
        }
        var passwords: [String: String] = [:]
        for id in profileIDs(in: defaults.data(forKey: providersKey)) {
            if let password = secrets.providerPassword(id) { passwords[id.uuidString] = password }
        }
        var tokens: [String: String] = [:]
        for id in profileIDs(in: defaults.data(forKey: serversKey)) + [SeerrStore.credentialID] {
            if let token = secrets.mediaToken(id) { tokens[id.uuidString] = token }
        }
        return DeviceSetupPayload(values: values, providerPasswords: passwords, mediaTokens: tokens, library: library)
    }

    /// Writes what the phone sent. A provider or server the TV already has
    /// under the same id takes the phone's; one only the TV has stays, with its
    /// sign-in. Sign-ins are written first, so a Keychain that refuses one
    /// leaves the TV as it was rather than holding sources it can't open.
    @discardableResult
    static func apply(_ payload: DeviceSetupPayload, defaults: UserDefaults = .standard,
                      secrets: Secrets = .keychain) throws -> Applied {
        guard payload.version == DeviceSetupPayload.currentVersion else { throw DeviceSetupError.otherVersion }
        var settings: [String: Any] = [:]
        for (key, data) in payload.values where carries(key) {
            guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { continue }
            if key == providersKey || key == serversKey, let incoming = value as? Data {
                settings[key] = merged(incoming, over: defaults.data(forKey: key))
            } else {
                settings[key] = value
            }
        }
        let providers = profileIDs(in: settings[providersKey] as? Data ?? defaults.data(forKey: providersKey))
        let servers = profileIDs(in: settings[serversKey] as? Data ?? defaults.data(forKey: serversKey))
        do {
            for (key, password) in payload.providerPasswords {
                guard let id = UUID(uuidString: key), providers.contains(id) else { continue }
                try secrets.saveProviderPassword(password, id)
            }
            for (key, token) in payload.mediaTokens {
                guard let id = UUID(uuidString: key), servers.contains(id) || id == SeerrStore.credentialID else { continue }
                try secrets.saveMediaToken(token, id)
            }
        } catch {
            throw DeviceSetupError.keychain
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        return Applied(providers: payload.count(of: providersKey), servers: payload.count(of: serversKey))
    }

    /// The phone's list first, in its order, then whatever only the TV has.
    static func merged(_ incoming: Data, over existing: Data?) -> Data {
        guard let phone = try? JSONSerialization.jsonObject(with: incoming) as? [[String: Any]] else { return incoming }
        let ids = Set(phone.compactMap { $0["id"] as? String })
        let saved = existing.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let own = ((saved as? [[String: Any]]) ?? []).filter { entry in
            (entry["id"] as? String).map { !ids.contains($0) } ?? false
        }
        return (try? JSONSerialization.data(withJSONObject: phone + own)) ?? incoming
    }

    static func profileIDs(in data: Data?) -> [UUID] {
        guard let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
    }
}

/// What the phone sends.
struct DeviceSetupPayload: Codable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    /// Settings as property lists, under the keys the app keeps them by.
    var values: [String: Data]
    /// Each IPTV provider's password, by its id.
    var providerPasswords: [String: String]
    /// Each media server's sign-in, and Seerr's, by id.
    var mediaTokens: [String: String]
    var library: LibraryChoices

    /// What the Library holds as it runs. The TV makes each choice the way its
    /// own settings make it, so connecting MDBList checks the key and starts
    /// tracking, as it does by hand.
    struct LibraryChoices: Codable, Sendable, Equatable {
        var mdbListAPIKey: String?
        var localTracking = true
        var mdbListTracking = false
        var metadataSource: String?
        var episodeDataSource: String?
        var introDB = true
        var skipRecaps = true
        var creditsPrompt = true
        var postCreditsNotice = true
        var fanart = true
        var betterPosters = false
        var betterPostersTemplate: String?
        /// The person's own collections, as the Library writes them.
        var collections: Data?
        /// Watch history kept on the phone, its favorites, and the titles it
        /// took out of Continue Watching, as the Library writes them.
        var playback: Data?
        var favorites: Data?
        var hiddenFromContinueWatching: Data?
    }

    /// How many entries a list in it has.
    func count(of key: String) -> Int {
        guard let data = values[key],
              let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? Data
        else { return 0 }
        return DeviceSetup.profileIDs(in: list).count
    }
}

extension DeviceSetupPayload.LibraryChoices {
    @MainActor init(_ media: MediaLibrary) {
        mdbListAPIKey = media.isMDBListConnected ? MDBListKeychainStore.apiKey() : nil
        localTracking = media.localTrackingEnabled
        mdbListTracking = media.mdbListTrackingEnabled
        metadataSource = media.metadataSource.rawValue
        episodeDataSource = media.episodeDataSource.rawValue
        introDB = media.introDBEnabled
        skipRecaps = media.recapSkippingEnabled
        creditsPrompt = media.creditsPromptEnabled
        postCreditsNotice = media.postCreditsNoticeEnabled
        fanart = media.fanartEnabled
        betterPosters = media.betterPostersEnabled
        betterPostersTemplate = media.betterPostersTemplate
        collections = media.personalCollections.isEmpty ? nil : try? JSONEncoder().encode(media.personalCollections)
        // Local history only: MDBList's own history reaches the TV from
        // MDBList once the key is there.
        if media.localTrackingEnabled, !media.localPlayback.isEmpty {
            playback = try? JSONEncoder().encode(media.localPlayback.map(\.kept))
        }
        if !media.localFavorites.isEmpty {
            favorites = try? JSONEncoder().encode(media.localFavorites.map { favorite in
                var kept = favorite
                kept.item = favorite.item.historyCopy
                return kept
            })
        }
        if !media.hiddenFromContinueWatching.isEmpty {
            hiddenFromContinueWatching = try? JSONEncoder().encode(media.hiddenFromContinueWatching)
        }
    }
}

extension MediaLibrary {
    /// Takes the Library's part of a setup sent from the phone, after its
    /// settings are written: the servers and shelves as iCloud's do, then
    /// each choice through the path the Library's own settings use.
    func adoptSetup(_ choices: DeviceSetupPayload.LibraryChoices) async {
        await restoreCloudSettings()
        seerr.restore()
        if let source = choices.metadataSource.flatMap(LibraryMetadataSource.init(rawValue:)) {
            setMetadataSource(source)
        }
        if let source = choices.episodeDataSource.flatMap(LibraryMetadataSource.init(rawValue:)) {
            setMetadataSource(source, episodes: true)
        }
        introDBEnabled = choices.introDB
        recapSkippingEnabled = choices.skipRecaps
        creditsPromptEnabled = choices.creditsPrompt
        postCreditsNoticeEnabled = choices.postCreditsNotice
        fanartEnabled = choices.fanart
        betterPostersEnabled = choices.betterPosters
        if let template = choices.betterPostersTemplate, MobileBetterPosters.validTemplate(template) {
            betterPostersTemplate = template
        }
        // The TV's own collections stay; the phone's are added beside them.
        if let data = choices.collections,
           let theirs = try? JSONDecoder().decode([MobileLibraryCollection].self, from: data) {
            let mine = Set(personalCollections.map(\.id))
            let arriving = theirs.filter { !mine.contains($0.id) }
            if !arriving.isEmpty { personalCollections += arriving }
        }
        setLocalTrackingEnabled(choices.localTracking)
        let decoder = JSONDecoder()
        adoptPlaybackHistory(
            choices.playback.flatMap { try? decoder.decode([LocalMediaPlayback].self, from: $0) } ?? [],
            favorites: choices.favorites.flatMap { try? decoder.decode([LocalMediaFavorite].self, from: $0) } ?? [],
            dismissals: choices.hiddenFromContinueWatching.flatMap {
                try? decoder.decode([LocalContinueWatchingDismissal].self, from: $0)
            } ?? [])
        if let key = choices.mdbListAPIKey, !isMDBListConnected || MDBListKeychainStore.apiKey() != key {
            _ = await connectMDBList(apiKey: key)
        }
        setMDBListTrackingEnabled(choices.mdbListTracking && isMDBListConnected)
    }
}

/// The TV's code: which TV, and the secret only its screen shows.
struct DeviceSetupPairing: Identifiable, Equatable, Sendable {
    static let serviceType = "_lineup-setup._tcp"

    /// The name the TV advertises while its code is showing.
    let service: String
    /// 32 random bytes, a fresh set each time the code is shown.
    let secret: Data
    var id: String { service }

    init(service: String, secret: Data) {
        self.service = service
        self.secret = secret
    }

    static func make() -> DeviceSetupPairing {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let tag = String(format: "%04X", Int.random(in: 0...0xFFFF))
        return DeviceSetupPairing(service: "Lineup Apple TV \(tag)", secret: secret)
    }

    /// The code's text: lineup://setup?v=1&s=<name>&k=<secret>. The Camera
    /// app opens it in Lineup.
    var url: URL {
        var parts = URLComponents()
        parts.scheme = "lineup"
        parts.host = "setup"
        parts.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "s", value: service),
                            URLQueryItem(name: "k", value: secret.base64URL)]
        // A fixed scheme and host with query items always make a URL.
        return parts.url!
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "lineup", parts.host?.lowercased() == "setup" else { return nil }
        var items: [String: String] = [:]
        for item in parts.queryItems ?? [] where items[item.name] == nil { items[item.name] = item.value }
        guard items["v"] == "1", let service = items["s"], !service.isEmpty, service.utf8.count <= 63,
              let key = items["k"], let secret = Data(base64URL: key), secret.count == 32 else { return nil }
        self.init(service: service, secret: secret)
    }

    /// Which way a message goes. Each direction seals under its own label, so
    /// a phone's message can't be played back to it as the TV's answer.
    enum Direction: String, Sendable {
        case toTV = "Lineup setup v1: phone to TV"
        case reply = "Lineup setup v1: TV to phone"
    }

    func seal(_ data: Data, _ direction: Direction) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(direction.rawValue.utf8)).combined
        else { throw DeviceSetupError.unreadable }
        return combined
    }

    func open(_ data: Data, _ direction: Direction) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key,
                                    authenticating: Data(direction.rawValue.utf8))
        } catch {
            throw DeviceSetupError.wrongCode
        }
    }

    private var key: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               salt: Data("Lineup device setup".utf8),
                               info: Data(service.utf8), outputByteCount: 32)
    }
}

/// The TV's answer.
struct DeviceSetupReply: Codable, Sendable {
    var ok: Bool
    var message: String?
}

enum DeviceSetupError: LocalizedError, Equatable {
    case wrongCode
    case unreadable
    case otherVersion
    case keychain
    case timedOut
    case unreachable
    case localNetworkDenied
    case closed
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .wrongCode, .closed:
            return "The Apple TV didn’t take it. A code only works while it’s on the TV’s screen, so scan the one showing now."
        case .unreadable:
            return "Something went wrong packing up your setup. Try again."
        case .otherVersion:
            return "This iPhone and the Apple TV have different versions of Lineup. Update both, then try again."
        case .keychain:
            return "The Apple TV couldn’t save your sign-ins, so nothing was changed. Try again."
        case .timedOut, .unreachable:
            return "Lineup couldn’t reach the Apple TV. Make sure both are on the same Wi-Fi, then try again."
        case .localNetworkDenied:
            return "Lineup isn’t allowed to use your local network. Turn it on in Settings › Privacy & Security › Local Network, then try again."
        case .refused(let message):
            return message.isEmpty ? "The Apple TV couldn’t take your setup. Try again." : message
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
