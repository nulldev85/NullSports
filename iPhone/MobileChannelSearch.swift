import Foundation
import Combine

private struct MobileChannelIndexEntry: Sendable {
    let stream: XtreamStream
    let name: String
}

private struct MobileChannelIndex: Sendable {
    let id = UUID()
    let entries: [MobileChannelIndexEntry]
    let suggested: [XtreamStream]
    let favoriteIDs: Set<Int>
}

/// One completed answer. Its identity lets the reusable table accept it in
/// constant time instead of comparing every channel on a SwiftUI update.
final class MobileChannelSearchPage: Sendable {
    let id = UUID()
    let catalogID: UUID?
    let query: String
    let results: [XtreamStream]
    let suggested: [XtreamStream]
    let favoriteIDs: Set<Int>
    let loading: Bool

    init(catalogID: UUID? = nil, query: String = "", results: [XtreamStream] = [],
         suggested: [XtreamStream] = [], favoriteIDs: Set<Int> = [], loading: Bool = true) {
        self.catalogID = catalogID
        self.query = query
        self.results = results
        self.suggested = suggested
        self.favoriteIDs = favoriteIDs
        self.loading = loading
    }
}

/// Indexing, favorite resolution and filtering stay off the UI actor. Only a
/// completed page publishes: a keystroke does not invalidate the results view.
@MainActor
final class MobileChannelSearch: ObservableObject {
    @Published private(set) var page = MobileChannelSearchPage()
    var results: [XtreamStream] { page.results }
    var loading: Bool { page.loading }
    private var index: MobileChannelIndex?
    /// Newest requested text, which can be ahead of the last completed page.
    private(set) var query = ""
    private var request = UUID()
    private var catalogTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?

    func update(channels: [XtreamStream], preferred: [XtreamStream], favoriteOrder: [Int]) {
        catalogTask?.cancel()
        queryTask?.cancel()
        request = UUID()
        index = nil
        page = MobileChannelSearchPage()
        catalogTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { () -> MobileChannelIndex? in
                var entries: [MobileChannelIndexEntry] = []
                entries.reserveCapacity(channels.count)
                var byID: [Int: XtreamStream] = [:]
                byID.reserveCapacity(channels.count)
                for stream in channels {
                    guard !Task.isCancelled else { return nil }
                    guard !["radio", "radio_streams"].contains(stream.streamType?.lowercased() ?? ""),
                          byID[stream.id] == nil else { continue }
                    byID[stream.id] = stream
                    entries.append(.init(stream: stream,
                        name: stream.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)))
                }
                entries.sort {
                    if ($0.stream.num ?? Int.max) != ($1.stream.num ?? Int.max) {
                        return ($0.stream.num ?? Int.max) < ($1.stream.num ?? Int.max)
                    }
                    return $0.stream.name.localizedCaseInsensitiveCompare($1.stream.name) == .orderedAscending
                }
                guard !Task.isCancelled else { return nil }
                var seen: Set<Int> = []
                var suggested: [XtreamStream] = []
                for id in preferred.map(\.id) + favoriteOrder {
                    guard !Task.isCancelled else { return nil }
                    if let stream = byID[id], seen.insert(id).inserted { suggested.append(stream) }
                    if suggested.count == 6 { break }
                }
                return MobileChannelIndex(entries: entries, suggested: suggested, favoriteIDs: Set(favoriteOrder))
            }
            let index = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, let index, !Task.isCancelled else { return }
            self.index = index
            self.search(self.query, immediately: true)
        }
    }

    func search(_ query: String, immediately: Bool = false) {
        guard immediately || query != self.query else { return }
        self.query = query
        queryTask?.cancel()
        let token = UUID()
        request = token
        guard let index else { return } // The catalog completion uses the newest draft.
        queryTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { () -> MobileChannelSearchPage? in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let term = trimmed
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                let suggested = term.isEmpty ? index.suggested : []
                let excluded = Set(suggested.map(\.id))
                var matches: [XtreamStream] = []
                matches.reserveCapacity(index.entries.count)
                for entry in index.entries {
                    guard !Task.isCancelled else { return nil }
                    if term.isEmpty ? !excluded.contains(entry.stream.id) : entry.name.contains(term) {
                        matches.append(entry.stream)
                    }
                }
                return MobileChannelSearchPage(catalogID: index.id, query: trimmed,
                    results: matches, suggested: suggested, favoriteIDs: index.favoriteIDs, loading: false)
            }
            let page = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, let page, !Task.isCancelled, self.request == token else { return }
            self.page = page
        }
    }

    func cancel() { catalogTask?.cancel(); queryTask?.cancel(); request = UUID() }
    deinit { catalogTask?.cancel(); queryTask?.cancel() }
}
