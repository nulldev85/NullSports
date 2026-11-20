import SwiftUI

enum PlaybackOptionsTab: String, CaseIterable, Identifiable {
    case info = "Info", stats = "Stats", video = "Video", audio = "Audio"
    case subtitles = "Subtitles", chapters = "Chapters"
    var id: Self { self }
}

struct PlaybackOptionRow: Identifiable {
    let title: String
    var detail: String? = nil
    var selected = false
    var key: String? = nil
    var action: (() -> Void)? = nil
    var id: String { key ?? title }
}

struct PlaybackOptionsPanel: View {
    let tabs: [PlaybackOptionsTab]
    let close: () -> Void
    let rows: (PlaybackOptionsTab) -> [PlaybackOptionRow]
    @State private var tab: PlaybackOptionsTab = .info
    #if os(tvOS)
    private enum FocusTarget: Hashable {
        case tab(PlaybackOptionsTab), row(String), close
    }
    @FocusState private var focus: FocusTarget?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(tabs) { item in tabButton(item) }
                    }
                    .padding(6)
                }
                .scrollIndicators(.hidden)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                    #if os(tvOS)
                        .lineupFocusLayer(focus == .close, in: RoundedRectangle(cornerRadius: 10))
                    #endif
                }
                .lineupFlatButton()
                #if os(tvOS)
                .focused($focus, equals: .close)
                #endif
                .accessibilityLabel("Close playback options")
            }
            .lineupFocusRegion()
            .padding(.horizontal, 8)
            Rectangle().fill(.white.opacity(0.65)).frame(height: 2)
            ScrollView {
                if tab == .stats || tab == .info || tab == .chapters {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in optionRows }
                } else {
                    optionRows
                }
            }
            .id(tab)
            .frame(maxHeight: panelHeight)
            .lineupFocusRegion()
        }
        .foregroundStyle(LineupStyle.mediaText)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
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

    private var panelHeight: CGFloat {
        #if os(tvOS)
        390
        #else
        250
        #endif
    }

    private func tabButton(_ item: PlaybackOptionsTab) -> some View {
        Button { tab = item } label: {
            VStack(spacing: 5) {
                Text(item.rawValue)
                    .font(.inter(.callout, tab == item ? .bold : .medium))
                Capsule().fill(tab == item ? Color.white : .clear).frame(height: 3)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            #if os(tvOS)
            .lineupFocusLayer(focus == .tab(item), in: RoundedRectangle(cornerRadius: 10))
            #endif
        }
        .lineupFlatButton()
        #if os(tvOS)
        .focused($focus, equals: .tab(item))
        #endif
        .accessibilityAddTraits(tab == item ? [.isSelected] : [])
    }

    private var optionRows: some View {
        let entries = rows(tab)
        #if os(tvOS)
        let firstActions = Array(entries.lazy.filter { $0.action != nil }.prefix(2).map(\.id))
        #endif
        return LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(entries) { row in
                if let action = row.action {
                    let control = Button(action: action) {
                        rowLabel(row)
                        #if os(tvOS)
                            .lineupFocusLayer(focus == .row(row.id), in: RoundedRectangle(cornerRadius: 10))
                        #endif
                    }
                    .lineupFlatButton()
                    .accessibilityAddTraits(row.selected ? [.isSelected] : [])
                    #if os(tvOS)
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
                    #else
                    control
                    #endif
                } else {
                    rowLabel(row)
                }
            }
        }
        .padding(12)
    }

    private func rowLabel(_ row: PlaybackOptionRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.title)
                .font(.inter(.body, .semibold))
            if let detail = row.detail {
                Spacer(minLength: 8)
                Text(detail).font(.inter(.callout)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if row.selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LineupStyle.highlight)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

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
                 action: { select(chapter.start) })
        }
    }

    static func speedRows(_ current: Double, set: @escaping (Double) -> Void) -> [Self] {
        [0.5, 0.75, 1, 1.25, 1.5, 2].map { rate in
            Self(title: rate.formatted() + "× speed", selected: rate == current, action: { set(rate) })
        }
    }

    static func subtitleTiming(_ seconds: Double, set: @escaping (Double) -> Void) -> [Self] {
        [Self(title: "Earlier by 250 ms", action: { set(seconds - 0.25) }),
         Self(title: "Later by 250 ms", action: { set(seconds + 0.25) }),
         Self(title: "Reset subtitle delay", detail: String(format: "%+.0f ms", seconds * 1_000), action: { set(0) })]
    }

    static func metrics(buffer: Double?, dropped: Int?, network: Double?) -> [Self] {
        var rows: [Self] = []
        if let buffer, buffer.isFinite { rows.append(.init(title: "Forward buffer", detail: String(format: "%.1f s", buffer))) }
        if let dropped { rows.append(.init(title: "Dropped frames", detail: dropped.formatted())) }
        if let network, network.isFinite { rows.append(.init(title: "Network throughput", detail: String(format: "%.1f Mbps", network))) }
        return rows
    }
}
