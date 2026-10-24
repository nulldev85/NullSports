import XCTest
import UIKit
@testable import LineupiOS

@MainActor
final class MobilePlaybackPresentationTests: XCTestCase {
    private final class Canvas: UIView {
        let picture = UIView()
        override init(frame: CGRect) { super.init(frame: frame); addSubview(picture) }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() { super.layoutSubviews(); picture.frame = bounds }
    }
    func testEngineCanvasGetsItsActualViewportBeforeDecoderStartupAndAfterRotation() {
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 393, height: 221))
        let canvas = Canvas(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        host.installEngineSurface(canvas)
        XCTAssertEqual(canvas.frame, host.bounds)
        XCTAssertEqual(canvas.picture.frame, canvas.bounds, "Do not open a decoder against placeholder or zero child bounds")
        host.frame.size = CGSize(width: 852, height: 393)
        host.setNeedsLayout(); host.layoutIfNeeded()
        host.installEngineSurface(canvas)
        XCTAssertEqual(canvas.frame, host.bounds)
        XCTAssertEqual(canvas.picture.frame, canvas.bounds)
        XCTAssertEqual(host.subviews.count, 1, "Resizing must reuse the renderer")
    }
    func testLateVLCStyleDrawableFillsTheHostFromItsFirstFrame() {
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 393, height: 221))
        host.holdPicture(true)
        let renderer = Canvas(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        host.addSubview(renderer)
        XCTAssertEqual(renderer.frame, host.bounds)
        XCTAssertEqual(renderer.picture.frame, renderer.bounds)
        XCTAssertEqual(renderer.alpha, 0)
        host.holdPicture(false)
        XCTAssertEqual(renderer.alpha, 1)
        XCTAssertEqual(renderer.frame, host.bounds)
    }
}
