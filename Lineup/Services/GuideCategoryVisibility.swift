import Foundation

/// The TV Guide's hidden categories, on the iPhone and the Apple TV alike.
/// The name is from when only the phone could hide one.
///
/// Saved with the provider's native ID, so combined Guide display IDs and
/// switching between providers cannot hide another service's categories.
struct MobileGuideCategoryVisibility {
    static let storageKey = "lineup.mobile.guide.hiddenCategories.v1"
    private var hidden: [String: Set<String>]

    init(_ raw: String) {
        hidden = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:]
    }
    /// One provider's hidden categories, by the provider's own IDs for them.
    func hiddenIDs(provider: UUID?) -> Set<String> {
        guard let provider else { return [] }
        return hidden[provider.uuidString] ?? []
    }
    func isHidden(_ category: String, provider: UUID?) -> Bool {
        guard let provider else { return false }
        return hidden[provider.uuidString]?.contains(category) == true
    }
    func hiddenDisplayIDs(in categories: [XtreamCategory], source: (String) -> (profileID: UUID?, categoryID: String)) -> Set<String> {
        Set(categories.compactMap { category in
            let origin = source(category.id)
            return isHidden(origin.categoryID, provider: origin.profileID) ? category.id : nil
        })
    }
    static func filtered(_ streams: [XtreamStream], hidden: Set<String>, personalList: Bool, gamePicker: Bool) -> [XtreamStream] {
        guard !gamePicker, !personalList, !hidden.isEmpty else { return streams }
        return streams.filter { !hidden.contains($0.categoryID ?? "") }
    }
    func setting(_ hide: Bool, category: String, provider: UUID?) -> String? {
        guard let provider, !category.isEmpty else { return nil }
        var copy = hidden
        if hide { copy[provider.uuidString, default: []].insert(category) }
        else { copy[provider.uuidString]?.remove(category) }
        if copy[provider.uuidString]?.isEmpty == true { copy[provider.uuidString] = nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(copy) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
