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
        /// The TV's own ids for providers and servers the phone has too, each
        /// with the phone's id it goes by from now on.
        var renamed: [String: String] = [:]
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
    /// takes the phone's, whether it has the same id or is the same one added
    /// by hand on each device: then everything the TV kept under its own id,
    /// its favorites, shelves and channel choices, goes by the phone's, and
    /// there is one of it rather than two. One only the TV has stays, with its
    /// sign-in. A list or a table on both, favorites or shelf names, keeps
    /// what only the TV had after the phone's.
    ///
    /// Sign-ins are written first, so a Keychain that refuses one leaves the
    /// TV as it was rather than holding sources it can't open.
    @discardableResult
    static func apply(_ payload: DeviceSetupPayload, defaults: UserDefaults = .standard,
                      secrets: Secrets = .keychain) throws -> Applied {
        guard payload.version == DeviceSetupPayload.currentVersion else { throw DeviceSetupError.otherVersion }
        var renamed = aliases(phone: payload.list(providersKey), tv: defaults.data(forKey: providersKey),
                              identity: providerIdentity)
        renamed.merge(aliases(phone: payload.list(serversKey), tv: defaults.data(forKey: serversKey),
                              identity: serverIdentity)) { first, _ in first }

        // The TV's settings as they read once its copies go by the phone's ids.
        var writes: [String: Any] = [:]
        var stale: Set<String> = []
        if !renamed.isEmpty {
            for (key, value) in defaults.dictionaryRepresentation() where carries(key) {
                guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
                else { continue }
                let rewritten = replacingIDs(in: data, renamed)
                let newKey = replacingIDs(in: key, renamed)
                guard rewritten != data || newKey != key,
                      let object = try? PropertyListSerialization.propertyList(from: rewritten, options: [], format: nil)
                else { continue }
                if newKey != key { stale.insert(key) }
                writes[newKey] = writes[newKey].map { combined(object, over: $0) } ?? object
            }
        }
        func own(_ key: String) -> Any? { writes[key] ?? (stale.contains(key) ? nil : defaults.object(forKey: key)) }

        for (key, data) in payload.values where carries(key) {
            guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { continue }
            let taken: Any
            if key == providersKey || key == serversKey, let incoming = value as? Data {
                taken = merged(incoming, over: own(key) as? Data)
            } else {
                taken = combined(value, over: own(key))
            }
            writes[key] = taken
        }
        let providers = profileIDs(in: own(providersKey) as? Data)
        let servers = profileIDs(in: own(serversKey) as? Data)
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
        for key in stale where writes[key] == nil { defaults.removeObject(forKey: key) }
        for (key, value) in writes { defaults.set(value, forKey: key) }
        return Applied(providers: payload.count(of: providersKey), servers: payload.count(of: serversKey),
                       renamed: renamed)
    }

    /// The phone's list first, in its order, then whatever only the TV has.
    static func merged(_ incoming: Data, over existing: Data?) -> Data {
        guard let phone = try? JSONSerialization.jsonObject(with: incoming) as? [[String: Any]] else { return incoming }
        let ids = Set(phone.compactMap { $0["id"] as? String })
        let own = entries(existing).filter { entry in
            (entry["id"] as? String).map { !ids.contains($0) } ?? false
        }
        return (try? JSONSerialization.data(withJSONObject: phone + own)) ?? incoming
    }

    /// A list or a table from the phone, with whatever only the TV had kept
    /// after it. Anything else is the phone's.
    static func combined(_ incoming: Any, over existing: Any?) -> Any {
        if let phone = incoming as? [Any], let own = existing as? [Any] {
            let extra = own.filter { item in
                !phone.contains { ($0 as? NSObject)?.isEqual(item) ?? false }
            }
            return phone + extra
        }
        if let phone = incoming as? [String: Any], let own = existing as? [String: Any] {
            return own.merging(phone) { _, theirs in theirs }
        }
        return incoming
    }

    /// Each of the TV's providers or servers that the phone has under another
    /// id: added by hand on both, the same one has an id of its own on each.
    static func aliases(phone: Data?, tv: Data?, identity: ([String: Any]) -> String?) -> [String: String] {
        let theirs = entries(phone)
        let theirIDs = Set(theirs.compactMap { $0["id"] as? String })
        var byIdentity: [String: String] = [:]
        for entry in theirs {
            if let key = identity(entry), let id = entry["id"] as? String, byIdentity[key] == nil { byIdentity[key] = id }
        }
        var result: [String: String] = [:]
        for entry in entries(tv) {
            guard let id = entry["id"] as? String, !theirIDs.contains(id),
                  let key = identity(entry), let phoneID = byIdentity[key] else { continue }
            result[id] = phoneID
        }
        return result
    }

    /// The same provider: the same kind of connection, address and account.
    static func providerIdentity(_ entry: [String: Any]) -> String? {
        guard let address = normalizedAddress(entry["serverURL"]) else { return nil }
        let user = ((entry["username"] as? String) ?? "").lowercased()
        return "\((entry["connectionKind"] as? String) ?? "xtream")|\(address)|\(user)"
    }

    /// The same server: the same software and the same account on it. A
    /// Jellyfin or Emby user id belongs to its server, whichever address
    /// reaches it. A Plex account's id is the same on each of its servers, so
    /// the server is told by its plex.direct name, or by its address.
    static func serverIdentity(_ entry: [String: Any]) -> String? {
        let software = (entry["software"] as? String) ?? MediaServerBrand.jellyfin.rawValue
        guard let user = (entry["userID"] as? String)?.lowercased(), !user.isEmpty else { return nil }
        if software == MediaServerBrand.plex.rawValue {
            guard let host = normalizedAddress(entry["serverURL"]).flatMap({ URL(string: $0)?.host }) else { return nil }
            let labels = host.split(separator: ".")
            let server = host.hasSuffix(".plex.direct") && labels.count > 2 ? String(labels[1]) : host
            return "\(software)|\(user)|\(server)"
        }
        return "\(software)|\(user)|\((entry["siloProfileID"] as? String) ?? "")"
    }

    static func normalizedAddress(_ value: Any?) -> String? {
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Every mention of one id swapped for another: in a key, in a setting
    /// written out, in a watch history. An id is 36 characters either way, so
    /// what holds it keeps its shape.
    static func replacingIDs(in data: Data, _ renamed: [String: String]) -> Data {
        var result = data
        for (old, new) in renamed {
            for (from, to) in [(old.uppercased(), new.uppercased()), (old.lowercased(), new.lowercased())] {
                let needle = Data(from.utf8)
                let replacement = Data(to.utf8)
                var start = result.startIndex
                while let found = result.range(of: needle, in: start..<result.endIndex) {
                    result.replaceSubrange(found, with: replacement)
                    start = found.lowerBound + replacement.count
                }
            }
        }
        return result
    }

    static func replacingIDs(in text: String, _ renamed: [String: String]) -> String {
        var result = text
        for (old, new) in renamed {
            result = result.replacingOccurrences(of: old.uppercased(), with: new.uppercased())
                .replacingOccurrences(of: old.lowercased(), with: new.lowercased())
        }
        return result
    }

    static func entries(_ data: Data?) -> [[String: Any]] {
        guard let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
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

    /// A list it carries, as the app keeps it.
    func list(_ key: String) -> Data? {
        guard let data = values[key] else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? Data
    }

    /// How many entries a list in it has.
    func count(of key: String) -> Int {
        DeviceSetup.profileIDs(in: list(key)).count
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
    func adoptSetup(_ choices: DeviceSetupPayload.LibraryChoices, renamed: [String: String] = [:]) async {
        // The TV's copies of the phone's servers go by the phone's ids now:
        // its history, favorites and collections first, before anything
        // reloads, so each title is one record rather than one per copy.
        adoptProfileIDs(renamed)
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
