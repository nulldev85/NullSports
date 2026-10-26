import XCTest
@testable import LineupiOS

final class CloudSettingsMergeTests: XCTestCase {
    private typealias Side = CloudSettingsMerge.Side
    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testEachSettingKeepsItsOwnNewestChange() {
        // The phone changed the accent last; the television added a favourite
        // after the phone's copy of the favourites was made.
        let phone = Side(values: ["accent": data("red"), "favorites": data("[]")],
                         changedAt: ["accent": late, "favorites": early])
        let television = Side(values: ["accent": data("blue"), "favorites": data("[espn]")],
                              changedAt: ["accent": early, "favorites": late])
        let merge = CloudSettingsMerge(local: television, remote: phone)
        XCTAssertEqual(merge.taken, ["accent": data("red")])
        XCTAssertEqual(merge.merged.values, ["accent": data("red"), "favorites": data("[espn]")])
        XCTAssertEqual(merge.merged.changedAt, ["accent": late, "favorites": late])
        // The phone, merging what the television then shares, ends up the same.
        let back = CloudSettingsMerge(local: phone, remote: merge.merged)
        XCTAssertEqual(back.taken, ["favorites": data("[espn]")])
        XCTAssertEqual(back.merged, merge.merged)
    }

    func testAValueOnlyOneDeviceHasIsKeptAndNothingIsDeleted() {
        let local = Side(values: ["profiles": data("mine")], changedAt: ["profiles": late])
        let remote = Side(values: ["guide": data("theirs")], changedAt: ["guide": early])
        let merge = CloudSettingsMerge(local: local, remote: remote)
        XCTAssertEqual(merge.taken, ["guide": data("theirs")])
        XCTAssertEqual(merge.merged.values, ["profiles": data("mine"), "guide": data("theirs")])
        XCTAssertEqual(merge.merged.changedAt, ["profiles": late, "guide": early])
    }

    func testAnUnchangedValueTakesNothingAndATieSettlesTheSameWayOnBothDevices() {
        let local = Side(values: ["same": data("value"), "tie": data("apple")], changedAt: ["same": early, "tie": late])
        let remote = Side(values: ["same": data("value"), "tie": data("pear")], changedAt: ["same": late, "tie": late])
        let here = CloudSettingsMerge(local: local, remote: remote)
        let there = CloudSettingsMerge(local: remote, remote: local)
        XCTAssertEqual(here.taken, ["tie": data("pear")])
        XCTAssertTrue(there.taken.isEmpty)
        XCTAssertEqual(here.merged.values, there.merged.values)
        XCTAssertEqual(here.merged.changedAt["same"], late)
    }

    func testSignInsFillGapsAndFollowTheDeviceThatChangedLast() {
        let local = ["one": "old", "two": "kept"]
        let remote = ["one": "new", "three": "added"]
        let newer = CloudSettingsMerge.secrets(local: local, remote: remote, remoteNewer: true)
        XCTAssertEqual(newer.taken, ["one": "new", "three": "added"])
        XCTAssertEqual(newer.merged, ["one": "new", "two": "kept", "three": "added"])
        let older = CloudSettingsMerge.secrets(local: local, remote: remote, remoteNewer: false)
        XCTAssertEqual(older.taken, ["three": "added"])
        XCTAssertEqual(older.merged, ["one": "old", "two": "kept", "three": "added"])
    }
}
