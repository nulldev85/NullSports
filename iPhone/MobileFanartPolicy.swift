import Foundation

struct MobileFanartIdentity: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case movie, series }
    let kind: Kind
    let id: String
    init?(kind: Kind, id: String) {
        let numeric = id.range(of: "^[1-9][0-9]{0,17}$", options: .regularExpression) != nil
        let imdb = id.range(of: "^tt[0-9]{7,}$", options: .regularExpression) != nil
        guard numeric || (kind == .movie && imdb) else { return nil }
        self.kind = kind; self.id = id
    }
    func request(key: String) -> URLRequest? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let route = kind == .movie ? "movies" : "tv"
        var parts = URLComponents(string: "https://webservice.fanart.tv/v3.2/\(route)/\(id)")!
        parts.queryItems = [.init(name: "api_key", value: key)]
        var request = URLRequest(url: parts.url!, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

enum MobileFanartPolicy {
    /// Exact external IDs only. Fanart's movie and TV numeric namespaces differ.
    static func logo(_ data: Data, identity: MobileFanartIdentity, language: String = "en") -> URL? {
        guard data.count <= 2_000_000,
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func scalar(_ key: String) -> String? {
            if let text = value[key] as? String { return text }
            // JSON booleans/fractions are not external IDs.
            if let number = value[key] as? NSNumber, String(cString: number.objCType) != "c",
               number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue {
                return number.stringValue
            }
            return nil
        }
        let returnedID = identity.kind == .series ? scalar("thetvdb_id")
            : identity.id.hasPrefix("tt") ? scalar("imdb_id") : scalar("tmdb_id")
        guard returnedID == identity.id else { return nil }
        let fields = identity.kind == .movie ? ["hdmovielogo", "movielogo"] : ["hdtvlogo", "clearlogo"]
        struct Candidate {
            let url: URL
            let language: Int, quality: Int, likes: Int
        }
        var candidates: [Candidate] = []
        for (quality, field) in fields.enumerated() {
            for row in value[field] as? [[String: Any]] ?? [] {
                guard let text = row["url"] as? String, let url = imageURL(text) else { continue }
                let lang = (row["lang"] as? String ?? "").lowercased()
                let rank: Int
                if lang == language.lowercased() { rank = 0 }
                else if lang == "en" { rank = 1 }
                else if lang.isEmpty || lang == "00" { rank = 2 }
                else { continue }
                if let width = row["width"], let height = row["height"] {
                    let w = Double(String(describing: width)) ?? 0
                    let h = Double(String(describing: height)) ?? 0
                    guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 8000, h <= 4000, w * h <= 10_000_000 else { continue }
                }
                let likes = min(1_000_000, max(0, Int(String(describing: row["likes"] ?? "0")) ?? 0))
                candidates.append(Candidate(url: url, language: rank, quality: quality, likes: likes))
            }
        }
        return candidates.sorted {
            if $0.language != $1.language { return $0.language < $1.language }
            if $0.quality != $1.quality { return $0.quality < $1.quality }
            if $0.likes != $1.likes { return $0.likes > $1.likes }
            return $0.url.absoluteString < $1.url.absoluteString
        }.first?.url
    }

    static func imageURL(_ text: String) -> URL? {
        guard text.count <= 2048, let parts = URLComponents(string: text),
              parts.scheme == "https", parts.host?.lowercased() == "assets.fanart.tv",
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.hasPrefix("/fanart/"),
              !parts.path.contains(".."), let url = parts.url,
              ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}
