import SwiftUI
import Combine

/// The field's draft is separate from completed search results. Only the field
/// observes it, so typing cannot invalidate the provider-sized result subtree.
@MainActor
final class MobileChannelSearchDraft: ObservableObject {
    @Published private(set) var query = ""

    /// Forward edits at the input boundary, without waiting for a SwiftUI
    /// render/onChange pass. The search store still debounces and filters off-main.
    func binding(onQuery: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { self.query }, set: { value in
            guard self.query != value else { return }
            self.query = value
            onQuery(value)
        })
    }
}

/// Channel/favorite publications refresh the catalog; unrelated sports-store
/// publications and the search field's draft do not invalidate the results.
struct MobileChannelPicker: View {
    let library: SportsLibrary
    let game: SportsGame
    let onPick: (XtreamStream) -> Void
    @StateObject private var search = MobileChannelSearch()
    @State private var reloadTask: Task<Void, Never>?

    private func reloadChannels() {
        let preferred = [library.verifiedStream(for: game)].compactMap { $0 }
            + library.tennisCoverage(for: game)
        // Resolve favorites in the background index instead of walking the
        // full guide on the main actor, with a favorite-array scan per channel.
        search.update(channels: library.streams, preferred: preferred, favoriteOrder: library.favoriteStreamOrder)
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            // Published emits before the new catalog/favorites are stored.
            await Task.yield()
            guard !Task.isCancelled else { return }
            reloadChannels()
        }
    }

    var body: some View {
        MobileChannelPickerContent(game: game, search: search, onPick: onPick)
            .presentationDetents([.large])
            .presentationBackground(LineupStyle.background)
            .task { reloadChannels() }
            .onReceive(library.$streams.dropFirst()) { _ in scheduleReload() }
            .onReceive(library.$favoriteStreamOrder.dropFirst()) { _ in scheduleReload() }
            .onDisappear { reloadTask?.cancel(); search.cancel() }
    }
}

@MainActor
struct MobileChannelPickerContent: View {
    @Environment(\.dismiss) private var dismiss
    let game: SportsGame
    @ObservedObject var search: MobileChannelSearch
    // Retain the reference without subscribing the whole sheet to keystrokes.
    // The field below owns the ObservableObject subscription.
    @State private var draft: MobileChannelSearchDraft
    let onPick: (XtreamStream) -> Void

    init(game: SportsGame, search: MobileChannelSearch, draft: MobileChannelSearchDraft? = nil,
         onPick: @escaping (XtreamStream) -> Void) {
        self.game = game
        self.search = search
        _draft = State(initialValue: draft ?? MobileChannelSearchDraft())
        self.onPick = onPick
    }

    var body: some View {
        let page = search.page
        NavigationStack {
            ZStack {
                LineupStyle.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    MobileChannelSearchField(draft: draft) { query in search.search(query) }
                    MobileChannelResults(search: search, matchup: "\(game.awayTeam) versus \(game.homeTeam)", onPick: onPick)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if page.loading {
                                ProgressView("Loading channels…")
                            } else if page.results.isEmpty && page.suggested.isEmpty {
                                LineupUnavailableView("No channels", systemImage: "magnifyingglass",
                                    description: Text(page.query.isEmpty
                                        ? "Refresh your guide to load this provider's channels."
                                        : "Nothing matched “\(page.query)”."))
                            }
                        }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LineupToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.buttonStyle(LineupBarButtonStyle())
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(game.awayTeam) vs. \(game.homeTeam)")
                .font(.inter(.headline, .bold)).lineLimit(1)
            Text(game.broadcast.isEmpty ? "Choose a channel" : "Choose a channel · \(game.broadcast)")
                .font(.inter(.caption)).foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 12)
    }
}

/// Typing changes only this small subtree. The results publish separately
/// after background filtering; neither the table nor the sheet owns this draft.
private struct MobileChannelSearchField: View {
    @ObservedObject var draft: MobileChannelSearchDraft
    let onQuery: (String) -> Void
    @FocusState private var searchFocused: Bool

    private var text: Binding<String> { draft.binding(onQuery: onQuery) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
            TextField("Search channels", text: text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("ChooseAnotherChannelSearch")
            if !draft.query.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .font(.inter(.body))
        .padding(.horizontal, 14).frame(height: 44)
        .background(LineupPanelStyle.fill, in: Capsule())
        .padding(.horizontal, LineupPanelStyle.margin).padding(.bottom, 12)
        .task { searchFocused = true }
    }
}
