import XCTest
@testable import LineupiOS

@MainActor
final class ChannelSearchTests: XCTestCase {
    func testSearchBuildsProviderOrderAndLatestQueryWinsWhileClearRestoresSuggestions() async throws {
        let search = MobileChannelSearch()
        defer { search.cancel() }
        let channels = try [channel(3, "Café Sports", number: 3), channel(2, "ESPN 2", number: 2),
                            channel(1, "ESPN", number: 1), channel(4, "ESPN Radio", number: 0, type: "radio")]
        search.update(channels: channels, excluding: [1])
        try await settle { !search.loading && search.results.map(\.id) == [2, 3] }
        search.search("e")
        search.search("esp")
        search.search("cafe")
        try await settle { search.results.map(\.id) == [3] }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(search.results.map(\.id), [3], "An older query cannot replace the newest results")
        search.search("ESPN")
        try await settle { search.results.map(\.id) == [1, 2] }
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
        search.update(channels: try [channel(1, "Old provider", number: 1)], excluding: [])
        search.update(channels: try [channel(2, "New provider", number: 1)], excluding: [])
        try await settle { !search.loading && search.results.map(\.id) == [2] }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(search.results.map(\.id), [2])
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
