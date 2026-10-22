#if os(iOS)
import SwiftUI
import UIKit

/// First-run sign-in. It uses the same provider store as Settings, while the
/// poster field comes only from TMDB's real movie and television artwork.
struct MobileWelcomeView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: ProviderField?

    @State private var posters: [TMDBWelcomePoster] = []
    @State private var playlistConnection = false
    @State private var profileName = "My IPTV"
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var guideURL = ""
    @State private var connecting = false
    @State private var connectionError: String?
    @State private var showingMediaSetup = false

    private enum ProviderField: Hashable {
        case profileName, server, username, password, guide
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LineupStyle.background.ignoresSafeArea()

                MobileWelcomePosterBackdrop(posters: posters,
                    isActive: scenePhase == .active && !reduceMotion)
                    .ignoresSafeArea()

                LinearGradient(stops: [
                    .init(color: .black.opacity(0.08), location: 0),
                    .init(color: .black.opacity(0.16), location: 0.27),
                    .init(color: .black.opacity(0.54), location: 0.51),
                    .init(color: .black.opacity(0.91), location: 0.72),
                    .init(color: .black, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .accessibilityHidden(true)

                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: max(geometry.size.height * 0.28, 190))
                        welcomeForm
                            .padding(.bottom, max(geometry.safeAreaInsets.bottom, 16) + 12)
                    }
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                    .padding(.horizontal, 22)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LineupStyle.background.ignoresSafeArea())
        }
        .task {
            guard media.metadataAvailable(.tmdb) else { return }
            posters = await media.tmdbWelcomePosters()
        }
        .sheet(isPresented: $showingMediaSetup) {
            MediaServerSetupView()
        }
        .preferredColorScheme(.dark)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private var welcomeForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(LineupStyle.highlight)
                Text("LINEUP")
                    .font(.inter(16, .black))
                    .tracking(3.2)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)

            Text("Your TV. Your teams.")
                .font(.inter(30, .heavy))
                .tracking(-0.5)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)

            Text("Connect your IPTV provider to bring live TV and sports together.")
                .font(.inter(15, .medium))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)

            connectionPicker

            TextField("Profile name", text: $profileName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .profileName)
                .submitLabel(.next)
                .onSubmit { focusedField = .server }
                .welcomeFieldStyle()

            providerField(playlistConnection ? "Playlist URL" : "Server URL",
                          text: $serverURL, field: .server, keyboard: .URL,
                          contentType: .URL)
            if playlistConnection {
                providerField("XMLTV guide URL (optional)", text: $guideURL,
                              field: .guide, keyboard: .URL, contentType: .URL)
            } else {
                providerField("Username", text: $username, field: .username,
                              contentType: .username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .welcomeFieldStyle()
            }

            Button(action: connect) {
                HStack(spacing: 10) {
                    if connecting {
                        ProgressView().tint(LineupStyle.onHighlight)
                    }
                    Text(connecting ? "Connecting…" : "Connect provider")
                        .font(.inter(16, .bold))
                    Spacer()
                    if !connecting { Image(systemName: "arrow.right") }
                }
                .foregroundStyle(LineupStyle.onHighlight)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(LineupStyle.highlight, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(connecting || !canConnect)
            .opacity(canConnect || connecting ? 1 : 0.58)

            if let connectionError, !connectionError.isEmpty {
                Text(connectionError)
                    .font(.inter(13, .medium))
                    .foregroundStyle(Color.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 5) {
                Text("Using a media server?")
                    .foregroundStyle(.white.opacity(0.63))
                Button("Set it up here") { showingMediaSetup = true }
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .font(.inter(13))
            .frame(maxWidth: .infinity)
            .padding(.top, 1)

            VStack(spacing: 4) {
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    HStack(spacing: 6) {
                        Image("Rating-TMDB").resizable().scaledToFit().frame(width: 27, height: 18)
                        Text("Movie and series artwork by TMDB")
                    }
                    .font(.inter(10, .semibold))
                    .foregroundStyle(.white.opacity(0.63))
                }
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.inter(9))
                    .foregroundStyle(.white.opacity(0.47))
                    .multilineTextAlignment(.center)
                Text("Lineup is a media player. It does not provide content.")
                    .font(.inter(10, .medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 3)
        }
        .padding(18)
        .background(.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.11), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var connectionPicker: some View {
        HStack(spacing: 4) {
            connectionChoice("Xtream", selected: !playlistConnection) {
                playlistConnection = false
                profileName = "My IPTV"
                focusedField = nil
            }
            connectionChoice("M3U / EPG", selected: playlistConnection) {
                playlistConnection = true
                profileName = "My Playlist"
                focusedField = nil
            }
        }
        .padding(4)
        .background(.white.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider type")
    }

    private func connectionChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.inter(14, .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(0.69))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background {
                    if selected {
                        Capsule().fill(.white.opacity(0.15))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func providerField(_ title: String, text: Binding<String>, field: ProviderField,
                               keyboard: UIKeyboardType = .default,
                               contentType: UITextContentType? = nil) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
            .focused($focusedField, equals: field)
            .submitLabel(field == .username ? .next : .go)
            .onSubmit {
                switch field {
                case .profileName: focusedField = .server
                case .server: focusedField = playlistConnection ? .guide : .username
                case .username: focusedField = .password
                case .guide, .password: connect()
                }
            }
            .welcomeFieldStyle()
    }

    private var canConnect: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (playlistConnection || (!username.isEmpty && !password.isEmpty))
    }

    private func connect() {
        guard canConnect, !connecting else { return }
        focusedField = nil
        connectionError = nil
        connecting = true
        Task {
            let added: Bool
            if playlistConnection {
                added = await library.addPlaylist(name: profileName, playlist: serverURL, guide: guideURL)
            } else {
                added = await library.addProfile(name: profileName,
                    serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    username: username, password: password)
            }
            connecting = false
            if !added {
                connectionError = library.errorMessage ?? "Could not connect. Check the details and try again."
                // Keep the setup error on this welcome screen instead of
                // presenting the app-wide alert behind the sign-in form.
                library.errorMessage = nil
            }
        }
    }
}

private struct MobileWelcomePosterBackdrop: View {
    let posters: [TMDBWelcomePoster]
    let isActive: Bool

    private let rowCount = 6

    var body: some View {
        GeometryReader { geometry in
            let width = min(108, max(78, (geometry.size.width - 40) / 3.45))
            let height = width * 1.48
            VStack(spacing: 8) {
                ForEach(0..<rowCount, id: \.self) { index in
                    MobileWelcomePosterRow(posters: rowPosters(index), rowIndex: index,
                                           rowCount: rowCount, posterWidth: width,
                                           posterHeight: height, isActive: isActive)
                        .frame(height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .background(.black)
        .accessibilityHidden(true)
    }

    private func rowPosters(_ row: Int) -> [TMDBWelcomePoster] {
        guard !posters.isEmpty else { return [] }
        let shift = (row * 3) % posters.count
        return Array(posters.dropFirst(shift)) + Array(posters.prefix(shift))
    }
}

private struct MobileWelcomePosterRow: View {
    let posters: [TMDBWelcomePoster]
    let rowIndex: Int
    let rowCount: Int
    let posterWidth: CGFloat
    let posterHeight: CGFloat
    let isActive: Bool

    @State private var hasStarted = false

    private let spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let span = CGFloat(posters.count) * (posterWidth + spacing)
            let initialOffset = span * CGFloat(rowIndex) / CGFloat(max(1, rowCount))
            let currentOffset = hasStarted ? span - initialOffset : -initialOffset

            HStack(spacing: spacing) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: spacing) {
                        ForEach(posters) { poster in
                            LineupArtView(url: poster.imageURL, width: posterWidth) { image in
                                Group {
                                    if let image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .fill(.white.opacity(0.09))
                                    }
                                }
                                .frame(width: posterWidth, height: posterHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(.white.opacity(0.12), lineWidth: 1)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: currentOffset)
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
            .animation(isActive && span > 0
                       ? .linear(duration: Double(span / 24)).repeatForever(autoreverses: false)
                       : nil, value: hasStarted)
        .task(id: isActive && span > 0) {
                guard isActive, span > 0 else {
                    hasStarted = false
                    return
                }
                hasStarted = false
                await Task.yield()
                guard !Task.isCancelled else { return }
                hasStarted = true
            }
        }
    }
}

private extension View {
    func welcomeFieldStyle() -> some View {
        self
            .font(.inter(15, .medium))
            .foregroundStyle(.white)
            .tint(LineupStyle.highlight)
            .padding(.horizontal, 15)
            .frame(height: 48)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
#endif
