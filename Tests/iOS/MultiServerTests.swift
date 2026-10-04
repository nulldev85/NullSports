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
