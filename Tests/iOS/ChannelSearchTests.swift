import XCTest
import Combine
@testable import LineupiOS

@MainActor
final class ChannelSearchTests: XCTestCase {
    func testSearchBuildsProviderOrderAndLatestQueryWinsWhileClearRestoresSuggestions() async throws {
        let search = MobileChannelSearch()
        defer { search.cancel() }
        let channels = try [channel(3, "Café Sports", number: 3), channel(2, "ESPN 2", number: 2),
                            channel(1, "ESPN", number: 1), channel(4, "ESPN Radio", number: 0, type: "radio")]
        search.update(channels: channels, preferred: [channels[2]], favoriteOrder: [])
        try await settle { !search.loading && search.results.map(\.id) == [2, 3] }
        XCTAssertEqual(search.page.suggested.map(\.id), [1])
        search.search("e")
        search.search("esp")
        search.search("cafe")
        try await settle { search.results.map(\.id) == [3] }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(search.results.map(\.id), [3], "An older query cannot replace the newest results")
        search.search("ESPN")
        try await settle { search.results.map(\.id) == [1, 2] }
        XCTAssertTrue(search.page.suggested.isEmpty)
        search.search("")
        try await settle { search.results.map(\.id) == [2, 3] }
        search.search("ESPN")
        search.cancel()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(search.results.map(\.id), [2, 3], "Dismissal cancels queued search work")
    }

    func testReplacingTheProviderCannotPublishThePreviousCatalog() async throws {
        let search = MobileChannelSearch()
        defer { search.cancel() }
        search.update(channels: try [channel(1, "Old provider", number: 1)], preferred: [], favoriteOrder: [])
        search.search("New") // A draft entered while the catalog is still being built.
        search.update(channels: try [channel(2, "New provider", number: 1)], preferred: [], favoriteOrder: [])
        try await settle { !search.loading && search.results.map(\.id) == [2] }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(search.results.map(\.id), [2])
        XCTAssertEqual(search.page.query, "New")
    }

    func testLargeCatalogDraftsDoNotPublishAndOnlyTheSettledQueryReplacesResults() async throws {
        let search = MobileChannelSearch()
        defer { search.cancel() }
        let channels = (0..<30_000).map { id in
            XtreamStream(num: id, name: "Sports \(id)", streamType: "live", streamID: id,
                         streamIcon: nil, epgChannelID: nil, categoryID: nil)
        }
        search.update(channels: channels, preferred: [channels[10], channels[10]], favoriteOrder: [20, 999_999, 30])
        try await settle { !search.loading }
        XCTAssertEqual(search.page.suggested.map(\.id), [10, 20, 30])
        XCTAssertEqual(search.results.count, channels.count - 3)
        let originalPage = search.page.id
        var publications = 0
        let subscription = search.$page.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        for query in ["S", "Sp", "Spo", "Sport", "Sports", "Sports 2", "Sports 29", "Sports 29999"] {
            search.search(query)
            XCTAssertEqual(search.page.id, originalPage, "A draft must not invalidate the provider-sized results view")
        }
        XCTAssertEqual(publications, 0)
        try await settle { search.page.query == "Sports 29999" }
        XCTAssertEqual(search.results.map(\.id), [29_999])
        XCTAssertEqual(publications, 1)
        search.search("   ")
        try await settle { search.page.query.isEmpty }
        XCTAssertEqual(search.page.suggested.map(\.id), [10, 20, 30])
        XCTAssertEqual(search.results.count, channels.count - 3)
    }

    func testSuggestionsCannotIncludeRadioStaleIDsOrDuplicateProviderRows() async throws {
        let search = MobileChannelSearch()
        defer { search.cancel() }
        let channels = try [channel(1, "Sports", number: 1), channel(1, "Duplicate", number: 2),
                            channel(2, "Radio", number: 3, type: "radio_streams"), channel(3, "Other", number: 4)]
        search.update(channels: channels, preferred: [channels[2], channels[0]], favoriteOrder: [2, 1, 99])
        try await settle { !search.loading }
        XCTAssertEqual(search.page.suggested.map(\.id), [1])
        XCTAssertEqual(search.results.map(\.id), [3])
        search.search("Sports")
        try await settle { search.results.map(\.id) == [1] }
    }

    private func channel(_ id: Int, _ name: String, number: Int, type: String = "live") throws -> XtreamStream {
        let data = try JSONSerialization.data(withJSONObject: ["stream_id": id, "name": name,
                                                               "num": number, "stream_type": type])
        return try JSONDecoder().decode(XtreamStream.self, from: data)
    }

    private func settle(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
