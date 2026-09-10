import SwiftUI

struct ProfileSetupView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var profileName = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false

    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 26) {
                Text("LINEUP").foregroundColor(LineupStyle.lightPurple)
                    .font(.caption.weight(.black))
                    .tracking(3)
                    .foregroundStyle(LineupStyle.field)
                Text("Your games.\nYour provider.").foregroundColor(LineupStyle.lightPurple)
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(LineupStyle.text)
                Text("A quiet, fast home for live American sports.").foregroundColor(LineupStyle.lightPurple)
                    .font(.title3)
                    .foregroundStyle(LineupStyle.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 18) {
                TextField("Profile name", text: $profileName)
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button {
                    connect()
                } label: {
                    HStack {
                        Text(isConnecting ? "Connecting…" : "Connect").foregroundColor(LineupStyle.lightPurple)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                }
                .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty || isConnecting)
            }
            .textFieldStyle(.plain)
            .foregroundColor(LineupStyle.lightPurple)
            .focusEffectDisabled()
            .buttonStyle(LineupButtonStyle())
            .padding(34)
            .background(LineupStyle.surface)
            .overlay(Rectangle().stroke(LineupStyle.line, lineWidth: 1))
            .frame(width: 560)
        }
        .padding(.horizontal, 90)
        .background(LineupStyle.background.ignoresSafeArea())
    }

    private func connect() {
        isConnecting = true
        Task {
            _ = await library.addProfile(name: profileName, serverURL: serverURL, username: username, password: password)
            isConnecting = false
        }
    }
}
