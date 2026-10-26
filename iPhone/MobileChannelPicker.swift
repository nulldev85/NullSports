import SwiftUI

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
        MobileChannelPickerContent(game: game, search: search,
            providerName: library.enabledProfiles.count > 1 ? "All enabled providers" : library.enabledProfiles.first?.name,
            onPick: onPick)
            .presentationDetents([.large])
            .presentationBackground(LineupPresentationStyle.ground)
            .task { reloadChannels() }
            .onChange(of: library.streamsRevision) { scheduleReload() }
            .onChange(of: library.favoriteStreamOrder) { scheduleReload() }
            .onDisappear { reloadTask?.cancel(); search.cancel() }
    }
}

@MainActor
struct MobileChannelPickerContent: View {
    @Environment(\.dismiss) private var dismiss
    let game: SportsGame
    @ObservedObject var search: MobileChannelSearch
    var automaticallyFocusSearch = true
    var providerName: String? = nil
    let onPick: (XtreamStream) -> Void

    var body: some View {
        let page = search.page
        NavigationStack {
            ZStack {
                LineupPresentationStyle.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    MobileChannelSearchField(search: search, automaticallyFocus: automaticallyFocusSearch)
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
                .font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.text.opacity(0.62))
                .lineLimit(1)
            if let providerName {
                Label("Provider: \(providerName)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.inter(.caption, .semibold)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 12)
    }
}

/// The native field owns its editing buffer. SwiftUI only observes completed
/// results, so keystrokes do not invalidate the sheet or reset the editor.
private struct MobileChannelSearchField: View {
    let search: MobileChannelSearch
    let automaticallyFocus: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LineupPresentationStyle.text.opacity(0.55))
            MobileChannelSearchInput(search: search, automaticallyFocus: automaticallyFocus)
        }
        .font(.inter(.body))
        .padding(.horizontal, 14).frame(height: 44)
        .background(LineupPresentationStyle.card, in: Capsule())
        .padding(.horizontal, LineupPanelStyle.margin).padding(.bottom, 12)
    }
}
