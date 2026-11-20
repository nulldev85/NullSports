import SwiftUI

enum PlaybackOptionsTab: String, CaseIterable, Identifiable {
    case info = "Info", stats = "Stats", video = "Video", audio = "Audio"
    case subtitles = "Subtitles", chapters = "Chapters"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .stats: return "waveform.path.ecg"
        case .video: return "film"
        case .audio: return "waveform"
        case .subtitles: return "captions.bubble"
        case .chapters: return "list.bullet.rectangle"
        }
    }
}

struct PlaybackOptionRow: Identifiable {
    enum Style: Equatable {
        case standard, overview, toggle, action
    }

    let title: String
    var detail: String? = nil
    var selected = false
    var key: String? = nil
    var section: String? = nil
    var symbol: String? = nil
    var style: Style = .standard
    var action: (() -> Void)? = nil
    var id: String { key ?? title }
}

private struct PlaybackOptionGroup: Identifiable {
    let id: String
    let title: String?
    let rows: [PlaybackOptionRow]
}

struct PlaybackOptionsPanel: View {
    let tabs: [PlaybackOptionsTab]
    let close: () -> Void
    let rows: (PlaybackOptionsTab) -> [PlaybackOptionRow]
    @State private var tab: PlaybackOptionsTab = .info
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    #if os(tvOS)
    private enum FocusTarget: Hashable {
        case tab(PlaybackOptionsTab), row(String), close
    }
    @FocusState private var focus: FocusTarget?
    #endif

    private var cornerRadius: CGFloat {
        #if os(tvOS)
        28
        #else
        24
        #endif
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
                .lineupFocusRegion()
            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(height: 1)
            ScrollView {
                if tab == .stats || tab == .info || tab == .chapters {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in tabContent }
                } else {
                    tabContent
                }
            }
            .scrollIndicators(.hidden)
            .id(tab)
            .frame(maxHeight: panelHeight)
            .lineupFocusRegion()
        }
        .foregroundStyle(LineupStyle.mediaText)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(red: 0.055, green: 0.060, blue: 0.075).opacity(0.84))
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.white.opacity(0.08), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 56)
                    Spacer(minLength: 0)
                }
            }
            .clipShape(shape)
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.07)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .lineupShadow(.overlay)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: tab)
        #if os(tvOS)
        .onAppear { focus = .tab(tab) }
        .onChange(of: focus) { _, target in
            if case .tab(let item)? = target { tab = item }
        }
        #endif
        .onChange(of: tabs) { _, available in
            guard !available.contains(tab) else { return }
            tab = .info
            #if os(tvOS)
            focus = .tab(.info)
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(tabs) { item in tabButton(item) }
                }
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .padding(.trailing, 6)
            }
            .scrollIndicators(.hidden)
            closeButton
                .padding(.trailing, 10)
        }
    }

    private var closeButton: some View {
        #if os(tvOS)
        let visualSize: CGFloat = 44
        let hitSize: CGFloat = 52
        let iconSize: CGFloat = 17
        #else
        let visualSize: CGFloat = 32
        let hitSize: CGFloat = 44
        let iconSize: CGFloat = 13
        #endif
        return Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: iconSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.86))
                .frame(width: visualSize, height: visualSize)
                .background(Color.white.opacity(0.10), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .frame(width: hitSize, height: hitSize)
                .contentShape(Circle())
            #if os(tvOS)
                .lineupFocusLayer(focus == .close, in: Circle())
            #endif
        }
        #if os(tvOS)
        .lineupFlatButton()
        .focused($focus, equals: .close)
        #else
        .buttonStyle(PlaybackOptionsPressStyle(pressedScale: 0.88))
        #endif
        .accessibilityLabel("Close playback options")
    }

    private var panelHeight: CGFloat {
        #if os(iOS)
        verticalSizeClass == .compact ? 248 : 360
        #else
        390
        #endif
    }

    private var sectionHeaderSize: CGFloat {
        #if os(tvOS)
        17
        #else
        11
        #endif
    }

    private var statLabelSize: CGFloat {
        #if os(tvOS)
        16
        #else
        10.5
        #endif
    }

    private func tabButton(_ item: PlaybackOptionsTab) -> some View {
        let selected = tab == item
        #if os(tvOS)
        let iconSize: CGFloat = 16
        let hPad: CGFloat = 16
        let vPad: CGFloat = 10
        #else
        let iconSize: CGFloat = 13
        let hPad: CGFloat = 12
        let vPad: CGFloat = 8
        #endif
        return Button { tab = item } label: {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.system(size: iconSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? LineupStyle.highlight : Color.white.opacity(0.55))
                Text(item.rawValue)
                    .font(.inter(.subheadline, selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.64))
                    .lineLimit(1)
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.15))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
                }
            }
            .contentShape(Capsule())
            #if os(tvOS)
            .lineupFocusLayer(focus == .tab(item), in: Capsule())
            #endif
        }
        #if os(tvOS)
        .lineupFlatButton()
        .focused($focus, equals: .tab(item))
        #else
        .buttonStyle(PlaybackOptionsPressStyle(pressedScale: 0.94))
        #endif
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var tabContent: some View {
        let entries = rows(tab)
        if tab == .stats, entries.allSatisfy({ $0.action == nil }) {
            statsGrid(entries)
        } else {
            optionGroups(entries)
        }
    }

    // MARK: - Stats Telemetry Grid

    private func statsGrid(_ entries: [PlaybackOptionRow]) -> some View {
        let compact = entries.filter { !Self.isWideStat($0) }
        let wide = entries.filter { Self.isWideStat($0) }
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return VStack(alignment: .leading, spacing: 10) {
            if !compact.isEmpty {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(compact) { row in statTile(row) }
                }
            }
            ForEach(wide) { row in statTile(row) }
        }
        .padding(14)
    }

    private static func isWideStat(_ row: PlaybackOptionRow) -> Bool {
        let title = row.title.lowercased()
        if title == "formats" || title == "source" { return true }
        return (row.detail?.count ?? 0) > 22
    }

    private func statTile(_ row: PlaybackOptionRow) -> some View {
        let tileShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let statusTint = Self.statusColor(for: row)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let symbol = row.symbol ?? Self.defaultStatSymbol(for: row.title) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusTint ?? Color.white.opacity(0.45))
                }
                Text(row.title.uppercased())
                    .font(.inter(statLabelSize, .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.48))
                    .lineLimit(1)
            }
            HStack(spacing: 7) {
                if let statusTint {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 7, height: 7)
                        .shadow(color: statusTint.opacity(0.7), radius: 4)
                }
                Text(row.detail ?? "—")
                    .font(.interDigits(.subheadline, .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.055), in: tileShape)
        .overlay(tileShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private static func statusColor(for row: PlaybackOptionRow) -> Color? {
        guard row.title.lowercased() == "playback", let value = row.detail?.lowercased() else { return nil }
        if value == "playing" { return LineupStyle.positive }
        if value == "loading" || value == "reconnecting" { return LineupStyle.warning }
        return Color.white.opacity(0.45)
    }

    private static func defaultStatSymbol(for title: String) -> String? {
        switch title.lowercased() {
        case "playback": return "play.circle.fill"
        case "engine": return "cpu"
        case "resolution", "quality": return "sparkles.tv"
        case "source bitrate": return "gauge.with.dots.needle.67percent"
        case "formats": return "rectangle.badge.checkmark"
        case "source": return "server.rack"
        case "forward buffer": return "hourglass"
        case "dropped frames": return "exclamationmark.triangle"
        case "network throughput": return "arrow.down.circle"
        default: return nil
        }
    }

    // MARK: - Grouped Rows

    private func optionGroups(_ entries: [PlaybackOptionRow]) -> some View {
        let groups = Self.group(entries)
        #if os(tvOS)
        let firstActions = Array(entries.lazy.filter { $0.action != nil }.prefix(2).map(\.id))
        #endif
        let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if let heading = group.title, !heading.isEmpty {
                        Text(heading.uppercased())
                            .font(.inter(sectionHeaderSize, .bold))
                            .tracking(0.9)
                            .foregroundStyle(Color.white.opacity(0.46))
                            .padding(.horizontal, 6)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            #if os(tvOS)
                            rowView(row, firstActions: firstActions)
                            #else
                            rowView(row)
                            #endif
                            if index < group.rows.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.07))
                                    .frame(height: 1)
                                    .padding(.leading, 14)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.055), in: cardShape)
                    .overlay(cardShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                }
            }
        }
        .padding(14)
    }

    private static func group(_ entries: [PlaybackOptionRow]) -> [PlaybackOptionGroup] {
        var groups: [PlaybackOptionGroup] = []
        for row in entries {
            if let last = groups.last, last.title == row.section {
                groups[groups.count - 1] = PlaybackOptionGroup(id: last.id, title: last.title, rows: last.rows + [row])
            } else {
                groups.append(PlaybackOptionGroup(id: "\(groups.count)-\(row.section ?? "default")",
                                                  title: row.section, rows: [row]))
            }
        }
        return groups
    }

    #if os(tvOS)
    @ViewBuilder
    private func rowView(_ row: PlaybackOptionRow, firstActions: [String]) -> some View {
        if let action = row.action {
            let control = Button(action: action) {
                rowLabel(row)
                    .lineupFocusLayer(focus == .row(row.id), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .lineupFlatButton()
            .accessibilityAddTraits(row.selected ? [.isSelected] : [])
            let focusedControl = control.focused($focus, equals: .row(row.id))
            if row.id == firstActions.first {
                focusedControl.onMoveCommand { direction in
                    // A full-width row is geometrically closer to the trailing tabs.
                    if direction == .up { focus = .tab(tab) }
                    if direction == .down, let next = firstActions.dropFirst().first { focus = .row(next) }
                }
            } else {
                focusedControl
            }
        } else {
            rowLabel(row)
        }
    }
    #else
    @ViewBuilder
    private func rowView(_ row: PlaybackOptionRow) -> some View {
        if let action = row.action {
            Button(action: action) {
                rowLabel(row)
            }
            .buttonStyle(PlaybackOptionsRowPressStyle())
            .accessibilityAddTraits(row.selected ? [.isSelected] : [])
        } else {
            rowLabel(row)
        }
    }
    #endif

    @ViewBuilder
    private func rowLabel(_ row: PlaybackOptionRow) -> some View {
        if row.style == .overview {
            Text(row.title)
                .font(.inter(.subheadline, .regular))
                .foregroundStyle(Color.white.opacity(0.80))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            let isToggle = row.style == .toggle || (row.action != nil && (row.detail == "On" || row.detail == "Off"))
            HStack(spacing: 12) {
                if let symbol = row.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(row.selected ? LineupStyle.highlight : Color.white.opacity(0.62))
                        .frame(width: 22, alignment: .center)
                }
                Text(row.title)
                    .font(.inter(.subheadline, row.selected ? .bold : .semibold))
                    .foregroundStyle(row.action != nil || row.detail == nil ? Color.white.opacity(0.95) : Color.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if isToggle, let detail = row.detail {
                    toggleBadge(detail)
                } else if let detail = row.detail {
                    Text(detail)
                        .font(.interDigits(.footnote, .semibold))
                        .foregroundStyle(row.selected ? Color.white.opacity(0.92) : Color.white.opacity(0.56))
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, tab == .chapters ? 8 : 0)
                        .padding(.vertical, tab == .chapters ? 3 : 0)
                        .background {
                            if tab == .chapters {
                                Capsule().fill(Color.white.opacity(row.selected ? 0.16 : 0.08))
                            }
                        }
                }
                if row.selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(LineupStyle.highlight)
                        .accessibilityHidden(true)
                } else if row.style == .action {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.36))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if row.selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LineupStyle.highlight.opacity(0.15))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func toggleBadge(_ value: String) -> some View {
        let isOn = value.lowercased() == "on"
        return Text(value)
            .font(.inter(.caption, .bold))
            .foregroundStyle(isOn ? LineupStyle.onHighlight : Color.white.opacity(0.66))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isOn ? LineupStyle.highlight : Color.white.opacity(0.11), in: Capsule())
    }
}

#if !os(tvOS)
private struct PlaybackOptionsPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

private struct PlaybackOptionsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif

/// Chapter ticks do not take focus from the seek gesture or the remote.
struct PlaybackSeekTrack: View {
    let value: Double
    let duration: Double
    var reach: Double? = nil
    var chapters: [PlaybackChapter] = []
    var height: CGFloat

    var body: some View {
        LineupProgressBar(value: value, reach: reach, height: height, track: .white.opacity(0.30), tint: .white)
            .overlay {
                if duration.isFinite, duration > 0, !chapters.isEmpty {
                    Canvas { context, size in
                        let half = (height + 12) / 2
                        var marks = Path()
                        for chapter in chapters where chapter.start > 0 && chapter.start < duration {
                            let x = size.width * (chapter.start / duration)
                            marks.move(to: CGPoint(x: x, y: size.height / 2 - half))
                            marks.addLine(to: CGPoint(x: x, y: size.height / 2 + half))
                        }
                        context.stroke(marks, with: .color(.black.opacity(0.65)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        context.stroke(marks, with: .color(.white.opacity(0.94)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                    .frame(height: height + 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

extension PlaybackOptionRow {
    static func chapterRows(_ chapters: [PlaybackChapter], position: Double,
                            clock: (Double) -> String, select: @escaping (Double) -> Void) -> [Self] {
        let current = chapters.last { $0.start <= position }?.start
        return chapters.enumerated().map { index, chapter in
            Self(title: chapter.label(at: index), detail: clock(chapter.start),
                 selected: chapter.start == current, key: "chapter-\(chapter.start)",
                 section: "Chapters", symbol: "bookmark.fill",
                 action: { select(chapter.start) })
        }
    }

    static func speedRows(_ current: Double, set: @escaping (Double) -> Void) -> [Self] {
        [0.5, 0.75, 1, 1.25, 1.5, 2].map { rate in
            Self(title: rate.formatted() + "× speed", selected: rate == current,
                 section: "Playback Speed", symbol: "gauge.with.needle",
                 action: { set(rate) })
        }
    }

    static func subtitleTiming(_ seconds: Double, set: @escaping (Double) -> Void) -> [Self] {
        [Self(title: "Earlier by 250 ms", section: "Timing", symbol: "gobackward", action: { set(seconds - 0.25) }),
         Self(title: "Later by 250 ms", section: "Timing", symbol: "goforward", action: { set(seconds + 0.25) }),
         Self(title: "Reset subtitle delay", detail: String(format: "%+.0f ms", seconds * 1_000),
              section: "Timing", symbol: "arrow.counterclockwise", action: { set(0) })]
    }

    static func metrics(buffer: Double?, dropped: Int?, network: Double?) -> [Self] {
        var rows: [Self] = []
        if let buffer, buffer.isFinite {
            rows.append(.init(title: "Forward buffer", detail: String(format: "%.1f s", buffer), symbol: "hourglass"))
        }
        if let dropped {
            rows.append(.init(title: "Dropped frames", detail: dropped.formatted(), symbol: "exclamationmark.triangle"))
        }
        if let network, network.isFinite {
            rows.append(.init(title: "Network throughput", detail: String(format: "%.1f Mbps", network), symbol: "arrow.down.circle"))
        }
        return rows
    }
}
