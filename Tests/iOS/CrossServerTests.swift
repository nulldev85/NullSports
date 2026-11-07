import XCTest
@testable import LineupiOS

/// Two servers with the same catalog -- Nullfin and AIOStreams, say -- give
/// one title two identities. Continue Watching and the stream list treat
/// them as the one title they are.
final class CrossServerTests: XCTestCase {
    private func stream(server: UUID, id: String, filename: String, size: Int64? = nil,
                        aiostreams: Bool) throws -> MediaPlaybackSource {
        var payload: [String: Any] = ["Id": id, "Name": "Stream"]
        if let size { payload["Size"] = size }
        if aiostreams { payload["aiostreams"] = ["filename": filename] }
        else { payload["Remux"] = ["ProviderInfo": ["filename": filename]] }
        var source = try JSONDecoder().decode(MediaPlaybackSource.self,
                                              from: JSONSerialization.data(withJSONObject: payload))
        source.serverID = server
        return source
    }

    func testTheSameReleaseFromTwoServersIsListedOnce() throws {
        let aio = UUID(), nullfin = UUID()
        let first = try stream(server: aio, id: "a1", filename: "Show.S01E01.2160p.WEB-DL.DV-FLUX.mkv",
                               size: 5_000_000_000, aiostreams: true)
        let again = try stream(server: nullfin, id: "n1", filename: "show.s01e01.2160p.web-dl.dv-flux.mkv",
                               size: 5_010_000_000, aiostreams: false)
        let other = try stream(server: nullfin, id: "n2", filename: "Show.S01E01.1080p.WEB-DL-NTb.mkv",
                               aiostreams: false)
        let resized = try stream(server: nullfin, id: "n3", filename: "Show.S01E01.2160p.WEB-DL.DV-FLUX.mkv",
                                 size: 9_000_000_000, aiostreams: false)
        let sameServer = try stream(server: aio, id: "a2", filename: "Show.S01E01.2160p.WEB-DL.DV-FLUX.mkv",
                                    size: 5_000_000_000, aiostreams: true)
        XCTAssertEqual(MediaPlaybackSource.withoutDuplicates([first, again, other, resized, sameServer]).map(\.sourceID),
                       ["a1", "n2", "n3", "a2"],
                       "The other server's copy of the same file goes; a different file, size or server's own copies stay")
    }

    func testATitleIsKnownAcrossServers() {
        func movie(_ ids: [String: String]?, name: String = "Dune: Part Two", year: Int? = 2024) -> MediaItem {
            MediaItem(id: UUID().uuidString, name: name, type: "Movie", overview: nil, productionYear: year,
                      primaryImageAspectRatio: nil, childCount: nil, providerIDs: ids)
        }
        XCTAssertEqual(MediaLibrary.crossServerKey(movie(["Imdb": "tt15239678"])),
                       MediaLibrary.crossServerKey(movie(["imdb": "TT15239678", "Tmdb": "693134"])))
        XCTAssertEqual(MediaLibrary.crossServerKey(movie(nil)), MediaLibrary.crossServerKey(movie([:])))
        XCTAssertNotEqual(MediaLibrary.crossServerKey(movie(nil)), MediaLibrary.crossServerKey(movie(nil, year: 1984)))
        let episode = { (series: String) in
            MediaItem(id: UUID().uuidString, name: "Pilot", type: "Episode", overview: nil, productionYear: nil,
                      primaryImageAspectRatio: nil, childCount: nil, indexNumber: 1, parentIndexNumber: 1,
                      seriesName: series, seriesID: UUID().uuidString)
        }
        XCTAssertEqual(MediaLibrary.crossServerKey(episode("Tulsa King")),
                       MediaLibrary.crossServerKey(episode("Tulsa King (2022)")))
        XCTAssertNotEqual(MediaLibrary.crossServerKey(episode("Tulsa King")),
                          MediaLibrary.crossServerKey(episode("Landman")))
    }
}
