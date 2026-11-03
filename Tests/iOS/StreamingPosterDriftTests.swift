import XCTest
@testable import LineupiOS

/// The art on a streaming service's poster covers the card at every moment
/// of its drift, whatever shape the art and the card are.
final class StreamingPosterDriftTests: XCTestCase {
    private let cards = [CGSize(width: 120, height: 180), CGSize(width: 210, height: 315),
                         CGSize(width: 310, height: 465)]
    private let pictures = [CGSize(width: 1280, height: 720), CGSize(width: 780, height: 1170),
                            CGSize(width: 1000, height: 1000), CGSize(width: 2000, height: 600)]

    func testArtCoversTheCardThroughoutItsDrift() {
        for card in cards {
            for picture in pictures {
                for direction: CGFloat in [1, -1] {
                    let drift = StreamingPosterDrift(picture: picture, card: card, direction: direction)
                    for step in 0...100 {
                        let progress = CGFloat(step) / 100
                        XCTAssertTrue(drift.covers(card, at: progress),
                                      "\(picture) on \(card) shows an edge at \(progress)")
                    }
                }
            }
        }
    }

    func testWideArtTravelsAndPortraitArtOnlyEasesBack() {
        let card = CGSize(width: 210, height: 315)
        let wide = StreamingPosterDrift(picture: CGSize(width: 1280, height: 720), card: card, direction: 1)
        XCTAssertGreaterThan(wide.reach, 0)
        XCTAssertEqual(wide.offset(at: 0), -wide.offset(at: 1), accuracy: 0.001)
        XCTAssertEqual(wide.offset(at: 0.5), 0, accuracy: 0.001)

        let portrait = StreamingPosterDrift(picture: CGSize(width: 780, height: 1170), card: card, direction: 1)
        XCTAssertEqual(portrait.reach, 0, accuracy: 0.001)
        XCTAssertEqual(portrait.scale(at: 0), StreamingPosterDrift.zoom, accuracy: 0.001)
        XCTAssertEqual(portrait.scale(at: 1), 1, accuracy: 0.001)
    }

    func testAlternateTitlesTravelOppositeWays() {
        let card = CGSize(width: 210, height: 315), picture = CGSize(width: 1280, height: 720)
        let one = StreamingPosterDrift(picture: picture, card: card, direction: 1)
        let other = StreamingPosterDrift(picture: picture, card: card, direction: -1)
        XCTAssertEqual(one.offset(at: 0.2), -other.offset(at: 0.2), accuracy: 0.001)
    }

    /// Every poster keeps one beat: which title is up, and since when,
    /// follows from the time alone, so a poster rebuilt mid-way is where it
    /// would have been.
    @MainActor
    func testPostersChangeOnTheSharedBeat() {
        let interval = StreamingServicePoster.interval
        let first = StreamingPosterSchedule(order: 0)
        let now: CFTimeInterval = 1000
        let tick = first.nextTick(after: now, anchor: 0)
        XCTAssertGreaterThan(tick, now)
        XCTAssertLessThanOrEqual(tick - now, interval)
        XCTAssertEqual(first.target(at: tick, count: 5, after: nil), (first.index(at: now, count: 5) + 1) % 5)
        XCTAssertEqual(first.began(at: tick + interval / 2) ?? -1, tick, accuracy: 0.0001)
        XCTAssertEqual(first.index(at: now, count: 5), first.index(at: now + 0.5, count: 5))
    }

    @MainActor
    func testNeighbouringServicesChangeAQuarterBeatApart() {
        let interval = StreamingServicePoster.interval
        let ticks = (0..<4).map { StreamingPosterSchedule(order: $0).nextTick(after: 1000, anchor: 0) }
        XCTAssertEqual(Set(ticks.map { Int(($0 * 1000).rounded()) }).count, 4)
        XCTAssertEqual(StreamingPosterSchedule(order: 1).offset - StreamingPosterSchedule(order: 0).offset,
                       interval / 4, accuracy: 0.0001)
    }

    /// A title is up for less time than one way of its drift takes, so it is
    /// still moving when the next fades in over it.
    @MainActor
    func testAPictureIsStillMovingWhenTheNextArrives() {
        XCTAssertGreaterThanOrEqual(StreamingServicePoster.span,
                                    StreamingServicePoster.interval + StreamingServicePoster.fade)
    }
}
