import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// What a stream list is for, drawn at its top.
struct MediaStreamHeading {
    let title: String
    let subtitle: String?
    let backdrop: URL?
}

/// One part of the stream list: the IPTV provider's copies, or one server's
/// streams, ranked by that server's score, highest first.
struct MediaStreamSection: Identifiable {
    let title: String
    let sources: [MediaPlaybackSource]
    var id: String { title }

    /// By where each stream comes from -- VOD first, then the servers in the
    /// order they answered -- and each ranked by its own server's score.
    /// Scores are never compared across servers: StreamNZB's run to the tens
    /// of thousands and AIOStreams' to the hundreds, so a list mixing them
    /// ranks nothing; it only puts one server above the other.
    static func sections(of sources: [MediaPlaybackSource]) -> [MediaStreamSection] {
        var order: [String] = []
        var grouped: [String: [MediaPlaybackSource]] = [:]
        for source in sources {
            if grouped[source.group] == nil { order.append(source.group) }
            grouped[source.group, default: []].append(source)
        }
        return (order.filter { $0 == "VOD" } + order.filter { $0 != "VOD" }).map { group in
            MediaStreamSection(title: group, sources: MediaPlaybackSource.ranked(grouped[group] ?? []))
        }
    }
}

/// The stream list as it is drawn: the title it is for, a tab for each place
/// that was asked, and what they found -- each server's streams ranked by its
/// score, each row leading with what a stream is chosen by. Everything comes
/// from the picker, which does the asking; nothing here goes to a server.
struct MediaStreamBoard: View {
    let heading: MediaStreamHeading
    let statuses: [StreamServerStatus]
    let sources: [MediaPlaybackSource]
    let loading: Bool
    let error: String?
    @Binding var filter: String?
    let choose: (MediaPlaybackSource) -> Void

    private typealias Style = MediaStreamStyle

    private var visible: [MediaPlaybackSource] {
        guard let filter else { return sources }
        return sources.filter { $0.group == filter }
    }

    private var selectedStatus: StreamServerStatus? {
        filter.flatMap { name in statuses.first { $0.name == name } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if statuses.count > 1 { tabs }
                list
            }
            .frame(maxWidth: Style.boardWidth, alignment: .leading)
            .padding(.horizontal, Style.sideInset)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Style.bottomInset)
            // Part of what scrolls, so it leaves with the title and the rows
            // below the first screen sit on a plain background.
            .background(alignment: .top) { MediaStreamBackdrop(url: heading.backdrop) }
        }
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .foregroundStyle(LineupPresentationStyle.text)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Style.headerGap) {
            Text("CHOOSE A STREAM")
                .font(.inter(Style.eyebrowSize, .heavy)).tracking(Style.eyebrowTracking)
                .foregroundStyle(Style.caption)
            Text(heading.title)
                .font(.inter(Style.titleSize, .bold))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let subtitle = heading.subtitle {
                Text(subtitle)
                    .font(.inter(Style.subtitleSize))
                    .foregroundStyle(LineupPresentationStyle.text.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 14, y: 2)
        .padding(.top, Style.headerTop).padding(.bottom, Style.headerBottom)
    }

    // MARK: Tabs

    /// One tab for everything, then one for each place asked -- each server,
    /// and VOD -- saying how its search is going: still looking, how many it
    /// found, or that it has none.
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Style.tabGap) {
                tab(nil, title: "All", mark: allMark)
                ForEach(statuses) { status in
                    tab(status.name, title: status.name, mark: status.mark, brand: status.brand)
                }
            }
            .padding(.vertical, Style.tabLift)
        }
        .scrollClipDisabled()
        .lineupFocusRegion()
        .padding(.bottom, Style.tabsBottom)
    }

    private var allMark: MediaStreamTab.Mark {
        sources.isEmpty && statuses.contains(where: \.isWaiting) ? .looking : .count(sources.count)
    }

    private func tab(_ value: String?, title: String, mark: MediaStreamTab.Mark,
                     brand: MediaServerBrand? = nil) -> some View {
        Button { filter = value } label: {
            MediaStreamTab(title: title, mark: mark, active: filter == value, brand: brand)
        }
        .lineupFlatButton()
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let shown = visible
        if shown.isEmpty {
            emptyState
        } else {
            let sections = MediaStreamSection.sections(of: shown)
            LazyVStack(alignment: .leading, spacing: Style.rowSpacing) {
                ForEach(sections) { section in
                    if sections.count > 1 {
                        sectionHeader(section, first: section.id == sections.first?.id)
                    }
                    ForEach(section.sources) { source in
                        row(source)
                    }
                }
            }
            if filter == nil { missingFooter }
        }
    }

    private func sectionHeader(_ section: MediaStreamSection, first: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let brand = statuses.first(where: { $0.name == section.title })?.brand {
                MediaServerLogo(brand: brand)
                    .frame(width: Style.sectionSize + 2, height: Style.sectionSize + 2)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            }
            Text(section.title.uppercased())
                .font(.inter(Style.sectionSize, .heavy)).tracking(Style.eyebrowTracking)
            Spacer()
            Text("\(section.sources.count)")
                .font(.interDigits(Style.sectionSize, .heavy))
        }
        .foregroundStyle(Style.sectionCaption)
        .padding(.horizontal, Style.rowInsetH)
        .padding(.top, first ? 0 : Style.sectionGap - Style.rowSpacing)
    }

    @ViewBuilder
    private func row(_ source: MediaPlaybackSource) -> some View {
        let label = MediaStreamRow(source: source)
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.cardLift, fillRadius: Style.rowRadius, action: { choose(source) }) {
            label
        }
        #else
        Button { choose(source) } label: { label }
            .lineupFlatButton()
        #endif
    }

    /// The places that added nothing, and why, under everything the others
    /// found -- so a server that should have had the title says how it was
    /// asked, without standing between the viewer and a stream.
    @ViewBuilder
    private var missingFooter: some View {
        let missing = statuses.filter { $0.tried != nil || $0.failure != nil }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: Style.lineGap * 2) {
                ForEach(missing) { status in
                    VStack(alignment: .leading, spacing: Style.lineGap) {
                        HStack(spacing: 6) {
                            if let brand = status.brand {
                                MediaServerLogo(brand: brand).frame(width: Style.noteSize, height: Style.noteSize)
                            }
                            Text(status.failure == nil ? "\(status.name) doesn't have this title"
                                                       : "\(status.name) didn't answer")
                                .font(.inter(Style.noteSize, .semibold))
                        }
                        if let why = status.tried ?? status.failure {
                            Text(why).font(.inter(Style.noteSize - 2)).lineLimit(2)
                                .foregroundStyle(LineupPresentationStyle.text.opacity(0.7))
                        }
                    }
                }
            }
            .foregroundStyle(LineupPresentationStyle.text.opacity(0.6))
            .padding(.horizontal, Style.rowInsetH)
            .padding(.top, Style.sectionGap)
        }
    }

    // MARK: Nothing to list (yet)

    @ViewBuilder
    private var emptyState: some View {
        if let error, sources.isEmpty {
            notice("exclamationmark.triangle", title: "Streams unavailable", detail: error)
        } else if let status = selectedStatus {
            switch status.phase {
            case .looking, .preparing:
                waiting("Asking \(status.name)…", detail: status.isPreparing ? status.detail : nil)
            case .notOnServer(let tried):
                notice("film.stack", title: "\(status.name) doesn't have this title", detail: tried)
            case .failed(let message):
                notice("wifi.exclamationmark", title: "\(status.name) didn't answer", detail: message)
            case .found:
                notice("play.slash", title: "No streams on \(status.name)", detail: nil)
            }
        } else if loading || statuses.contains(where: \.isWaiting) {
            waiting("Finding streams…", detail: asking)
        } else {
            notice("play.slash", title: "No streams found",
                   detail: statuses.count > 1 ? "None of your servers had a playable version of this title."
                                              : "Your server had no playable version of this title.")
        }
    }

    private var asking: String? {
        let names = statuses.map(\.name)
        return names.isEmpty ? nil : "Asking " + ListFormatter.localizedString(byJoining: names)
    }

    private func waiting(_ title: String, detail: String?) -> some View {
        VStack(spacing: Style.lineGap * 2) {
            ProgressView().controlSize(.large)
            Text(title).font(.inter(Style.noticeTitleSize, .semibold))
            if let detail {
                Text(detail).font(.inter(Style.noteSize))
                    .foregroundStyle(LineupPresentationStyle.text.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Style.noticeTop)
        .mediaFocusAnchor()
    }

    private func notice(_ symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: Style.lineGap * 2) {
            Image(systemName: symbol)
                .font(.system(size: Style.noticeSymbolSize, weight: .semibold, design: .rounded))
                .opacity(0.5)
            Text(title).font(.inter(Style.noticeTitleSize, .semibold))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.inter(Style.noteSize))
                    .foregroundStyle(LineupPresentationStyle.text.opacity(0.6))
                    .multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Style.noticeTop)
        .mediaFocusAnchor()
    }
}

/// The title's own wide picture behind the top of the list, fading into the
/// background well before the first row, so it sets the scene without
/// sitting behind anything that has to be read.
struct MediaStreamBackdrop: View {
    let url: URL?

    var body: some View {
        Color.clear
            .frame(height: MediaStreamStyle.backdropHeight + MediaStreamStyle.backdropBleed)
            .frame(maxWidth: .infinity)
            .overlay {
                LineupArtView(url: url, width: MediaStreamStyle.backdropWidth) { image in
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
            .clipped()
            .overlay {
                LinearGradient(stops: [
                    .init(color: LineupPresentationStyle.ground.opacity(0.45), location: 0),
                    .init(color: LineupPresentationStyle.ground.opacity(0.78), location: 0.5),
                    .init(color: LineupPresentationStyle.ground, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                LinearGradient(colors: [LineupPresentationStyle.ground.opacity(0.7), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
            // Up into the margin above the list -- the television's overscan,
            // the phone's bar -- so the picture runs to the top edge rather
            // than stopping a band short of it.
            .padding(.top, -MediaStreamStyle.backdropBleed)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A tab in the stream list: its name, then how its search went.
struct MediaStreamTab: View {
    enum Mark: Equatable {
        case count(Int)
        case looking
        case missing
        case failed
    }

    @Environment(\.isFocused) private var focused
    let title: String
    let mark: Mark
    let active: Bool
    /// The server's logo, ahead of its name.
    var brand: MediaServerBrand? = nil

    private typealias Style = MediaStreamStyle

    var body: some View {
        HStack(spacing: Style.tabInnerGap) {
            if let brand {
                MediaServerLogo(brand: brand).frame(width: Style.tabSize, height: Style.tabSize)
            }
            Text(title).font(.inter(Style.tabSize, .semibold)).lineLimit(1)
            markView
        }
        .padding(.horizontal, Style.tabPadH).padding(.vertical, Style.tabPadV)
        // The app's chips, on both: the accent filled when chosen, outlined
        // otherwise.
        .foregroundStyle(active ? LineupStyle.onHighlight : LineupStyle.highlight)
        .background(active ? LineupStyle.highlight : Color.clear, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? Color.clear : LineupStyle.highlight, lineWidth: 1.5))
        .opacity(quiet && !active ? 0.55 : 1)
        .lineupFocusLayer(focused && !active, in: Capsule())
        .scaleEffect(focused ? LineupStyle.controlLift : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }

    /// A place that found nothing stays a tab -- it says why when chosen --
    /// but steps back from the ones with streams.
    private var quiet: Bool { mark == .missing || mark == .failed }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .count(let count):
            Text("\(count)").font(.interDigits(Style.tabCountSize, .bold)).opacity(0.55)
        case .looking:
            ProgressView()
                .tint(active ? LineupStyle.onHighlight : LineupStyle.highlight)
                .scaleEffect(Style.tabSpinnerScale)
                .frame(width: Style.tabSpinner, height: Style.tabSpinner)
        case .missing:
            Text("—").font(.inter(Style.tabCountSize, .bold)).opacity(0.5)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Style.tabCountSize - 3, weight: .bold, design: .rounded)).opacity(0.6)
        }
    }
}

/// One stream, read the way a stream is chosen: its resolution and range on
/// the left, what it is in a line, the release under that, where it is from
/// under that, and its size on the right, where every row's lines up.
struct MediaStreamRow: View {
    let source: MediaPlaybackSource

    private typealias Style = MediaStreamStyle

    var body: some View {
        HStack(alignment: .center, spacing: Style.rowGap) {
            tile
            VStack(alignment: .leading, spacing: Style.lineGap) {
                Text(summary)
                    .font(.inter(Style.summarySize, .semibold))
                    .lineLimit(Style.summaryLines)
                    .fixedSize(horizontal: false, vertical: true)
                Text(source.releaseName)
                    .font(.inter(Style.releaseSize))
                    .foregroundStyle(LineupPresentationStyle.text.opacity(0.55))
                    .lineLimit(1).truncationMode(.middle)
                #if !os(tvOS)
                // A phone is too narrow for a column of sizes beside the
                // text, so they are a line of their own.
                if let measures = measuresLine {
                    Text(measures)
                        .font(.interDigits(Style.rateSize, .semibold))
                        .foregroundStyle(LineupPresentationStyle.text.opacity(0.8))
                }
                #endif
                origin
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            measures
            #endif
        }
        .padding(.horizontal, Style.rowInsetH).padding(.vertical, Style.rowInsetV)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: Style.rowRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Style.rowRadius, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
        #else
        // A panel of its own, as every card on the phone is.
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: Style.rowRadius, style: .continuous))
        #endif
        .foregroundStyle(LineupPresentationStyle.text)
        .accessibilityElement(children: .combine)
    }

    /// Resolution, large, with the dynamic range under it.
    private var tile: some View {
        VStack(spacing: Style.tileGap) {
            Text(source.quality ?? (source.directURL != nil ? "VOD" : "SD"))
                .font(.interDigits(Style.tileSize, .heavy))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let range = dynamicRange {
                Text(range)
                    .font(.inter(Style.tileRangeSize, .heavy)).tracking(0.6)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .opacity(0.72)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: Style.tileWidth, height: Style.tileHeight)
        .background(LineupPresentationStyle.text.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Style.tileRadius, style: .continuous))
    }

    private var dynamicRange: String? {
        let tags = source.dynamicRangeTags
        return tags.isEmpty ? nil : tags.joined(separator: " · ")
    }

    /// What it is, in one line: where it was mastered from, how it is
    /// encoded, how it sounds.
    private var summary: String {
        var parts: [String] = []
        if let tag = source.sourceTag { parts.append(tag) }
        if let codec = source.videoCodec {
            parts.append(source.bitDepth == "10-bit" ? codec + " 10-bit" : codec)
        }
        let audio = [source.audioCodec, source.audioChannels].compactMap { $0 }.joined(separator: " ")
        if source.hasAtmos {
            parts.append(audio.isEmpty ? "Atmos" : audio + " Atmos")
        } else if !audio.isEmpty {
            parts.append(audio)
        }
        if !parts.isEmpty { return parts.joined(separator: Style.separator) }
        if source.directURL != nil { return "Your IPTV provider's copy" }
        return source.containerLabel.map { $0 + " file" } ?? "Stream"
    }

    /// What a stream is chosen by beyond what it is: the server's ranking,
    /// which the list is in order of, and whether it plays at once. Its
    /// server is the section it is listed under. The add-on and indexer that
    /// found it are left out: they say nothing about which to pick.
    @ViewBuilder
    private var origin: some View {
        let rank = source.rankLabel
        if rank != nil || source.isInstant {
            HStack(spacing: Style.markGap) {
                if let rank {
                    Text(rank).tracking(1.2)
                        .font(.interDigits(Style.markSize + 1, .heavy))
                        .foregroundStyle(LineupPresentationStyle.text.opacity(0.9))
                        .fixedSize()
                }
                if source.isInstant {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                        Text("INSTANT").tracking(1.2)
                    }
                    .foregroundStyle(LineupPresentationStyle.text.opacity(0.85))
                    .fixedSize()
                }
            }
            .font(.inter(Style.markSize, .heavy))
            .foregroundStyle(LineupPresentationStyle.text.opacity(0.45))
        }
    }

    private var measuresLine: String? {
        let parts = [source.formattedSize, source.formattedBitrate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: Style.separator)
    }

    /// Size over bitrate, right-aligned, so the column of them can be read
    /// down the list.
    @ViewBuilder
    private var measures: some View {
        let size = source.formattedSize
        let rate = source.formattedBitrate
        if size != nil || rate != nil {
            VStack(alignment: .trailing, spacing: Style.lineGap) {
                if let size {
                    Text(size).font(.interDigits(Style.sizeSize, .semibold))
                }
                if let rate {
                    Text(rate).font(.interDigits(Style.rateSize)).opacity(0.55)
                }
            }
            .lineLimit(1)
            .frame(width: Style.measureWidth, alignment: .trailing)
        }
    }
}

/// The stream list's measurements, one set per platform.
enum MediaStreamStyle {
    #if os(tvOS)
    static let boardWidth: CGFloat = 1480
    static let sideInset: CGFloat = 0
    static let bottomInset: CGFloat = 60
    static let backdropHeight: CGFloat = 640
    static let backdropBleed: CGFloat = 90
    static let backdropWidth: CGFloat = 1920
    static let headerTop: CGFloat = 36
    static let headerBottom: CGFloat = 30
    static let headerGap: CGFloat = 8
    static let eyebrowSize: CGFloat = 15
    static var caption: Color { LineupPresentationStyle.text.opacity(0.55) }
    static var sectionCaption: Color { LineupPresentationStyle.text.opacity(0.5) }
    static let eyebrowTracking: CGFloat = 2.2
    static let titleSize: CGFloat = 54
    static let subtitleSize: CGFloat = 24
    static let tabSize: CGFloat = 22
    static let tabCountSize: CGFloat = 19
    static let tabPadH: CGFloat = 22
    static let tabPadV: CGFloat = 11
    static let tabGap: CGFloat = 14
    static let tabInnerGap: CGFloat = 10
    static let tabSpinner: CGFloat = 22
    static let tabSpinnerScale: CGFloat = 0.5
    static let tabLift: CGFloat = 10
    static let tabsBottom: CGFloat = 22
    static let sectionSize: CGFloat = 15
    static let sectionGap: CGFloat = 34
    static let rowSpacing: CGFloat = 12
    static let rowRadius: CGFloat = 18
    static let rowInsetH: CGFloat = 22
    static let rowInsetV: CGFloat = 18
    static let rowGap: CGFloat = 24
    static let lineGap: CGFloat = 6
    static let tileWidth: CGFloat = 118
    static let tileHeight: CGFloat = 84
    static let tileRadius: CGFloat = 12
    static let tileGap: CGFloat = 2
    static let tileSize: CGFloat = 30
    static let tileRangeSize: CGFloat = 13
    static let summarySize: CGFloat = 25
    static let releaseSize: CGFloat = 19
    static let markSize: CGFloat = 14
    static let markGap: CGFloat = 12
    static let sizeSize: CGFloat = 25
    static let rateSize: CGFloat = 18
    static let measureWidth: CGFloat = 150
    static let noteSize: CGFloat = 20
    static let noticeTitleSize: CGFloat = 28
    static let noticeSymbolSize: CGFloat = 44
    static let noticeTop: CGFloat = 70
    static let separator = "  ·  "
    static let summaryLines = 1
    #else
    static let boardWidth: CGFloat = .infinity
    static let sideInset: CGFloat = 16
    static let bottomInset: CGFloat = 28
    static let backdropHeight: CGFloat = 300
    static let backdropBleed: CGFloat = 240
    static let backdropWidth: CGFloat = 900
    static let headerTop: CGFloat = 8
    static let headerBottom: CGFloat = 16
    static let headerGap: CGFloat = 4
    static let eyebrowSize: CGFloat = 13
    static var caption: Color { LineupPanelStyle.caption }
    static var sectionCaption: Color { LineupPanelStyle.caption }
    static let eyebrowTracking: CGFloat = 0.4
    static let titleSize: CGFloat = 26
    static let subtitleSize: CGFloat = 14
    static let tabSize: CGFloat = 14
    static let tabCountSize: CGFloat = 12
    static let tabPadH: CGFloat = 14
    static let tabPadV: CGFloat = 8
    static let tabGap: CGFloat = 8
    static let tabInnerGap: CGFloat = 6
    static let tabSpinner: CGFloat = 14
    static let tabSpinnerScale: CGFloat = 0.6
    static let tabLift: CGFloat = 2
    static let tabsBottom: CGFloat = 14
    static let sectionSize: CGFloat = 14
    static let sectionGap: CGFloat = 22
    static let rowSpacing: CGFloat = 8
    static let rowRadius: CGFloat = 20
    static let rowInsetH: CGFloat = 12
    static let rowInsetV: CGFloat = 12
    static let rowGap: CGFloat = 12
    static let lineGap: CGFloat = 3
    static let tileWidth: CGFloat = 58
    static let tileHeight: CGFloat = 50
    static let tileRadius: CGFloat = 10
    static let tileGap: CGFloat = 1
    static let tileSize: CGFloat = 16
    static let tileRangeSize: CGFloat = 8
    static let summarySize: CGFloat = 15
    static let releaseSize: CGFloat = 12
    static let markSize: CGFloat = 9
    static let markGap: CGFloat = 8
    static let sizeSize: CGFloat = 14
    static let rateSize: CGFloat = 11
    static let measureWidth: CGFloat = 70
    static let noteSize: CGFloat = 13
    static let noticeTitleSize: CGFloat = 17
    static let noticeSymbolSize: CGFloat = 30
    static let noticeTop: CGFloat = 40
    static let separator = " · "
    static let summaryLines = 2
    #endif
}

/// A stream carries anywhere from two to seven badges. One row of them either
/// clips the last few or squeezes every badge until none of them read, so they
/// wrap onto as many lines as the width needs.
struct BadgeFlow: Layout {
    var spacing: CGFloat = 6
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = wrap(subviews, within: proposal.width ?? .infinity)
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? (lines.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in wrap(subviews, within: bounds.width) {
            var x = bounds.minX + (centered ? max(0, (bounds.width - line.width) / 2) : 0)
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func wrap(_ subviews: Subviews, within width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if extended > width, !line.indices.isEmpty {
                lines.append(line)
                line = Line(indices: [index], width: size.width, height: size.height)
            } else {
                line.indices.append(index)
                line.width = extended
                line.height = max(line.height, size.height)
            }
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}
