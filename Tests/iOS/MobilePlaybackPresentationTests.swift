import XCTest
import UIKit
import AVFoundation
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
    func testLateVLCStyleDrawableFillsTheHostFromItsFirstFrame() throws {
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 393, height: 221))
        host.holdPicture(true)
        let renderer = Canvas(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        host.addSubview(renderer)
        XCTAssertEqual(renderer.frame, host.bounds)
        XCTAssertEqual(renderer.picture.frame, renderer.bounds)
        XCTAssertEqual(renderer.alpha, 1, "The decoder must remain renderable while its picture is covered")
        XCTAssertFalse(renderer.isHidden)
        let cover = try XCTUnwrap(host.subviews.first { $0.accessibilityIdentifier == "PlaybackStartupCover" })
        XCTAssertTrue(host.subviews.last === cover, "A late decoder view must not cover the startup shield")
        XCTAssertEqual(cover.frame, host.bounds)
        XCTAssertEqual(cover.backgroundColor, .black)
        XCTAssertFalse(cover.isHidden)
        XCTAssertFalse(cover.isUserInteractionEnabled)
        host.holdPicture(false)
        XCTAssertNil(cover.superview)
        XCTAssertEqual(renderer.alpha, 1)
        XCTAssertEqual(renderer.frame, host.bounds)
    }

    func testStartupCoverActuallyHidesVideoPixelsAndLeavesDecoderVisible() throws {
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 64, height: 36))
        let video = UIView(frame: host.bounds)
        video.backgroundColor = .red
        host.addSubview(video)
        func pixel() throws -> [UInt8] {
            let image = UIGraphicsImageRenderer(size: host.bounds.size).image { host.layer.render(in: $0.cgContext) }
            let cgImage = try XCTUnwrap(image.cgImage)
            var rgba = [UInt8](repeating: 0, count: 4)
            let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            XCTAssertTrue(success)
            return rgba
        }
        host.holdPicture(true)
        XCTAssertEqual(video.alpha, 1)
        XCTAssertFalse(video.isHidden)
        XCTAssertEqual(Array(try pixel().prefix(3)), [0, 0, 0])
        host.holdPicture(false)
        let visible = try pixel()
        XCTAssertGreaterThan(visible[0], 240)
        XCTAssertLessThan(visible[1], 10)
        XCTAssertLessThan(visible[2], 10)
        XCTAssertEqual(host.subviews.count, 1)
    }

    func testStartupCoverStaysAboveANativePlayerLayerInstalledAfterIt() throws {
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 393, height: 221))
        host.holdPicture(true)
        let layer = host.installPlayerLayer(for: AVPlayer())
        let cover = try XCTUnwrap(host.subviews.first { $0.accessibilityIdentifier == "PlaybackStartupCover" })
        XCTAssertEqual(layer.opacity, 1, "Native video also needs a renderable layer while covered")
        XCTAssertGreaterThan(cover.layer.zPosition, layer.zPosition)
        XCTAssertEqual(cover.frame, host.bounds)
        host.holdPicture(false)
        XCTAssertNil(cover.superview)
        XCTAssertTrue(host.playerLayer === layer)
    }
}
