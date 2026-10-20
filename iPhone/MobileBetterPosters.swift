import SwiftUI

/// Keep the ordinary poster visible during a provider request and on failure.
/// Both downloads go through the same bounded, off-main artwork cache.
struct MobileRatedPoster<Content: View>: View {
    let url: URL?
    let fallback: URL?
    let pixels: Int
    @ViewBuilder var content: (Image?) -> Content

    var body: some View {
        if let url, url != fallback {
            MobileLibraryArtView(url: fallback, pixels: pixels) { ordinary in
                MobileLibraryArtView(url: url, pixels: pixels) { rated in content(rated ?? ordinary) }
            }
        } else {
            MobileLibraryArtView(url: fallback, pixels: pixels, content: content)
        }
    }
}

struct MobileBetterPostersSettings: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @State private var template = ""

    var body: some View {
        List {
            Section {
                Link("Open Official Configurator", destination: URL(string: "https://btttr.cc/configure")!)
                TextField("Poster URL", text: $template, axis: .vertical)
                    .font(.inter(.footnote)).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save Style") { media.betterPostersTemplate = template; dismiss() }
                    .disabled(!MobileBetterPosters.validTemplate(template))
                Button("Use Default Style") {
                    media.betterPostersTemplate = MobileBetterPosters.defaultTemplate
                    template = MobileBetterPosters.defaultTemplate
                }
            } header: { Text("BetterPosters").lineupSettingsHeader() }
              footer: { Text("Choose ‘AIOMetadata / Other Addon’ on the official configurator, then paste Your Poster URL here with {imdb_id} intact. No API key or account is required. Poster quality tags describe the title's releases, not the stream selected in Lineup; leave them off for playback accuracy.").lineupSettingsFooter() }
              .lineupSettingsRows()
            if !template.isEmpty && !MobileBetterPosters.validTemplate(template) {
                Section {
                    Text("Use an HTTPS poster URL from btttr.cc containing {imdb_id}. Addon manifest URLs cannot be used as poster images.")
                        .font(.inter(.footnote)).foregroundStyle(LineupPanelStyle.quiet)
                }.lineupSettingsRows()
            }
            Section {
                Link("Artwork provided by BetterPosters", destination: URL(string: "https://btttr.cc")!)
            }.lineupSettingsRows()
        }
        .lineupSettingsList().navigationTitle("Poster Style").navigationBarTitleDisplayMode(.inline)
        .onAppear { template = media.betterPostersTemplate }
    }
}
