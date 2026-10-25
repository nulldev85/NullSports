import SwiftUI

struct SeerrTitleRoute: Identifiable {
    let id: Int
    let kind: SeerrMediaKind
    let title: String
}

/// Request the same externally identified title, never a guessed name match.
struct SeerrLibraryRequestView: View {
    @Environment(MediaLibrary.self) private var media
    let item: MediaItem
    @State private var route: SeerrTitleRoute?
    @State private var loading = true
    var body: some View {
        Group {
            if let route { SeerrTitleView(id: route.id, kind: route.kind, initialTitle: route.title) }
            else if loading { ProgressView("Matching title…") }
            else {
                IntegrationPage(title: "Find in Seerr", symbol: "magnifyingglass", detail: "An exact TMDB identity was not available for this title.") {
                    NavigationLink { SeerrBrowserView() } label: { Text("Search Seerr") }.lineupButtonStyle()
                }
            }
        }.task(id: item.libraryKey) {
            defer { loading = false }
            let original: MediaItem
            if item.type == "Episode" { original = await media.metadataParent(for: item) ?? item }
            else { original = item }
            let identified = await media.libraryExternalIdentity(original, requiring: "tmdb")
            guard !Task.isCancelled, let raw = LibraryMetadataIdentity.ids(identified)["tmdb"], let id = Int(raw), id > 0 else { return }
            route = SeerrTitleRoute(id: id, kind: original.isSeries || item.type == "Episode" ? .tv : .movie, title: original.name)
        }
    }
}

struct IntegrationPage<Content: View>: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LineupPresentationHeading(title: title, symbol: symbol, detail: detail)
                content
            }
            .frame(maxWidth: width, alignment: .leading)
            .padding(inset).frame(maxWidth: .infinity)
        }
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .lineupPresentation()
    }
    private var width: CGFloat {
        #if os(tvOS)
        1320
        #else
        650
        #endif
    }
    private var inset: CGFloat {
        #if os(tvOS)
        52
        #else
        20
        #endif
    }
}

struct IntegrationField: View {
    let title: String
    @Binding var text: String
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.inter(.caption, .heavy)).foregroundStyle(LineupPresentationStyle.secondary)
            Group {
                if secure { SecureField(title, text: $text) }
                else { TextField(title, text: $text) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .font(.inter(.body, .semibold)).padding(14)
            .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct IntegrationAction: View {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.inter(.body, .heavy))
                .foregroundStyle(destructive ? LineupPresentationStyle.destructive : LineupPresentationStyle.text)
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.lineupButtonStyle()
    }
}

struct IntegrationErrorText: View {
    let message: String?
    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.inter(.callout, .semibold)).foregroundStyle(LineupPresentationStyle.destructive)
                .fixedSize(horizontal: false, vertical: true).accessibilityLabel(message)
        }
    }
}

private struct IntegrationPosterFocus: ViewModifier {
    @Environment(\.isFocused) private var focused
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content.padding(8)
            .background(LineupPresentationStyle.card, in: shape)
            .lineupFocusLayer(focused, in: shape)
            .scaleEffect(focused ? 1.035 : 1)
            .animation(.easeOut(duration: 0.16), value: focused)
    }
}

struct SeerrSettingsView: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Seerr"
    @State private var address = ""
    @State private var email = ""
    @State private var password = ""
    @State private var key = ""
    @State private var method: SeerrSignInMethod = .local
    @State private var pinCode: String?
    @State private var linkingPlex: Task<Void, Never>?
    @State private var plexRequestID = UUID()
    @State private var plexError: String?
    @State private var editing = false
    @State private var confirmingDisconnect = false

    var body: some View {
        IntegrationPage(title: "Seerr", symbol: "tray.and.arrow.down", detail: "Discover movies and series, request missing titles, and follow their availability.") {
            if let connection = media.seerr.connection {
                VStack(alignment: .leading, spacing: 12) {
                    Text(connection.name).font(.inter(.title2, .heavy))
                    Text(media.seerr.user?.name ?? "Connected").foregroundStyle(LineupPresentationStyle.secondary)
                    Text(connection.address).font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
                    NavigationLink { SeerrBrowserView() } label: { Label("Discover & Request", systemImage: "sparkles") }.lineupButtonStyle()
                    NavigationLink { SeerrRequestsView() } label: { Label("Requests", systemImage: "tray.full") }.lineupButtonStyle()
                    IntegrationAction(title: "Reconnect", symbol: "arrow.clockwise") { editing.toggle() }
                    IntegrationAction(title: "Disconnect", symbol: "link.badge.minus", destructive: true) { confirmingDisconnect = true }
                }.padding(20).lineupPresentationSurface(RoundedRectangle(cornerRadius: 20))
            }
            if !media.seerr.isConnected || editing {
                VStack(spacing: 16) {
                    IntegrationField(title: "Display name", text: $name)
                    IntegrationField(title: "Server address", text: $address)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(SeerrSignInMethod.allCases, id: \.self) { choice in
                                IntegrationAction(title: (method == choice ? "✓ " : "") + choice.title, symbol: "person.crop.circle") { method = choice }
                            }
                        }
                    }.scrollIndicators(.hidden)
                    if method == .plex {
                        if let pinCode {
                            Text(pinCode).font(.inter(40, .heavy))
                            Text("Open plex.tv/link on another device and enter this code to sign in to Seerr.")
                                .font(.inter(.callout)).foregroundStyle(LineupPresentationStyle.secondary)
                        }
                        IntegrationAction(title: linkingPlex != nil ? "Waiting for Plex…" : "Sign In with Plex", symbol: "link") { linkPlex() }
                            .disabled(linkingPlex != nil || media.seerr.isConnecting || address.isEmpty)
                        if linkingPlex != nil { IntegrationAction(title: "Cancel Link", symbol: "xmark") { cancelPlexLink() } }
                        IntegrationErrorText(message: plexError)
                    } else {
                        if method == .apiKey { IntegrationField(title: "API key", text: $key, secure: true) }
                        else {
                            IntegrationField(title: method == .local ? "Seerr email" : "Username", text: $email)
                            IntegrationField(title: "Password", text: $password, secure: true)
                        }
                        IntegrationAction(title: media.seerr.isConnecting ? "Connecting…" : "Connect Seerr", symbol: "link") {
                            Task {
                                if await media.seerr.connect(name: name, address: address, apiKey: method == .apiKey ? key : "", email: email, password: password, method: method) {
                                    key = ""; password = ""; editing = false
                                }
                            }
                        }.disabled(media.seerr.isConnecting || address.isEmpty || (method == .apiKey ? key.isEmpty : email.isEmpty || (method == .local && password.isEmpty)))
                    }
                    Text("Connect an account enabled on your configured Seerr server, or use its API key. Plex uses a code; Jellyfin and Emby use the server already linked to Seerr. Your session stays in this device’s Keychain. Seerr controls permissions, approvals and quotas.")
                        .font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
                }.padding(20).lineupPresentationSurface(RoundedRectangle(cornerRadius: 20))
            }
            IntegrationErrorText(message: media.seerr.error)
            IntegrationAction(title: "Done", symbol: "checkmark") { dismiss() }
        }
        .task { address = media.seerr.connection?.address ?? ""; await media.seerr.refreshAccount() }
        .integrationConfirm("Disconnect Seerr?", isPresented: $confirmingDisconnect, destructive: true) { media.seerr.disconnect() }
        .onChange(of: method) { _, _ in cancelPlexLink() }
        .onChange(of: address) { _, _ in cancelPlexLink() }
        .onDisappear { cancelPlexLink() }
    }

    private func cancelPlexLink() {
        plexRequestID = UUID(); linkingPlex?.cancel(); linkingPlex = nil; pinCode = nil
    }
    private func linkPlex() {
        cancelPlexLink(); plexError = nil
        let request = UUID(); plexRequestID = request
        let target = address, displayName = name
        linkingPlex = Task { @MainActor in
            defer { if plexRequestID == request { linkingPlex = nil; pinCode = nil } }
            do {
                let api = try SeerrClient(address: target, credential: .init())
                let settings = try await api.publicSettings()
                guard settings.initialized, let identifier = settings.plexClientIdentifier, !identifier.isEmpty else {
                    throw MediaIntegrationError.unavailable("Configure Seerr in its web app before linking a Plex account.")
                }
                let pin = try await PlexAccount.requestPin(clientID: identifier)
                try Task.checkCancellation()
                guard plexRequestID == request else { return }
                pinCode = pin.code
                let deadline = Date().addingTimeInterval(15 * 60)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    let checked = try await PlexAccount.checkPin(pin.id, clientID: identifier)
                    if let token = checked.authToken {
                        try Task.checkCancellation()
                        guard plexRequestID == request, address == target, method == .plex else { return }
                        if await media.seerr.connect(name: displayName, address: target, apiKey: "", email: "", password: "", method: .plex, plexToken: token) { editing = false }
                        return
                    }
                }
                plexError = "That Plex code expired. Get a new code to try again."
            } catch { if !Task.isCancelled, plexRequestID == request { plexError = error.localizedDescription } }
        }
    }
}

struct SeerrBrowserView: View {
    @Environment(MediaLibrary.self) private var media
    @State private var kind: SeerrMediaKind = .movie
    @State private var query = ""
    @State private var titles: [SeerrTitle] = []
    @State private var nextPage = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    init(query: String = "") { _query = State(initialValue: query) }
    private var searchID: String { media.seerr.connectionID.uuidString + "|" + kind.rawValue + "|" + query }
    var body: some View {
        IntegrationPage(title: "Discover & Request", symbol: "sparkles", detail: "Browse Seerr’s catalog. Requests and availability come directly from your server.") {
            NavigationLink { SeerrRequestsView() } label: { Label("Your Requests", systemImage: "tray.full") }.lineupButtonStyle()
            IntegrationField(title: "Search movies and series", text: $query)
            HStack {
                ForEach(SeerrMediaKind.allCases, id: \.self) { option in
                    IntegrationAction(title: (kind == option ? "✓ " : "") + option.title, symbol: option == .movie ? "film" : "tv") { kind = option }
                }
            }
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(titles) { title in
                    NavigationLink { SeerrTitleView(id: title.id, kind: title.kind, initialTitle: title.displayName) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            LineupArtView(url: title.posterURL, width: posterWidth) { image in
                                if let image { image.resizable().scaledToFill() }
                                else { LineupPresentationStyle.row.overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(LineupPresentationStyle.secondary)) }
                            }.aspectRatio(2 / 3, contentMode: .fit).clipped().clipShape(RoundedRectangle(cornerRadius: 15))
                            Text(title.displayName).font(.inter(.callout, .heavy)).lineLimit(2)
                            Text(SeerrMediaInfo.statusTitle(title.mediaInfo?.status)).font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
                        }.modifier(IntegrationPosterFocus())
                    }.lineupFlatButton()
                }
            }
            if loading { ProgressView("Loading…") }
            IntegrationErrorText(message: error)
            if hasMore && !loading { IntegrationAction(title: error == nil ? "Load More" : "Retry", symbol: "arrow.down") { Task { await load(reset: false) } } }
            if titles.isEmpty && !loading && error == nil { Text("No matching titles.").foregroundStyle(LineupPresentationStyle.secondary) }
        }
        .task(id: searchID) { await load(reset: true) }
    }
    private var posterWidth: CGFloat {
        #if os(tvOS)
        215
        #else
        170
        #endif
    }
    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible()), count: 5)
        #else
        Array(repeating: GridItem(.flexible()), count: 2)
        #endif
    }
    @MainActor private func load(reset: Bool) async {
        if !reset && loading { return }
        let id = UUID(); requestID = id
        let connection = media.seerr.connectionID
        if reset { nextPage = 1; titles = []; hasMore = true }
        loading = true; error = nil
        defer { if requestID == id { loading = false } }
        do {
            if reset && !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let client = try media.seerr.client()
            let result: SeerrPage<SeerrTitle>
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result = try await client.discover(kind: kind, page: nextPage) }
            else { result = try await client.search(query, page: nextPage) }
            try Task.checkCancellation()
            guard requestID == id, media.seerr.isConnected, media.seerr.connectionID == connection else { return }
            var known = Set(titles.map(\.id))
            titles += result.results.filter { $0.mediaType != "person" && $0.kind == kind && known.insert($0.id).inserted }
            hasMore = nextPage < (result.totalPages ?? nextPage)
            nextPage += 1
        } catch { if requestID == id && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct SeerrTitleView: View {
    @Environment(MediaLibrary.self) private var media
    let id: Int
    let kind: SeerrMediaKind
    var initialTitle = "Title"
    @State private var title: SeerrTitle?
    @State private var seasons: Set<Int> = []
    @State private var is4k = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var confirming = false
    @State private var quota: SeerrQuota?
    @State private var dataConnection: UUID?
    @State private var loadID = UUID()
    @State private var showingOptions = false
    @State private var options: SeerrRequestOptions?
    var body: some View {
        IntegrationPage(title: title?.displayName ?? initialTitle, symbol: kind == .movie ? "film" : "tv") {
            if let title {
                if let url = title.posterURL {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() }
                        placeholder: { RoundedRectangle(cornerRadius: 18).fill(LineupPresentationStyle.card) }
                        .frame(height: posterHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(title.displayName + " poster")
                }
                if let overview = title.overview { Text(overview).font(.inter(.body)).foregroundStyle(LineupPresentationStyle.secondary) }
                Text(SeerrMediaInfo.statusTitle(is4k ? title.mediaInfo?.status4k : title.mediaInfo?.status)).font(.inter(.title3, .heavy))
                if media.seerr.user?.canRequest(kind, is4k: true) == true {
                    IntegrationAction(title: is4k ? "✓ 4K Request" : "Standard Request · Switch to 4K", symbol: "4k.tv") { is4k.toggle() }
                }
                if media.seerr.user?.permits(8192) == true || media.seerr.user?.managesRequests == true {
                    IntegrationAction(title: options.map { "Request Options · " + $0.serverName } ?? "Request Options · Server Defaults", symbol: "slider.horizontal.3") {
                        showingOptions = true
                    }.disabled(busy)
                }
                if kind == .tv {
                    Text("Choose seasons").font(.inter(.headline, .heavy))
                    ForEach(title.seasons ?? []) { season in
                        let status = title.mediaInfo?.seasons?.first { $0.seasonNumber == season.seasonNumber }
                        let available = (is4k ? status?.status4k : status?.status) == 5
                        let queued = [2, 3].contains((is4k ? status?.status4k : status?.status) ?? 0)
                        IntegrationAction(title: (seasons.contains(season.seasonNumber) ? "✓ " : "") + (season.name ?? "Season \(season.seasonNumber)") + (available ? " · Available" : ""), symbol: "rectangle.stack") {
                            if !seasons.insert(season.seasonNumber).inserted { seasons.remove(season.seasonNumber) }
                        }.disabled(available || queued || busy)
                    }
                }
                if let limit = kind == .movie ? quota?.movie : quota?.tv, let remaining = limit.remaining {
                    Text("\(remaining) requests remaining" + (limit.days.map { " in your \($0)-day quota" } ?? ""))
                        .font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
                }
                if media.seerr.user?.canRequest(kind, is4k: is4k) == true {
                    IntegrationAction(title: busy ? "Submitting…" : "Request \(is4k ? "4K " : "")\(kind == .movie ? "Movie" : "Selected Seasons")", symbol: "tray.and.arrow.down") { confirming = true }
                        .disabled(busy || (kind == .tv && seasons.isEmpty) || (is4k ? title.mediaInfo?.status4k : title.mediaInfo?.status) == 5)
                } else { Text("Requests for this type or quality are not enabled for your account.").foregroundStyle(LineupPresentationStyle.secondary) }
                ForEach(title.mediaInfo?.requests ?? []) { request in
                    Text("\(request.is4k == true ? "4K · " : "")\(request.statusTitle) · \(request.requestedBy?.name ?? "Seerr user")")
                        .font(.inter(.callout)).foregroundStyle(LineupPresentationStyle.secondary)
                }
            } else if busy { ProgressView("Loading title…") }
            if let notice { Text(notice).foregroundStyle(LineupStyle.highlight) }
            IntegrationErrorText(message: error)
            IntegrationAction(title: "Refresh Status", symbol: "arrow.clockwise") { Task { await load() } }.disabled(busy)
        }
        .task(id: media.seerr.connectionID) { await load() }
        .onChange(of: is4k) { _, _ in options = nil }
        .lineupSheet(isPresented: $showingOptions) {
            SeerrRequestOptionsView(kind: kind, is4k: is4k, selection: $options).environment(media)
        }
        .integrationConfirm("Send this request to Seerr?", isPresented: $confirming) { Task { await submit() } }
    }
    private var posterHeight: CGFloat {
        #if os(tvOS)
        360
        #else
        240
        #endif
    }
    @MainActor private func load() async {
        let request = UUID(); loadID = request
        let connection = media.seerr.connectionID
        if dataConnection != connection { title = nil; quota = nil; seasons = []; is4k = false; notice = nil; options = nil }
        busy = true; error = nil
        defer { if loadID == request { busy = false } }
        do {
            await media.seerr.refreshAccount()
            try Task.checkCancellation()
            guard media.seerr.connectionID == connection else { return }
            let api = try media.seerr.client()
            let latest = try await api.details(id: id, kind: kind)
            try Task.checkCancellation()
            guard loadID == request, media.seerr.connectionID == connection else { return }
            title = latest
            dataConnection = connection
            if let user = media.seerr.user {
                let fetched = try? await api.quota(userID: user.id)
                if loadID == request, media.seerr.connectionID == connection { quota = fetched }
            }
        } catch { if loadID == request, media.seerr.connectionID == connection, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    @MainActor private func submit() async {
        guard !busy, dataConnection == media.seerr.connectionID else { return }
        let connection = media.seerr.connectionID
        let requestID = UUID(); loadID = requestID; busy = true; error = nil; notice = nil
        defer { if loadID == requestID { busy = false } }
        do {
            let api = try media.seerr.client()
            let request = try await api.request(id: id, kind: kind, seasons: seasons, is4k: is4k, options: options)
            guard media.seerr.connectionID == connection else { return }
            notice = "Request \(request.statusTitle.lowercased())."
            let latest = try await api.details(id: id, kind: kind)
            guard loadID == requestID, media.seerr.connectionID == connection else { return }
            title = latest
        } catch {
            // No write retry: a lost response may still have created a request.
            guard loadID == requestID, media.seerr.connectionID == connection else { return }
            self.error = error.localizedDescription + " Refresh Status before submitting again."
        }
    }
}

private struct SeerrRequestOptionsView: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    let kind: SeerrMediaKind
    let is4k: Bool
    @Binding var selection: SeerrRequestOptions?
    @State private var servers: [SeerrService] = []
    @State private var serverID: Int?
    @State private var details: SeerrServiceDetails?
    @State private var profileID: Int?
    @State private var folder: String?
    @State private var languageID: Int?
    @State private var error: String?
    @State private var loadingServers = false
    @State private var loadingDetails = false
    @State private var connectionID = UUID()
    @State private var detailRequest = UUID()
    var body: some View {
        IntegrationPage(title: "Request Options", symbol: "slider.horizontal.3", detail: "Choose from the services and quality profiles configured on your Seerr server.") {
            if loadingServers || loadingDetails { ProgressView("Loading options…") }
            ForEach(servers) { server in
                IntegrationAction(title: (serverID == server.id ? "✓ " : "") + server.name, symbol: "externaldrive") { serverID = server.id }
            }
            if let details {
                Text("Quality Profile").font(.inter(.headline, .heavy))
                IntegrationAction(title: profileID == nil ? "✓ Server Default" : "Server Default", symbol: "gearshape") { profileID = nil }
                ForEach(details.profiles) { profile in
                    IntegrationAction(title: (profileID == profile.id ? "✓ " : "") + profile.name, symbol: "slider.horizontal.3") { profileID = profile.id }
                }
                if let folders = details.rootFolders, !folders.isEmpty {
                    Text("Destination").font(.inter(.headline, .heavy))
                    IntegrationAction(title: folder == nil ? "✓ Server Default" : "Server Default", symbol: "folder") { folder = nil }
                    ForEach(folders) { root in
                        IntegrationAction(title: (folder == root.path ? "✓ " : "") + root.path, symbol: "folder") { folder = root.path }
                    }
                }
                if let languages = details.languageProfiles, !languages.isEmpty {
                    Text("Language Profile").font(.inter(.headline, .heavy))
                    IntegrationAction(title: languageID == nil ? "✓ Server Default" : "Server Default", symbol: "globe") { languageID = nil }
                    ForEach(languages) { language in
                        IntegrationAction(title: (languageID == language.id ? "✓ " : "") + language.name, symbol: "globe") { languageID = language.id }
                    }
                }
                IntegrationAction(title: "Use These Options", symbol: "checkmark") {
                    guard connectionID == media.seerr.connectionID else { return }
                    selection = SeerrRequestOptions(serverID: details.server.id, serverName: details.server.name,
                        profileID: profileID, rootFolder: folder, languageProfileID: languageID)
                    dismiss()
                }.disabled(loadingDetails)
            }
            IntegrationErrorText(message: error)
            IntegrationAction(title: "Use Server Defaults", symbol: "arrow.uturn.backward") { selection = nil; dismiss() }
            IntegrationAction(title: "Cancel", symbol: "xmark") { dismiss() }
        }
        .task(id: media.seerr.connectionID) {
            connectionID = media.seerr.connectionID
            servers = []; details = nil; serverID = nil; error = nil; loadingServers = true
            defer { loadingServers = false }
            do {
                let choices = try await media.seerr.client().services(kind: kind)
                try Task.checkCancellation()
                guard connectionID == media.seerr.connectionID else { return }
                servers = choices.filter { ($0.is4k ?? false) == is4k }
                serverID = servers.first(where: { $0.id == selection?.serverID })?.id
                    ?? servers.first(where: { $0.isDefault == true })?.id ?? servers.first?.id
                if servers.isEmpty { error = "No request servers are configured for this media type and quality." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .task(id: serverID) {
            let request = UUID(); detailRequest = request
            details = nil; profileID = nil; folder = nil; languageID = nil; loadingDetails = false
            guard let serverID else { return }
            let connection = media.seerr.connectionID
            loadingDetails = true; error = nil
            defer { if detailRequest == request { loadingDetails = false } }
            do {
                let loaded = try await media.seerr.client().serviceDetails(id: serverID, kind: kind)
                try Task.checkCancellation()
                guard detailRequest == request, connection == media.seerr.connectionID, loaded.server.id == serverID else { return }
                details = loaded
                if selection?.serverID == serverID {
                    profileID = selection?.profileID; folder = selection?.rootFolder; languageID = selection?.languageProfileID
                }
            } catch { if detailRequest == request && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct SeerrRequestsView: View {
    @Environment(MediaLibrary.self) private var media
    @State private var requests: [SeerrRequest] = []
    @State private var busy = false
    @State private var hasMore = true
    @State private var error: String?
    @State private var filter = "all"
    @State private var pending: SeerrRequest?
    @State private var generation = UUID()
    @State private var dataConnection = UUID()
    @State private var dataFilter = "all"
    @State private var nextOffset = 0
    var body: some View {
        IntegrationPage(title: "Requests", symbol: "tray.full", detail: media.seerr.user?.managesRequests == true ? "Requests visible to your Seerr account. Approvals follow server permissions." : "Your requests and their current server status.") {
            ScrollView(.horizontal) { HStack {
                ForEach(["all", "pending", "processing", "available", "failed"], id: \.self) { option in
                    IntegrationAction(title: (filter == option ? "✓ " : "") + option.capitalized, symbol: "line.3.horizontal.decrease") { filter = option }
                }
            }}.scrollIndicators(.hidden)
            LazyVStack(spacing: 16) {
                ForEach(requests) { request in SeerrRequestRow(request: request, connectionID: dataConnection, changed: { Task { await load(reset: true) } }) }
            }
            if busy { ProgressView("Loading requests…") }
            IntegrationErrorText(message: error)
            if requests.isEmpty && !busy && error == nil { Text("No requests in this view.").foregroundStyle(LineupPresentationStyle.secondary) }
            IntegrationAction(title: "Refresh", symbol: "arrow.clockwise") { Task { await load(reset: true) } }.disabled(busy)
            if hasMore && !busy { IntegrationAction(title: "Load More", symbol: "arrow.down") { Task { await load(reset: false) } } }
        }.task(id: media.seerr.connectionID.uuidString + "|" + filter) { await media.seerr.refreshAccount(); await load(reset: true) }
    }
    @MainActor private func load(reset: Bool) async {
        if !reset && busy { return }
        let id = UUID(); generation = id; busy = true; error = nil
        let connection = media.seerr.connectionID
        if reset {
            if dataConnection != connection || dataFilter != filter { requests = [] }
            hasMore = true; nextOffset = 0; dataConnection = connection; dataFilter = filter
        }
        defer { if generation == id { busy = false } }
        do {
            let result = try await media.seerr.client().requests(skip: nextOffset, filter: filter)
            try Task.checkCancellation(); guard generation == id, media.seerr.connectionID == connection else { return }
            if reset { requests = [] }
            var known = Set(requests.map(\.id))
            requests += result.results.filter { known.insert($0.id).inserted }
            nextOffset += result.results.count
            hasMore = !result.results.isEmpty && nextOffset < (result.pageInfo?.results ?? nextOffset)
        } catch { if generation == id && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct SeerrRequestRow: View {
    @Environment(MediaLibrary.self) private var media
    let request: SeerrRequest
    let connectionID: UUID
    let changed: () -> Void
    @State private var title: SeerrTitle?
    @State private var busy = false
    @State private var error: String?
    @State private var action: String?
    @State private var confirming = false
    private var kind: SeerrMediaKind? { SeerrMediaKind(rawValue: request.media?.mediaType ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = request.media?.tmdbId, let kind {
                NavigationLink { SeerrTitleView(id: id, kind: kind, initialTitle: title?.displayName ?? "Request #\(request.id)") } label: {
                    Text(title?.displayName ?? "Request #\(request.id)").font(.inter(.headline, .heavy))
                }.lineupButtonStyle()
            }
            Text("\(request.is4k == true ? "4K · " : "")\(request.statusTitle)")
            Text(SeerrMediaInfo.statusTitle(request.is4k == true ? request.media?.status4k : request.media?.status))
                .foregroundStyle(LineupPresentationStyle.secondary)
            Text(request.requestedBy?.name ?? "Seerr user").font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
            if media.seerr.user?.managesRequests == true, request.status == 1 {
                IntegrationAction(title: "Approve", symbol: "checkmark.circle") { action = "Approve"; confirming = true }
                IntegrationAction(title: "Decline", symbol: "xmark.circle", destructive: true) { action = "Decline"; confirming = true }
            }
            if media.seerr.user?.managesRequests == true, request.status == 4 {
                IntegrationAction(title: "Retry Failed Request", symbol: "arrow.clockwise") { action = "Retry"; confirming = true }
            }
            if media.seerr.user?.managesRequests == true || (media.seerr.user?.id == request.requestedBy?.id && request.status == 1) {
                IntegrationAction(title: "Cancel Request", symbol: "trash", destructive: true) { action = "Cancel"; confirming = true }
            }
            if busy { ProgressView() }
            IntegrationErrorText(message: error)
        }.padding(20).lineupPresentationSurface(RoundedRectangle(cornerRadius: 18)).disabled(busy || connectionID != media.seerr.connectionID)
        .task(id: connectionID.uuidString + "|" + String(request.id)) {
            title = nil
            if connectionID == media.seerr.connectionID, let id = request.media?.tmdbId, let kind {
                let loaded = try? await media.seerr.client().details(id: id, kind: kind)
                if !Task.isCancelled, connectionID == media.seerr.connectionID { title = loaded }
            }
        }
        .integrationConfirm("\(action ?? "Update") this request?", isPresented: $confirming, destructive: ["Cancel", "Decline"].contains(action ?? "")) {
            let selected = action; action = nil
            Task {
                guard connectionID == media.seerr.connectionID else { return }
                busy = true; error = nil; defer { busy = false }
                do {
                    let api = try media.seerr.client()
                    if selected == "Cancel" { try await api.cancel(request) }
                    else if selected == "Retry" { _ = try await api.retry(request) }
                    else { _ = try await api.decide(request, approve: selected == "Approve") }
                    changed()
                } catch { self.error = error.localizedDescription + " Refresh requests before retrying." }
            }
        }
    }
}

extension View {
    func integrationConfirm(_ title: String, isPresented: Binding<Bool>, destructive: Bool = false,
                            confirm: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self.tvChoices(title, symbol: "questionmark.circle", isPresented: isPresented) {
            [TVChoice("Confirm", isDestructive: destructive, action: confirm)]
        }
        #else
        self.lineupChoices(title, symbol: "questionmark.circle", isPresented: isPresented) {
            [MobileMenuItem("Confirm", isDestructive: destructive, action: confirm)]
        }
        #endif
    }
}
