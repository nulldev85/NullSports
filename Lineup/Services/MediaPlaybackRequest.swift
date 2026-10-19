import Foundation

struct MediaPlaybackRequest: Sendable {
    var fresh = false
    var refresh = false
    var mediaSourceID: String? = nil

    var body: [String: Any] {
        var value: [String: Any] = [:]
        if fresh { value["Fresh"] = true }
        if refresh { value["Refresh"] = true }
        if let mediaSourceID {
            value["MediaSourceId"] = mediaSourceID
            value["IsPlayback"] = true
        }
        // Direct play only. Do not advertise transcoding, YouTube playback,
        // or RequiredHttpHeaders until all Lineup engines implement them.
        return value
    }
}

extension MediaPlaybackInfo {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        playSessionID = values.lenientString(.playSessionID)
        var records = try values.nestedUnkeyedContainer(forKey: .mediaSources)
        var sources: [MediaPlaybackSource] = []
        while !records.isAtEnd {
            let record = try records.superDecoder()
            if let source = try? MediaPlaybackSource(from: record) { sources.append(source) }
        }
        mediaSources = sources
    }
}

extension MediaPlaybackSource {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = values.lenientString(.sourceID), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sourceID, in: values, debugDescription: "Missing media source identity")
        }
        sourceID = id
        name = values.lenientString(.name)
        path = values.lenientString(.path)
        container = values.lenientString(.container)
        sourceType = values.lenientString(.sourceType)
        size = values.lenientString(.size).flatMap(Int64.init)
        bitrate = values.lenientString(.bitrate).flatMap(Int64.init)
        remux = try? values.decodeIfPresent(RemuxInfo.self, forKey: .remux)
        aiostreams = try? values.decodeIfPresent(AIOStreamsInfo.self, forKey: .aiostreams)
    }
}
