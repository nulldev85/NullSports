import Foundation
import Combine

private struct MobileChannelIndexEntry: Sendable {
    let stream: XtreamStream
    let name: String
}

/// Build the provider's sorted, folded-name index once, then filter away from
/// the UI actor. New keystrokes cancel old work and only the latest can publish.
@MainActor
final class MobileChannelSearch: ObservableObject {
    @Published private(set) var results: [XtreamStream] = []
    @Published private(set) var loading = true
    private var entries: [MobileChannelIndexEntry] = []
    private var excluded: Set<Int> = []
    private var query = ""
    private var request = UUID()
    private var catalogTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?

    func update(channels: [XtreamStream], excluding suggested: Set<Int>) {
        catalogTask?.cancel()
        queryTask?.cancel()
        request = UUID()
        excluded = suggested
        loading = true
        catalogTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return [MobileChannelIndexEntry]() }
                let ordered = channels.filter { !["radio", "radio_streams"].contains($0.streamType?.lowercased() ?? "") }
                    .sorted {
                        if ($0.num ?? Int.max) != ($1.num ?? Int.max) { return ($0.num ?? Int.max) < ($1.num ?? Int.max) }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                var index: [MobileChannelIndexEntry] = []
                index.reserveCapacity(ordered.count)
                for stream in ordered {
                    guard !Task.isCancelled else { return [MobileChannelIndexEntry]() }
                    index.append(.init(stream: stream,
                        name: stream.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)))
                }
                return index
            }
            let index = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, !Task.isCancelled else { return }
            self.entries = index
            self.loading = false
            self.search(self.query, immediately: true)
        }
    }

    func search(_ query: String, immediately: Bool = false) {
        self.query = query
        queryTask?.cancel()
        let token = UUID()
        request = token
        let index = entries
        let excluded = excluded
        queryTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) {
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                var matches: [XtreamStream] = []
                for entry in index {
                    guard !Task.isCancelled else { return [XtreamStream]() }
                    if term.isEmpty ? !excluded.contains(entry.stream.id) : entry.name.contains(term) {
                        matches.append(entry.stream)
                    }
                }
                return matches
            }
            let matches = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, !Task.isCancelled, self.request == token else { return }
            self.results = matches
        }
    }

    func cancel() { catalogTask?.cancel(); queryTask?.cancel(); request = UUID() }
    deinit { catalogTask?.cancel(); queryTask?.cancel() }
}
