import SwiftUI

enum MobileBetterPosters {
    static let defaultTemplate = "https://btttr.cc/poster/imdb/poster-default/{imdb_id}.jpg"

    /// Accept only the image pattern produced by the official configurator.
    /// Never accept manifests, third-party proxies, or credentials in a URL.
    static func validTemplate(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 1024, text.components(separatedBy: "{imdb_id}").count == 2,
              let url = URLComponents(string: text.replacingOccurrences(of: "{imdb_id}", with: "tt0903747")),
              url.scheme == "https", url.host?.lowercased() == "btttr.cc",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              url.path.range(of: "^/poster(-[gnrqa]+)?/imdb/poster-default/tt0903747\\.jpg$",
                             options: .regularExpression) != nil else { return false }
        let allowed: Set<String> = ["tag", "lang", "rs"]
        return (url.queryItems ?? []).allSatisfy { allowed.contains($0.name) && !($0.value ?? "").isEmpty }
    }

    static func url(for item: MediaItem, template: String) -> URL? {
        guard ["Movie", "Series"].contains(item.type), validTemplate(template),
              let imdb = LibraryMetadataIdentity.ids(item)["imdb"],
              imdb.range(of: "^tt[0-9]{7,}$", options: .regularExpression) != nil else { return nil }
        return URL(string: template.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{imdb_id}", with: imdb))
    }
}

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

extension MediaLibrary {
    func betterPosterURL(for item: MediaItem) -> URL? {
        guard betterPostersEnabled else { return nil }
        let item = displayItem(item)
        if let url = MobileBetterPosters.url(for: item, template: betterPostersTemplate) { return url }
        guard let imdb = betterPosterIDs[item.libraryKey] else { return nil }
        let identity = item.withMetadata(LibraryMetadata(source: .provider, title: item.name, externalIDs: ["imdb": imdb]))
        return MobileBetterPosters.url(for: identity, template: betterPostersTemplate)
    }

    func resolveBetterPosterIdentity(for item: MediaItem) async {
        guard betterPostersEnabled, ["Movie", "Series"].contains(item.type),
              LibraryMetadataIdentity.ids(displayItem(item))["imdb"] == nil,
              betterPosterIDs[item.libraryKey] == nil else { return }
        await resolveMetadata(for: item)
        guard !Task.isCancelled, LibraryMetadataIdentity.ids(displayItem(item))["imdb"] == nil else { return }
        let matched = await libraryExternalIdentity(item)
        guard !Task.isCancelled, let imdb = LibraryMetadataIdentity.ids(matched)["imdb"] else { return }
        betterPosterIDs[item.libraryKey] = imdb
    }
}

struct MobileBetterPostersSettings: View {
    @EnvironmentObject private var media: MediaLibrary
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
