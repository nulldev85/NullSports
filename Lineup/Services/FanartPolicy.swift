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

private struct TMDBImageResponse: Decodable {
    let id: Int
    let logos: [TMDBLogoImage]?
}

private struct TMDBLogoImage: Decodable {
    let file_path: String?
    let iso_639_1: String?
    let width: Int?
    let height: Int?
    let vote_average: Double?
    let vote_count: Int?
}

enum TMDBTitleLogoPolicy {
    static func logo(_ data: Data, expectedID: Int) -> URL? {
        guard data.count <= 2_000_000,
              let response = try? JSONDecoder().decode(TMDBImageResponse.self, from: data),
              response.id == expectedID else { return nil }
        let candidates = (response.logos ?? []).compactMap { image -> (URL, Int, Double, Int)? in
            guard let path = image.file_path, let url = imageURL(path),
                  let width = image.width, let height = image.height,
                  (1...8000).contains(width), (1...4000).contains(height),
                  width * height <= 10_000_000 else { return nil }
            let language = image.iso_639_1?.lowercased()
            let languageRank: Int
            if language == "en" || language?.hasPrefix("en-") == true { languageRank = 0 }
            else if language == nil { languageRank = 1 }
            else { return nil }
            let rating = image.vote_average.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let votes = min(1_000_000, max(0, image.vote_count ?? 0))
            return (url, languageRank, rating, votes)
        }
        return candidates.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.3 != $1.3 { return $0.3 > $1.3 }
            return $0.0.absoluteString < $1.0.absoluteString
        }.first?.0
    }

    static func imageURL(_ path: String) -> URL? {
        guard path.count <= 512, path.hasPrefix("/"), !path.contains(".."),
              path.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "/-_.0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
                      .contains($0)
              }), let url = URL(string: "https://image.tmdb.org/t/p/w1280\(path)"),
              url.host == "image.tmdb.org" else { return nil }
        return url
    }
}
