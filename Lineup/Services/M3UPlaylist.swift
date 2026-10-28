import Foundation
import CryptoKit

struct PlaylistCredentials: Codable, Sendable {
    let playlist: URL
    let guide: URL?

    init(playlist: String, guide: String) throws {
        self.playlist = try Self.webURL(playlist)
        self.guide = guide.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try Self.webURL(guide)
    }

    static func webURL(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else {
            throw PlaylistError.address
        }
        // EPGenius also supplies Google Drive share links. Turn only the
        // known file-share form into a download; preserve unrelated URLs.
        if parts.host?.lowercased() == "drive.google.com", parts.path.hasPrefix("/file/d/") {
            let segments = parts.path.split(separator: "/")
            guard segments.count >= 3 else { throw PlaylistError.address }
            parts.path = "/uc"
            parts.queryItems = [URLQueryItem(name: "export", value: "download"),
                                URLQueryItem(name: "id", value: String(segments[2]))]
        }
        guard let url = parts.url else { throw PlaylistError.address }
        return url
    }

    var encoded: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "" }
    static func read(_ secret: String) throws -> Self {
        guard let result = try? JSONDecoder().decode(Self.self, from: Data(secret.utf8)) else { throw PlaylistError.address }
        return result
    }
}

enum PlaylistError: LocalizedError {
    case address, content, empty, download, guide
    var errorDescription: String? {
        switch self {
        case .address: "Enter an HTTP or HTTPS playlist and guide URL."
        case .content: "This link did not return an M3U playlist. Use a direct download link, with sharing enabled."
        case .empty: "This playlist contains no supported live HTTP streams."
        case .download: "The playlist or guide could not be downloaded. Check its URL and access permissions."
        case .guide: "This link did not return a valid XMLTV guide."
        }
    }
}

struct M3UPlaylist: Codable, Sendable {
    let streams: [XtreamStream]
    let categories: [XtreamCategory]
    let urls: [Int: URL]
    let guide: URL?
    let digest: String
    let bytes: Int

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
                .hasPrefix("#EXTM3U") else { throw PlaylistError.content }
        var streams: [XtreamStream] = [], categories: [XtreamCategory] = []
        var urls: [Int: URL] = [:], groups: Set<String> = [], pending: (String, [String: String])?
        var guide: URL?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("#EXTM3U") && guide == nil {
                let attributes = attributes(line)
                guide = (attributes["x-tvg-url"] ?? attributes["url-tvg"]).flatMap { try? PlaylistCredentials.webURL($0) }
            } else if line.hasPrefix("#EXTINF:") {
                var quote: Character?
                let comma = line.indices.first { index in
                    let character = line[index]
                    if character == "\"" || character == "'" {
                        if quote == character { quote = nil } else if quote == nil { quote = character }
                    }
                    return character == "," && quote == nil
                }
                if let comma { pending = (String(line[line.index(after: comma)...]), attributes(String(line[..<comma]))) }
                else { pending = nil }
            } else if !line.hasPrefix("#"), !line.isEmpty, let (title, attributes) = pending {
                pending = nil
                guard let url = try? PlaylistCredentials.webURL(line) else { continue }
                let id = stableID(url.absoluteString)
                if urls[id] != nil { continue }
                let group = attributes["group-title"].flatMap { $0.isEmpty ? nil : $0 } ?? "Live TV"
                let groupID = String(stableID(group))
                if groups.insert(group).inserted { categories.append(XtreamCategory(categoryID: groupID, categoryName: group)) }
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                streams.append(XtreamStream(num: streams.count + 1,
                    name: name.isEmpty ? (attributes["tvg-name"] ?? "Channel \(streams.count + 1)") : name,
                    streamType: "live", streamID: id, streamIcon: attributes["tvg-logo"],
                    epgChannelID: attributes["tvg-id"], categoryID: groupID))
                urls[id] = url
            }
        }
        guard !streams.isEmpty else { throw PlaylistError.empty }
        return Self(streams: streams, categories: categories, urls: urls, guide: guide,
                    digest: XtreamPayloadDigest.of(data), bytes: data.count)
    }

    /// Titles and group names can change with the live event. The source URL,
    /// stripped of rotating authentication parameters, supplies channel identity.
    static func stableID(_ value: String) -> Int {
        var identity = value
        if var parts = URLComponents(string: value), parts.host != nil {
            let secrets = Set(["username", "password", "token", "auth", "expires", "signature", "sig", "api_key"])
            parts.queryItems = parts.queryItems?.filter { !secrets.contains($0.name.lowercased()) }
                .sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
            if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
            parts.fragment = nil
            identity = parts.string ?? value
        }
        return SHA256.hash(data: Data(identity.utf8)).prefix(7).reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func attributes(_ text: String) -> [String: String] {
        guard let regex = attributeRegex else { return [:] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).reduce(into: [:]) { result, match in
            let value = (2...4).first { match.range(at: $0).location != NSNotFound }!
            result[string.substring(with: match.range(at: 1)).lowercased()] = string.substring(with: match.range(at: value))
        }
    }
    private static let attributeRegex = try? NSRegularExpression(
        pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))"#)
}

/// Playlist URLs frequently embed credentials. Keep the connection in Keychain
/// and its downloaded source URLs in an encrypted cache, never the channel JSON.
enum PlaylistCache {
    private final class Box: NSObject {
        let value: M3UPlaylist
        init(_ value: M3UPlaylist) { self.value = value }
    }
    private static let memory: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 4
        return cache
    }()
    private static func key(_ profileID: UUID, _ secret: String) -> NSString {
        (profileID.uuidString + XtreamPayloadDigest.of(Data(secret.utf8))) as NSString
    }
    static func url(_ profileID: UUID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lineup-\(profileID.uuidString)-playlist.enc")
    }
    static func write(_ playlist: M3UPlaylist, profileID: UUID, secret: String) throws {
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let box = try AES.GCM.seal(JSONEncoder().encode(playlist), using: key)
        try box.combined?.write(to: url(profileID), options: .atomic)
        memory.setObject(Box(playlist), forKey: self.key(profileID, secret))
    }
    static func read(profileID: UUID, secret: String) -> M3UPlaylist? {
        if let saved = memory.object(forKey: key(profileID, secret)) { return saved.value }
        guard let data = try? Data(contentsOf: url(profileID)),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))) else { return nil }
        guard let playlist = try? JSONDecoder().decode(M3UPlaylist.self, from: plain) else { return nil }
        memory.setObject(Box(playlist), forKey: key(profileID, secret))
        return playlist
    }
    static func remove(profileID: UUID) {
        clearMemory()
        try? FileManager.default.removeItem(at: url(profileID))
    }
    static func clearMemory() { memory.removeAllObjects() }
}

actor PlaylistDownloads {
    static let shared = PlaylistDownloads()
    private var pending: [UUID: Task<M3UPlaylist, Error>] = [:]
    private var recent: [UUID: (Date, M3UPlaylist)] = [:]

    func load(profileID: UUID, secret: String) async throws -> M3UPlaylist {
        if let task = pending[profileID] { return try await task.value }
        if let (date, value) = recent[profileID], Date().timeIntervalSince(date) < 2 { return value }
        let task = Task.detached(priority: .userInitiated) {
            let credentials = try PlaylistCredentials.read(secret)
            var request = URLRequest(url: credentials.playlist)
            request.timeoutInterval = 45
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let download: (Data, URLResponse)
            do { download = try await URLSession.shared.data(for: request) }
            catch { throw PlaylistError.download }
            let (data, response) = download
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PlaylistError.download }
            let playlist = try M3UPlaylist.parse(data)
            try PlaylistCache.write(playlist, profileID: profileID, secret: secret)
            return playlist
        }
        pending[profileID] = task
        defer { pending[profileID] = nil }
        let result = try await task.value
        recent[profileID] = (Date(), result)
        return result
    }
}
