import Foundation
import Observation

/// A badge drawn under a stream in the stream list: a picture, or a word in
/// a chip, for each stream whose description matches its pattern.
///
/// Badges come in packs at an address the viewer adds, written the way
/// AIOStreams' own app writes them, or the way Fusion and Nuvio do, so the
/// packs people already share work here unchanged.
struct StreamBadge: Codable, Hashable, Sendable {
    var label: String
    /// A regular expression, matched without regard to case.
    var match: String
    /// Shown in place of the label.
    var image: String?
    var color: String?
    var background: String?
    var border: String?
    /// Badges sharing a group are alternatives: only the first match shows.
    var group: String?
    /// Only these parts of a stream are matched; otherwise all of it.
    var fields: [String]?

    var imageURL: URL? { image.flatMap(URL.init(string:)) }
}

// MARK: - Reading a pack

enum StreamBadgeReader {
    /// Every badge in a pack, or nil when it holds none this app can read.
    static func read(_ data: Data) -> [StreamBadge]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return read(json)
    }

    static func read(_ value: Any) -> [StreamBadge]? {
        if let list = value as? [Any] {
            let found = list.flatMap { read($0) ?? [] }
            return found.isEmpty ? nil : found
        }
        guard let object = value as? [String: Any] else { return nil }
        if let badges = object["badges"] as? [Any] { return badges.compactMap(own) }
        if let filters = object["filters"] as? [Any] { return filters.compactMap(fusion) }
        let rules = (object["settings"] as? [String: Any])?["streamBadgeRules"] ?? object["streamBadgeRules"]
        let imports = (rules as? [String: Any])?["imports"] ?? object["imports"]
        if let imports = imports as? [Any] {
            let entries = imports.compactMap { $0 as? [String: Any] }
            let active = entries.first { ($0["isActive"] as? Bool) != false } ?? entries.first
            guard let filters = active?["filters"] as? [Any] else { return nil }
            return filters.compactMap(fusion)
        }
        if let one = own(object) ?? fusion(object) { return [one] }
        return nil
    }

    /// AIOStreams' own way of writing a badge.
    static func own(_ value: Any) -> StreamBadge? {
        guard let object = value as? [String: Any],
              let label = text(object["label"]), let match = text(object["match"]) else { return nil }
        let named = (object["fields"] as? [Any])?.compactMap { $0 as? String } ?? []
        let fields = named.filter { MediaPlaybackSource.AIOStreamsInfo.fieldNames.contains($0) || $0 == "seadex" }
        // A badge naming only parts this app lacks would otherwise match everything.
        if !named.isEmpty, fields.isEmpty { return nil }
        return StreamBadge(label: label, match: match, image: link(object["image"]),
                           color: color(object["color"]), background: color(object["background"]),
                           border: color(object["border"]), group: text(object["group"]),
                           fields: fields.isEmpty ? nil : fields)
    }

    /// One of Fusion's filters, which Nuvio reads too.
    static func fusion(_ value: Any) -> StreamBadge? {
        guard let object = value as? [String: Any], (object["isEnabled"] as? Bool) != false,
              let label = text(object["name"]), let match = text(object["pattern"]) else { return nil }
        let filled = text(object["tagStyle"])?.lowercased().hasPrefix("filled") == true
        return StreamBadge(label: label, match: match, image: link(object["imageURL"]),
                           color: fusionColor(object["textColor"]),
                           background: filled ? fusionColor(object["tagColor"]) : nil,
                           border: fusionColor(object["borderColor"]))
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func link(_ value: Any?) -> String? {
        guard let value = text(value), let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return value
    }

    private static func color(_ value: Any?) -> String? {
        guard let value = text(value), StreamBadgeColor(value) != nil else { return nil }
        return value
    }

    /// Fusion writes eight-digit colours with the alpha first.
    private static func fusionColor(_ value: Any?) -> String? {
        guard let value = text(value) else { return nil }
        let digits = value.dropFirst()
        if value.hasPrefix("#"), digits.count == 8, digits.allSatisfy(\.isHexDigit) {
            return "#" + String(digits.dropFirst(2)) + String(digits.prefix(2))
        }
        return color(value)
    }
}

/// A colour as a pack writes it: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`,
/// `rgb(...)`, `rgba(...)` or `transparent`.
struct StreamBadgeColor: Equatable, Sendable {
    let red: Double, green: Double, blue: Double, alpha: Double

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "transparent" {
            red = 0; green = 0; blue = 0; alpha = 0
            return
        }
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
            if digits.count <= 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            if digits.count == 6 { digits += "ff" }
            guard let number = UInt64(digits, radix: 16) else { return nil }
            red = Double((number >> 24) & 0xff) / 255
            green = Double((number >> 16) & 0xff) / 255
            blue = Double((number >> 8) & 0xff) / 255
            alpha = Double(number & 0xff) / 255
            return
        }
        guard value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let inside = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let parts = inside.split(whereSeparator: { ",/ ".contains($0) }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func channel(_ part: String) -> Double? {
            if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
            return Double(part).map { $0 / 255 }
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
        let a: Double
        if parts.count == 4 {
            guard let value = parts[3].hasSuffix("%") ? Double(parts[3].dropLast()).map({ $0 / 100 })
                                                      : Double(parts[3]) else { return nil }
            a = value
        } else {
            a = 1
        }
        red = min(max(r, 0), 1)
        green = min(max(g, 0), 1)
        blue = min(max(b, 0), 1)
        alpha = min(max(a, 0), 1)
    }
}

// MARK: - Matching

/// A stream's text as badges read it: each part on its own, and all of it.
struct StreamBadgeText {
    let fields: [String: [String]]
    let lines: [String]
    let all: String

    init(fields: [String: [String]]) {
        self.fields = fields
        let order = MediaPlaybackSource.AIOStreamsInfo.fieldNames + ["seadex"]
        let joined = Self.joined(order.flatMap { fields[$0] ?? [] })
        lines = joined.lines
        all = joined.all
    }

    func only(_ names: [String]) -> (lines: [String], all: String) {
        Self.joined(names.flatMap { fields[$0] ?? [] })
    }

    private static func joined(_ values: [String]) -> (lines: [String], all: String) {
        let lines = values.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (lines, lines.joined(separator: " "))
    }
}

struct StreamBadgeMatcher {
    private struct Compiled {
        let badge: StreamBadge
        let regex: NSRegularExpression
        /// An anchored pattern is tried on each line too, which the joined
        /// text would miss.
        let perLine: Bool
        let keys: [String]
    }

    private let compiled: [Compiled]

    var isEmpty: Bool { compiled.isEmpty }

    /// A pattern that will not compile is left out.
    init(_ badges: [StreamBadge]) {
        compiled = badges.compactMap { badge in
            guard let regex = try? NSRegularExpression(pattern: badge.match, options: [.caseInsensitive]) else { return nil }
            return Compiled(badge: badge, regex: regex, perLine: badge.match.contains("^") || badge.match.contains("$"),
                            keys: [badge.label.lowercased()] + (badge.image.map { [$0] } ?? []))
        }
    }

    /// In list order, skipping a repeated label or picture, and all but the
    /// first of a group.
    func badges(for text: StreamBadgeText) -> [StreamBadge] {
        var seen = Set<String>()
        var groups = Set<String>()
        var shown: [StreamBadge] = []
        for entry in compiled {
            if entry.keys.contains(where: seen.contains) { continue }
            if let group = entry.badge.group, groups.contains(group) { continue }
            let target: (lines: [String], all: String) = entry.badge.fields.map { text.only($0) } ?? (lines: text.lines, all: text.all)
            guard Self.matches(entry.regex, target.all)
                    || (entry.perLine && target.lines.contains { Self.matches(entry.regex, $0) }) else { continue }
            entry.keys.forEach { seen.insert($0) }
            if let group = entry.badge.group { groups.insert(group) }
            shown.append(entry.badge)
        }
        return shown
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

extension MediaPlaybackSource {
    /// What a badge reads: AIOStreams' parsed parts where it sends them,
    /// and every server's name, description and file name.
    var badgeText: StreamBadgeText {
        var fields = aiostreams?.fields ?? [:]
        let named = [aiostreams?.name ?? name].compactMap { $0 }.filter { !$0.isEmpty }
        if !named.isEmpty { fields["name"] = named }
        if fields["description"] == nil, let description = aiostreams?.description ?? remux?.providerInfo?.description,
           !description.isEmpty {
            fields["description"] = [description]
        }
        if fields["filename"] == nil {
            let file = aiostreams?.filename ?? remux?.providerInfo?.filename
                ?? path.flatMap { URL(string: $0)?.lastPathComponent ?? ($0 as NSString).lastPathComponent }
            if let file, !file.isEmpty { fields["filename"] = [file] }
        }
        return StreamBadgeText(fields: fields)
    }
}

// MARK: - The packs

/// The badge packs the viewer has added, each kept from its last download
/// so the stream list has them at once and without a connection.
@MainActor
@Observable
final class StreamBadgeStore {
    static let shared = StreamBadgeStore()

    struct Pack: Codable, Hashable {
        var badges: [StreamBadge]
        var fetched: Date
    }

    private(set) var links: [String]
    private(set) var packs: [String: Pack]
    /// Why a pack could not be read, by its address.
    private(set) var failures: [String: String] = [:]
    private(set) var matcher = StreamBadgeMatcher([])

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var memo: [String: [StreamBadge]] = [:]
    @ObservationIgnored private var refreshing = false

    static let linksKey = "Lineup.streams.badgeLinks.v1"
    static let packsKey = "Lineup.streams.badgePacks.v1"
    /// How long a downloaded pack is used before it is asked for again.
    static let freshFor: TimeInterval = 6 * 60 * 60

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        links = defaults.stringArray(forKey: Self.linksKey) ?? []
        packs = defaults.data(forKey: Self.packsKey)
            .flatMap { try? JSONDecoder().decode([String: Pack].self, from: $0) } ?? [:]
        rebuild()
    }

    /// The badges for one stream, worked out once per stream.
    func badges(for source: MediaPlaybackSource) -> [StreamBadge] {
        guard !matcher.isEmpty else { return [] }
        if let known = memo[source.id] { return known }
        let found = matcher.badges(for: source.badgeText)
        memo[source.id] = found
        return found
    }

    /// Adds a pack's address and downloads it. Returns why it could not be
    /// added, or nil.
    @discardableResult
    func add(_ text: String) async -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            return "That isn't a web address."
        }
        guard !links.contains(value) else { return "That pack is already added." }
        switch await download(url) {
        case .failure(let message):
            return message
        case .success(let badges):
            links.append(value)
            packs[value] = Pack(badges: badges, fetched: Date())
            failures[value] = nil
            save()
            return nil
        }
    }

    func remove(_ link: String) {
        links.removeAll { $0 == link }
        packs[link] = nil
        failures[link] = nil
        save()
    }

    /// Downloads again every pack older than `freshFor`, or all of them.
    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var changed = false
        for link in links {
            if !force, let pack = packs[link], Date().timeIntervalSince(pack.fetched) < Self.freshFor { continue }
            guard let url = URL(string: link) else { continue }
            switch await download(url) {
            case .success(let badges):
                if packs[link]?.badges != badges { changed = true }
                packs[link] = Pack(badges: badges, fetched: Date())
                failures[link] = nil
            case .failure(let message):
                // The copy from last time stays in use.
                failures[link] = message
            }
        }
        if changed || force { save() }
    }

    private enum Download { case success([StreamBadge]), failure(String) }

    private func download(_ url: URL) async -> Download {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else {
            return .failure("That address didn't answer.")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failure("That address answered \(http.statusCode).")
        }
        guard data.count <= 2_000_000, let badges = StreamBadgeReader.read(data), !badges.isEmpty else {
            return .failure("There are no badges Lineup can read at that address.")
        }
        return .success(badges)
    }

    private func save() {
        defaults.set(links, forKey: Self.linksKey)
        let kept = packs.filter { links.contains($0.key) }
        defaults.set(try? JSONEncoder().encode(kept), forKey: Self.packsKey)
        rebuild()
    }

    private func rebuild() {
        matcher = StreamBadgeMatcher(links.flatMap { packs[$0]?.badges ?? [] })
        memo = [:]
    }

    /// Every badge in use, for the settings screen's count.
    var count: Int { links.reduce(0) { $0 + (packs[$1]?.badges.count ?? 0) } }
}
