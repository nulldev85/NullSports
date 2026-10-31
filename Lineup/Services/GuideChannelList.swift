import Foundation

/// A snapshot query: callers can filter/sort a large provider catalog away
/// from the UI actor and publish only the request that is still on screen.
enum GuideChannelList {
    struct Query: Hashable, Sendable {
        var categoryID: String? = nil
        var favoritesOnly = false
        var recentsOnly = false
        var text = ""
        var favorites: [Int] = []
        var recents: [Int] = []
        var hiddenCategories: Set<String> = []
        var gamePicker = false
        var recommendedID: Int? = nil
    }

    @MainActor
    static func load(_ streams: [XtreamStream], query: Query) async throws -> [XtreamStream] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try build(streams, query: query) }
        return try await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() })
    }

    static func build(_ streams: [XtreamStream], query: Query) throws -> [XtreamStream] {
        try Task.checkCancellation()
        let favorites = Set(query.favorites), recents = Set(query.recents)
        let personal = query.favoritesOnly || query.recentsOnly
        var filtered: [XtreamStream] = []
        for stream in streams {
            try Task.checkCancellation()
            let type = stream.streamType?.lowercased()
            guard type != "radio", type != "radio_streams",
                  !query.favoritesOnly || favorites.contains(stream.id),
                  !query.recentsOnly || recents.contains(stream.id),
                  query.categoryID == nil || stream.categoryID == query.categoryID,
                  query.gamePicker || personal || !query.hiddenCategories.contains(stream.categoryID ?? ""),
                  query.text.isEmpty || stream.name.localizedCaseInsensitiveContains(query.text) else { continue }
            filtered.append(stream)
        }
        var result: [XtreamStream]
        if personal {
            let byID = Dictionary(filtered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            result = (query.favoritesOnly ? query.favorites : query.recents).compactMap { byID[$0] }
        } else {
            // Throwing comparators allow a superseded search to stop during
            // sorting as well as filtering, rather than consume another pass.
            result = try filtered.sorted {
                try Task.checkCancellation()
                if ($0.num ?? Int.max) != ($1.num ?? Int.max) { return ($0.num ?? Int.max) < ($1.num ?? Int.max) }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        if query.gamePicker, let recommended = query.recommendedID,
           let index = result.firstIndex(where: { $0.id == recommended }), index != 0 {
            result.insert(result.remove(at: index), at: 0)
        }
        try Task.checkCancellation()
        return result
    }
}
