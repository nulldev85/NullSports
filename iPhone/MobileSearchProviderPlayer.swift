import SwiftUI

struct MobileSearchProviderPlayback: Identifiable {
    let id = UUID()
    let library: SportsLibrary
    let stream: XtreamStream
}

/// Search retains its existing full player and dismissal/PiP controls. Only
/// the source account and its visible identity come from the combined catalog.
struct MobileSearchProviderPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SportsLibrary.self) private var root
    let selection: MobileSearchProviderPlayback

    var body: some View {
        MobilePlayerView(name: selection.stream.name,
            urls: selection.library.playbackURLs(for: selection.stream), isLive: true,
            providerName: selection.library.providerName(for: selection.stream),
            onPlaybackStarted: { selection.library.recordRecentChannel(selection.stream) })
            .onAppear {
                guard sourceAvailable else { dismiss(); return }
            }
            .onChange(of: root.enabledProfiles.map(\.id)) { _, _ in
                if !sourceAvailable { dismiss() }
            }
            .onChange(of: selection.library.streamsRevision) { _, _ in
                if !sourceAvailable { dismiss() }
            }
    }

    private var sourceAvailable: Bool {
        selection.library.stream(withID: selection.stream.id) != nil
            && !selection.library.playbackURLs(for: selection.stream).isEmpty
    }
}
