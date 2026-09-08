import SwiftUI

struct MobileGuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var category: String?
    @State private var favorites = false
    @State private var window = MobileGuideWindow(now: .now)
    @State private var horizontalOffset: CGFloat = 0
    @State private var resetPosition = UUID()
    @ScaledMetric(relativeTo: .body) private var rowHeight = 88.0
    var game: SportsGame? = nil
    let onPlay: (XtreamStream) -> Void
    private let logoWidth: CGFloat = 96

    private var channels: [XtreamStream] {
        library.guideStreams(categoryID: category, favoritesOnly: favorites, query: query)
    }
    private var title: String {
        if game != nil { return "Choose a channel" }
        if favorites { return "Favorites" }
        return library.categories.first { $0.id == category }?.categoryName ?? "Guide"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let game {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(game.awayTeam) vs. \(game.homeTeam)").font(.subheadline.bold())
                        Text("Choose a channel · \(game.broadcast.isEmpty ? "Network unavailable" : game.broadcast)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                if library.isLoading || library.isGuideLoading {
                    ProgressView("Updating guide…").font(.caption).padding(8)
                }
                if channels.isEmpty {
                    ContentUnavailableView("No channels", systemImage: "tv",
                        description: Text("Try another category or search, or refresh your guide."))
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { clock in
                        guide(now: clock.date)
                    }
                }
            }
            .background(NullSportsStyle.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search channels")
            .toolbar {
                if game != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Now", systemImage: "clock.arrow.circlepath") { returnToNow() }
                    Menu {
                        Toggle("Favorites only", isOn: $favorites)
                        Picker("Category", selection: $category) {
                            Text("All channels").tag(nil as String?)
                            ForEach(library.categories) { Text($0.categoryName).tag(Optional($0.id)) }
                        }
                        Button("Refresh guide", systemImage: "arrow.clockwise") {
                            Task { await library.reload() }
                        }.disabled(library.channelsAreSyncing)
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("Guide filters")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && Date() >= window.end { returnToNow() }
            }
        }
    }

    private func returnToNow() {
        window = MobileGuideWindow(now: .now)
        horizontalOffset = 0
        resetPosition = UUID()
    }

    private func guide(now: Date) -> some View {
        GeometryReader { viewport in
            // One horizontal scroller moves every program row and the ruler together.
            // The nested vertical scroller moves logos and programs as a single row.
            // Counter-offset logo tiles keep the channel column frozen horizontally.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    ruler(now: now)
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(channels) { stream in
                                HStack(spacing: 0) {
                                    channelTile(stream)
                                        .offset(x: horizontalOffset).zIndex(2)
                                    programRow(stream, now: now, viewportWidth: viewport.size.width - logoWidth)
                                }.frame(height: rowHeight)
                            }
                        }
                    }
                    .frame(height: max(0, viewport.size.height - 40))
                    .refreshable { await library.reload() }
                }
                .frame(width: logoWidth + window.width)
                .background {
                    GeometryReader { position in
                        Color.clear.preference(key: GuideHorizontalPosition.self,
                            value: position.frame(in: .named("guideHorizontal")).minX)
                    }
                }
            }
            .coordinateSpace(name: "guideHorizontal")
            .onPreferenceChange(GuideHorizontalPosition.self) { value in
                horizontalOffset = max(0, -value)
            }
            .id(resetPosition)
        }
    }

    private func ruler(now: Date) -> some View {
        HStack(spacing: 0) {
            Text(Calendar.current.isDateInToday(window.start) ? "Today" : window.start.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption.bold()).frame(width: logoWidth, height: 40)
                .background(NullSportsStyle.background)
                .offset(x: horizontalOffset).zIndex(2)
            ZStack(alignment: .topLeading) {
                ForEach(window.ticks, id: \.self) { date in
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption.bold()).monospacedDigit()
                        .padding(.leading, 7).frame(width: 110, height: 32, alignment: .leading)
                        .offset(x: window.x(date))
                }
                if now >= window.start && now < window.end {
                    Image(systemName: "triangle.fill").font(.system(size: 10))
                        .rotationEffect(.degrees(180))
                        .foregroundStyle(NullSportsStyle.guidePlayhead)
                        .offset(x: window.x(now) - 5, y: 28)
                        .accessibilityLabel("Current time")
                }
            }.frame(width: window.width, height: 40, alignment: .topLeading)
        }
        .background(NullSportsStyle.background)
        .overlay(alignment: .bottom) { Rectangle().fill(NullSportsStyle.line).frame(height: 1) }
    }

    private func channelTile(_ stream: XtreamStream) -> some View {
        Button { onPlay(stream) } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(NullSportsStyle.raised)
                AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(10)
                    } else {
                        Text(stream.name).font(.caption.bold()).lineLimit(3)
                            .multilineTextAlignment(.center).padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if library.isFavorite(stream) {
                    Image(systemName: "star.fill").font(.caption2)
                        .padding(4).background(NullSportsStyle.background.opacity(0.85), in: Circle())
                        .padding(3)
                }
            }
            .frame(width: logoWidth - 10, height: rowHeight - 10)
            .padding(5).background(NullSportsStyle.background)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch \(stream.name) live\(library.isFavorite(stream) ? ", favorite" : "")")
        .contextMenu {
            Button(library.isFavorite(stream) ? "Remove favorite" : "Add favorite", systemImage: "star") {
                if library.isFavorite(stream) { library.removeFavorite(stream) }
                else { library.addFavorite(stream) }
            }
        }
    }

    private func programRow(_ stream: XtreamStream, now: Date, viewportWidth: CGFloat) -> some View {
        let programs = library.guidePrograms(for: stream)
        let segments = window.segments(programs.map { (start: $0.start, end: $0.end) })
        return ZStack(alignment: .leading) {
            ForEach(segments) { segment in
                let program = segment.programIndex.map { programs[$0] }
                let cellX = window.x(segment.start)
                let width = max(1, window.x(segment.end) - cellX - 5)
                let textInset = min(max(0, horizontalOffset - cellX), max(0, width - 24))
                let live = program.map { $0.start <= now && now < $0.end } ?? false
                Button { onPlay(stream) } label: {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(live ? NullSportsStyle.selected : NullSportsStyle.surface)
                        if program != nil {
                            Rectangle().fill(NullSportsStyle.lightPurple.opacity(0.13))
                                .frame(width: min(width, max(0, window.x(now) - cellX)))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(stream.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if let program {
                                    Text(program.start, format: .dateTime.hour().minute()).lineLimit(1)
                                }
                            }.font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(program?.title ?? "No guide information")
                                .font(.subheadline.bold()).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if live || program?.isNew == true {
                                Text(live ? "LIVE" : "NEW").font(.system(size: 9, weight: .bold)).tracking(2)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(width: max(1, min(width - textInset, viewportWidth)), alignment: .leading)
                        .offset(x: textInset)
                    }
                    .frame(width: width, height: rowHeight - 10)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Watch \(stream.name) live. \(program?.title ?? "No guide information")")
                .offset(x: cellX)
            }
            if now >= window.start && now < window.end {
                Rectangle().fill(NullSportsStyle.guidePlayhead.opacity(0.5))
                    .frame(width: 1, height: rowHeight).offset(x: window.x(now))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }.frame(width: window.width, height: rowHeight, alignment: .leading)
    }
}

private struct GuideHorizontalPosition: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
