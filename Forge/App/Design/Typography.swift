import SwiftUI
import UIKit

/// Manrope for words, Geist Mono for numbers and data. Sizes track the
/// system text styles (a touch smaller, since Manrope sets wider than SF)
/// and scale with Dynamic Type.
enum Typeface {
    static func sans(_ weight: Font.Weight) -> String {
        switch weight {
        case .medium: return "Manrope-Medium"
        case .semibold: return "Manrope-SemiBold"
        case .bold: return "Manrope-Bold"
        case .heavy, .black: return "Manrope-ExtraBold"
        default: return "Manrope-Regular"
        }
    }

    static func mono(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: return "GeistMono-Light"
        case .medium: return "GeistMono-Medium"
        case .semibold: return "GeistMono-SemiBold"
        case .bold, .heavy, .black: return "GeistMono-Bold"
        default: return "GeistMono-Regular"
        }
    }

    static func size(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 32
        case .title: return 26
        case .title2: return 21
        case .title3: return 19
        case .headline: return 16
        case .body: return 16
        case .callout: return 15
        case .subheadline: return 14
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 16
        }
    }

    static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .largeTitle, .title: return .bold
        case .title2, .title3, .headline: return .semibold
        default: return .regular
        }
    }

    static func uiFont(_ name: String, size: CGFloat, relativeTo style: UIFont.TextStyle) -> UIFont {
        let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
}

extension Font {
    /// Manrope in a system text style's role.
    static func app(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        .custom(Typeface.sans(weight ?? Typeface.defaultWeight(for: style)), size: Typeface.size(for: style), relativeTo: style)
    }

    /// Manrope at a fixed size that still scales with Dynamic Type.
    static func app(size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(Typeface.sans(weight), size: size, relativeTo: style)
    }

    /// Geist Mono for numbers: weights, reps, clocks, stats.
    static func num(_ style: Font.TextStyle, _ weight: Font.Weight = .medium) -> Font {
        .custom(Typeface.mono(weight), size: (Typeface.size(for: style) * 0.95).rounded(), relativeTo: style)
    }

    static func num(size: CGFloat, _ weight: Font.Weight = .medium, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(Typeface.mono(weight), size: size, relativeTo: style)
    }
}

extension View {
    /// Small mono caps used for labels above values and list sections
    /// ("SETS", "MY ROUTINES").
    func eyebrow() -> some View {
        font(.num(.caption2, .medium))
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(.secondary)
    }
}

/// UIKit-drawn text (navigation titles, tab labels, segmented controls,
/// bar buttons) doesn't read SwiftUI's font environment, so it's set here.
enum AppAppearance {
    static func apply() {
        let ink = Theme.inkUIColor

        let navigation = UINavigationBar.appearance()
        navigation.largeTitleTextAttributes = [
            .font: Typeface.uiFont("Manrope-Bold", size: 32, relativeTo: .largeTitle),
            .foregroundColor: ink,
        ]
        navigation.titleTextAttributes = [
            .font: Typeface.uiFont("Manrope-SemiBold", size: 16, relativeTo: .headline),
            .foregroundColor: ink,
        ]

        let barButton = [NSAttributedString.Key.font: Typeface.uiFont("Manrope-SemiBold", size: 16, relativeTo: .body)]
        UIBarButtonItem.appearance().setTitleTextAttributes(barButton, for: .normal)
        UIBarButtonItem.appearance().setTitleTextAttributes(barButton, for: .highlighted)

        let tab = [NSAttributedString.Key.font: Typeface.uiFont("Manrope-SemiBold", size: 10, relativeTo: .caption2)]
        UITabBarItem.appearance().setTitleTextAttributes(tab, for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes(tab, for: .selected)

        let segmented = UISegmentedControl.appearance()
        segmented.setTitleTextAttributes([.font: Typeface.uiFont("Manrope-Medium", size: 13, relativeTo: .footnote)], for: .normal)
        segmented.setTitleTextAttributes([.font: Typeface.uiFont("Manrope-Bold", size: 13, relativeTo: .footnote)], for: .selected)

    }
}
