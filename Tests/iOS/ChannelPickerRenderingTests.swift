import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

@MainActor
final class ChannelPickerRenderingTests: XCTestCase {
    /// Exercise the real picker, not only its background filter. The number of
    /// constructed rows must follow the viewport, even when clearing search
    /// returns a whole provider. No network logos or external provider needed.
    func testThirtyThousandChannelsOnlyBuildVisibleRowsAndTheLastChannelCanBePicked() async throws {
        let channels = (0..<30_000).map { id in
            XtreamStream(num: id, name: "Sports \(id)", streamType: "live", streamID: id,
                         streamIcon: nil, epgChannelID: nil, categoryID: nil)
        }
        let search = MobileChannelSearch()
        let draft = MobileChannelSearchDraft()
        defer { search.cancel() }
        search.update(channels: channels, preferred: [], favoriteOrder: [])
        try await settle { !search.loading }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let game = SportsGame(id: "picker-preview", league: .nba, start: .now,
            awayTeam: "Boston Celtics", homeTeam: "Charlotte Hornets", awayAbbreviation: "BOS", homeAbbreviation: "CHA",
            awayLogo: "", homeLogo: "", awayScore: "", homeScore: "", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Live", state: "in",
            broadcast: "ESPN", eventName: nil)
        var picked: Int?
        window.rootViewController = UIHostingController(rootView:
            MobileChannelPickerContent(game: game, search: search, draft: draft) { picked = $0.id }
                .preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let table = try XCTUnwrap(findTable(in: window))
        let coordinator = try XCTUnwrap(table.dataSource as? MobileChannelResults.Coordinator)
        let counted = CountingChannelDataSource(wrapped: coordinator)
        table.dataSource = counted
        table.reloadData()
        table.layoutIfNeeded()
        XCTAssertEqual(table.numberOfRows(inSection: 0), channels.count)
        XCTAssertGreaterThan(counted.cellsCreated, 0)
        XCTAssertLessThan(counted.cellsCreated, 200, "Opening the picker must not materialize the entire provider")
        let openingCells = counted.cellsCreated
        for _ in 0..<100 { coordinator.apply(search.page, to: table) }
        table.layoutIfNeeded()
        XCTAssertEqual(counted.cellsCreated, openingCells, "Unrelated parent updates must not reload the results")

        // Drive the field's public binding, without relying on SwiftUI's
        // private backing-view class or accessibility-to-UIView propagation.
        // The visible field and search callback then receive the same draft.
        for query in ["S", "Sp", "Sport", "Sports 2", "Sports 29999"] {
            draft.query = query
        }
        XCTAssertEqual(counted.cellsCreated, openingCells, "Draft changes must not rebuild the channel rows")
        try await settle { search.page.query == "Sports 29999" && table.numberOfRows(inSection: 0) == 1 }
        table.layoutIfNeeded()
        XCTAssertEqual(search.results.first?.id, 29_999)
        XCTAssertLessThan(counted.cellsCreated - openingCells, 200)

        let beforeClear = counted.cellsCreated
        draft.query = ""
        try await settle { search.page.query.isEmpty && table.numberOfRows(inSection: 0) == channels.count }
        table.layoutIfNeeded()
        XCTAssertLessThan(counted.cellsCreated - beforeClear, 200, "Clearing search must also remain lazy")
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let image = XCTAttachment(image: screenshot)
        image.name = "Choose-another-channel-30000-results"
        image.lifetime = .keepAlways
        add(image)

        let last = IndexPath(row: channels.count - 1, section: 0)
        let beforeScroll = counted.cellsCreated
        table.scrollToRow(at: last, at: .bottom, animated: false)
        table.layoutIfNeeded()
        try await settle { table.cellForRow(at: last) != nil }
        XCTAssertEqual(table.cellForRow(at: last)?.accessibilityIdentifier, "ChooseChannel-29999")
        XCTAssertLessThan(counted.cellsCreated - beforeScroll, 200)
        table.delegate?.tableView?(table, didSelectRowAt: last)
        XCTAssertEqual(picked, 29_999, "Selecting a reused row must return the correct stream")
        let evidence = XCTAttachment(string: "30,000 channels; opening cells: \(openingCells); total configured cells after filtering, clearing and end scrolling: \(counted.cellsCreated)")
        evidence.name = "Channel-picker-rendering-work"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func findTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView, table.accessibilityIdentifier == "ChooseAnotherChannelResults" { return table }
        for child in view.subviews { if let table = findTable(in: child) { return table } }
        return nil
    }

    private func settle(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Picker did not reach the expected UI state", file: file, line: line)
        if !condition() { throw NSError(domain: "ChannelPickerRenderingTests", code: 1) }
    }
}

/// Count requests from UIKit itself; the production data source has no test
/// counter or instrumentation that could hide eager row construction.
@MainActor
private final class CountingChannelDataSource: NSObject, UITableViewDataSource {
    let wrapped: MobileChannelResults.Coordinator
    private(set) var cellsCreated = 0
    init(wrapped: MobileChannelResults.Coordinator) { self.wrapped = wrapped }
    func numberOfSections(in tableView: UITableView) -> Int { wrapped.numberOfSections(in: tableView) }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        wrapped.tableView(tableView, numberOfRowsInSection: section)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        cellsCreated += 1
        return wrapped.tableView(tableView, cellForRowAt: indexPath)
    }
}
