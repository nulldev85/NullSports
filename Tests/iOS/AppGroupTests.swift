import XCTest
@testable import LineupiOS

/// The App Group the widget reads the app's games from, found under whatever
/// name the install was signed with.
final class AppGroupTests: XCTestCase {
    /// A provisioning file as it arrives: the profile as a property list,
    /// wrapped in a signature's binary bytes on both sides.
    private func provisioningFile(groups: [String]) -> Data {
        let list = groups.map { "<string>\($0)</string>" }.joined()
        let profile = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>Name</key><string>Lineup</string>
            <key>Entitlements</key><dict>
                <key>application-identifier</key><string>TEAM123.com.nulldev85.NullSports.iOS</string>
                <key>com.apple.security.application-groups</key><array>\(list)</array>
            </dict>
        </dict></plist>
        """
        return Data([0x30, 0x80, 0x06, 0x09, 0x2A, 0x86]) + Data(profile.utf8) + Data([0xA0, 0x82, 0x0B, 0x00])
    }

    func testTheGroupsAreReadOutOfASignedProvisioningFile() {
        let data = provisioningFile(groups: ["group.com.nulldev85.NullSports.TEAM123"])
        XCTAssertEqual(LineupAppGroup.groups(inProvisioningProfile: data),
                       ["group.com.nulldev85.NullSports.TEAM123"])
        XCTAssertEqual(LineupAppGroup.groups(inProvisioningProfile: Data([0x00, 0x01])), [])
        XCTAssertEqual(LineupAppGroup.groups(inProvisioningProfile: provisioningFile(groups: [])), [])
    }

    func testARenamedGroupForLineupIsTriedBeforeTheDeclaredNameAndAnyOther() {
        let declared = LineupAppGroup.declared
        XCTAssertEqual(LineupAppGroup.candidates(provisioned: ["group.other.app", declared + ".TEAM123"],
                                                 noted: [declared + ".TEAM123"]),
                       [declared + ".TEAM123", declared, "group.other.app"])
        XCTAssertEqual(LineupAppGroup.candidates(provisioned: [], noted: []), [declared])
    }
}
