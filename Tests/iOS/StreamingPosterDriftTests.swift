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
}
