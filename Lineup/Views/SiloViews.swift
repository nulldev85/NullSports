import SwiftUI

struct SiloPlaybackPreparation<Content: View>: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let source: MediaPlaybackSource
    let startsOver: Bool
    let content: (MediaPlaybackSource, SiloPlaybackSession?) -> Content
    @State private var native: SiloPlaybackSession?
    @State private var prepared: MediaPlaybackSource?
    @State private var error: String?
    @State private var started = false

    init(item: MediaItem, source: MediaPlaybackSource, startsOver: Bool,
         @ViewBuilder content: @escaping (MediaPlaybackSource, SiloPlaybackSession?) -> Content) {
        self.item = item; self.source = source; self.startsOver = startsOver; self.content = content
    }

    var body: some View {
        Group {
            if source.siloFileID == nil { content(source, nil) }
            else if let prepared, let native { content(prepared, native) }
            else {
                IntegrationPage(title: "Silo Playback", symbol: "play.rectangle") {
                    if error == nil { ProgressView("Preparing your selected version…") }
                    IntegrationErrorText(message: error)
                    IntegrationAction(title: "Close", symbol: "xmark") { dismiss() }
                }
            }
        }
        .task {
            guard source.siloFileID != nil, !started else { return }; started = true
            do {
                let session = try await media.prepareSiloPlayback(for: item, source: source, startsOver: startsOver)
                guard !Task.isCancelled, let asset = session.asset else { await session.stop(); return }
                var copy = source
                copy.directURL = asset.url; copy.siloLease = asset.lease
                native = session; prepared = copy
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { if let native { media.releaseUnpresentedSiloPlayback(native) } }
    }
}

struct SiloSignInPanel: View {
    @Environment(MediaLibrary.self) private var media
    let onAdded: () -> Void
    @State private var address = ""
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var key = ""
    @State private var pin = ""
    @State private var useKey = false
    @State private var busy = false
    @State private var error: String?
    @State private var pendingClient: SiloClient?
    @State private var account: SiloAccount?
    @State private var profiles: [SiloProfile] = []
    @State private var selected: String?

    var body: some View {
        MediaServerPanel(brand: .silo, title: "Connect Silo") {
            VStack(alignment: .leading, spacing: 16) {
                if pendingClient == nil {
                    IntegrationField(title: "Server address", text: $address)
                    IntegrationField(title: "Display name (optional)", text: $name)
                    HStack {
                        IntegrationAction(title: useKey ? "Account" : "✓ Account", symbol: "person") { useKey = false }
                        IntegrationAction(title: useKey ? "✓ API Key" : "API Key", symbol: "key") { useKey = true }
                    }
                    if useKey { IntegrationField(title: "Silo API key", text: $key, secure: true) }
                    else {
                        IntegrationField(title: "Username", text: $username)
                        IntegrationField(title: "Password", text: $password, secure: true)
                    }
                    IntegrationAction(title: busy ? "Signing in…" : "Choose Profile", symbol: "person.crop.circle") { Task { await signIn() } }
                        .disabled(busy || address.isEmpty || (useKey ? key.isEmpty : username.isEmpty))
                } else {
                    Text("Choose your household profile").font(.inter(.headline, .heavy))
                    ForEach(profiles) { profile in
                        IntegrationAction(title: (selected == profile.id ? "✓ " : "") + profile.name,
                            symbol: profile.has_pin ? "lock.circle" : "person.crop.circle") {
                            selected = profile.id; pin = ""
                        }.disabled(busy)
                    }
                    if profiles.first(where: { $0.id == selected })?.has_pin == true {
                        IntegrationField(title: "Profile PIN", text: $pin, secure: true)
                    }
                    IntegrationAction(title: busy || media.isAddingServer ? "Connecting…" : "Connect Profile", symbol: "link") {
                        Task { await connect() }
                    }.disabled(busy || media.isAddingServer || selected == nil)
                    IntegrationAction(title: "Use Another Account", symbol: "arrow.backward") {
                        pendingClient = nil; account = nil; profiles = []; selected = nil; pin = ""
                    }.disabled(busy)
                }
                IntegrationErrorText(message: error)
                Text("Connect with your Silo username and password, or an API key owned by your account. Your household profile controls library access and watch state. Sign-ins and profile verification are kept in this device’s Keychain.")
                    .font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }

    @MainActor private func signIn() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let client = try SiloClient(address: address, credential: .init(accessToken: useKey ? key.trimmingCharacters(in: .whitespacesAndNewlines) : ""),
                profileID: nil, deviceID: media.plexClientID)
            _ = try await client.publicInfo()
            let user: SiloAccount
            if useKey { user = try await client.account() }
            else { user = try await client.signIn(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
            let choices = try await client.profiles()
            try Task.checkCancellation()
            guard !choices.isEmpty else { throw MediaIntegrationError.unavailable("This Silo account has no household profiles. Create one on your server first.") }
            account = user; profiles = choices; selected = choices.first(where: \.is_primary)?.id ?? choices.first?.id
            pendingClient = client; key = ""; password = ""
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    @MainActor private func connect() async {
        guard !busy, let client = pendingClient, let account,
              let profile = profiles.first(where: { $0.id == selected }) else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            try await client.selectProfile(profile, pin: pin)
            if await media.addSiloServer(client, account: account, household: profile, name: name) { pin = ""; onAdded() }
            else { error = media.errorMessage }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
