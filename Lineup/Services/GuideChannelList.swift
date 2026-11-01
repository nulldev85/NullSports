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
    static func load(_ streams: [XtreamStream], query: Query,
                     programs: [String: [CurrentProgram]] = [:], at point: Date = Date()) async throws -> [XtreamStream] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try build(streams, query: query, programs: programs, at: point) }
        return try await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() })
    }

    static func build(_ streams: [XtreamStream], query: Query,
                      programs: [String: [CurrentProgram]] = [:], at point: Date = Date()) throws -> [XtreamStream] {
        try Task.checkCancellation()
        let favorites = Set(query.favorites), recents = Set(query.recents)
        let personal = query.favoritesOnly || query.recentsOnly
        let search = ChannelSearchText.Query(query.text)
        var guideText: [String: String] = [:]
        var filtered: [XtreamStream] = []
        for stream in streams {
            try Task.checkCancellation()
            let type = stream.streamType?.lowercased()
            guard type != "radio", type != "radio_streams",
                  !query.favoritesOnly || favorites.contains(stream.id),
                  !query.recentsOnly || recents.contains(stream.id),
                  query.categoryID == nil || stream.categoryID == query.categoryID,
                  query.gamePicker || personal || !query.hiddenCategories.contains(stream.categoryID ?? "") else { continue }
            if !search.isEmpty {
                let key = stream.epgChannelID ?? ""
                if guideText[key] == nil { guideText[key] = ChannelSearchText.programme(programs[key] ?? [], at: point) }
                guard search.matches(ChannelSearchText.fold(stream.name), programme: guideText[key] ?? "") else { continue }
            }
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

/// Shared manual search for channel names and the programme covering the
/// requested time. Search is discovery; it never establishes playback proof.
enum ChannelSearchText {
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func programme(_ entries: [CurrentProgram], at point: Date) -> String {
        fold(entries.filter { $0.start <= point && point < $0.end }.map { $0.title + " " + $0.detail }.joined(separator: " "))
    }

    struct Query: Sendable {
        let phrase: String
        let words: [String]
        let exactWords: Set<String>
        var isEmpty: Bool { phrase.isEmpty }

        init(_ value: String) {
            phrase = ChannelSearchText.fold(value)
            let all = phrase.split(separator: " ").map(String.init)
            let meaningful = all.filter { !["v", "vs", "versus", "at"].contains($0) }
            words = meaningful.count >= 2 ? meaningful : all
            exactWords = all.count > 1 ? Set(words.filter { $0.count == 1 }) : []
        }

        func matches(_ name: String, programme: String) -> Bool {
            if phrase.isEmpty { return true }
            if exactWords.isEmpty, name.contains(phrase) || programme.contains(phrase) { return true }
            // Both sides can be reversed in Guide. Keep all query terms in
            // the same field instead of combining unrelated channel metadata.
            func matches(_ value: String) -> Bool {
                words.allSatisfy { word in
                    if exactWords.contains(word) {
                        return value == word || value.hasPrefix(word + " ") || value.hasSuffix(" " + word)
                            || value.contains(" " + word + " ")
                    }
                    return value.contains(word)
                }
            }
            return !words.isEmpty && (matches(name) || matches(programme))
        }
    }
}
