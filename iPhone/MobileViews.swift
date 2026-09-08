import SwiftUI

struct MainView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = 0
    @State private var playing: XtreamStream?
    @State private var guideFullscreen = false

    var body: some View {
        MobilePagingView(selection: $tab, pages: [
            page(MobileLiveView { playing = $0 }),
            page(MobileGuideView(isActive: tab == 1, onFullscreenChange: { guideFullscreen = $0 }) { playing = $0 }),
            page(MobileAccountView())
        ], allowsPaging: !guideFullscreen && playing == nil, reduceMotion: reduceMotion)
        .ignoresSafeArea(guideFullscreen ? .all : [], edges: .all)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !guideFullscreen {
                HStack(spacing: 0) {
                    tabButton("Live", symbol: "play.rectangle.fill", index: 0)
                    tabButton("Guide", symbol: "list.bullet.rectangle", index: 1)
                    tabButton("Account", symbol: "person.crop.circle", index: 2)
                }
                .padding(.top, 7).padding(.bottom, 4)
                .background(NullSportsStyle.surface)
                .overlay(alignment: .top) { Rectangle().fill(NullSportsStyle.line).frame(height: 1) }
                .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    tab = min(2, max(0, tab + (value.translation.width < 0 ? 1 : -1)))
                })
            }
        }
        .background(NullSportsStyle.background)
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

    private func page<Content: View>(_ content: Content) -> AnyView {
        AnyView(content.environmentObject(library)
            .environment(\.scenePhase, scenePhase)
            .foregroundStyle(NullSportsStyle.lightPurple)
            .tint(NullSportsStyle.lightPurple).preferredColorScheme(.dark))
    }

    private func tabButton(_ title: String, symbol: String, index: Int) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(NullSportsStyle.lightPurple.opacity(tab == index ? 1 : 0.45))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(tab == index ? .isSelected : [])
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
                    LabeledContent("App version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
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
