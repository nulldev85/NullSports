import SwiftUI

/// Library stream results use the same charcoal panel, dividers, selected
/// wells and separate Cancel row as Lineup's dropdown and held-item menus.
struct MobileStreamPickerBoard: View {
    let heading: MediaStreamHeading
    let statuses: [StreamServerStatus]
    let sources: [MediaPlaybackSource]
    let loading: Bool
    let error: String?
    @Binding var filter: String?
    let choose: (MediaPlaybackSource) -> Void
    let cancel: () -> Void
    @State private var contentHeight: CGFloat = 0

    private var sections: [MediaStreamSection] {
        MediaStreamSection.sections(of: sources.filter { filter == nil || $0.group == filter })
    }
    private var shownStatuses: [StreamServerStatus] {
        statuses.filter { filter == nil || $0.name == filter }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                            .padding(.horizontal, LineupPanelStyle.inset)
                        rows
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: MobileStreamContentHeight.self, value: proxy.size.height)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                // Reserve the Cancel row, spacing and outer padding. The
                // entire panel scrolls on short screens or with long titles.
                .frame(height: min(contentHeight > 0 ? contentHeight : 240,
                                   max(0, geometry.size.height - 88)))
                .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
                .overlay(LineupPanelStyle.shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .clipShape(LineupPanelStyle.shape)
                Button(action: cancel) {
                    Text("Cancel")
                        .font(.inter(17, .bold)).foregroundStyle(LineupStyle.text)
                        .fixedSize()
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
                        .overlay(LineupPanelStyle.shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .contentShape(LineupPanelStyle.shape)
                }
                .buttonStyle(MobileStreamRowStyle())
                .accessibilityIdentifier("lineup.streams.cancel")
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .onPreferenceChange(MobileStreamContentHeight.self) { contentHeight = $0 }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            LineupPanelHeader("Choose a Stream", systemImage: "play.rectangle.fill")
            VStack(alignment: .leading, spacing: 4) {
                Text(heading.title).font(.inter(20, .bold)).foregroundStyle(LineupStyle.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let subtitle = heading.subtitle {
                    Text(subtitle).font(.inter(14)).foregroundStyle(LineupPanelStyle.quiet)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if statuses.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterButton(nil, title: "All", count: sources.count)
                        ForEach(statuses) { status in
                            filterButton(status.name, title: status.name,
                                         count: sources.filter { $0.group == status.name }.count,
                                         waiting: status.isWaiting)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(LineupPanelStyle.inset)
    }

    private func filterButton(_ value: String?, title: String, count: Int, waiting: Bool = false) -> some View {
        Button { filter = value } label: {
            HStack(spacing: 6) {
                Text(title).font(.inter(14, .semibold)).lineLimit(1)
                if waiting { ProgressView().controlSize(.mini).tint(LineupPanelStyle.quiet) }
                else { Text("\(count)").font(.interDigits(12, .semibold)).foregroundStyle(LineupPanelStyle.quiet) }
                if filter == value {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LineupStyle.highlight)
                }
            }
            .foregroundStyle(LineupStyle.text)
            .padding(.horizontal, 10).frame(minHeight: 40)
            .background(filter == value ? LineupPanelStyle.well : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle()).fixedSize()
        }
        .buttonStyle(MobileStreamRowStyle())
        .accessibilityAddTraits(filter == value ? [.isSelected] : [])
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sections) { section in
                if sections.count > 1 {
                    Text(section.title.uppercased()).font(.inter(12, .heavy))
                        .foregroundStyle(LineupPanelStyle.caption).padding(.horizontal, 12).padding(.top, 10)
                }
                ForEach(section.sources) { source in
                    Button { choose(source) } label: { MobileStreamResultRow(source: source) }
                        .buttonStyle(MobileStreamRowStyle())
                        .accessibilityIdentifier("lineup.streams.result.\(source.id)")
                }
            }
            if sections.isEmpty, !loading, !shownStatuses.contains(where: \.isWaiting) {
                Text(error ?? "No streams found. Try another source above.")
                    .font(.inter(15)).foregroundStyle(LineupPanelStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
            ForEach(shownStatuses.filter { !$0.isGood }) { status in
                HStack(alignment: .top, spacing: 10) {
                    if status.isWaiting { ProgressView().tint(LineupPanelStyle.quiet) }
                    else { Image(systemName: status.symbol).foregroundStyle(LineupPanelStyle.quiet) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.name).font(.inter(14, .semibold)).foregroundStyle(LineupStyle.text)
                        Text(status.detail).font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                            .fixedSize(horizontal: false, vertical: true)
                        if let tried = status.tried {
                            Text(tried).font(.inter(12)).foregroundStyle(LineupPanelStyle.quiet)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(12)
            }
            if loading && statuses.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Finding streams…").font(.inter(15)) }
                    .foregroundStyle(LineupPanelStyle.quiet).padding(12)
            }
        }.padding(8)
    }
}

private struct MobileStreamResultRow: View {
    let source: MediaPlaybackSource
    private var detail: String {
        [source.quality, source.dynamicRangeTags.isEmpty ? nil : source.dynamicRangeTags.joined(separator: " / "),
         source.sourceTag, source.videoCodec, source.bitDepth, source.audioCodec,
         source.hasAtmos ? "Atmos" : nil, source.audioChannels, source.formattedSize, source.formattedBitrate,
         source.rankLabel, source.isInstant ? "Instant" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LineupIconTile(symbol: "play.fill", size: 28).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.directURL != nil ? "Your IPTV provider’s copy" : source.releaseName)
                    .font(.inter(16, .semibold)).foregroundStyle(LineupStyle.text)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if source.directURL != nil {
                    Text(source.releaseName).font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(2)
                }
                if !detail.isEmpty {
                    Text(detail).font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Text(source.group).font(.inter(12, .semibold)).foregroundStyle(LineupPanelStyle.caption)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LineupPanelStyle.quiet).padding(.top, 8)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct MobileStreamRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LineupPanelStyle.well : .clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MobileStreamContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
