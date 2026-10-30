import Foundation

/// Only catalog changes rebuild display channels. Scores, match results,
/// validation flags and refresh timestamps are deliberately absent.
struct MobileCombinedCatalogVersion: Equatable, Sendable {
    let providerID: UUID
    let generation: UUID
    let connection: [String]
    let name: String
    let categories: Int
    let streams: Int
    let guide: Int
}

struct MobileDisplayIDSnapshot: Sendable {
    var ids: [String: Int]
    var next: Int

    mutating func id(provider: UUID, stream: Int) -> Int {
        let key = provider.uuidString + "|" + String(stream)
        if let known = ids[key] { return known }
        let id = next
        next -= 1
        ids[key] = id
        return id
    }
}

/// Value snapshots cross to a background worker; provider stores stay on the
/// main actor. The completed maps are installed together after version checks.
struct MobileCombinedCatalog: Sendable {
    struct Provider: Sendable {
        let profile: XtreamProfile
        let categories: [XtreamCategory]
        let streams: [XtreamStream]
        let programs: [String: [CurrentProgram]]
    }
    struct Source: Sendable {
        let providerID: UUID
        let stream: XtreamStream
    }

    let registry: MobileDisplayIDSnapshot
    let channels: [XtreamStream]
    let channelsByID: [Int: XtreamStream]
    let categories: [XtreamCategory]
    let programs: [String: [CurrentProgram]]
    let sources: [Int: Source]

    static func build(providers: [Provider], registry initial: MobileDisplayIDSnapshot) throws -> Self {
        var registry = initial
        var channels: [XtreamStream] = [], categories: [XtreamCategory] = []
        var channelsByID: [Int: XtreamStream] = [:]
        var programs: [String: [CurrentProgram]] = [:]
        var sources: [Int: Source] = [:]
        channels.reserveCapacity(providers.reduce(0) { $0 + $1.streams.count })
        for provider in providers {
            try Task.checkCancellation()
            let profile = provider.profile
            let prefix = profile.id.uuidString + "|"
            categories += provider.categories.map {
                XtreamCategory(categoryID: prefix + $0.id, categoryName: "\(profile.name) · \($0.categoryName)",
                    sourceCategoryName: $0.matchingName)
            }
            for native in provider.streams {
                try Task.checkCancellation()
                let id = registry.id(provider: profile.id, stream: native.id)
                let channel = XtreamStream(num: native.num, name: native.name, streamType: native.streamType,
                    streamID: id, streamIcon: native.streamIcon,
                    epgChannelID: native.epgChannelID.map { prefix + $0 },
                    categoryID: native.categoryID.map { prefix + $0 },
                    tvArchive: native.tvArchive, archiveDays: native.archiveDays)
                channels.append(channel)
                channelsByID[id] = channel
                sources[id] = Source(providerID: profile.id, stream: native)
            }
            for (id, entries) in provider.programs {
                try Task.checkCancellation()
                programs[prefix + id] = entries
            }
        }
        return Self(registry: registry, channels: channels, channelsByID: channelsByID,
                    categories: categories, programs: programs, sources: sources)
    }
}
