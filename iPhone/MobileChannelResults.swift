import SwiftUI
import UIKit
import Combine

/// The provider can contain tens of thousands of channels. Reuse visible cells
/// instead of handing the entire result array to List/ForEach identification
/// on each answer. A repeated parent update does no table work at all.
struct MobileChannelResults: UIViewRepresentable {
    let search: MobileChannelSearch
    let matchup: String
    let onPick: (XtreamStream) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(matchup: matchup, onPick: onPick) }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.backgroundColor = UIColor(LineupStyle.background)
        table.separatorColor = UIColor(LineupPanelStyle.divider)
        table.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 60
        table.sectionHeaderHeight = UITableView.automaticDimension
        table.estimatedSectionHeaderHeight = 44
        table.sectionFooterHeight = LineupPanelStyle.gap
        table.estimatedSectionFooterHeight = LineupPanelStyle.gap
        table.keyboardDismissMode = .interactive
        table.accessibilityIdentifier = "ChooseAnotherChannelResults"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "channel")
        table.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "heading")
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.bind(search, to: table)
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.bind(search, to: table)
    }

    static func dismantleUIView(_ table: UITableView, coordinator: Coordinator) {
        coordinator.disconnect()
        table.dataSource = nil
        table.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        private var page = MobileChannelSearchPage()
        private let matchup: String
        var onPick: (XtreamStream) -> Void
        private var subscription: AnyCancellable?
        private weak var observedSearch: MobileChannelSearch?
        private weak var observedTable: UITableView?

        init(matchup: String, onPick: @escaping (XtreamStream) -> Void) {
            self.matchup = matchup
            self.onPick = onPick
        }

        /// Completed pages drive UIKit directly. A deferred SwiftUI body update
        /// cannot leave the visible table on an older answer or replay that answer.
        func bind(_ search: MobileChannelSearch, to table: UITableView) {
            guard observedSearch !== search || observedTable !== table else { return }
            disconnect()
            observedSearch = search
            observedTable = table
            subscription = search.$page.sink { [weak self, weak table] page in
                guard let self, let table else { return }
                // MobileChannelSearch is main-actor isolated, including every
                // page publication. Use the emitted page, not its willSet value.
                self.apply(page, to: table)
            }
        }

        func disconnect() {
            subscription?.cancel()
            subscription = nil
            observedSearch = nil
            observedTable = nil
        }

        func apply(_ next: MobileChannelSearchPage, to table: UITableView) {
            guard next.id != page.id else { return }
            let resetPosition = next.query != page.query || next.catalogID != page.catalogID
            page = next
            UIView.performWithoutAnimation {
                table.reloadData()
                if resetPosition {
                    table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
                }
            }
        }

        func numberOfSections(in tableView: UITableView) -> Int {
            guard !page.loading else { return 0 }
            return (page.suggested.isEmpty ? 0 : 1) + (page.results.isEmpty ? 0 : 1)
        }

        private func isSuggested(_ section: Int) -> Bool { !page.suggested.isEmpty && section == 0 }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            isSuggested(section) ? page.suggested.count : page.results.count
        }

        private func stream(at path: IndexPath) -> XtreamStream? {
            let rows = isSuggested(path.section) ? page.suggested : page.results
            return rows.indices.contains(path.row) ? rows[path.row] : nil
        }

        func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "channel", for: path)
            guard let stream = stream(at: path) else { return cell }
            let favorite = page.favoriteIDs.contains(stream.id)
            let suggested = isSuggested(path.section)
            cell.contentConfiguration = UIHostingConfiguration {
                MobileChannelResultRow(stream: stream, favorite: favorite, suggested: suggested)
                    .id(stream)
            }.margins(.all, 0)
            cell.backgroundColor = UIColor(LineupPanelStyle.fill)
            let selected = UIView()
            selected.backgroundColor = UIColor(LineupPanelStyle.well)
            cell.selectedBackgroundView = selected
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "Watch \(matchup) on \(stream.name)"
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = "ChooseChannel-\(stream.id)"
            return cell
        }

        func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            let heading = tableView.dequeueReusableHeaderFooterView(withIdentifier: "heading")
            let suggested = isSuggested(section)
            let title = suggested ? "Suggested" : (page.query.isEmpty ? "All channels" : "Results")
            let symbol = suggested ? "star" : (page.query.isEmpty ? "tv" : "magnifyingglass")
            heading?.contentConfiguration = UIHostingConfiguration {
                LineupPanelHeader(title, systemImage: symbol)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }.margins(.all, 0)
            heading?.backgroundConfiguration = .clear()
            return heading
        }

        func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
            guard let stream = stream(at: path) else { return }
            tableView.deselectRow(at: path, animated: false)
            tableView.window?.endEditing(true)
            onPick(stream)
        }
    }
}

private struct MobileChannelResultRow: View {
    let stream: XtreamStream
    let favorite: Bool
    let suggested: Bool

    var body: some View {
        HStack(spacing: 12) {
            LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 44) { loaded in
                if let image = loaded {
                    image.resizable().scaledToFit()
                } else {
                    Text(stream.name.prefix(3).uppercased()).font(.inter(.caption2, .bold))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.7))
                }
            }
            .frame(width: 44, height: 30).accessibilityHidden(true)
            Text(stream.name).font(.inter(.body, .semibold))
                .lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if favorite {
                Image(systemName: "star.fill").font(.inter(.caption2))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
            }
            if suggested {
                Image(systemName: "sparkles").font(.inter(.caption2))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
