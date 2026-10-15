import SwiftUI

/// Choosing the channel to watch a game on.
///
/// This used to open the Guide with a different title on it — the full EPG,
/// its timeline, its filters and every channel a provider carries, when the
/// question is only "which of these is showing this game". People got lost in
/// it. This asks the one question: a search field, the app's own match at the
/// top where it can be taken at a glance, and everything else a keystroke away.
struct MobileChannelPicker: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @StateObject private var search = MobileChannelSearch()
    @State private var suggestedChannels: [XtreamStream] = []
    @State private var favoriteIDs: Set<Int> = []
    @State private var reloadTask: Task<Void, Never>?
    let game: SportsGame
    let onPick: (XtreamStream) -> Void

    /// The app's own match, and the channels the broadcast names, first. A
    /// viewer who recognises one of these never has to type at all.
    private var suggested: [XtreamStream] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestedChannels : []
    }

    private func reloadChannels() {
        favoriteIDs = Set(library.favoriteStreamOrder)
        var seen: Set<Int> = []
        var out: [XtreamStream] = []
        if let matched = library.verifiedStream(for: game), seen.insert(matched.id).inserted {
            out.append(matched)
        }
        for showing in library.tennisCoverage(for: game) where seen.insert(showing.id).inserted {
            out.append(showing)
        }
        for favorite in library.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
        where seen.insert(favorite.id).inserted {
            out.append(favorite)
        }
        suggestedChannels = Array(out.prefix(6))
        search.update(channels: library.streams, excluding: Set(suggestedChannels.map(\.id)))
    }

    private var results: [XtreamStream] {
        search.results
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            // Published emits before its new catalog/favorites are stored.
            // Read matching state after that publication has finished.
            await Task.yield()
            guard !Task.isCancelled else { return }
            reloadChannels()
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LineupStyle.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    searchField
                    if search.loading && results.isEmpty && suggested.isEmpty {
                        ProgressView("Loading channels…").frame(maxHeight: .infinity)
                    } else if results.isEmpty && suggested.isEmpty {
                        LineupUnavailableView("No channels", systemImage: "magnifyingglass",
                            description: Text(query.isEmpty
                                ? "Refresh your guide to load this provider's channels."
                                : "Nothing matched “\(query)”."))
                            .frame(maxHeight: .infinity)
                    } else {
                        List {
                            if !suggested.isEmpty {
                                Section {
                                    ForEach(suggested) { row($0, suggested: true) }
                                } header: { sectionLabel("Suggested", systemImage: "star") }
                                    .listRowBackground(LineupRowBackground())
                                    .listRowSeparatorTint(LineupPanelStyle.divider)
                            }
                            Section {
                                ForEach(results) { row($0, suggested: false) }
                            } header: {
                                sectionLabel(query.isEmpty ? "All channels" : "Results",
                                             systemImage: query.isEmpty ? "tv" : "magnifyingglass")
                            }
                                .listRowBackground(LineupRowBackground())
                                .listRowSeparatorTint(LineupPanelStyle.divider)
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(LineupPanelStyle.gap)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LineupToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.buttonStyle(LineupBarButtonStyle()) }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LineupStyle.background)
        .task { reloadChannels(); searchFocused = true }
        .onChange(of: query) { _, value in search.search(value) }
        .onReceive(library.$streams.dropFirst()) { _ in scheduleReload() }
        .onReceive(library.$favoriteStreamOrder.dropFirst()) { _ in scheduleReload() }
        .onDisappear { reloadTask?.cancel(); search.cancel() }
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

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
            TextField("Search channels", text: $query)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .font(.inter(.body))
        .padding(.horizontal, 14).frame(height: 44)
        .background(LineupPanelStyle.fill, in: Capsule())
        .padding(.horizontal, LineupPanelStyle.margin).padding(.bottom, 12)
    }

    /// The panels' own header, over the panel it names.
    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        LineupPanelHeader(text, systemImage: systemImage)
            .textCase(nil)
            .padding(.leading, -4)
    }

    private func row(_ stream: XtreamStream, suggested: Bool) -> some View {
        Button {
            searchFocused = false
            onPick(stream)
        } label: {
            HStack(spacing: 12) {
                MobileChannelBadge(stream: stream)
                Text(stream.name).font(.inter(.body, .semibold))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if favoriteIDs.contains(stream.id) {
                    Image(systemName: "star.fill").font(.inter(.caption2))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                }
                if suggested {
                    Image(systemName: "sparkles").font(.inter(.caption2))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch \(game.awayTeam) versus \(game.homeTeam) on \(stream.name)")
    }
}

/// The channel's own logo where it has one, its name where it does not, at a
/// size that keeps every row the same height either way.
private struct MobileChannelBadge: View {
    let stream: XtreamStream

    var body: some View {
        LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 44) { loaded in
            if let image = loaded {
                image.resizable().scaledToFit()
            } else {
                Text(stream.name.prefix(3).uppercased())
                    .font(.inter(.caption2, .bold))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.7))
            }
        }
        .frame(width: 44, height: 30)
        .accessibilityHidden(true)
    }
}
