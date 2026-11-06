import SwiftUI

struct LibraryTrackingSettingsView: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false

    var body: some View {
        Form {
            Section {
                Toggle("Local Tracking", isOn: Binding(get: { media.localTrackingEnabled },
                    set: { media.setLocalTrackingEnabled($0) }))
                    .tint(LineupStyle.highlight)
                Toggle("MDBList Tracking", isOn: Binding(get: { media.mdbListTrackingEnabled },
                    set: { media.setMDBListTrackingEnabled($0) }))
                    .tint(LineupStyle.highlight)
                    .disabled(!media.isMDBListConnected && !media.mdbListTrackingEnabled)
            } header: { Text("Watch Tracking") } footer: {
                Text("Choose either tracker, both, or neither. Local Tracking saves progress on this device. MDBList Tracking shares activity across devices using the same account. With both on, newer account progress can supply your resume point while current playback and newer local choices stay protected. Saved local history remains separate. Silo also manages its own profile’s watch state independently.")
            }
            Section {
                Toggle("Server Tracking", isOn: Binding(get: { media.serverTrackingEnabled },
                    set: { media.setServerTrackingEnabled($0) }))
                    .tint(LineupStyle.highlight)
            } header: { Text("Jellyfin, Emby and AIOStreams") } footer: {
                Text("Tells your server what you watch in Lineup and where you stopped, as every Jellyfin app does, so any app you open next picks up there. What you watched in other apps joins Continue Watching here, with Local Tracking on. Whichever was watched more recently wins.")
            }
            Section {
                if let account = media.mdbListAccount { LabeledContent("Account", value: "@\(account.username)") }
                Button(media.isMDBListConnected ? "Configure MDBList" : "Connect MDBList") { connecting = true }
                if media.mdbListTrackingEnabled {
                    LabeledContent("Tracking", value: media.mdbListTracking.status)
                    if let date = media.mdbListTracking.lastSynced {
                        LabeledContent("Last Synced", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if media.mdbListTracking.pendingCount > 0 {
                        Text("\(media.mdbListTracking.pendingCount) viewing updates waiting to sync")
                            .foregroundStyle(.secondary)
                    }
                    Button("Sync Now") { media.refreshTracking(force: true) }
                }
            } header: { Text("MDBList") } footer: {
                Text("MDBList catalogs and ratings use your connection independently of tracking. In MDBList-only mode, Library resume points, watched history and Up Next come from your account when a matching title is available. MDBList can mark titles watched at 80%; local tracking keeps Lineup’s completion rules.")
            }
            #if os(tvOS)
            Section { Button("Done") { dismiss() } }
            #endif
        }
        .font(.inter(17, .semibold))
        .lineupButtonStyle()
        .navigationTitle("Tracking")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .lineupSettingsList()
        #endif
        .onAppear {
            media.loadMDBListIntegrationIfNeeded()
            media.refreshTracking()
        }
        .lineupSheet(isPresented: $connecting) { MDBListIntegrationView().environment(media) }
    }
}
