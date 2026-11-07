import XCTest
@testable import LineupiOS

/// Badge packs as people share them -- AIOStreams' format, Fusion's and
/// Nuvio's -- and which streams each badge lands on.
final class StreamBadgeTests: XCTestCase {
    private func source(_ json: String) throws -> MediaPlaybackSource {
        try JSONDecoder().decode(MediaPlaybackSource.self, from: Data(json.utf8))
    }

    func testAIOStreamsPacksAreRead() throws {
        let pack = #"""
        {"badges":[
          {"label":"4K","match":"\\b(2160p|4k)\\b","image":"https://example.test/4k.png","group":"res"},
          {"label":"1080p","match":"1080p","group":"res"},
          {"label":"Dolby Vision","match":"\\bDV\\b","fields":["visualTags"],"color":"#fff","background":"#000000cc"},
          {"label":"Broken","match":"x","fields":["somethingElse"]},
          {"label":"","match":"x"}
        ]}
        """#
        let badges = try XCTUnwrap(StreamBadgeReader.read(Data(pack.utf8)))
        XCTAssertEqual(badges.map(\.label), ["4K", "1080p", "Dolby Vision"],
                       "A badge naming only unknown parts, or with no label, is left out")
        XCTAssertEqual(badges[0].imageURL?.absoluteString, "https://example.test/4k.png")
        XCTAssertEqual(badges[2].fields, ["visualTags"])
    }

    func testFusionAndNuvioPacksAreRead() throws {
        let fusion = #"""
        {"filters":[
          {"name":"HDR","pattern":"HDR10","imageURL":"https://example.test/hdr.png","textColor":"#80FF0000",
           "tagStyle":"filled","tagColor":"#FF00FF00","isEnabled":true},
          {"name":"Off","pattern":"x","isEnabled":false}
        ]}
        """#
        let badges = try XCTUnwrap(StreamBadgeReader.read(Data(fusion.utf8)))
        XCTAssertEqual(badges.map(\.label), ["HDR"])
        XCTAssertEqual(badges[0].color, "#FF000080", "Fusion's alpha-first colour is turned round")
        XCTAssertEqual(badges[0].background, "#00FF00FF")

        let nuvio = #"""
        {"settings":{"streamBadgeRules":{"imports":[
          {"isActive":false,"filters":[{"name":"Old","pattern":"x"}]},
          {"isActive":true,"filters":[{"name":"Atmos","pattern":"atmos"}]}
        ]}}}
        """#
        XCTAssertEqual(StreamBadgeReader.read(Data(nuvio.utf8))?.map(\.label), ["Atmos"],
                       "Only the active import of Nuvio's settings is used")
        XCTAssertNil(StreamBadgeReader.read(Data(#"{"hello":"world"}"#.utf8)))
    }

    func testColoursAreRead() {
        XCTAssertEqual(StreamBadgeColor("#fff")?.red, 1)
        XCTAssertEqual(StreamBadgeColor("#00000080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(StreamBadgeColor("rgba(255, 0, 0, 0.5)")?.alpha, 0.5)
        XCTAssertEqual(StreamBadgeColor("transparent")?.alpha, 0)
        XCTAssertNil(StreamBadgeColor("red"))
        XCTAssertNil(StreamBadgeColor("#12345"))
    }

    func testBadgesMatchTheStreamsTheyDescribe() throws {
        let stream = try source(#"""
        {"Id":"a","Name":"4K ⚡ Web-dl","aiostreams":{"id":"v1","name":"4K ⚡ Web-dl",
         "description":"HEVC · DV · HDR10+\nFLUX","filename":"Show.S01E01.2160p.WEB-DL.DV.mkv",
         "visualTags":["DV","HDR10+"],"audioTags":["Atmos"],"resolution":"2160p"}}
        """#)
        let badges = [
            StreamBadge(label: "4K", match: "2160p|4k", group: "res"),
            StreamBadge(label: "1080p", match: "web", group: "res"),
            StreamBadge(label: "DV", match: "^DV$", fields: ["visualTags"]),
            StreamBadge(label: "Atmos", match: "atmos", fields: ["audioTags"]),
            StreamBadge(label: "FLUX", match: "^flux$"),
            StreamBadge(label: "Remux", match: "remux"),
            StreamBadge(label: "Again", match: "2160p", image: nil),
            StreamBadge(label: "4k", match: "hevc"),
            StreamBadge(label: "Bad", match: "(")
        ]
        let shown = StreamBadgeMatcher(badges).badges(for: stream.badgeText).map(\.label)
        XCTAssertEqual(shown, ["4K", "DV", "Atmos", "FLUX", "Again"],
                       "Group alternatives, repeated labels and broken patterns are skipped; anchored patterns match a line")
    }

    func testTheFormattersOwnLinesAreKept() throws {
        let stream = try source(#"""
        {"Id":"a","Name":"x","aiostreams":{"name":"4K ⚡ ⟨Web-dl⟩ ★★★★★",
         "description":"✎ Visionquest S01·E01\n▣ HEVC ✦ 10bit · DV\n\n◈ 5.17 GB · 12.8 Mbps"}}
        """#)
        let lines = try XCTUnwrap(stream.formatterLines)
        XCTAssertEqual(lines.name, ["4K ⚡ ⟨Web-dl⟩ ★★★★★"])
        XCTAssertEqual(lines.description, ["✎ Visionquest S01·E01", "▣ HEVC ✦ 10bit · DV", "◈ 5.17 GB · 12.8 Mbps"])
        XCTAssertNil(try source(#"{"Id":"b","Name":"Plain Jellyfin copy"}"#).formatterLines,
                     "A server without a formatter keeps Lineup's own reading")
        let nullfin = try source(#"{"Id":"c","Name":"StreamNZB\nReacher\nReacher (2022) S04E04 (2160p WEB-DL)\n🎯 Score: +70494"}"#)
        XCTAssertEqual(nullfin.formatterLines?.name, ["StreamNZB"])
        XCTAssertEqual(nullfin.formatterLines?.description,
                       ["Reacher", "Reacher (2022) S04E04 (2160p WEB-DL)", "🎯 Score: +70494"],
                       "A server's name written over several lines is its formatter's, shown as written")
    }
}
