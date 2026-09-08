import SwiftUI

struct MainView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var playing: XtreamStream?

    var body: some View {
        TabView(selection: $tab) {
            MobileLiveView { playing = $0 }
                .tabItem { Label("Live", systemImage: "play.rectangle.fill") }.tag(0)
            MobileGuideView { playing = $0 }
                .tabItem { Label("Guide", systemImage: "list.bullet.rectangle") }.tag(1)
            MobileAccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(2)
        }
        .fullScreenCover(item: $playing) { stream in
            MobilePlayerView(name: stream.name, urls: library.playbackURLs(for: stream))
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                library.refreshSchedule(showsLoading: false, includeTomorrow: false)
            }
        }
    }
}

struct ProfileSetupView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("NULLSPORTS").font(.caption.bold()).tracking(3)
                        Text("Your games.\nAnywhere.").font(.largeTitle.bold())
                        Text("Connect your provider to bring live sports to your iPhone.")
                    }.padding(.vertical, 16)
                }.listRowBackground(NullSportsStyle.surface)
                Section("Your provider") {
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Server URL", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }.listRowBackground(NullSportsStyle.surface)
                Section {
                    Button {
                        connecting = true
                        Task {
                            _ = await library.addProfile(name: name,
                                serverURL: server.trimmingCharacters(in: .whitespacesAndNewlines),
                                username: username, password: password)
                            connecting = false
                        }
                    } label: {
                        HStack {
                            Text(connecting ? "Connecting…" : "Connect")
                            Spacer()
                            if connecting { ProgressView() } else { Image(systemName: "arrow.right") }
                        }
                    }.disabled(connecting || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty || password.isEmpty)
                } footer: {
                    Text("Use your Xtream-compatible provider. Your password is stored securely in this iPhone’s Keychain.")
                }.listRowBackground(NullSportsStyle.raised)
            }
            .disabled(connecting)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(NullSportsStyle.background)
        }
    }
}

private struct MobileAccountView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var confirmingRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected provider") {
                    if let profile = library.activeProfile {
                        LabeledContent("Profile", value: profile.name)
                        LabeledContent("Username", value: profile.username)
                    }
                    LabeledContent("Channels", value: "\(library.streams.count)")
                    Button("Refresh channels and guide", systemImage: "arrow.clockwise") {
                        Task { await library.reload() }
                    }.disabled(library.channelsAreSyncing)
                    if library.channelsAreSyncing { ProgressView("Updating…") }
                }.listRowBackground(NullSportsStyle.surface)
                Section {
                    Button("Remove provider", role: .destructive) { confirmingRemoval = true }
                }.listRowBackground(NullSportsStyle.surface)
            }
            .scrollContentBackground(.hidden).background(NullSportsStyle.background)
            .navigationTitle("Account")
            .confirmationDialog("Remove this provider and its saved password?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove provider", role: .destructive) { library.removeActiveProfile() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
