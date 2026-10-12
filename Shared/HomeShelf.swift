import Foundation
import Security

// What Lineup puts in front of a viewer before Lineup is open: the Apple TV
// Top Shelf and the iPhone's Home Screen widget.
//
// Neither extension can reach the app's stores. They run in their own
// processes, briefly, with a few megabytes to spare, and the stores they would
// need hold a provider's whole channel list and a day of guide. So the app
// writes a small, finished account of what is worth showing -- the followed
// teams' next games and what is part-watched -- into the App Group container
// they share, and the extensions only ever read that. An install signed with a
// shared certificate has no App Group to share; the shelf goes into the team's
// keychain instead (see `LineupSharedKeychain`).
//
// Foundation and Security only. This file is compiled into both apps and both extensions,
// and an extension that reached for anything else would drag the app in with
// it.

/// The App Group the apps share with their extensions.
///
/// One identifier for both platforms: the Top Shelf and the widget each sit
/// beside a different app, but neither ever reads the other's container, so
/// there is nothing to keep apart.
///
/// A sideloaded install is signed again on the way onto the device, and the
/// tool that signs it can give the group a name of its own -- AltStore adds
/// the signer's team to the end and notes the new name in the Info.plist.
/// The group that counts is the one this install can open, so it is looked
/// for where a signer leaves it: the provisioning profile inside the bundle,
/// then AltStore's note, then the name the project gives it. The app and its
/// extension are signed together and find the same one.
enum LineupAppGroup {
    /// The name the project gives the group.
    static let declared = "group.com.nulldev85.NullSports"

    /// The group this install can open, or the declared one if it can open
    /// none, so a build without the group still has a name to fail on.
    static let identifier: String = {
        let fileManager = FileManager.default
        return candidates(provisioned: provisionedGroups(), noted: notedGroups())
            .first { fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil } ?? declared
    }()

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Every group worth trying, in order: the profile's, then the note's,
    /// then the declared name; within that, one named for Lineup ahead of
    /// any other the signer granted.
    static func candidates(provisioned: [String], noted: [String]) -> [String] {
        var seen = Set<String>()
        let all = (provisioned + noted + [declared]).filter { !$0.isEmpty && seen.insert($0).inserted }
        return all.filter { $0.hasPrefix(declared) } + all.filter { !$0.hasPrefix(declared) }
    }

    /// The groups granted by the profile a provisioning file carries.
    static func groups(inProvisioningProfile data: Data) -> [String] {
        entitlements(inProvisioningProfile: data)["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// What the profile a provisioning file carries grants: a signed
    /// envelope with the profile inside it as a plain property list.
    static func entitlements(inProvisioningProfile data: Data) -> [String: Any] {
        guard let start = data.range(of: Data("<?xml".utf8)) ?? data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { return [:] }
        return profile["Entitlements"] as? [String: Any] ?? [:]
    }

    /// The keychain groups the profile a provisioning file carries grants.
    static func keychainGroups(inProvisioningProfile data: Data) -> [String] {
        entitlements(inProvisioningProfile: data)["keychain-access-groups"] as? [String] ?? []
    }

    /// This install's own profile, or nothing for a build that carries none.
    private static let profile: Data? = Bundle.main
        .url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }

    /// The keychain groups this install's profile grants.
    static let provisionedKeychainGroups: [String] = profile.map(keychainGroups(inProvisioningProfile:)) ?? []

    private static func provisionedGroups() -> [String] {
        profile.map(groups(inProvisioningProfile:)) ?? []
    }

    private static func notedGroups() -> [String] {
        Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    }
}

// MARK: - Links

/// Somewhere in Lineup a link from outside it can ask for.
///
/// A Top Shelf item and a widget row can only hand the system a URL, so every
/// destination has one. The ids inside are whatever the app uses for them, and
/// several of those carry characters a URL path cannot hold as they are -- a
/// provider's item id has colons in it, and nothing promises a game id never
/// will -- so each is percent-encoded against a deliberately short list of
/// characters and decoded again on the way back in.
enum LineupLink: Hashable, Sendable {
    case game(id: String)
    case channel(id: Int)
    case media(profileID: UUID, itemID: String)

    static let scheme = "lineup"

    var url: URL {
        let text: String
        switch self {
        case .game(let id):
            text = "game/" + Self.encoded(id)
        case .channel(let id):
            text = "channel/" + String(id)
        case .media(let profileID, let itemID):
            text = "media/" + profileID.uuidString + "/" + Self.encoded(itemID)
        }
        // Every character left after encoding is unreserved ASCII, so this
        // cannot fail; the fallback is only there so a URL is always returned.
        return URL(string: Self.scheme + "://" + text) ?? Self.root
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        // Split before decoding, so an id that contained a slash -- encoded as
        // %2F on the way out -- stays one segment rather than becoming two.
        let segments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? "" }
        switch host {
        case "game":
            guard segments.count == 1, let id = segments.first, !id.isEmpty else { return nil }
            self = .game(id: id)
        case "channel":
            guard segments.count == 1, let id = segments.first.flatMap({ Int($0) }) else { return nil }
            self = .channel(id: id)
        case "media":
            guard segments.count == 2, let profileID = UUID(uuidString: segments[0]),
                  !segments[1].isEmpty else { return nil }
            self = .media(profileID: profileID, itemID: segments[1])
        default:
            return nil
        }
    }

    private static let root = URL(string: "lineup://")!

    /// Letters, digits and the four marks RFC 3986 leaves unreserved. Built by
    /// hand because `CharacterSet.alphanumerics` admits every script's letters,
    /// and a URL with an unencoded "é" in it is a URL `URL(string:)` may refuse.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

// MARK: - The shelf

/// Everything the Top Shelf and the widget draw, as of `savedAt`.
struct HomeShelfSnapshot: Codable, Sendable {
    var savedAt: Date
    /// The followed teams' games that are on or start within two days, live
    /// first and then by start time.
    var games: [HomeShelfGame]
    /// Part-watched films and episodes, most recently watched first.
    var continueWatching: [HomeShelfMedia]
    /// Whether the viewer follows any team at all, so an empty list can say
    /// the right thing: "follow a team" is no help to someone following five
    /// whose teams simply do not play this week. Optional so a file written
    /// without it still reads.
    var followsTeams: Bool? = nil
}

struct HomeShelfGame: Codable, Identifiable, Hashable, Sendable {
    let id: String
    /// The league's short name, "NFL".
    let league: String
    let awayName: String
    let homeName: String
    let awayAbbreviation: String
    let homeAbbreviation: String
    let awayLogo: String?
    let homeLogo: String?
    let awayScore: String?
    let homeScore: String?
    let awayRank: Int?
    let homeRank: Int?
    let start: Date
    /// Whether the game was on when the app wrote the shelf.
    let isLive: Bool
    /// The feed's clock line while the game is on, "Q3 4:12"; empty otherwise.
    let status: String
    /// The Lineup channel the game was matched to, when one was.
    let channelName: String?
    let isEvent: Bool
    let eventName: String?

    var link: LineupLink { .game(id: id) }

    /// When the game is assumed to be over if nothing has said so.
    ///
    /// The extensions cannot ask: they see the shelf as the app last wrote it,
    /// which may be hours old. Four hours covers a game with overtime in any
    /// of the leagues followed here; an event -- a fight card, RedZone -- runs
    /// most of an afternoon or evening.
    var assumedEnd: Date {
        start.addingTimeInterval(isEvent ? 9 * 60 * 60 : 4 * 60 * 60)
    }

    /// Whether the game is still worth showing at `date`: not yet started, or
    /// started recently enough that it may still be going.
    func isCurrent(at date: Date) -> Bool { date < assumedEnd }

    /// Whether the game should read as live at `date`. The start time settles
    /// it when the shelf was written before the game began, which is what
    /// turns a widget's "7:05 PM" into "Live" without the app being opened.
    func showsAsLive(at date: Date) -> Bool {
        (isLive || start <= date) && date < assumedEnd
    }

    /// The start time in as few words as carry it: "7:05 PM" today, "Tomorrow
    /// 7:05 PM", otherwise the weekday. `now` is a parameter because a widget
    /// draws for a moment of its own choosing, not for the moment it is built.
    func startLabel(relativeTo now: Date, calendar: Calendar = .current) -> String {
        let time = start.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(start, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(start, inSameDayAs: tomorrow) {
            return "Tomorrow " + time
        }
        return start.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }

    /// "BOS @ NYY" ahead of the game, "BOS 3 – NYY 5" once it has a score. An
    /// event is given its own name instead, since the two "teams" the feed
    /// lists for it are only the first bout on the card.
    func matchupLine(at date: Date) -> String {
        if isEvent, let name = eventName { return name }
        if showsAsLive(at: date), let away = awayScore, let home = homeScore {
            return "\(awayAbbreviation) \(away) \u{2013} \(homeAbbreviation) \(home)"
        }
        return "\(awayAbbreviation) @ \(homeAbbreviation)"
    }

    /// The games worth showing at `date`, live first and then by start time.
    static func current(_ games: [HomeShelfGame], at date: Date) -> [HomeShelfGame] {
        games.filter { $0.isCurrent(at: date) }.sorted { left, right in
            let leftLive = left.showsAsLive(at: date)
            let rightLive = right.showsAsLive(at: date)
            if leftLive != rightLive { return leftLive }
            if left.start != right.start { return left.start < right.start }
            return left.id < right.id
        }
    }
}

struct HomeShelfMedia: Codable, Identifiable, Hashable, Sendable {
    /// The server's profile id and the item id, joined with "|".
    let id: String
    let profileID: UUID
    let itemID: String
    /// The film, or the show an episode belongs to.
    let title: String
    /// "S2 · E5 · Episode name" for an episode, the year for a film.
    let subtitle: String?
    /// Landscape art where the title has any, for a 16:9 tile.
    let imageURL: String?
    let posterURL: String?
    /// How far through, 0 to 1.
    let progress: Double

    var link: LineupLink { .media(profileID: profileID, itemID: itemID) }
}

// MARK: - The file

/// The shelf on disk, in the App Group container.
///
/// A build signed without the App Group has no container to share, and
/// `containerURL` answers nil for it. That is an ordinary state here rather
/// than an error: reading gives nil, writing does nothing, and the Top Shelf
/// and widget fall back to what they show when there is nothing to say.
enum HomeShelfStore {
    static let fileName = "home-shelf.json"

    /// Nil when this install can open no App Group.
    static var fileURL: URL? {
        LineupAppGroup.containerURL?.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Whether this install has anywhere its extensions can read: the App
    /// Group, or failing that the team's keychain.
    static var isShared: Bool {
        fileURL != nil || LineupSharedKeychain.accessGroup != nil
    }

    /// What an extension finds.
    enum Reading {
        case shelf(HomeShelfSnapshot)
        /// Somewhere to read from, and nothing there yet: the app has not
        /// been opened since it was installed.
        case nothingYet
        /// Nowhere the app and its extensions can both reach.
        case unreachable

        var shelf: HomeShelfSnapshot? {
            if case .shelf(let shelf) = self { return shelf }
            return nil
        }
    }

    static func reading() -> Reading {
        let data: Data?
        if let url = fileURL {
            data = try? Data(contentsOf: url)
        } else if LineupSharedKeychain.accessGroup != nil {
            do {
                data = try LineupSharedKeychain.read()
            } catch {
                return .unreachable
            }
        } else {
            return .unreachable
        }
        guard let data, let shelf = try? JSONDecoder().decode(HomeShelfSnapshot.self, from: data) else {
            return .nothingYet
        }
        return .shelf(shelf)
    }

    static func read() -> HomeShelfSnapshot? {
        reading().shelf
    }

    static func write(_ snapshot: HomeShelfSnapshot) {
        guard let data = try? encoded(snapshot) else { return }
        if let url = fileURL {
            // Atomic, so an extension reading at the same moment sees the old
            // shelf or the new one and never half of each.
            try? data.write(to: url, options: .atomic)
        } else {
            LineupSharedKeychain.write(data)
        }
    }

    /// The bytes `write` puts on disk. Keys are sorted so the same shelf
    /// always encodes the same way, which is what lets the app compare two
    /// shelves by their bytes and skip a write that would change nothing.
    static func encoded(_ snapshot: HomeShelfSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}

// MARK: - Without an App Group

/// Where the shelf is kept when the install has no App Group: one keychain
/// item, in an access group of the signing team's.
///
/// A shared signing certificate's profile has no App Group in it and cannot
/// be given one. What it does grant is a keychain group written "TEAM.*",
/// which a signer copies into the app and its extension as it is. The
/// keychain reads that as the name of one group, not a pattern, so the app
/// and its extension -- every app signed with that certificate, in fact --
/// share it, and the shelf's own service name keeps it apart from theirs.
/// The keychain is no place for a large file, but the shelf is a few
/// kilobytes.
enum LineupSharedKeychain {
    static let service = "com.nulldev85.NullSports.home-shelf"
    static let account = "shelf"

    /// The group the shelf is kept in, when the profile grants the team's
    /// shared one; nil when it grants less, or there is no profile.
    static let accessGroup: String? = sharedGroup(granted: LineupAppGroup.provisionedKeychainGroups)

    /// "TEAM.*" itself, for a profile that grants it.
    static func sharedGroup(granted: [String]) -> String? {
        granted.first { $0.hasSuffix(".*") && $0.count > 2 }
    }

    struct Unreachable: Error {
        let status: OSStatus
    }

    private static func query(group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: group]
    }

    /// The shelf, nil when none has been written, and throws when the
    /// keychain group cannot be opened -- a signer that narrowed the team's
    /// keychain to the app's own entry.
    static func read() throws -> Data? {
        guard let group = accessGroup else { throw Unreachable(status: errSecMissingEntitlement) }
        var request = query(group: group)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Unreachable(status: status)
        }
    }

    @discardableResult
    static func write(_ data: Data) -> Bool {
        guard let group = accessGroup else { return false }
        let base = query(group: group)
        // Readable once the device has been unlocked after starting up, so
        // a widget refreshing while the phone sits locked still can.
        let contents: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(base as CFDictionary, contents as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(contents) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
