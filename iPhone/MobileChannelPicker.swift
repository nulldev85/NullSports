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
    let game: SportsGame
    let onPick: (XtreamStream) -> Void

    /// The app's own match, and the channels the broadcast names, first. A
    /// viewer who recognises one of these never has to type at all.
    private var suggested: [XtreamStream] {
        guard query.isEmpty else { return [] }
        var seen: Set<Int> = []
        var out: [XtreamStream] = []
        if let matched = library.verifiedStream(for: game), seen.insert(matched.id).inserted {
            out.append(matched)
        }
        for favorite in library.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
        where seen.insert(favorite.id).inserted {
            out.append(favorite)
        }
        return Array(out.prefix(6))
    }

    private var results: [XtreamStream] {
        let all = library.guideStreams(categoryID: nil, favoritesOnly: false, query: query)
        guard query.isEmpty else { return all }
        let shown = Set(suggested.map(\.id))
        return all.filter { !shown.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LineupStyle.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    searchField
                    if results.isEmpty && suggested.isEmpty {
                        ContentUnavailableView("No channels", systemImage: "magnifyingglass",
                            description: Text(query.isEmpty
                                ? "Refresh your guide to load this provider's channels."
                                : "Nothing matched “\(query)”."))
                            .frame(maxHeight: .infinity)
                    } else {
                        List {
                            if !suggested.isEmpty {
                                Section {
                                    ForEach(suggested) { row($0, suggested: true) }
                                } header: { sectionLabel("Suggested") }
                                    .listRowBackground(LineupGlassRow())
                            }
                            Section {
                                ForEach(results) { row($0, suggested: false) }
                            } header: { sectionLabel(query.isEmpty ? "All channels" : "Results") }
                                .listRowBackground(LineupGlassRow())
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LineupStyle.background)
        .task { searchFocused = true }
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
        .lineupLiquidGlass(Capsule(), fallback: LineupStyle.surface, border: LineupStyle.line)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.inter(.caption2, .bold)).tracking(1.4)
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
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
                if library.isFavorite(stream) {
                    Image(systemName: "star.fill").font(.caption2)
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                }
                if suggested {
                    Image(systemName: "sparkles").font(.caption2)
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
        AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
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
