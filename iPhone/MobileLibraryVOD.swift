import SwiftUI

/// Each IPTV provider's films and shows as a folder in the Library, the way
/// collections are: one tile a provider, by the name it was given.
struct MobileLibraryVODRow: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.mobileShelfBleed) private var bleed

    static let rowID = "builtin:iptv-vod"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IPTV MOVIES & SHOWS")
                .font(.inter(14, .heavy))
                .padding(.horizontal, LineupPanelStyle.inset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(media.providerVODAccounts) { provider in
                        NavigationLink { MobileProviderVODView(provider: provider) } label: {
                            tile(provider)
                        }
                        .lineupFlatButton()
                    }
                }
                .padding(.leading, LineupPanelStyle.inset + bleed.leading)
                .padding(.trailing, LineupPanelStyle.inset + bleed.trailing)
            }
            .mobileShelfRowBleed(bleed)
        }
        .padding(.vertical, 4)
    }

    private func tile(_ provider: XtreamProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LineupPanelStyle.fill
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(LineupStyle.highlight)
            }
            .frame(height: 205 * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(provider.name).font(.inter(.subheadline, .bold)).lineLimit(1)
            Text("Movies and shows").font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
        }
        .frame(width: 205, alignment: .leading).padding(14)
        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundStyle(LineupStyle.text)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this provider's movie and show categories")
    }
}

/// One provider's films and shows: its categories, Movies and Shows on tabs
/// of their own, each opening its titles.
struct MobileProviderVODView: View {
    @Environment(MediaLibrary.self) private var media
    let provider: XtreamProfile

    private enum Kind: String, CaseIterable, Identifiable {
        case movies = "Movies", shows = "Shows"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .movies
    @State private var categories: (films: [MediaItem], shows: [MediaItem])?
    @State private var failed = false
    @State private var query = ""

    private var shown: [MediaItem] {
        let all = kind == .movies ? categories?.films ?? [] : categories?.shows ?? []
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? all : all.filter { $0.name.localizedStandardContains(term) }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                if categories == nil {
                    HStack(spacing: 12) {
                        if failed {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(LineupIconTile.orange)
                            Text("\(provider.name) didn’t send its list. Try again in a moment.")
                        } else {
                            ProgressView()
                            Text("Loading \(provider.name)’s list…")
                        }
                    }
                    .font(.inter(.subheadline, .medium))
                } else if shown.isEmpty {
                    Text(query.isEmpty ? "\(provider.name) has no \(kind.rawValue.lowercased())."
                                       : "No categories match.")
                        .font(.inter(.subheadline, .medium))
                        .foregroundStyle(LineupPanelStyle.quiet)
                } else {
                    ForEach(shown, id: \.libraryKey) { category in
                        NavigationLink(value: category) {
                            HStack(spacing: 14) {
                                LineupIconTile(symbol: kind == .movies ? "film" : "tv", size: 30)
                                Text(category.name)
                                    .font(.inter(.body, .semibold))
                                    .foregroundStyle(LineupStyle.text)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                if let count = category.childCount {
                                    Text(count.formatted())
                                        .font(.interDigits(15, .medium))
                                        .foregroundStyle(LineupPanelStyle.listValue)
                                }
                            }
                        }
                    }
                }
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .searchable(text: $query, prompt: "Find a category")
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: provider.id) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        failed = false
        let found = await media.providerVODCategories(provider.id)
        guard !Task.isCancelled else { return }
        categories = found
        failed = found == nil
        // A provider with shows and no films opens on its shows.
        if let found, found.films.isEmpty, !found.shows.isEmpty { kind = .shows }
    }
}
