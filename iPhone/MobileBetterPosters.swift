import SwiftUI

/// Keep the ordinary poster visible during a provider request and on failure.
/// Both downloads go through the same bounded, off-main artwork cache, and the
/// fallback view keeps a stable identity even when a BetterPosters URL arrives
/// asynchronously so an in-flight download is never torn down mid-flight.
struct MobileRatedPoster<Content: View>: View {
    let url: URL?
    let fallback: URL?
    var secondaryFallback: URL? = nil
    let pixels: Int
    private let content: (Image?, Bool) -> Content

    init(url: URL?, fallback: URL?, secondaryFallback: URL? = nil, pixels: Int,
         @ViewBuilder content: @escaping (Image?) -> Content) {
        self.url = url
        self.fallback = fallback
        self.secondaryFallback = secondaryFallback
        self.pixels = pixels
        self.content = { image, _ in content(image) }
    }

    init(url: URL?, fallback: URL?, secondaryFallback: URL? = nil, pixels: Int,
         @ViewBuilder content: @escaping (Image?, Bool) -> Content) {
        self.url = url
        self.fallback = fallback
        self.secondaryFallback = secondaryFallback
        self.pixels = pixels
        self.content = content
    }

    var body: some View {
        MobileLibraryArtView(url: fallback, fallbackURL: secondaryFallback, pixels: pixels) { ordinary, ordinaryLoading in
            if let url, url != fallback {
                MobileLibraryArtView(url: url, pixels: pixels) { rated, ratedLoading in
                    let resolved = rated ?? ordinary
                    content(resolved, resolved == nil && (ordinaryLoading || ratedLoading))
                }
            } else {
                content(ordinary, ordinary == nil && ordinaryLoading)
            }
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
