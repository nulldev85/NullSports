import XCTest
@testable import Lineup

@MainActor
final class TVNavigationWorkTests: XCTestCase {
    func testGuideWindowReusesListingsAcrossFocusMovesAndInvalidatesOnChanges() async {
        let cache = TVGuideProgramWindow()
        let start = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 7200)
        let owner = ObjectIdentifier(cache)
        var reads = 0
        func read(_ revision: Int, _ windowStart: Date, channel: String = "abc") -> [CurrentProgram] {
            cache.programs(channel: channel, library: owner, revision: revision, start: windowStart, end: end) {
                reads += 1
                return [120, 60, 0, -60, 7200].map { offset in
                    let time = start.addingTimeInterval(Double(offset))
                    return CurrentProgram(channelID: channel, title: String(offset), detail: "",
                                          start: time, end: time.addingTimeInterval(60))
                }
            }
        }
        for _ in 0..<200 { XCTAssertEqual(read(1, start).map(\.title), ["0", "60", "120"]) }
        XCTAssertEqual(reads, 1)
        _ = read(1, start, channel: "def")
        _ = read(2, start)
        XCTAssertEqual(read(2, start.addingTimeInterval(60)).map(\.title), ["60", "120"])
        XCTAssertEqual(reads, 4)
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
