import SwiftUI

// MARK: - The poster

/// A service's poster on the Streaming Services row: its official mark on the
/// Library's flat grey, sized the way a title's name sits on a poster.
struct StreamingServicePoster: View {
    let service: StreamingService

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LineupStyle.raised
                if UIImage(named: service.logoAsset) != nil {
                    Image(service.logoAsset)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: proxy.size.width * 0.7, maxHeight: proxy.size.height * 0.24)
                } else {
                    // A mark not yet in the catalog: its name, set plainly.
                    Text(service.name)
                        .font(.inter(proxy.size.width * 0.12, .bold))
                        .foregroundStyle(LineupStyle.text)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, proxy.size.width * 0.1)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityLabel(service.name)
    }
}

// MARK: - One service

/// What one service has on that the viewer can play: its films or its shows,
/// one at a time, in the order the viewer chooses. Each title is the same
/// card, and opens the same page, as anywhere else in the Library.
struct StreamingServiceScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let service: StreamingService

    @State private var kind: StreamingTitle.Kind = .movie
    @State private var order = StreamingOrderMemo()
    @AppStorage("Lineup.streamingSort.movie") private var movieSort: StreamingSort = .popular
    @AppStorage("Lineup.streamingSort.show") private var showSort: StreamingSort = .popular
    #if os(tvOS)
    // tvOS pushes by hand: its cards are not NavigationLinks.
    @State private var pushed: MediaItem?
    @State private var choosingSort = false
    #endif

    private var titles: StreamingServiceTitles { media.streamingTitles(for: service) }

    private var sort: StreamingSort { kind == .movie ? movieSort : showSort }

    private var sortBinding: Binding<StreamingSort> {
        Binding(get: { sort }, set: { value in
            if kind == .movie { movieSort = value } else { showSort = value }
        })
    }

    /// The titles in the chosen order, sorted once per change of order or
    /// of titles rather than on every redraw.
    private var shown: [MediaItem] {
        let key = "\(service.id)|\(kind.rawValue)|\(sort.rawValue)|\(media.streamingMemoKey)"
        if order.key != key {
            order.key = key
            order.items = sort.sorted(titles.titles(kind)).map(\.item)
        }
        return order.items
    }

    var body: some View {
        Group {
            if titles.isEmpty {
                ContentUnavailableView("Nothing to Play Yet", systemImage: "play.slash",
                    description: Text("None of what \(service.name) has on right now is on your servers or your IPTV provider."))
                    .mediaFocusAnchor()
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        .onAppear {
            // A service with only shows opens on its shows.
            if titles.movies.isEmpty, !titles.shows.isEmpty { kind = .show }
        }
        #if os(tvOS)
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .confirmationDialog("Sort \(kind == .movie ? "Movies" : "TV Shows")", isPresented: $choosingSort,
                            titleVisibility: .visible) {
            ForEach(StreamingSort.allCases) { option in
                Button(option == sort ? "\(option.label) ✓" : option.label) { sortBinding.wrappedValue = option }
            }
            Button("Cancel", role: .cancel) { }
        }
        #else
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Image(service.logoAsset).resizable().scaledToFit()
                    .frame(maxWidth: 140, maxHeight: 22)
                    .accessibilityLabel(service.name)
            }
        }
        .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                header
                controls
                LazyVGrid(columns: Metrics.columns, spacing: Metrics.gridSpacing) {
                    ForEach(shown, id: \.libraryKey) { item in
                        cell(item)
                    }
                }
                .lineupFocusRegion()
                // A new order starts from the top, rather than leaving the
                // grid reshuffled under where the viewer was.
                .id("\(kind.rawValue)|\(sort.rawValue)")
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.top, Metrics.topInset)
            .padding(.bottom, 44)
        }
        .lineupFocusRegion()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.headerGap) {
            #if os(tvOS)
            Image(service.logoAsset).resizable().scaledToFit()
                .frame(maxWidth: 360, maxHeight: 76, alignment: .leading)
                .accessibilityLabel(service.name)
            #endif
            Text(summary)
                .font(.inter(Metrics.summarySize, .medium))
                .foregroundStyle(LineupStyle.secondary)
        }
    }

    /// "42 movies · 18 shows · Updated today", and only what plays.
    private var summary: String {
        var parts: [String] = []
        let movies = titles.movies.count, shows = titles.shows.count
        if movies > 0 { parts.append(movies == 1 ? "1 movie" : "\(movies) movies") }
        if shows > 0 { parts.append(shows == 1 ? "1 show" : "\(shows) shows") }
        if let updated = media.streamingUpdatedAt {
            let calendar = Calendar.current
            if calendar.isDateInToday(updated) { parts.append("Updated today") }
            else if calendar.isDateInYesterday(updated) { parts.append("Updated yesterday") }
            else { parts.append("Updated " + updated.formatted(.dateTime.month(.abbreviated).day())) }
        }
        return parts.joined(separator: " · ")
    }

    /// Movies or TV Shows on the left, the order on the right.
    private var controls: some View {
        HStack(spacing: Metrics.chipGap) {
            kindChip(.movie, title: "Movies", count: titles.movies.count)
            kindChip(.show, title: "TV Shows", count: titles.shows.count)
            Spacer(minLength: 8)
            sortControl
        }
        .lineupFocusRegion()
    }

    @ViewBuilder
    private func kindChip(_ value: StreamingTitle.Kind, title: String, count: Int) -> some View {
        let chip = StreamingChip(title: title, count: count, active: kind == value)
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { kind = value }) { chip }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
        #else
        Button { withAnimation(.easeOut(duration: 0.18)) { kind = value } } label: { chip }
            .lineupFlatButton()
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
        #endif
    }

    @ViewBuilder
    private var sortControl: some View {
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { choosingSort = true }) {
            StreamingSortLabel(sort: sort)
        }
        #else
        Menu {
            Picker("Sort By", selection: sortBinding) {
                ForEach(StreamingSort.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
        } label: {
            StreamingSortLabel(sort: sort)
        }
        .accessibilityLabel("Sort by \(sort.label)")
        #endif
    }

    @ViewBuilder
    private func cell(_ item: MediaItem) -> some View {
        #if os(tvOS)
        TVSelectable(drawsFocusChrome: false, action: { pushed = item }) {
            MediaItemCard(item: item, shape: .poster)
        }
        #else
        NavigationLink(value: item) { MediaItemCard(item: item, shape: .poster) }
            .lineupFlatButton()
        #endif
    }
}

// MARK: - Every service

/// The whole row, from its See All: every service with something to play.
struct StreamingServicesScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    #if os(tvOS)
    @State private var pushed: MediaItem?
    #endif

    private var services: [MediaItem] { media.streamingShelf?.items ?? [] }

    var body: some View {
        Group {
            if services.isEmpty {
                ContentUnavailableView("Nothing to Play Yet", systemImage: "play.slash",
                    description: Text("None of what the streaming services have on right now is on your servers or your IPTV provider."))
                    .mediaFocusAnchor()
            } else {
                ScrollView {
                    LazyVGrid(columns: Metrics.columns, spacing: Metrics.gridSpacing) {
                        ForEach(services, id: \.libraryKey) { item in
                            #if os(tvOS)
                            TVSelectable(drawsFocusChrome: false, action: { pushed = item }) {
                                MediaItemCard(item: item, shape: .poster)
                            }
                            #else
                            NavigationLink(value: item) { MediaItemCard(item: item, shape: .poster) }
                                .lineupFlatButton()
                            #endif
                        }
                    }
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, Metrics.topInset)
                    .lineupFocusRegion()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        #if os(tvOS)
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        #else
        .navigationTitle(StreamingService.rowTitle)
        .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
        #endif
    }
}

// MARK: - Pieces

/// A service screen's last ordering, kept across redraws.
private final class StreamingOrderMemo {
    var key = ""
    var items: [MediaItem] = []
}

/// Movies or TV Shows, and how many of each: the chosen one is filled.
private struct StreamingChip: View {
    let title: String
    let count: Int
    let active: Bool
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var focused
    #endif

    var body: some View {
        HStack(spacing: Metrics.chipCountGap) {
            Text(title).font(.inter(Metrics.chipSize, .bold))
            Text("\(count)").font(.interDigits(Metrics.chipSize, .bold)).opacity(0.55)
        }
        .padding(.horizontal, Metrics.chipPadding)
        .frame(height: Metrics.chipHeight)
        #if os(tvOS)
        .foregroundStyle(active ? activeText : LineupStyle.text)
        .background(Capsule().fill(active ? activeFill : LineupStyle.surface))
        .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: active ? 0 : 1))
        .lineupFocusLayer(focused && !active, in: Capsule())
        #else
        // Filled with the accent when chosen, its outline otherwise.
        .foregroundStyle(active ? activeText : LineupStyle.highlight)
        .background(Capsule().fill(active ? activeFill : Color.clear))
        .overlay(Capsule().strokeBorder(active ? Color.clear : LineupStyle.highlight, lineWidth: 1.5))
        #endif
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.18), value: active)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// The phone's chosen accent, the television's white.
    private var activeFill: Color {
        #if os(tvOS)
        .white
        #else
        LineupStyle.highlight
        #endif
    }

    private var activeText: Color {
        #if os(tvOS)
        LineupStyle.background
        #else
        LineupStyle.onHighlight
        #endif
    }
}

/// The order in use, and that it can be changed.
private struct StreamingSortLabel: View {
    let sort: StreamingSort
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var focused
    #endif

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: Metrics.chipSize - 3, weight: .bold))
                .foregroundStyle(LineupStyle.secondary)
            Text(sort.label).font(.inter(Metrics.chipSize, .semibold)).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: Metrics.chipSize - 5, weight: .bold))
                .foregroundStyle(LineupStyle.secondary)
        }
        .foregroundStyle(LineupStyle.text)
        .padding(.horizontal, Metrics.chipPadding)
        .frame(height: Metrics.chipHeight)
        .background(Capsule().fill(LineupStyle.surface))
        .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 1))
        #if os(tvOS)
        .lineupFocusLayer(focused, in: Capsule())
        #endif
        .contentShape(Capsule())
    }
}

private enum Metrics {
    #if os(tvOS)
    static let inset: CGFloat = 70
    static let topInset: CGFloat = 30
    static let sectionGap: CGFloat = 30
    static let headerGap: CGFloat = 16
    static let summarySize: CGFloat = 22
    static let chipSize: CGFloat = 22
    static let chipHeight: CGFloat = 54
    static let chipPadding: CGFloat = 24
    static let chipGap: CGFloat = 16
    static let chipCountGap: CGFloat = 10
    static let gridSpacing: CGFloat = 30
    static let columns = [GridItem(.adaptive(minimum: 250, maximum: 310), spacing: 24)]
    #else
    static let inset: CGFloat = 16
    static let topInset: CGFloat = 8
    static let sectionGap: CGFloat = 16
    static let headerGap: CGFloat = 6
    static let summarySize: CGFloat = 13
    static let chipSize: CGFloat = 14
    static let chipHeight: CGFloat = 34
    static let chipPadding: CGFloat = 14
    static let chipGap: CGFloat = 8
    static let chipCountGap: CGFloat = 6
    static let gridSpacing: CGFloat = 20
    static let columns = [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 14)]
    #endif
}
