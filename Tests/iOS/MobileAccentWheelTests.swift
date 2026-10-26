import XCTest
import CoreGraphics
@testable import LineupiOS

final class MobileAccentWheelTests: XCTestCase {
    func testHueMatchesTheWheelAndTouchesClampToTheColorRim() {
        for (point, expected) in [(CGPoint(x: 282, y: 150), 0.0), (CGPoint(x: 150, y: 282), 0.25),
                                  (CGPoint(x: 18, y: 150), 0.5), (CGPoint(x: 150, y: 18), 0.75)] {
            let color = MobileAccentWheelGeometry.selection(at: point, side: 300, previousHue: 0.7)
            XCTAssertEqual(color.hue, expected, accuracy: 0.0001)
            XCTAssertEqual(color.saturation, 1, accuracy: 0.0001)
        }
        let outer = MobileAccentWheelGeometry.selection(at: CGPoint(x: 900, y: 150), side: 300, previousHue: 0.7)
        XCTAssertEqual(outer.saturation, 1)
    }
    func testNeutralCenterPreservesHueAndInvalidGeometryDoesNotProduceAnInvalidColor() {
        let center = MobileAccentWheelGeometry.selection(at: CGPoint(x: 150, y: 150), side: 300, previousHue: 0.7)
        XCTAssertEqual(center.hue, 0.7)
        XCTAssertEqual(center.saturation, 0)
        let invalid = MobileAccentWheelGeometry.selection(at: CGPoint(x: CGFloat.nan, y: 0), side: 0, previousHue: 0.7)
        XCTAssertEqual(invalid.hue, 0.7)
        XCTAssertEqual(invalid.saturation, 0)
    }
}
