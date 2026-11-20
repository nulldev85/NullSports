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
                button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close playback options")
            }
            .lineupFocusRegion()
            .padding(.horizontal, 8)
            Rectangle().fill(LineupStyle.highlight.opacity(0.65)).frame(height: 2)
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
        .onChange(of: tabs) { _, available in
            if !available.contains(tab) { tab = .info }
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
        button(initialFocus: item == .info, onFocus: { tab = item }, action: { tab = item }) {
            VStack(spacing: 5) {
                Text(item.rawValue)
                    .font(.inter(.callout, tab == item ? .bold : .medium))
                Capsule().fill(tab == item ? LineupStyle.highlight : .clear).frame(height: 3)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .accessibilityAddTraits(tab == item ? [.isSelected] : [])
    }

    private var optionRows: some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(rows(tab)) { row in
                if let action = row.action {
                    button(action: action) { rowLabel(row) }
                        .accessibilityAddTraits(row.selected ? [.isSelected] : [])
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

    private func button<Label: View>(initialFocus: Bool = false, onFocus: (() -> Void)? = nil,
                                     action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        #if os(tvOS)
        TVSelectable(scale: 1.02, fillRadius: 10, drawsFocusChrome: false,
                     action: action, onFocusChange: { focused in
                         if focused { onFocus?() }
                     }, requestInitialFocus: initialFocus) {
            PlaybackOptionFocusLabel { label() }
        }
        #else
        Button(action: action, label: label).buttonStyle(.plain)
        #endif
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
        LineupProgressBar(value: value, reach: reach, height: height, track: .white.opacity(0.30))
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

#if os(tvOS)
private struct PlaybackOptionFocusLabel<Label: View>: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    @ViewBuilder var label: Label

    var body: some View {
        label.lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: 10), lifts: false)
    }
}
#endif
