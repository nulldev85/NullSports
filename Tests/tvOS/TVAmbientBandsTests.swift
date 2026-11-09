import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import Lineup

final class TVAmbientBandsTests: XCTestCase {
    let screen = CGSize(width: 1920, height: 1080)

    func testScopeMovieLightsInnerHalfOfEachHorizontalBar() throws {
        let bands = try XCTUnwrap(TVAmbientBands(video: CGSize(width: 1920, height: 800), drawable: screen, host: screen))
        XCTAssertTrue(bands.horizontal)
        XCTAssertEqual(bands.first, CGRect(x: 0, y: 70, width: 1920, height: 70))
        XCTAssertEqual(bands.second, CGRect(x: 0, y: 940, width: 1920, height: 70))
    }

    func testPillarboxLightsInnerHalfOfEachSideBar() throws {
        let bands = try XCTUnwrap(TVAmbientBands(video: CGSize(width: 1440, height: 1080), drawable: screen, host: screen))
        XCTAssertFalse(bands.horizontal)
        XCTAssertEqual(bands.first, CGRect(x: 120, y: 0, width: 120, height: 1080))
        XCTAssertEqual(bands.second, CGRect(x: 1680, y: 0, width: 120, height: 1080))
    }

    func testFullFrameBlackCreditsUnavailableAndInvalidGeometryHaveNoOverlay() {
        for video in [screen, CGSize.zero, CGSize(width: CGFloat.nan, height: 1080)] {
            XCTAssertNil(TVAmbientBands(video: video, drawable: screen, host: screen))
        }
        XCTAssertNil(TVAmbientBands(video: screen, drawable: .zero, host: screen))
        XCTAssertNil(TVAmbientBands(video: screen, drawable: screen, host: .zero))
    }

    func testArtworkNeverIntersectsMovieAcrossFractionalAndNarrowHosts() {
        for host in [screen, CGSize(width: 1421, height: 1080), CGSize(width: 3840, height: 2160)] {
            let scale = min(host.width / screen.width, host.height / screen.height)
            for width in stride(from: 360, through: 3840, by: 13) {
                let video = CGSize(width: width, height: 1080)
                let fit = min(screen.width / video.width, screen.height / video.height) * scale
                let picture = CGRect(x: (host.width - video.width * fit) / 2, y: (host.height - video.height * fit) / 2,
                                     width: video.width * fit, height: video.height * fit)
                guard let bands = TVAmbientBands(video: video, drawable: screen, host: host) else { continue }
                for band in [bands.first, bands.second] {
                    let overlap = band.intersection(picture)
                    XCTAssertTrue(overlap.isNull || overlap.width < 0.000001 || overlap.height < 0.000001)
                    XCTAssertTrue(CGRect(origin: .zero, size: host).contains(band))
                }
            }
        }
    }
}
