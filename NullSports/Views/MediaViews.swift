import SwiftUI

struct MediaServersView: View {
    @EnvironmentObject private var media: MediaLibrary
    @State private var addingServer = false

    var body: some View {
        NavigationStack {
            Group {
            #if os(tvOS)
            TVMediaServersHome(addingServer: $addingServer)
            #else
            Group {
                if media.activeProfile == nil {
                    ContentUnavailableView {
                        Label("Connect a Media Server", systemImage: "play.square.stack")
                    } description: {
                        Text("Browse your Jellyfin library or connect Nullfin for addon-powered catalogs and streams.")
                    } actions: {
                        Button("Add Media Server", systemImage: "plus") { addingServer = true }
                    }
                } else if media.roots.isEmpty && media.isLoading {
                    ProgressView("Loading libraries…")
                } else {
                    MediaCatalogsScreen(catalogs: media.catalogs)
                }
            }
            .background(NullSportsStyle.background.ignoresSafeArea())
            .navigationTitle("Media Servers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus") { addingServer = true }
                }
            }
            #endif
            }
            .sheet(isPresented: $addingServer) {
                MediaServerSetupView()
                    .environmentObject(media)
                    .preferredColorScheme(.dark)
            }
            .task {
                if media.activeProfile != nil && media.roots.isEmpty { await media.reload() }
            }
            .alert("Media Server", isPresented: Binding(
                get: { media.errorMessage != nil },
                set: { if !$0 { media.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(media.errorMessage ?? "Unknown error") }
        }
    }
}

#if os(tvOS)
private struct TVMediaServersHome: View {
    @EnvironmentObject private var media: MediaLibrary
    @Binding var addingServer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MEDIA SERVERS")
                        .font(.system(size: 13, weight: .bold)).tracking(2.2)
                        .foregroundStyle(NullSportsStyle.lightPurple.opacity(0.62))
                    Text(media.activeProfile?.name ?? "Your library")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(NullSportsStyle.lightPurple)
                }
                Spacer()
                if let profile = media.activeProfile {
                    Label(profile.username, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NullSportsStyle.lightPurple.opacity(0.72))
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(NullSportsStyle.surface, in: Capsule())
                }
                Button { Task { await media.reload() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 42, height: 42)
                }
                .buttonStyle(TVMediaHeaderButtonStyle()).disabled(media.isLoading || media.activeProfile == nil)
                Button { addingServer = true } label: {
                    Label("Add Server", systemImage: "plus").padding(.horizontal, 4).frame(height: 42)
                }
                .buttonStyle(TVMediaHeaderButtonStyle())
            }
            .padding(.horizontal, 54).padding(.top, 18)

            if media.activeProfile == nil {
                TVMediaEmptyState { addingServer = true }
            } else if media.roots.isEmpty && media.isLoading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Loading your libraries…").font(.headline)
                }
                .foregroundStyle(NullSportsStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if media.roots.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.exclamationmark").font(.system(size: 42, weight: .light))
                    Text("No libraries found").font(.title2.weight(.semibold))
                    Text("Refresh the server, or confirm this account can access a library.")
                        .font(.callout).opacity(0.68)
                }
                .foregroundStyle(NullSportsStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaCatalogsScreen(catalogs: media.catalogs)
            }
        }
        .background(
            ZStack {
                NullSportsStyle.background
                RadialGradient(colors: [NullSportsStyle.lightPurple.opacity(0.055), .clear],
                    center: .topTrailing, startRadius: 30, endRadius: 760)
            }.ignoresSafeArea()
        )
    }
}

private struct TVMediaEmptyState: View {
    let add: () -> Void
    var body: some View {
        HStack(spacing: 34) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(NullSportsStyle.surface)
                Image(systemName: "play.square.stack.fill")
                    .font(.system(size: 72, weight: .light)).foregroundStyle(NullSportsStyle.lightPurple)
            }
            .frame(width: 210, height: 150)
            VStack(alignment: .leading, spacing: 12) {
                Text("Bring your media to the big screen.")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text("Connect Jellyfin or Nullfin to browse libraries, addon catalogs, and streams.")
                    .font(.system(size: 18)).opacity(0.68).frame(maxWidth: 590, alignment: .leading)
                Button("Connect a Server", systemImage: "plus", action: add)
                    .buttonStyle(NullSportsButtonStyle()).focusEffectDisabled().padding(.top, 6)
            }
            .foregroundStyle(NullSportsStyle.lightPurple)
        }
        .padding(42)
        .background(NullSportsStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(NullSportsStyle.line, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 90).padding(.bottom, 80)
    }
}

private struct TVMediaHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderLabel(configuration: configuration)
    }
    private struct HeaderLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: ButtonStyle.Configuration
        var body: some View {
            configuration.label
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(focused ? NullSportsStyle.background : NullSportsStyle.lightPurple)
                .padding(.horizontal, 14).frame(minHeight: 42)
                .background(focused ? NullSportsStyle.lightPurple : NullSportsStyle.surface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .scaleEffect(focused ? 1.055 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: focused)
        }
    }
}
#endif

private struct MediaCatalogsScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let catalogs: [MediaCatalog]
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").opacity(0.58)
                    TextField("Search movies, shows, and addon catalogs", text: $query).textFieldStyle(.plain)
                    if searching { ProgressView().controlSize(.small) }
                    if !query.isEmpty {
                        Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                }
                .font(searchFont).padding(.horizontal, 16).frame(height: searchHeight)
                .background(NullSportsStyle.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(NullSportsStyle.line, lineWidth: 1))
                Menu {
                    if media.availableShelves.isEmpty {
                        Button("All available shelves are visible") { }.disabled(true)
                    } else {
                        ForEach(media.availableShelves) { root in
                            Button(root.name, systemImage: "plus") { Task { await media.addShelf(root) } }
                        }
                    }
                } label: {
                    Label("Add Shelf", systemImage: "plus.rectangle.on.rectangle")
                        .font(.system(size: 16, weight: .semibold)).padding(.horizontal, 10).frame(height: searchHeight)
                }
            }
            .padding(.horizontal, horizontalPadding).padding(.bottom, 18)

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if searching && results.isEmpty {
                    ProgressView("Searching connected addons…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let searchError {
                    ContentUnavailableView("Search Unavailable", systemImage: "exclamationmark.triangle", description: Text(searchError))
                } else if results.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                        description: Text("No connected catalog or metadata addon returned a match."))
                } else {
                    MediaGridScreen(title: "Search Results", items: results)
                }
            } else {
                if catalogs.isEmpty {
                    ContentUnavailableView("Choose Your Shelves", systemImage: "rectangle.stack.badge.plus",
                        description: Text("Add only the catalogs you want. Trending Movies and Trending TV are selected automatically when the server provides them."))
                } else { ScrollView {
                    LazyVStack(alignment: .leading, spacing: catalogSpacing) {
                        ForEach(catalogs) { catalog in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(catalog.title).font(sectionTitleFont)
                                    Spacer()
                                    Button { media.removeShelf(catalog) } label: {
                                        Image(systemName: "minus.circle").accessibilityLabel("Remove \(catalog.title) shelf")
                                    }.buttonStyle(.plain)
                                    NavigationLink(value: catalog.root) {
                                        Label("See All", systemImage: "chevron.right").font(.system(size: 14, weight: .semibold))
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, horizontalPadding)
                                if catalog.items.isEmpty {
                                    Text("No titles in this catalog.").font(.callout)
                                        .foregroundStyle(NullSportsStyle.lightPurple.opacity(0.58)).frame(height: 64)
                                        .padding(.horizontal, horizontalPadding)
                                } else {
                                    // The shelf spans the full width and insets its
                                    // content instead, so a card scrolls away at the
                                    // screen edge rather than being clipped by the
                                    // margin with the first one cut in half at rest.
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        LazyHStack(alignment: .top, spacing: itemSpacing) {
                                            ForEach(catalog.items) { item in
                                                Group {
                                                    if item.isFolder {
                                                        NavigationLink(value: item) { MediaItemCard(item: item) }.buttonStyle(.plain)
                                                    } else { MediaPlayableCard(item: item) }
                                                }.frame(width: cardWidth)
                                            }
                                        }
                                        .padding(.vertical, 8)
                                    }
                                    .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 44)
                } }
            }
        }
        .foregroundStyle(NullSportsStyle.lightPurple)
        .navigationDestination(for: MediaItem.self) { folder in MediaFolderScreen(folder: folder) }
        .task(id: query) {
            let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { results = []; searching = false; searchError = nil; return }
            searching = true
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            do {
                let found = try await media.search(value)
                guard !Task.isCancelled else { return }
                results = found; searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []; searchError = error.localizedDescription
            }
            searching = false
        }
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        54
        #else
        16
        #endif
    }
    private var catalogSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        26
        #endif
    }
    private var itemSpacing: CGFloat {
        #if os(tvOS)
        22
        #else
        14
        #endif
    }
    private var cardWidth: CGFloat {
        #if os(tvOS)
        230
        #else
        150
        #endif
    }
    private var sectionTitleFont: Font {
        #if os(tvOS)
        .system(size: 24, weight: .semibold, design: .rounded)
        #else
        .title3.weight(.bold)
        #endif
    }
    private var searchFont: Font {
        #if os(tvOS)
        .system(size: 19, weight: .medium)
        #else
        .body
        #endif
    }
    private var searchHeight: CGFloat {
        #if os(tvOS)
        54
        #else
        46
        #endif
    }
}

private struct MediaGridScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let title: String
    let items: [MediaItem]

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(items) { item in
                    if item.isFolder {
                        NavigationLink(value: item) { MediaItemCard(item: item) }
                            .buttonStyle(.plain)
                    } else {
                        MediaPlayableCard(item: item)
                    }
                }
            }
            .padding(.horizontal, horizontalPadding).padding(.vertical, 28)
        }
    }

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        grid.navigationDestination(for: MediaItem.self) { folder in MediaFolderScreen(folder: folder) }
        #else
        grid.navigationTitle(title)
            .navigationDestination(for: MediaItem.self) { folder in MediaFolderScreen(folder: folder) }
        #endif
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 250, maximum: 310), spacing: 24)]
        #else
        [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 14)]
        #endif
    }
    private var gridSpacing: CGFloat {
        #if os(tvOS)
        30
        #else
        20
        #endif
    }
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        70
        #else
        16
        #endif
    }
}

private struct MediaFolderScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let folder: MediaItem
    @State private var items: [MediaItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading { ProgressView("Loading \(folder.name)…") }
            else if let error {
                ContentUnavailableView("Couldn’t Load Library", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if items.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "film.stack",
                    description: Text("This library did not return any playable items."))
            } else {
                MediaGridScreen(title: folder.name, items: items)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NullSportsStyle.background.ignoresSafeArea())
        .task(id: folder.id) {
            loading = true
            do { items = try await media.items(in: folder); error = nil }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct MediaPlayableCard: View {
    let item: MediaItem
    @State private var choosingSource = false

    var body: some View {
        Button { choosingSource = true } label: { MediaItemCard(item: item) }
            .buttonStyle(.plain)
            .sheet(isPresented: $choosingSource) {
                MediaSourcePicker(item: item)
            }
    }
}

private struct MediaSourcePicker: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var sources: [MediaPlaybackSource] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedSource: MediaPlaybackSource?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Finding the best streams…").font(.headline)
                        Text("Connected addons are ranking results for \(item.name).")
                            .font(.subheadline).foregroundStyle(NullSportsStyle.lightPurple.opacity(0.62))
                    }
                } else if let error {
                    ContentUnavailableView("Streams Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if sources.isEmpty {
                    ContentUnavailableView("No Streams Found", systemImage: "play.slash",
                        description: Text("None of the connected streaming addons returned a playable result."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: rowSpacing) {
                            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                                Button { selectedSource = source } label: {
                                    MediaSourceRow(source: source, rank: index + 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, horizontalPadding).padding(.vertical, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NullSportsStyle.background.ignoresSafeArea())
            .foregroundStyle(NullSportsStyle.lightPurple)
            .navigationTitle(item.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: dismiss.callAsFunction) }
            }
        }
        .task(id: item.id) {
            loading = true
            do { sources = try await media.playbackSources(for: item); error = nil }
            catch { self.error = error.localizedDescription }
            loading = false
        }
        .fullScreenCover(item: $selectedSource) { source in
            if let url = media.playbackURL(for: item, source: source) {
                #if os(tvOS)
                PlayerView(urls: [url], title: item.name, isLive: false)
                #else
                MobilePlayerView(name: item.name, urls: [url])
                #endif
            } else { ContentUnavailableView("Playback Unavailable", systemImage: "play.slash") }
        }
    }

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        16
        #else
        10
        #endif
    }
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        70
        #else
        16
        #endif
    }
}

private struct MediaSourceRow: View {
    @Environment(\.isFocused) private var focused
    let source: MediaPlaybackSource
    let rank: Int

    var body: some View {
        HStack(spacing: 14) {
            Text("#\(rank)")
                .font(.system(.subheadline, design: .rounded, weight: .bold)).monospacedDigit()
                .foregroundStyle(focused ? NullSportsStyle.background.opacity(0.65) : NullSportsStyle.lightPurple.opacity(0.48))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text(source.releaseName).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(source.provider).font(.caption.weight(.semibold))
                    if let quality = source.quality { sourceBadge(quality) }
                    if let size = source.formattedSize { sourceBadge(size) }
                    if let container = source.container?.split(separator: ",").first { sourceBadge(String(container).uppercased()) }
                }
                .foregroundStyle(focused ? NullSportsStyle.background.opacity(0.72) : NullSportsStyle.lightPurple.opacity(0.58))
            }
            Spacer(minLength: 10)
            if let score = source.score {
                VStack(spacing: 1) {
                    Text(score >= 0 ? "+\(score)" : "\(score)")
                        .font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
                    Text("SCORE").font(.system(size: 9, weight: .bold)).tracking(1.2)
                }
                .foregroundStyle(focused ? NullSportsStyle.background : NullSportsStyle.lightPurple)
            }
            Image(systemName: "play.fill").font(.headline)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(focused ? NullSportsStyle.lightPurple : NullSportsStyle.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(NullSportsStyle.line, lineWidth: focused ? 0 : 1))
        .foregroundStyle(focused ? NullSportsStyle.background : NullSportsStyle.lightPurple)
        .scaleEffect(focused ? 1.018 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }

    private func sourceBadge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background((focused ? NullSportsStyle.background : NullSportsStyle.lightPurple).opacity(0.1), in: Capsule())
    }
}

private struct MediaItemCard: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.isFocused) private var focused
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LinearGradient(colors: [NullSportsStyle.raised, NullSportsStyle.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                AsyncImage(url: media.imageURL(for: item)) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Image(systemName: item.isFolder ? "rectangle.stack.fill" : "film.fill").font(.largeTitle) }
                }
            }
            // Servers report a per-item ratio, so honouring it gave a shelf a mix
            // of tall posters and short backdrops. One poster shape for every card
            // keeps a row on a single baseline; the art fills and crops to it.
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cardRadius).stroke(
                focused ? NullSportsStyle.lightPurple.opacity(0.9) : NullSportsStyle.line, lineWidth: focused ? 2 : 1))
            Text(item.name).font(titleFont).lineLimit(2)
            HStack(spacing: 7) {
                Text(item.type.uppercased())
                if let year = item.productionYear { Text("· \(String(year))") }
                if let count = item.childCount { Text("· \(count)") }
            }
            .font(.caption2.weight(.medium)).foregroundStyle(NullSportsStyle.lightPurple.opacity(0.58))
        }
        .foregroundStyle(NullSportsStyle.lightPurple)
        .focusLift(focused, scale: 1.035)
    }

    private var cardRadius: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .headline
        #else
        .subheadline.weight(.semibold)
        #endif
    }
}

struct MediaServerSetupView: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Jellyfin-Compatible Server") {
                    TextField("Display name", text: $name)
                    TextField("Server URL", text: $server)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
                Section {
                    Button(media.isLoading ? "Connecting…" : "Connect") {
                        Task {
                            if await media.addServer(name: name, serverURL: server,
                                username: username, password: password) { dismiss() }
                        }
                    }
                    .disabled(media.isLoading
                        || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || password.isEmpty)
                } footer: {
                    Text("Supports Jellyfin and Nullfin. Nullfin libraries include catalogs and streams from the addons configured on your server. Access tokens are stored securely in this device’s Keychain.")
                }
                if let error = media.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Media Server")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .disabled(media.isLoading)
        }
    }
}

struct InitialSourceSetupView: View {
    @State private var addingIPTV = false
    @State private var addingMedia = false

    var body: some View {
        VStack(spacing: 30) {
            PageTitle(eyebrow: "NULLSPORTS", title: "Bring your streams together.",
                detail: "Connect live television, your own media library, or both.")
            #if os(tvOS)
            HStack(spacing: 24) {
                Button { addingIPTV = true } label: {
                    Label("Add IPTV Provider", systemImage: "dot.radiowaves.left.and.right")
                }
                Button { addingMedia = true } label: {
                    Label("Add Media Server", systemImage: "play.square.stack")
                }
            }
            .buttonStyle(NullSportsButtonStyle())
            #else
            VStack(spacing: 14) {
                Button { addingIPTV = true } label: {
                    Label("Add IPTV Provider", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                Button { addingMedia = true } label: {
                    Label("Add Media Server", systemImage: "play.square.stack")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(NullSportsButtonStyle())
            #endif
        }
        .padding(setupPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NullSportsStyle.background)
        .sheet(isPresented: $addingIPTV) {
            #if os(iOS)
            ProfileSetupView(addingProvider: true)
            #else
            ProfileSetupView()
            #endif
        }
        .sheet(isPresented: $addingMedia) { MediaServerSetupView() }
    }

    private var setupPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        24
        #endif
    }
}
