import SwiftUI

struct LibraryMetadataSettingsView: View {
    @EnvironmentObject private var media: MediaLibrary
    #if os(tvOS)
    @State private var choosingMetadata = false
    @State private var choosingEpisodes = false
    #endif

    private var metadataBinding: Binding<LibraryMetadataSource> {
        Binding(get: { media.metadataSource }, set: { media.setMetadataSource($0) })
    }
    private var episodeBinding: Binding<LibraryMetadataSource> {
        Binding(get: { media.episodeDataSource }, set: { media.setMetadataSource($0, episodes: true) })
    }

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Metadata").font(.inter(42, .bold))
                Text("Choose the titles, summaries, and artwork shown in Library.")
                    .font(.inter(23)).foregroundStyle(LineupPanelStyle.quiet)
                VStack(spacing: 16) {
                    sourceButton("Metadata source:", symbol: "film", value: media.metadataSource) { choosingMetadata = true }
                    sourceButton("Episode data:", symbol: "tv", value: media.episodeDataSource) { choosingEpisodes = true }
                }
                Text("Metadata source applies to movies and shows. Episode data applies to episode titles, summaries, and stills. Your provider's data is used when a match is unavailable.")
                    .font(.inter(21)).foregroundStyle(LineupPanelStyle.quiet)
                availability
                credits
            }
            .padding(40)
            .frame(width: 1100, alignment: .leading)
            .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
        .background(LineupStyle.background)
        .foregroundStyle(LineupStyle.text)
        .tvChoices("Metadata source", symbol: "film", isPresented: $choosingMetadata) {
            choices(episodes: false)
        }
        .tvChoices("Episode data", symbol: "tv", isPresented: $choosingEpisodes) {
            choices(episodes: true)
        }
        #else
        List {
            Section {
                Picker(selection: metadataBinding) {
                    ForEach(LibraryMetadataSource.allCases) { source in Text(source.title).tag(source) }
                } label: {
                    sourceLabel("Metadata source:", symbol: "film")
                }
                .pickerStyle(.menu)
                Picker(selection: episodeBinding) {
                    ForEach(LibraryMetadataSource.allCases) { source in Text(source.title).tag(source) }
                } label: {
                    sourceLabel("Episode data:", symbol: "tv")
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Metadata source applies to movies and shows. Episode data applies to episode titles, summaries, and stills. Your provider's data is used when a match is unavailable.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
            Section {
                availability
                credits
            } header: {
                Text("Credits").lineupSettingsHeader()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .navigationTitle("Metadata")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func sourceLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            LineupIconTile(symbol: symbol, size: 28)
            Text(title).font(.inter(16, .semibold)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(LineupStyle.text)
    }

    #if os(tvOS)
    private func sourceButton(_ title: String, symbol: String, value: LibraryMetadataSource,
                              action: @escaping () -> Void) -> some View {
        TVSelectable(scale: 1.015, fillRadius: 18, action: action) {
            HStack(spacing: 20) {
                LineupIconTile(symbol: symbol, size: 42)
                Text(title).font(.inter(26, .semibold))
                Spacer()
                Text(value.title).font(.inter(25)).foregroundStyle(LineupStyle.highlight)
                Image(systemName: "chevron.down").font(.system(size: 19, weight: .semibold))
            }
            .padding(24)
            .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func choices(episodes: Bool) -> [TVChoice] {
        LibraryMetadataSource.allCases.map { source in
            TVChoice(source.title, symbol: "rectangle.stack",
                     isSelected: (episodes ? media.episodeDataSource : media.metadataSource) == source) {
                media.setMetadataSource(source, episodes: episodes)
            }
        }
    }
    #endif

    @ViewBuilder private var availability: some View {
        if !media.metadataAvailable(.tmdb) || !media.metadataAvailable(.tvdb) {
            Text("Some metadata services are unavailable in this build. Provider data will continue to display.")
                .font(.inter(.footnote)).foregroundStyle(LineupPanelStyle.quiet)
        }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 18) {
            Link(destination: URL(string: "https://www.themoviedb.org")!) {
                HStack(spacing: 12) {
                    Image("Rating-TMDB").resizable().scaledToFit().frame(width: 40, height: 28)
                    Text("The Movie Database (TMDB)").font(.inter(.subheadline, .semibold))
                }
            }
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.inter(.footnote)).foregroundStyle(LineupPanelStyle.quiet)
            Link("Metadata provided by TheTVDB", destination: URL(string: "https://www.thetvdb.com")!)
                .font(.inter(.subheadline, .semibold))
        }
        .tint(LineupStyle.highlight)
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }
}

/// Source attribution travels with a resolved item, including cached matches.
struct LibraryMetadataCredit: View {
    let item: MediaItem
    let interactive: Bool

    init(item: MediaItem, interactive: Bool = true) {
        self.item = item
        self.interactive = interactive
    }

    private var title: String {
        let role = item.type == "Episode" ? "Episode data" : item.isSeries ? "Show metadata" : "Movie metadata"
        return role + ": " + (item.metadata?.source.title ?? LibraryMetadataSource.provider.title)
    }

    var body: some View {
        Group {
            if interactive, let url = item.metadata?.attributionURL.flatMap(URL.init(string:)) {
                Link(title, destination: url).buttonStyle(.plain)
            } else {
                Text(title)
            }
        }
        .font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet)
    }
}
