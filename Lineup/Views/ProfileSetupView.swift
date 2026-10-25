import SwiftUI

struct ProfileSetupView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var profileName = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var playlistConnection = false
    @State private var guideURL = ""
    @State private var connectionError: String?

    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 26) {
                Text("LINEUP").foregroundColor(LineupPresentationStyle.text)
                    .font(.inter(.caption, .black))
                    .tracking(3)
                    .foregroundStyle(LineupStyle.field)
                Text(playlistConnection ? "Your playlist.\nYour TV guide." : "Your games.\nYour provider.").foregroundColor(LineupPresentationStyle.text)
                    .font(.inter(58, .bold))
                    .foregroundStyle(LineupPresentationStyle.text)
                Text("A quiet, fast home for live American sports.").foregroundColor(LineupPresentationStyle.text)
                    .font(.inter(.title3))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 18) {
                Picker("Connection", selection: $playlistConnection) {
                    Label("Xtream", systemImage: "server.rack").tag(false)
                    Label("M3U / EPGenius", systemImage: "list.bullet.rectangle").tag(true)
                }
                TextField("Profile name", text: $profileName)
                TextField(playlistConnection ? "Playlist URL" : "Server URL", text: $serverURL)
                    .textContentType(.URL)
                if playlistConnection {
                    TextField("XMLTV guide URL (optional)", text: $guideURL).textContentType(.URL)
                    Text("EPGenius organizes your existing provider's channels and guide. It does not supply video. Paste the playlist and EPG links from its setup.")
                        .font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
                } else {
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                }
                Button {
                    connect()
                } label: {
                    HStack {
                        Text(isConnecting ? "Connecting…" : "Connect").foregroundColor(LineupPresentationStyle.text)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.inter(.headline))
                }
                .disabled(serverURL.isEmpty || (!playlistConnection && (username.isEmpty || password.isEmpty)) || isConnecting)
                if let connectionError { Text(connectionError).font(.inter(.caption)).foregroundStyle(.red) }
            }
            .textFieldStyle(.plain)
            .foregroundColor(LineupPresentationStyle.text)
            .focusEffectDisabled()
            .lineupButtonStyle()
            .padding(34)
            .background(LineupPresentationStyle.card)
            .overlay(Rectangle().stroke(LineupStyle.line, lineWidth: 1))
            .frame(width: 560)
        }
        .padding(.horizontal, 90)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        // Opened from Account, this is a sheet. The login is checked and saved
        // the moment the provider becomes active; its channels keep loading
        // behind the screen this returns to, as they do after first setup.
        .onChange(of: library.activeProfile?.id) { _, id in
            if id != nil { dismiss() }
        }
    }

    private func connect() {
        isConnecting = true
        connectionError = nil
        Task {
            let added: Bool
            if playlistConnection {
                added = await library.addPlaylist(name: profileName, playlist: serverURL, guide: guideURL)
            } else {
                added = await library.addProfile(name: profileName, serverURL: serverURL, username: username, password: password)
            }
            if added { dismiss() } else { connectionError = library.errorMessage }
            isConnecting = false
        }
    }
}
