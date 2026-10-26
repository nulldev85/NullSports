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
        MediaServerPanel(brand: .silo, title: "Sign in to Silo") {
            if pendingClient == nil { signInStep } else { profileStep }
            IntegrationErrorText(message: error)
            Text("Sign in with your Silo username and password, or an API key owned by your account. Your household profile controls library access and watch state. Sign-ins and profile verification are kept in this device's Keychain.")
                .font(.inter(footerSize)).foregroundStyle(LineupPresentationStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // The same fields as Jellyfin's and Emby's, with a choice of an account
    // or an API key above them.
    @ViewBuilder private var signInStep: some View {
        HStack(spacing: 10) {
            MediaServerChoice(title: "Account", symbol: "person", selected: !useKey) { useKey = false }
            MediaServerChoice(title: "API Key", symbol: "key", selected: useKey) { useKey = true }
        }
        .disabled(busy)
        fields
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button {
            Task { await signIn() }
        } label: {
            Text(busy ? "Signing in…" : "Sign In")
        }
        .buttonStyle(IntegrationButtonStyle()).focusEffectDisabled()
        .disabled(busy || address.isEmpty || (useKey ? key.isEmpty : username.isEmpty))
    }

    @ViewBuilder private var fields: some View {
        #if os(tvOS)
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 22) {
            GridRow {
                MediaServerField(label: "Server address", prompt: "192.168.1.50:8096", text: $address, kind: .address)
                MediaServerField(label: "Display name", prompt: "Optional", text: $name)
            }
            GridRow {
                if useKey {
                    MediaServerField(label: "API key", prompt: "Silo API key", text: $key, kind: .secret)
                        .gridCellColumns(2)
                } else {
                    MediaServerField(label: "Username", prompt: "Username", text: $username, kind: .username)
                    MediaServerField(label: "Password", prompt: "Password", text: $password, kind: .password)
                }
            }
        }
        #else
        VStack(spacing: 0) {
            MediaServerField(label: "Address", prompt: "192.168.1.50:8096", text: $address, kind: .address)
            MediaServerFieldDivider()
            MediaServerField(label: "Name", prompt: "Optional", text: $name)
            MediaServerFieldDivider()
            if useKey {
                MediaServerField(label: "API Key", prompt: "Required", text: $key, kind: .secret)
            } else {
                MediaServerField(label: "Username", prompt: "Required", text: $username, kind: .username)
                MediaServerFieldDivider()
                MediaServerField(label: "Password", prompt: "Password", text: $password, kind: .password)
            }
        }
        .background(fieldGround, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #endif
    }

    @ViewBuilder private var profileStep: some View {
        Text("Choose your household profile")
            .font(.inter(headlineSize, .semibold)).foregroundStyle(LineupPresentationStyle.text)
        VStack(alignment: .leading, spacing: choiceGap) {
            ForEach(profiles) { profile in
                MediaServerChoice(title: profile.name, symbol: profile.has_pin ? "lock.circle" : "person.crop.circle",
                                  selected: selected == profile.id) {
                    selected = profile.id; pin = ""
                }
            }
        }
        .disabled(busy)
        if profiles.first(where: { $0.id == selected })?.has_pin == true {
            #if os(tvOS)
            MediaServerField(label: "Profile PIN", prompt: "PIN", text: $pin, kind: .secret)
            #else
            MediaServerField(label: "PIN", prompt: "Required", text: $pin, kind: .secret)
                .background(fieldGround, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #endif
        }
        VStack(alignment: .leading, spacing: choiceGap) {
            Button {
                Task { await connect() }
            } label: {
                Text(busy || media.isAddingServer ? "Connecting…" : "Connect")
            }
            .disabled(busy || media.isAddingServer || selected == nil)
            Button {
                pendingClient = nil; account = nil; profiles = []; selected = nil; pin = ""
            } label: {
                Text("Use Another Account")
            }
            .disabled(busy)
        }
        .buttonStyle(IntegrationButtonStyle()).focusEffectDisabled()
    }

    private var fieldGround: Color { MediaServerBrand.silo.loginTint.opacity(0.09) }

    #if os(tvOS)
    private var footerSize: CGFloat { 20 }
    private var headlineSize: CGFloat { 26 }
    private var choiceGap: CGFloat { 16 }
    #else
    private var footerSize: CGFloat { 12 }
    private var headlineSize: CGFloat { 16 }
    private var choiceGap: CGFloat { 10 }
    #endif

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
