import SwiftUI

struct MediaServersView: View {
    @EnvironmentObject private var media: MediaLibrary
    @State private var addingServer = false

    var body: some View {
        NavigationStack {
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
                } else if media.catalogs.isEmpty && media.isLoading {
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
            .sheet(isPresented: $addingServer) {
                MediaServerSetupView()
                    .environmentObject(media)
                    .preferredColorScheme(.dark)
            }
            .task {
                if media.activeProfile != nil && media.catalogs.isEmpty { await media.reload() }
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
            } else if media.catalogs.isEmpty && media.isLoading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Loading your libraries…").font(.headline)
                }
                .foregroundStyle(NullSportsStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if media.catalogs.isEmpty {
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: catalogSpacing) {
                        ForEach(catalogs) { catalog in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(catalog.title).font(sectionTitleFont)
                                    Spacer()
                                    NavigationLink(value: catalog.root) {
                                        Label("See All", systemImage: "chevron.right").font(.system(size: 14, weight: .semibold))
                                    }.buttonStyle(.plain)
                                }
                                if catalog.items.isEmpty {
                                    Text("No titles in this catalog.").font(.callout)
                                        .foregroundStyle(NullSportsStyle.lightPurple.opacity(0.58)).frame(height: 64)
                                } else {
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
                                }
                            }
                        }
                    }
                    .padding(.horizontal, horizontalPadding).padding(.bottom, 44)
                }
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
    @EnvironmentObject private var media: MediaLibrary
    let item: MediaItem
    @State private var playing = false

    var body: some View {
        Button { playing = true } label: { MediaItemCard(item: item) }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $playing) {
                if let url = media.playbackURL(for: item) {
                    #if os(tvOS)
                    PlayerView(urls: [url], title: item.name, isLive: false)
                    #else
                    MobilePlayerView(name: item.name, urls: [url])
                    #endif
                } else {
                    ContentUnavailableView("Playback Unavailable", systemImage: "play.slash")
                }
            }
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
            .aspectRatio(item.primaryImageAspectRatio ?? 2 / 3, contentMode: .fit)
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
