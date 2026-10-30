#if os(iOS)
import XCTest
@testable import LineupiOS

@MainActor
final class DeviceReportsTests: XCTestCase {
    func testDetailedReportsStayBoundedAndRestoringOldHistoryCannotDuplicateOrReplaceNewerReports() throws {
        typealias Diagnostic = MobileDeviceReports.Diagnostic
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func report(_ offset: Int) -> Diagnostic {
            .init(begin: start, end: start.addingTimeInterval(Double(offset)), summary: "Hang",
                data: Data("{\"binaryUUID\":\"test-\(offset)\",\"callStackTree\":{}}".utf8))
        }
        let current = (10..<14).map(report)
        let restored = (0..<12).map(report)
        let kept = Diagnostic.keepingLatest(current, alongside: restored)
        XCTAssertEqual(kept.map(\.id), (8..<14).reversed().map { report($0).id })
        XCTAssertEqual(Set(kept.map(\.id)).count, 6)
        let decoded = try JSONDecoder().decode([Diagnostic].self, from: JSONEncoder().encode(kept))
        XCTAssertEqual(decoded, kept, "Keep the original binary UUIDs/stack JSON across launches")
        XCTAssertTrue(decoded[0].json.contains("test-13"))
        let oversized = Diagnostic(begin: start, end: start, summary: "Hang",
            data: Data(repeating: 65, count: 2 * 1024 * 1024 + 1))
        XCTAssertLessThan(oversized.json.utf8.count, 100)
        XCTAssertTrue(oversized.json.contains("local limit"))
    }
}
#endif
