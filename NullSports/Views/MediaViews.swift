import SwiftUI

struct MediaServersView: View {
    @EnvironmentObject private var media: MediaLibrary
    @State private var addingServer = false

    var body: some View {
        NavigationStack {
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
                    MediaGridScreen(title: media.activeProfile?.name ?? "Media Servers", items: media.roots)
                }
            }
            .background(NullSportsStyle.background.ignoresSafeArea())
            .navigationTitle("Media Servers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus") { addingServer = true }
                }
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

private struct MediaGridScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let title: String
    let items: [MediaItem]

    var body: some View {
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
        .navigationTitle(title)
        .navigationDestination(for: MediaItem.self) { folder in
            MediaFolderScreen(folder: folder)
        }
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
                    PlayerView(urls: [url])
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
                    .disabled(media.isLoading || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
