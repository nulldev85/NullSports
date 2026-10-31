import XCTest
@testable import Lineup

@MainActor
final class TVNavigationWorkTests: XCTestCase {
    func testTickerWindowIsBoundedAndWrapsWithoutDroppingGames() {
        XCTAssertEqual(TVTickerWindow.indices(count: 0, start: 0, viewportWidth: 1920), [])
        XCTAssertEqual(TVTickerWindow.indices(count: 1, start: 0, viewportWidth: 1920), [0, 0, 0, 0])
        XCTAssertEqual(TVTickerWindow.indices(count: 3, start: 2, viewportWidth: 1920), [2, 0, 1, 2])
        for count in [4, 125, 30_000] {
            XCTAssertEqual(TVTickerWindow.indices(count: count, start: count - 1, viewportWidth: 1920).count, 4)
            let visited = (0..<count).map { TVTickerWindow.indices(count: count, start: $0, viewportWidth: 1920)[0] }
            XCTAssertEqual(visited, Array(0..<count), "A bounded viewport must still cycle through every score")
        }
        XCTAssertEqual(TVTickerWindow.stride(at: 1, count: 3), 804)
        XCTAssertEqual(TVTickerWindow.stride(at: 2, count: 3), 838)
    }

    func testThirtyThousandChannelQueryYieldsTheUIActorAndBuildsTheRemoteIndex() async throws {
        let streams = (0..<30_000).map { id in
            XtreamStream(num: 30_000 - id, name: "Channel \(id)", streamType: "live", streamID: id,
                streamIcon: nil, epgChannelID: "epg-\(id)", categoryID: id.isMultiple(of: 2) ? "even" : "odd")
        }
        let heartbeat = TVNavigationHeartbeat()
        let ticker = Task { @MainActor in
            while !heartbeat.finished { heartbeat.beats += 1; await Task.yield() }
        }
        let snapshot = try await TVGuideChannelSnapshot.load(streams, query: .init(categoryID: "even"))
        heartbeat.finished = true
        await ticker.value
        XCTAssertGreaterThan(heartbeat.beats, 0, "Sorting and indexing must yield navigation's actor")
        XCTAssertEqual(snapshot.streams.count, 15_000)
        XCTAssertEqual(snapshot.streams.first?.id, 29_998)
        XCTAssertEqual(snapshot.positions[29_998], 0)
        XCTAssertNil(snapshot.positions[29_999])
        for (index, stream) in snapshot.streams.enumerated() { XCTAssertEqual(snapshot.positions[stream.id], index) }
        let favorites = try await TVGuideChannelSnapshot.load(streams, query: .init(favoritesOnly: true,
            favorites: [7, 5, 1]))
        XCTAssertEqual(favorites.streams.map(\.id), [7, 5, 1])
        let canceled = Task { try await TVGuideChannelSnapshot.load(streams, query: .init()) }
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("Obsolete channel work must cancel") } catch is CancellationError {}
    }
    func testDefaultPreviewUsesTheSameChannelEvidenceAndAirTimeBoundaries() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let streams = (1...3).map { id in
            XtreamStream(num: id, name: "Channel \(id)", streamType: "live", streamID: id,
                streamIcon: nil, epgChannelID: "\(id)", categoryID: nil)
        }
        let program = CurrentProgram(channelID: "3", title: "On air", detail: "",
            start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60))
        let old = CurrentProgram(channelID: "2", title: "Finished", detail: "",
            start: now.addingTimeInterval(-120), end: now)
        let programs = ["2": [old], "3": [program]]
        let preview = try await TVGuideChannelSnapshot.preview(in: streams, programs: programs, now: now)
        XCTAssertEqual(preview?.stream.id, 3)
        XCTAssertEqual(preview?.program, program)
        let ended = try await TVGuideChannelSnapshot.preview(in: streams, programs: programs, now: program.end)
        XCTAssertNil(ended, "A program's ending is exclusive")
        let canceled = Task { try await TVGuideChannelSnapshot.preview(in: streams, programs: programs, now: now) }
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("Canceled preview work must not publish") } catch is CancellationError {}
    }
}

@MainActor private final class TVNavigationHeartbeat {
    var finished = false
    var beats = 0
}
