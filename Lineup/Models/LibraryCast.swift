import Foundation

struct LibraryCastMember: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let role: String?
    let imageURL: URL?
    var fallbackImageURL: URL? = nil

    static func credits(_ data: Data, expectedID: Int) -> [Self] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["id"] as? Int == expectedID, let rows = value["cast"] as? [[String: Any]] else { return [] }
        var seen = Set<Int>()
        return rows.compactMap { row -> Self? in
            guard let id = row["id"] as? Int, id > 0, let rawName = row["name"] as? String else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(id).inserted else { return nil }
            let roles = (row["roles"] as? [[String: Any]] ?? []).compactMap { $0["character"] as? String }
            let role = (row["character"] as? String) ?? roles.prefix(2).joined(separator: ", ")
            let path = row["profile_path"] as? String
            let image = path.flatMap { path -> URL? in
                guard path.range(of: #"^/[A-Za-z0-9_-]+\.(jpg|png|webp)$"#, options: .regularExpression) != nil else { return nil }
                return URL(string: "https://image.tmdb.org/t/p/w185" + path)
            }
            return Self(id: "tmdb:\(id)", name: name, role: role.isEmpty ? nil : role, imageURL: image)
        }.prefix(40).map { $0 }
    }

    /// Provider names/roles/order are retained. Portrait fallback matches only
    /// unique names inside the verified title's credits, never a people search.
    static func merged(provider: [MediaPerson], credits: [Self], image: (MediaPerson) -> URL?) -> [Self] {
        let actors = provider.filter { $0.type?.lowercased() == "actor" }
        let names = Set(actors.map { normalized($0.name) })
        let byName = Dictionary(grouping: credits, by: { normalized($0.name) })
        let local = actors.enumerated().map { index, person in
            let matches = byName[normalized(person.name)] ?? []
            let match = matches.count == 1 ? matches.first : nil
            let serverImage = image(person)
            return Self(id: "provider:\(person.id):\(index)", name: person.name,
                role: person.role ?? match?.role, imageURL: serverImage ?? match?.imageURL,
                fallbackImageURL: serverImage == nil ? nil : match?.imageURL)
        }
        return local + credits.filter { !names.contains(normalized($0.name)) }
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
