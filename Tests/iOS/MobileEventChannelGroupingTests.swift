import XCTest
@testable import LineupiOS

final class MobileEventChannelGroupingTests: XCTestCase {
    private func channel(_ id: Int, _ name: String) -> LiveEventChannel {
        let stream = XtreamStream(num: id, name: name, streamType: "live", streamID: id,
            streamIcon: nil, epgChannelID: "game", categoryID: nil)
        return .init(stream: stream, program: nil, evidence: 100, quality: .init(name: name))
    }
    func testQualitySectionsKeepEveryFeedAndExistingOrderWithinEachQuality() {
        let feeds = [channel(1, "ABC 1080p60"), channel(2, "ABC UHD"), channel(3, "ABC HD"),
                     channel(4, "ABC 1080p50"), channel(5, "ABC 4K"), channel(6, "ABC 720p")]
        let sections = MobileEventChannelSection.grouped(feeds)
        XCTAssertEqual(sections.map(\.height), [2160, 1080, 720])
        XCTAssertEqual(sections.map(\.title), ["4K / UHD", "1080p / Full HD", "720p / HD"])
        XCTAssertEqual(sections.map { $0.channels.map(\.id) }, [[2, 5], [1, 4], [3, 6]])
        XCTAssertEqual(Set(sections.flatMap(\.channels).map(\.id)), Set(feeds.map(\.id)))
    }
    func testUnknownAndFrameRateOnlyFeedsRemainAvailableWithoutInventingResolution() {
        let feeds = [channel(1, "ABC HEVC HDR"), channel(2, "ABC 60FPS"), channel(3, "ABC SD")]
        let sections = MobileEventChannelSection.grouped(feeds)
        XCTAssertEqual(sections.map(\.height), [480, 0])
        XCTAssertEqual(sections.last?.title, "Quality not specified")
        XCTAssertEqual(sections.last?.channels.map(\.id), [1, 2])
        XCTAssertTrue(MobileEventChannelSection.grouped([]).isEmpty)
    }
    func testSeparateStreamsWithIdenticalProviderNamesAreNeverCollapsed() {
        let sections = MobileEventChannelSection.grouped([channel(1, "ABC 4K"), channel(2, "ABC 4K")])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].channels.map(\.id), [1, 2])
    }
}
