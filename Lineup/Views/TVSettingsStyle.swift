import SwiftUI

enum TVSettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sources, playback, library, sports, appearance, cloud, diagnostics, about
    var id: String { rawValue }
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
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
    var headline: String {
        switch self {
        case .sources: "Everything,\nconnected."
        case .playback: "A better\nwatch."
        case .library: "A library,\nyour way."
        case .sports: "Closer to\nyour teams."
        case .appearance: "Make it\nyours."
        case .cloud: "Your settings,\ntogether."
        case .diagnostics: "See what’s\nhappening."
        case .about: "Made for\nyour TV."
        }
    }
}

/// Fractions keep the three columns in the same proportions on HD and 4K TVs.
struct TVSettingsLayout {
    let size: CGSize
    var margin: CGFloat { min(50, max(28, size.width * 0.026)) }
    var panelWidth: CGFloat { max(0, size.width - margin * 2) }
    var inset: CGFloat { min(40, panelWidth * 0.023) }
    var sidebarWidth: CGFloat { panelWidth * 0.25 }
    var descriptionWidth: CGFloat { panelWidth * 0.18 }
    var contentWidth: CGFloat { max(0, panelWidth - inset * 2 - sidebarWidth - descriptionWidth) }
    var compactHeight: Bool { size.height < 800 }
    var verticalInset: CGFloat { compactHeight ? 22 : 38 }
    var sidebarSpacing: CGFloat { compactHeight ? 4 : 8 }
    var sidebarTitleSize: CGFloat { compactHeight ? 34 : 42 }
    var sidebarRowHeight: CGFloat {
        let header: CGFloat = compactHeight ? 64 : 80
        let available = size.height - 56 - 46 - verticalInset * 2 - header - sidebarSpacing * 7
        return min(68, max(44, available / 8))
    }
}

enum TVSettingsPalette {
    static let text = Color.white.opacity(0.96)
    static let secondary = Color.white.opacity(0.67)
    static let focus = Color(red: 0.83, green: 0.92, blue: 0.98)
    static let ink = Color(red: 0.10, green: 0.17, blue: 0.21)
}

struct TVSettingsBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.27, green: 0.30, blue: 0.34),
                                        Color(red: 0.14, green: 0.23, blue: 0.29),
                                        Color(red: 0.06, green: 0.20, blue: 0.31)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse().fill(Color(red: 0.26, green: 0.49, blue: 0.65).opacity(0.35))
                    .frame(width: geometry.size.width * 0.9, height: geometry.size.height * 0.65)
                    .blur(radius: 120)
                    .position(x: geometry.size.width * 0.75, y: geometry.size.height * 0.95)
            }
        }
        .accessibilityHidden(true)
    }
}

struct TVSettingsGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(red: 0.20, green: 0.27, blue: 0.33))
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.10),
                            Color(red: 0.19, green: 0.39, blue: 0.52).opacity(0.15)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.11)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 30, y: 16)
    }
}

private struct TVSettingsHelpKey: EnvironmentKey {
    static let defaultValue: ((String, String) -> Void)? = nil
}
extension EnvironmentValues {
    var tvSettingsHelp: ((String, String) -> Void)? {
        get { self[TVSettingsHelpKey.self] }
        set { self[TVSettingsHelpKey.self] = newValue }
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
                    .foregroundStyle(focused ? TVSettingsPalette.ink.opacity(0.78) : TVSettingsPalette.secondary)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium))
                    .opacity(0.65)
            }
        }
        .foregroundStyle(destructive ? (focused ? Color(red: 0.58, green: 0.12, blue: 0.15) : Color(red: 1, green: 0.64, blue: 0.65))
                         : (focused ? TVSettingsPalette.ink : TVSettingsPalette.text))
        .padding(.horizontal, 18).padding(.vertical, 18)
        .frame(minHeight: 76)
        .background(focused ? TVSettingsPalette.focus : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(enabled ? 1 : 0.36)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

struct TVSettingsAction: View {
    @Environment(\.tvSettingsHelp) private var help
    let symbol: String
    let title: String
    let detail: String
    var value: String? = nil
    var destructive = false
    let action: () -> Void
    var body: some View {
        TVSelectable(scale: 1, drawsFocusChrome: false, action: action,
                     onFocusChange: { focused in if focused { help?(title, detail) } }) {
            TVSettingsRowFace(symbol: symbol, title: title, value: value, destructive: destructive)
        }
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isButton)
    }
}

struct TVSettingsLink<Destination: View>: View {
    @Environment(\.tvSettingsHelp) private var help
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
        .onChange(of: focused) { _, value in if value { help?(title, detail) } }
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
