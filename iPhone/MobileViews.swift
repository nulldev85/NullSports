import SwiftUI

struct MainView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var playing: XtreamStream?
    @State private var guideFullscreen = false

    var body: some View {
        TabView(selection: $tab) {
            MobileLiveView { playing = $0 }
                .tabItem { Label("Live", image: tab == 0 ? "Tab-Live-Selected" : "Tab-Live") }.tag(0)
            MobileGuideView(isActive: tab == 1, onFullscreenChange: { guideFullscreen = $0 }) { playing = $0 }
                .id(library.activeProfile?.id)
                .tabItem { Label("Guide", image: tab == 1 ? "Tab-Guide-Selected" : "Tab-Guide") }.tag(1)
            MobileAccountView()
                .tabItem { Label("Account", image: tab == 2 ? "Tab-Account-Selected" : "Tab-Account") }.tag(2)
        }
        .tint(NullSportsStyle.lightPurple)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(guideFullscreen ? .all : [], edges: .all)
        .onChange(of: library.activeProfile?.id) { _, _ in
            playing = nil
            guideFullscreen = false
        }
        .statusBarHidden(guideFullscreen)
        .persistentSystemOverlays(guideFullscreen ? .hidden : .automatic)
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
    @Environment(\.dismiss) private var dismiss
    var addingProvider = false
    @EnvironmentObject private var library: SportsLibrary
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var connectionError: String?

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
                        connectionError = nil
                        Task {
                            let added = await library.addProfile(name: name,
                                serverURL: server.trimmingCharacters(in: .whitespacesAndNewlines),
                                username: username, password: password)
                            connecting = false
                            if !added { connectionError = library.errorMessage }
                            if added && addingProvider { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text(connecting ? "Connectingâ€¦" : "Connect")
                            Spacer()
                            if connecting { ProgressView() } else { Image(systemName: "arrow.right") }
                        }
                    }.disabled(connecting || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty || password.isEmpty)
                } footer: {
                    Text("Use your Xtream-compatible provider. Your password is stored securely in this iPhoneâ€™s Keychain.")
                }.listRowBackground(NullSportsStyle.raised)
                if let connectionError {
                    Section { Text(connectionError).foregroundStyle(.red) }
                        .listRowBackground(NullSportsStyle.surface)
                }
            }
            .navigationTitle(addingProvider ? "Add provider" : "")
            .toolbar {
                if addingProvider {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(connecting)
                    }
                }
            }
            .interactiveDismissDisabled(connecting)
            .disabled(connecting)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(NullSportsStyle.background)
        }
    }
}

private struct MobileAccountView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var addingProvider = false
    @State private var removingProfile: XtreamProfile?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(library.profiles) { profile in
                        HStack(spacing: 12) {
                            Button {
                                Task { await library.selectProfile(profile) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: library.activeProfile?.id == profile.id ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name).font(.body.weight(.semibold))
                                        Text(profile.username).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if library.activeProfile?.id == profile.id {
                                        Text("Active").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(profile.name), \(library.activeProfile?.id == profile.id ? "active provider" : "switch provider")")
                            Button(role: .destructive) { removingProfile = profile } label: {
                                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(profile.name)")
                        }
                        .disabled(library.isSwitchingProfile || library.channelsAreSyncing)
                    }
                    Button("Add provider", systemImage: "plus.circle") { addingProvider = true }
                        .disabled(library.isSwitchingProfile)
                    if library.isSwitchingProfile { ProgressView("Switching provider…") }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Select a provider to use its channels and guide. Each provider keeps its own favorites.")
                }.listRowBackground(NullSportsStyle.surface)
                Section("Current library") {
                    LabeledContent("App version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    LabeledContent("Channels", value: "\(library.streams.count)")
                    Button("Refresh channels and guide", systemImage: "arrow.clockwise") {
                        Task { await library.reload() }
                    }.disabled(library.channelsAreSyncing || library.isSwitchingProfile)
                    if library.channelsAreSyncing { ProgressView("Updating…") }
                }.listRowBackground(NullSportsStyle.surface)
            }
            .scrollContentBackground(.hidden).background(NullSportsStyle.background)
            .navigationTitle("Account")
            .sheet(isPresented: $addingProvider) {
                ProfileSetupView(addingProvider: true)
                    .environmentObject(library)
                    .tint(NullSportsStyle.lightPurple)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog("Remove \(removingProfile?.name ?? "provider") and its saved password?",
                isPresented: Binding(get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } }),
                titleVisibility: .visible) {
                Button("Remove provider", role: .destructive) {
                    if let profile = removingProfile { Task { await library.removeProfile(profile) } }
                    removingProfile = nil
                }
                Button("Cancel", role: .cancel) { removingProfile = nil }
            }
        }
    }
}
