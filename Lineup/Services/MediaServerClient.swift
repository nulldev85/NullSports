import Foundation

/// What the Library asks of a media server, whatever software it runs.
///
/// Jellyfin and Emby answer through `JellyfinClient` -- Emby's API is the one
/// Jellyfin grew from, and differs in little more than where it lives -- and
/// Plex through `PlexClient`, which asks Plex its own way and hands back the
/// same items. Everything above this sees one kind of server.
///
/// Every requirement takes all of its arguments. Defaults belong to the
/// concrete clients, where a call cannot be mistaken for another.
protocol MediaServerClient: Sendable {
    func views(userID: String) async throws -> [MediaItem]
    func items(userID: String, parentID: String, sortBy: String, limit: Int) async throws -> [MediaItem]
    func items(userID: String, parent: MediaItem, sortBy: String, limit: Int) async throws -> [MediaItem]
    func allCollections(userID: String, pageSize: Int, maxPages: Int) async throws -> [MediaItem]
    func episodes(userID: String, seriesID: String) async throws -> [MediaItem]
    func allTitles(userID: String, pageSize: Int, maxPages: Int) async throws -> [MediaItem]
    func item(userID: String, itemID: String) async throws -> MediaItem
    func similarItems(userID: String, itemID: String) async throws -> [MediaItem]
    func libraryCounts(userID: String) async throws -> MediaLibraryCounts
    func nextUp(userID: String, seriesID: String) async throws -> [MediaItem]
    func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws
    func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws
    func publicInfo() async throws -> MediaServerPublicInfo
    func items(userID: String, ids: [String]) async throws -> [MediaItem]
    func items(userID: String, providerIDs: [String: String], types: [String]) async throws -> [MediaItem]
    func search(userID: String, query: String, types: [String]) async throws -> [MediaItem]
    func imageURL(itemID: String, type: String, maxWidth: Int) -> URL?
    /// A title's artwork, from what the title itself says about it. Jellyfin
    /// and Emby name art by the item; Plex hands each item the paths of its
    /// own art, and those are what it is asked for.
    func artworkURL(for item: MediaItem, type: String, maxWidth: Int) -> URL?
    /// An episode's show's poster.
    func seriesPosterURL(for episode: MediaItem, maxWidth: Int) -> URL?
    func playbackURL(itemID: String, mediaSourceID: String?) -> URL?
    func playbackInfo(itemID: String) async throws -> MediaPlaybackInfo
    func playbackInfo(itemID: String, options: MediaPlaybackRequest) async throws -> MediaPlaybackInfo
    func playbackURL(itemID: String, mediaSourceID: String?, playSessionID: String?) -> URL?
    func seekPreview(userID: String, itemID: String, mediaSourceID: String) async throws -> MobileSeekPreviewSource?

    // Nullfin's own routes. Any other server has none of them, and says so
    // the way a plain Jellyfin server does: by refusing.
    func addons() async throws -> [NullfinAddon]
    func addonCatalogs(addonID: String) async throws -> [NullfinCatalog]
    func setCatalog(addonID: String, catalogID: String, enabled: Bool) async throws
    func refreshLibrary() async throws
    func itemMetrics(itemID: String) async throws -> [MediaMetric]
}

/// The defaults the Library asks with, written once.
enum MediaServerQuery {
    static let shelfSort = "SortName"
    static let shelfLimit = 40
    static let collectionPage = 200
    static let collectionPages = 25
    static let titlePage = 500
    static let titlePages = 50
    static let searchTypes = ["Movie", "Series", "Episode", "Video"]
}

extension MediaServerClient {
    func seekPreview(userID: String, itemID: String, mediaSourceID: String) async throws -> MobileSeekPreviewSource? { nil }
    func items(userID: String, parent: MediaItem, sortBy: String, limit: Int) async throws -> [MediaItem] {
        try await items(userID: userID, parentID: parent.id, sortBy: sortBy, limit: limit)
    }
    func playbackInfo(itemID: String, options: MediaPlaybackRequest) async throws -> MediaPlaybackInfo {
        try await playbackInfo(itemID: itemID)
    }
    func playbackURL(itemID: String, mediaSourceID: String?, playSessionID: String?) -> URL? {
        playbackURL(itemID: itemID, mediaSourceID: mediaSourceID)
    }
    func artworkURL(for item: MediaItem, type: String, maxWidth: Int) -> URL? {
        imageURL(itemID: item.id, type: type, maxWidth: maxWidth)
    }

    func seriesPosterURL(for episode: MediaItem, maxWidth: Int) -> URL? {
        episode.seriesID.flatMap { imageURL(itemID: $0, type: "primary", maxWidth: maxWidth) }
    }
}

extension JellyfinClient: MediaServerClient {}
