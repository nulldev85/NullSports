import XCTest
@testable import LineupiOS

/// Every connected server feeds the Library at once. These pin down the parts
/// that keep several servers apart -- and the part that recognises the same
/// title on two of them.
@MainActor
final class MultiServerTests: XCTestCase {
    private func movie(_ id: String, _ name: String, year: Int?, ids: [String: String]? = nil,
                       server: UUID? = nil) -> MediaItem {
        MediaItem(id: id, name: name, type: "Movie", overview: nil, productionYear: year,
                  primaryImageAspectRatio: nil, childCount: nil, providerIDs: ids, serverID: server)
    }

    private func episode(_ id: String, show: String, season: Int, number: Int) -> MediaItem {
        MediaItem(id: id, name: "Episode \(number)", type: "Episode", overview: nil,
                  productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                  indexNumber: number, parentIndexNumber: season, seriesName: show)
    }

    // MARK: The same title on two servers

    func testAFilmIsRecognisedByItsIDsWhateverEachServerCallsIt() {
        let nullfin = movie("a", "Dune: Part Two", year: 2024, ids: ["Imdb": "tt15239678"])
        let other = movie("b", "Dune Part Two", year: 2024, ids: ["imdb": "TT15239678", "Tmdb": "693134"])
        XCTAssertTrue(MediaTitleMatch.isSame(nullfin, other))
    }

    // A remake shares its name and nothing else.
    func testDifferentIDsOutweighTheSameName() {
        let original = movie("a", "Dune", year: 1984, ids: ["Imdb": "tt0087182"])
        let remake = movie("b", "Dune", year: 2021, ids: ["Imdb": "tt1160419"])
        XCTAssertFalse(MediaTitleMatch.isSame(original, remake))
    }

    // Providers disagree about release years often enough to allow one.
    func testWithoutIDsTheNameAndYearDecide() {
        let first = movie("a", "The Matrix", year: 1999)
        XCTAssertTrue(MediaTitleMatch.isSame(first, movie("b", "the matrix", year: 2000)))
        XCTAssertFalse(MediaTitleMatch.isSame(first, movie("c", "The Matrix", year: 2003)))
        XCTAssertFalse(MediaTitleMatch.isSame(first, movie("d", "The Matrix Reloaded", year: 1999)))
    }

    func testAnEpisodeIsTheSamePlaceInTheSameShow() {
        let here = episode("e1", show: "Reacher", season: 2, number: 4)
        XCTAssertTrue(MediaTitleMatch.isSame(here, episode("x", show: "reacher", season: 2, number: 4)))
        XCTAssertFalse(MediaTitleMatch.isSame(here, episode("y", show: "Reacher", season: 2, number: 5)))
        XCTAssertFalse(MediaTitleMatch.isSame(here, episode("z", show: "Jack Reacher", season: 2, number: 4)))
    }

    // Remux writes "693134" where an addon wrote "tmdb:693134", and an IMDb id
    // can arrive without its leading zero.
    func testAnIDIsTheSameIDHoweverAServerWritesIt() {
        let remux = movie("a", "The Matrix", year: 1999, ids: ["Tmdb": "603"])
        let addon = movie("b", "Matrix, The", year: 1999, ids: ["Tmdb": "tmdb:603"])
        XCTAssertTrue(MediaTitleMatch.isSame(remux, addon))
        XCTAssertEqual(MediaTitleMatch.canonicalID("imdb", "tt133093"), "tt0133093")
        XCTAssertEqual(MediaTitleMatch.canonicalID("Imdb", " TT0133093 "), "tt0133093")
        XCTAssertEqual(MediaTitleMatch.canonicalID("imdb", "imdb:tt15239678"), "tt15239678")
        XCTAssertEqual(MediaTitleMatch.canonicalID("tvdb", "tvdb:081189"), "81189")
        XCTAssertNil(MediaTitleMatch.canonicalID("tmdb", "movie/603"))
        XCTAssertNil(MediaTitleMatch.canonicalID("kitsu", "1376"))
    }

    // A show's TMDB id filed as a film's is a mistake, not a different title:
    // the name and the exact year still find it. A year apart they do not.
    func testADifferentTMDBIDLeavesTheNameAndExactYearToDecide() {
        let here = movie("a", "Nosferatu", year: 2024, ids: ["Tmdb": "426063"])
        XCTAssertTrue(MediaTitleMatch.isSame(here, movie("b", "Nosferatu", year: 2024, ids: ["Tmdb": "1"])))
        XCTAssertFalse(MediaTitleMatch.isSame(here, movie("c", "Nosferatu", year: 2023, ids: ["Tmdb": "1"])))
        XCTAssertFalse(MediaTitleMatch.isSame(here, movie("d", "Nosferatu", year: nil, ids: ["Tmdb": "1"])))
    }

    func testAFilmFiledAsAVideoIsStillTheFilm() {
        let film = movie("a", "Arrival", year: 2016, ids: ["Imdb": "tt2543164"])
        let video = MediaItem(id: "b", name: "Arrival", type: "Video", overview: nil, productionYear: 2016,
                              primaryImageAspectRatio: nil, childCount: nil, providerIDs: ["Imdb": "tt2543164"])
        XCTAssertTrue(MediaTitleMatch.isSame(film, video))
        let show = MediaItem(id: "c", name: "Arrival", type: "Series", overview: nil, productionYear: 2016,
                             primaryImageAspectRatio: nil, childCount: nil, providerIDs: ["Imdb": "tt2543164"])
        XCTAssertFalse(MediaTitleMatch.isSame(film, show))
    }

    func testANameIsTheSameWithoutItsYearOrItsAmpersand() {
        XCTAssertEqual(MediaTitleMatch.normalized("Dune (2021)"), MediaTitleMatch.normalized("Dune"))
        XCTAssertEqual(MediaTitleMatch.normalized("Fast & Furious"), MediaTitleMatch.normalized("Fast and Furious"))
        // A title that is a year keeps it.
        XCTAssertEqual(MediaTitleMatch.normalized("1917"), "1917")
    }

    // A search that does not see past punctuation is asked again in plain words.
    func testATitleIsSearchedForByItsNameThenItsWords() {
        XCTAssertEqual(MediaTitleMatch.searchTerms(for: "Dune: Part Two"), ["Dune: Part Two", "Dune Part Two"])
        XCTAssertEqual(MediaTitleMatch.searchTerms(for: "Schindler's List"), ["Schindler's List", "Schindlers List"])
        XCTAssertEqual(MediaTitleMatch.searchTerms(for: "Arrival"), ["Arrival"])
        XCTAssertEqual(MediaTitleMatch.searchTerms(for: "  "), [])
    }

    // MARK: Asking a server for a title by its ids

    // Ids made by AIOStreams' own packing code (packages/core/src/jellyfin/ids.ts)
    // from the same titles.
    func testAnAIOStreamsIDIsTheTitlesOwnIDPacked() {
        XCTAssertEqual(AIOStreamsItemID.make(.movie, provider: "imdb", value: "tt15239678"),
                       "a11101000000e889feffffffff000000")
        XCTAssertEqual(AIOStreamsItemID.make(.movie, provider: "Imdb", value: "tt133093"),
                       "a111010000000207e5ffffffff000000")
        XCTAssertEqual(AIOStreamsItemID.make(.movie, provider: "tmdb", value: "693134"),
                       "a112010000000a938effffffff000000")
        XCTAssertEqual(AIOStreamsItemID.make(.series, provider: "imdb", value: "tt0903747"),
                       "a121020000000dca43ffffffff000000")
        XCTAssertEqual(AIOStreamsItemID.make(.series, provider: "tmdb", value: "1396"),
                       "a12202000000000574ffffffff000000")
        XCTAssertEqual(AIOStreamsItemID.make(.series, provider: "tvdb", value: "81189"),
                       "a12302000000013d25ffffffff000000")
        XCTAssertEqual(AIOStreamsItemID.make(.episode, provider: "imdb", value: "tt0903747", season: 1, episode: 1),
                       "a141020000000dca4300010001000000")
        XCTAssertEqual(AIOStreamsItemID.make(.episode, provider: "tmdb", value: "1396", season: 2, episode: 3),
                       "a1420200000000057400020003000000")
        XCTAssertEqual(AIOStreamsItemID.make(.episode, provider: "imdb", value: "tt0903747", season: 0, episode: 12),
                       "a141020000000dca430000000c000000")
    }

    func testOnlyAWholeIDPacks() {
        XCTAssertNil(AIOStreamsItemID.make(.episode, provider: "imdb", value: "tt0903747"))
        XCTAssertNil(AIOStreamsItemID.make(.movie, provider: "kitsu", value: "1376"))
        XCTAssertNil(AIOStreamsItemID.make(.movie, provider: "imdb", value: "nm0000206"))
    }

    // Remux and AIOStreams each say which they are; anything else is Jellyfin.
    func testAServerSaysWhichKindItIs() throws {
        func kind(_ json: String) throws -> MediaServerKind {
            try JSONDecoder().decode(MediaServerPublicInfo.self, from: Data(json.utf8)).kind
        }
        XCTAssertEqual(try kind(#"{"ServerName":"AIOStreams","Version":"10.11.0","aiostreams":{"logo":null,"configureUrl":"https://example.com/configure","features":{"versions":1}}}"#),
                       .aiostreams)
        XCTAssertEqual(try kind(#"{"ServerName":"Nullfin","Version":"10.11.0","RemuxVersion":"0.9.2","Id":"x"}"#), .remux)
        XCTAssertEqual(try kind(#"{"ServerName":"Home","Version":"10.11.0","ProductName":"Jellyfin Server"}"#), .jellyfin)
    }

    // How a search across servers lists a title both of them hold once.
    func testTwoServersCopiesOfATitleShareASearchKey() {
        let first = movie("a", "Dune: Part Two", year: 2024, ids: ["Imdb": "tt15239678"])
        let second = movie("b", "Dune Part Two", year: 2024)
        let other = movie("c", "Arrival", year: 2016)
        XCTAssertFalse(Set(MediaTitleMatch.keys(of: first)).isDisjoint(with: MediaTitleMatch.keys(of: second)))
        XCTAssertTrue(Set(MediaTitleMatch.keys(of: first)).isDisjoint(with: MediaTitleMatch.keys(of: other)))
    }

    // MARK: Keeping servers apart

    func testAShelfIsNamedByItsServerAsWellAsItsLibrary() {
        let server = UUID()
        let root = MediaItem(id: "movies", name: "Movies", type: "CollectionFolder", overview: nil,
                             productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                             serverID: server)
        XCTAssertEqual(MediaCatalog(root: root, items: []).id, server.uuidString + "|movies")
        let list = MediaItem(id: "mdblist:7", name: "List", type: "Folder", overview: nil,
                             productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        XCTAssertEqual(MediaCatalog(root: list, items: []).id, "mdblist:7")
    }

    func testStreamsNumberedAlikeOnTwoServersStayApart() throws {
        let data = Data(#"{"Id":"source-1","Name":"StreamNZB"}"#.utf8)
        var first = try JSONDecoder().decode(MediaPlaybackSource.self, from: data)
        var second = first
        first.serverID = UUID()
        second.serverID = UUID()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.sourceID, "source-1")
    }

    func testAnItemsServerSurvivesTheLaunchCache() throws {
        let server = UUID()
        let item = movie("a", "Film", year: 2020, server: server)
        let restored = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.serverID, server)
        XCTAssertEqual(restored, item)
    }

    func testTheSameItemIDOnTwoServersKeepsTwoPlaces() throws {
        let (library, first, second, cleanup) = try makeLibrary()
        defer { cleanup() }
        let onFirst = movie("film", "Film", year: 2024, server: first.id)
        let onSecond = movie("film", "Film", year: 2024, server: second.id)

        library.trackPlayback(of: onFirst, position: 600, duration: 6_000)
        XCTAssertEqual(library.resumePosition(for: onFirst), 600)
        XCTAssertNil(library.resumePosition(for: onSecond))
        XCTAssertEqual(library.continueWatching.map(\.profileID), [first.id])

        library.setLocalFavorite(true, for: onSecond)
        XCTAssertTrue(library.isLocalFavorite(onSecond))
        XCTAssertFalse(library.isLocalFavorite(onFirst))
        XCTAssertEqual(library.favoriteMedia.first?.serverID, second.id)
    }

    // A record saved before items carried their server still knows it.
    func testOlderRecordsAreGivenTheServerTheyWereSavedUnder() throws {
        let suite = "MultiServerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MediaServerProfile(name: "First", serverURL: "http://first", username: "a", userID: "u1")
        let second = MediaServerProfile(name: "Second", serverURL: "http://second", username: "b", userID: "u2")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.mediaServers")
        let unmarked = movie("film", "Film", year: 2024)
        let record = LocalMediaPlayback(profileID: second.id, item: unmarked, position: 600,
                                        duration: 6_000, updatedAt: Date(), completed: false)
        defaults.set(try JSONEncoder().encode([record]), forKey: "Lineup.localMediaPlayback.v1")

        let library = MediaLibrary(defaults: defaults)

        XCTAssertEqual(library.continueWatching.first?.item.serverID, second.id)
    }

    // The hero and the MDBList shelves were chosen per server, and only the
    // active server's showed. The active server's hero carries over, and
    // every list any server had.
    func testTheActiveServersLibraryChoicesCarryOver() throws {
        let suite = "MultiServerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MediaServerProfile(name: "First", serverURL: "http://first", username: "a", userID: "u1")
        let second = MediaServerProfile(name: "Second", serverURL: "http://second", username: "b", userID: "u2")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.mediaServers")
        defaults.set(second.id.uuidString, forKey: "NullSports.activeMediaServer")
        defaults.set(try JSONEncoder().encode([first.id.uuidString: "movies",
                                               second.id.uuidString: "shows"]),
                     forKey: "Lineup.mediaHeroCatalog.v1")
        defaults.set(try JSONEncoder().encode([first.id.uuidString: [1, 2],
                                               second.id.uuidString: [2, 3]]),
                     forKey: "Lineup.mdbListShelves.v1")

        let library = MediaLibrary(defaults: defaults)

        XCTAssertEqual(library.selectedHeroCatalogID, second.id.uuidString + "|shows")
        let lists = try JSONDecoder().decode([String: [Int]].self,
            from: XCTUnwrap(defaults.data(forKey: "Lineup.mdbListShelves.v1")))
        XCTAssertEqual(lists, ["library": [2, 3, 1]])
    }

    func testShelvesNameTheirServerOnlyWhenThereAreSeveral() throws {
        let (library, first, _, cleanup) = try makeLibrary()
        defer { cleanup() }
        let root = MediaItem(id: "movies", name: "Movies", type: "CollectionFolder", overview: nil,
                             productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                             serverID: first.id)
        let shelf = MediaCatalog(root: root, items: [])
        XCTAssertEqual(library.serverName(for: shelf), "First")
        XCTAssertEqual(library.shelfName(shelf), "Movies · First")

        let suite = "MultiServerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([first]), forKey: "NullSports.mediaServers")
        let alone = MediaLibrary(defaults: defaults)
        XCTAssertNil(alone.serverName(for: shelf))
        XCTAssertEqual(alone.shelfName(shelf), "Movies")
    }

    // Only titles another server can be asked about by name go looking there.
    func testStreamsAreAskedOfEveryServerForAFilmOrAnEpisode() throws {
        let (library, first, second, cleanup) = try makeLibrary()
        defer { cleanup() }
        let film = movie("film", "Film", year: 2024, server: second.id)
        XCTAssertEqual(library.streamServers(for: film).map(\.id), [second.id, first.id])
        let clip = MediaItem(id: "clip", name: "Clip", type: "Video", overview: nil, productionYear: nil,
                             primaryImageAspectRatio: nil, childCount: nil, serverID: first.id)
        XCTAssertEqual(library.streamServers(for: clip).map(\.id), [first.id])
    }

    private func makeLibrary() throws
        -> (MediaLibrary, MediaServerProfile, MediaServerProfile, () -> Void) {
        let suite = "MultiServerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let first = MediaServerProfile(name: "First", serverURL: "http://first", username: "a", userID: "u1")
        let second = MediaServerProfile(name: "Second", serverURL: "http://second", username: "b", userID: "u2")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.mediaServers")
        return (MediaLibrary(defaults: defaults), first, second,
                { defaults.removePersistentDomain(forName: suite) })
    }
}
