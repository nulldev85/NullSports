import SwiftUI

enum TVSettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sources, playback, library, sports, appearance, cloud, diagnostics, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sources: "Servers & Sources"
        case .playback: "Playback"
        case .library: "Library"
        case .sports: "Sports & Teams"
        case .appearance: "Appearance"
        case .cloud: "iCloud"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .sources: "externaldrive"
        case .playback: "play.rectangle"
        case .library: "rectangle.stack"
        case .sports: "sportscourt"
        case .appearance: "rectangle.lefthalf.filled"
        case .cloud: "icloud.and.arrow.up"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .sources: "All the places you watch, together."
        case .playback: "Choose how each part of Lineup plays."
        case .library: "Make room for the things you love."
        case .sports: "Your teams. Your preferred channels."
        case .appearance: "A little more your own."
        case .cloud: "Your settings, across your devices."
        case .diagnostics: "A clearer view of how Lineup is running."
        case .about: "At home on your Apple TV."
        }
    }
}

/// The category sidebar stays visible while the settings use the remaining width.
struct TVSettingsLayout {
    let size: CGSize
    var margin: CGFloat { min(50, max(28, size.width * 0.026)) }
    var panelWidth: CGFloat { max(0, size.width - margin * 2) }
    var inset: CGFloat { min(40, panelWidth * 0.023) }
    var sidebarWidth: CGFloat { panelWidth * 0.25 }
    var contentWidth: CGFloat { max(0, panelWidth - inset * 2 - sidebarWidth) }
    var compactHeight: Bool { size.height < 800 }
    var verticalInset: CGFloat { compactHeight ? 22 : 38 }
    var sidebarSpacing: CGFloat { compactHeight ? 4 : 8 }
    var sidebarTitleSize: CGFloat { compactHeight ? 34 : 42 }
    var sidebarRowHeight: CGFloat {
        let header: CGFloat = compactHeight ? 64 : 80
        let available = size.height - 56 - verticalInset * 2 - header - sidebarSpacing * 7
        return min(68, max(44, available / 8))
    }
}

enum TVSettingsPalette {
    static var text: Color { LineupStyle.text }
    static var secondary: Color { LineupStyle.secondary }
    static var focus: Color { LineupStyle.focused }
}

struct TVSettingsBackdrop: View {
    var body: some View {
        LineupStyle.background
        .accessibilityHidden(true)
    }
}

struct TVSettingsGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)
        content
            // The charcoal surface covered almost all of a live material
            // blur. Draw that surface directly, without sampling the screen.
            .background(shape.fill(LineupStyle.surface))
            .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 30, y: 16)
    }
}

struct TVSettingsSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.inter(17, .medium)).tracking(1.4)
            .foregroundStyle(TVSettingsPalette.secondary)
            .padding(.top, 24).padding(.bottom, 8).padding(.horizontal, 18)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct TVSettingsRowFace: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    let symbol: String
    let title: String
    var value: String? = nil
    var chevron = true
    var destructive = false
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 25, weight: .regular))
                .frame(width: 32)
            Text(title).font(.inter(24, .medium)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 20)
            if let value {
                Text(value).font(.inter(21)).lineLimit(2).multilineTextAlignment(.trailing)
                    .foregroundStyle(TVSettingsPalette.secondary)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium))
                    .opacity(0.65)
            }
        }
        .foregroundStyle(destructive ? LineupPresentationStyle.destructive : TVSettingsPalette.text)
        .padding(.horizontal, 18).padding(.vertical, 18)
        .frame(minHeight: 76)
        .background(focused ? TVSettingsPalette.focus : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(enabled ? 1 : 0.36)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

struct TVSettingsAction: View {
    let symbol: String
    let title: String
    let detail: String
    var value: String? = nil
    var destructive = false
    let action: () -> Void
    var body: some View {
        TVSelectable(scale: 1, drawsFocusChrome: false, action: action) {
            TVSettingsRowFace(symbol: symbol, title: title, value: value, destructive: destructive)
        }
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isButton)
    }
}

struct TVSettingsLink<Destination: View>: View {
    @FocusState private var focused: Bool
    let symbol: String
    let title: String
    let detail: String
    var value: String? = nil
    @ViewBuilder var destination: Destination
    var body: some View {
        NavigationLink { destination } label: {
            TVSettingsRowFace(symbol: symbol, title: title, value: value)
                .environment(\.lineupTVSelectableFocused, focused)
        }
        .lineupFlatButton()
        .focused($focused)
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
        .accessibilityHint(detail)
    }
}

struct TVSettingsInfo: View {
    let symbol: String
    let title: String
    let value: String
    var body: some View {
        TVSettingsRowFace(symbol: symbol, title: title, value: value, chevron: false)
            .accessibilityElement(children: .combine)
    }
}
