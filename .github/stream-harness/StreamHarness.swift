
// TEMPORARY design harness -- never part of the app.
//
// The stream-design-snapshots workflow appends this file to the checkout's
// MediaViews.swift (so it can reach the stream list's private views), shows
// it instead of the app when launched with -StreamHarness <scenario>, and
// throws the checkout away afterwards.

enum StreamHarness {
    static var scenario: String? { value(after: "-StreamHarness") }
    static var backdrop: URL? { value(after: "-StreamHarnessBackdrop").flatMap(URL.init(string:)) }

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

struct StreamHarnessGate<Root: View>: View {
    @ViewBuilder var root: Root

    var body: some View {
        if let scenario = StreamHarness.scenario {
            StreamHarnessRoot(scenario: scenario)
        } else {
            root
        }
    }
}

private struct StreamHarnessRoot: View {
    let scenario: String
    @State private var filter: String?

    init(scenario: String) {
        self.scenario = scenario
        let start: String?
        switch scenario {
        case "matt": start = "Matt"
        case "vodmissing": start = "VOD"
        case "null": start = "Null"
        default: start = nil
        }
        _filter = State(initialValue: start)
    }

    var body: some View {
        #if os(tvOS)
        board
        #else
        NavigationStack {
            board
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") {} } }
        }
        #endif
    }

    private var board: some View {
        MediaStreamBoard(heading: heading, statuses: statuses, sources: sources,
                         loading: scenario == "waiting", error: nil, filter: $filter,
                         serverLabel: { $0.serverName }, choose: { _ in })
    }

    private var heading: MediaStreamHeading {
        if scenario == "episode" {
            return MediaStreamHeading(title: "Severance", subtitle: "S2E4  ·  Woe's Hollow",
                                      backdrop: StreamHarness.backdrop)
        }
        return MediaStreamHeading(title: "Mutiny", subtitle: "2026  ·  2h 7m", backdrop: StreamHarness.backdrop)
    }

    private static let nullID = UUID()
    private static let mattID = UUID()
    private static let vodID = UUID()

    private var statuses: [StreamServerStatus] {
        switch scenario {
        case "waiting":
            return [StreamServerStatus(id: Self.nullID, name: "Null", phase: .looking),
                    StreamServerStatus(id: Self.mattID, name: "Matt", phase: .looking),
                    StreamServerStatus(id: Self.vodID, name: "VOD", phase: .preparing("Reading its list…"))]
        case "partial":
            return [StreamServerStatus(id: Self.nullID, name: "Null", phase: .found(6)),
                    StreamServerStatus(id: Self.mattID, name: "Matt", phase: .looking),
                    StreamServerStatus(id: Self.vodID, name: "VOD", phase: .preparing("Downloading its list…"))]
        case "vodmissing":
            return [StreamServerStatus(id: Self.nullID, name: "Null", phase: .found(6)),
                    StreamServerStatus(id: Self.mattID, name: "Matt", phase: .found(4)),
                    StreamServerStatus(id: Self.vodID, name: "VOD", phase: .notOnServer(
                        tried: "Searched 41,203 films for TMDB 1146972 and “Mutiny” (2026)"))]
        default:
            return [StreamServerStatus(id: Self.nullID, name: "Null", phase: .found(6)),
                    StreamServerStatus(id: Self.mattID, name: "Matt", phase: .found(4)),
                    StreamServerStatus(id: Self.vodID, name: "VOD", phase: .found(1))]
        }
    }

    private var sources: [MediaPlaybackSource] {
        switch scenario {
        case "waiting": return []
        case "partial": return Self.null
        case "vodmissing": return Self.null + Self.matt
        default: return Self.null + Self.matt + Self.vod
        }
    }

    private static func decode(_ json: String, server: UUID, name: String) -> MediaPlaybackSource {
        var source = try! JSONDecoder().decode(MediaPlaybackSource.self, from: Data(json.utf8))
        source.serverID = server
        source.serverName = name
        return source
    }

    private static func nzb(_ id: String, _ release: String, size: Int64, rate: Int64, indexer: String,
                            score: Int) -> MediaPlaybackSource {
        let name = "StreamNZB\\nMutiny\\n\(release)\\n🔍 StreamNZB Library - \(indexer) • 🎯 Score: +\(score)"
        let json = #"{"Id":"\#(id)","Name":"\#(name)","Container":"mkv","Size":\#(size),"Bitrate":\#(rate),"#
            + #""Remux":{"ProviderInfo":{"source":"StreamNZB","filename":"🎯 SCORE +\#(score) 🎯 • \#(release)"}}}"#
        return decode(json, server: nullID, name: "Null")
    }

    private static let null: [MediaPlaybackSource] = [
        nzb("n1", "Mutiny.2026.2160p.MA.WEB-DL.DDP5.1.Atmos.DV.HDR10.H.265-FLUX", size: 20_711_934_361,
            rate: 27_000_000, indexer: "NZBgeek", score: 66359),
        nzb("n2", "Mutiny.2026.2160p.iT.WEB-DL.DDP5.1.HDR10.H.265-ABBiE", size: 12_562_779_340,
            rate: 16_000_000, indexer: "altHUB", score: 65263),
        nzb("n3", "Mutiny.2026.MULTI.HDR.2160p.WEB.H265-SUPPLY", size: 10_522_669_875,
            rate: 13_400_000, indexer: "NZBgeek", score: 61022),
        nzb("n4", "Mutiny.2026.1080p.MA.WEB-DL.DDP5.1.Atmos.H.264-FLUX", size: 8_804_682_956,
            rate: 11_200_000, indexer: "DrunkenSlug", score: 58410),
        nzb("n5", "Mutiny.2026.1080p.WEBRip.x265.10bit.AAC5.1-LAMA", size: 2_254_857_830,
            rate: 2_900_000, indexer: "altHUB", score: 41200),
        nzb("n6", "Mutiny.2026.720p.WEB-DL.DDP5.1.H.264-FLUX", size: 3_650_722_201,
            rate: 4_600_000, indexer: "NZBgeek", score: 30110)
    ]

    private static func aio(_ id: String, _ line: String, _ file: String, addon: String, indexer: String,
                            cached: Bool, size: Int64, rate: Int64) -> MediaPlaybackSource {
        let json = #"{"Id":"\#(id)","Name":"\#(line)\n\#(file)","Path":"https://cdn.example/\#(id).mkv","#
            + #""Container":"mkv","Size":\#(size),"Bitrate":\#(rate),"#
            + #""aiostreams":{"addon":"\#(addon)","filename":"\#(file)","indexer":"\#(indexer)","cached":\#(cached)}}"#
        return decode(json, server: mattID, name: "Matt")
    }

    private static let matt: [MediaPlaybackSource] = [
        aio("m1", "4K ⚡", "Mutiny.2026.2160p.WEB-DL.DV.HDR10+.DDP5.1.Atmos.H.265-HONE", addon: "Torrentio",
            indexer: "1337x", cached: true, size: 18_253_611_008, rate: 24_000_000),
        aio("m2", "4K ⚡", "Mutiny 2026 2160p UHD BluRay REMUX DV HDR TrueHD 7.1 Atmos HEVC-FraMeSToR",
            addon: "Comet", indexer: "TorrentGalaxy", cached: true, size: 61_203_283_968, rate: 64_000_000),
        aio("m3", "1080P ⚡", "Mutiny.2026.1080p.BluRay.x264.DTS-HD.MA.5.1-SWTYBLZ", addon: "Torrentio",
            indexer: "YTS", cached: true, size: 14_710_253_568, rate: 18_000_000),
        aio("m4", "1080P", "Mutiny.2026.1080p.WEB.H264-ETHEL", addon: "MediaFusion", indexer: "EZTV",
            cached: false, size: 5_046_586_572, rate: 6_200_000)
    ]

    private static var vod: [MediaPlaybackSource] {
        var source = decode(#"{"Id":"movie-1","Name":"EN - Mutiny (2026) [4K]","Container":"mkv","#
            + #""Remux":{"ProviderInfo":{"source":"IPTV","filename":"EN - Mutiny (2026) [4K]"}}}"#,
            server: vodID, name: "null")
        source.directURL = URL(string: "http://provider.example/movie/u/p/1.mkv")
        return [source]
    }
}
