import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class PlaylistCompatibilityTests: XCTestCase {
    private let playlist = #"""
    #EXTM3U x-tvg-url="https://example.test/guide.xml.gz?token=test"
    #EXTINF:-1 tvg-id="sports.nba" tvg-logo="https://example.test/logo.png" group-title="NBA",Trail Blazers at Warriors
    https://example.test/live/123.ts?token=first
    #EXTINF:-1 tvg-id="sports.nba" group-title="NBA",Warriors Alternate
    https://example.test/live/456.ts?token=second
    #EXTINF:-1 tvg-id="abc.local" group-title="Local",Local ABC
    https://example.test/live/789.m3u8
    """#

    func testReadsEPGeniusStylePlaylistGroupsLogosAndDistinctFeedsSharingEPG() throws {
        let list = try M3UPlaylist.parse(Data(playlist.utf8))
        XCTAssertEqual(list.streams.count, 3)
        XCTAssertEqual(list.categories.map(\.categoryName), ["NBA", "Local"])
        XCTAssertEqual(list.streams[0].epgChannelID, "sports.nba")
        XCTAssertEqual(list.streams[0].streamIcon, "https://example.test/logo.png")
        XCTAssertEqual(list.guide?.host, "example.test")
        XCTAssertNotEqual(list.streams[0].id, list.streams[1].id, "One EPG ID can have several quality variants")
        XCTAssertFalse(list.streams[0].hasCatchUp, "M3U catch-up formats are not Xtream archives")
        let renamed = playlist.replacingOccurrences(of: "Trail Blazers at Warriors", with: "Tomorrow's event")
            .replacingOccurrences(of: "token=first", with: "token=rotated")
        XCTAssertEqual(try M3UPlaylist.parse(Data(renamed.utf8)).streams.map(\.id), list.streams.map(\.id))
        let channelCache = String(data: try JSONEncoder().encode(list.streams), encoding: .utf8)!
        XCTAssertFalse(channelCache.contains("token="), "Playback URLs stay out of ordinary channel caches")
    }

    func testHTMLAndUnsupportedEntriesCannotReplaceAWorkingPlaylist() throws {
        XCTAssertThrowsError(try M3UPlaylist.parse(Data("<html>Sign in to Drive</html>".utf8)))
        XCTAssertThrowsError(try M3UPlaylist.parse(Data("#EXTM3U\n#EXTINF:-1,Unknown\nfile:///private/file.ts".utf8)))
        let list = try M3UPlaylist.parse(Data((playlist + "\n#EXTINF:-1,Unknown\nrtsp://example.test/source").utf8))
        XCTAssertEqual(list.streams.count, 3)
    }

    func testDriveLinkAndConnectionSecrets() throws {
        let credentials = try PlaylistCredentials(playlist: "https://drive.google.com/file/d/example-id/view?usp=sharing",
            guide: "https://example.test/guide.xml?token=test")
        XCTAssertEqual(credentials.playlist.path, "/uc")
        XCTAssertTrue(credentials.playlist.absoluteString.contains("export=download"))
        XCTAssertEqual(try PlaylistCredentials.read(credentials.encoded).guide, credentials.guide)
        XCTAssertThrowsError(try PlaylistCredentials(playlist: "javascript:alert(1)", guide: ""))
        let oldProfile = try JSONDecoder().decode(XtreamProfile.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Old","serverURL":"https://example.test","username":"user"}"#.utf8))
        XCTAssertFalse(oldProfile.isPlaylist, "Existing Xtream profiles need no migration")
    }

    func testEncryptedCacheRequiresCorrectSecretAndPlaybackUsesPlaylistURL() throws {
        let list = try M3UPlaylist.parse(Data(playlist.utf8))
        var profile = XtreamProfile(name: "Playlist", serverURL: "https://example.test", username: "M3U playlist")
        profile.connectionKind = "m3u"
        defer { try? FileManager.default.removeItem(at: PlaylistCache.url(profile.id)) }
        try PlaylistCache.write(list, profileID: profile.id, secret: "test-secret")
        PlaylistCache.clearMemory()
        XCTAssertNil(PlaylistCache.read(profileID: profile.id, secret: "wrong-secret"))
        let client = XtreamClient(profile: profile, password: "test-secret")
        XCTAssertEqual(client.playbackURLs(for: list.streams[0]), [try XCTUnwrap(list.urls[list.streams[0].id])])
        let bytes = try Data(contentsOf: PlaylistCache.url(profile.id))
        XCTAssertNil(bytes.range(of: Data("token=first".utf8)))
        XCTAssertTrue(client.catchUpURLs(for: list.streams[0], from: Date(), minutes: 30, serverTimeZone: .current).isEmpty)
    }

    func testGzipGuideAndMalformedGuide() throws {
        // gzip.compress(b'<tv></tv>', mtime=0), no Content-Encoding required.
        let compressed = Data([31,139,8,0,0,0,0,0,2,3,179,41,41,179,179,209,7,18,0,118,210,162,192,9,0,0,0])
        let expanded = try XMLTVData.expanded(compressed)
        XCTAssertEqual(String(data: expanded, encoding: .utf8), "<tv></tv>")
        let parser = XMLTVParser()
        _ = parser.parse(expanded)
        XCTAssertTrue(parser.isValid)
        XCTAssertThrowsError(try XMLTVData.expanded(Data([31,139,8,0])))
        let html = XMLTVParser()
        _ = html.parse(Data("<html>Sign in</html>".utf8))
        XCTAssertFalse(html.isValid)
        _ = html.parse(Data("<html><tv/></html>".utf8))
        XCTAssertFalse(html.isValid, "A login page with nested markup is not an XMLTV document")
    }
}
