import SwiftUI
import CoreText
import UIKit

/// Inter, which is the app's typeface everywhere text is drawn.
///
/// The app used the system font: San Francisco on both platforms, with a few
/// screens asking for its rounded cut. That is three typefaces' worth of
/// personality across one app -- SF Pro on the phone, SF Pro at television
/// metrics on the television, and SF Rounded wherever a heading happened to
/// have been written that way -- and none of them were chosen. Inter is one
/// face, drawn for screens, and it is chosen.
///
/// Seven weights ship with the app. A weight is a *file* here rather than an
/// argument: SwiftUI's `.weight()` and `.bold()` reliably pick a face only for
/// the system font, so asking a custom font for semibold can silently hand
/// back regular, or a synthesised smear of it. Naming the face outright is the
/// only way to be sure the letters on screen are the ones intended.
enum LineupFonts {
    /// PostScript names, which is what `Font.custom` resolves.
    static let faces = [
        "Inter-Light", "Inter-Regular", "Inter-Medium", "Inter-SemiBold",
        "Inter-Bold", "Inter-ExtraBold", "Inter-Black"
    ]

    /// Make the bundled faces available to the process.
    ///
    /// Registered in code rather than declared in `UIAppFonts`, because both
    /// targets have their Info.plist generated for them and there is no build
    /// setting for that key. This runs before the first view is built; if it
    /// somehow fails, `Font.custom` falls back to the system font and the app
    /// reads as it did before rather than drawing nothing.
    static func register() {
        let urls = faces.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
        }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// The face that carries a weight. Inter has no ultra-light or thin cut in
    /// this set, and nothing in the app asks for one; both land on Light.
    static func face(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: return "Inter-Light"
        case .medium: return "Inter-Medium"
        case .semibold: return "Inter-SemiBold"
        case .bold: return "Inter-Bold"
        case .heavy: return "Inter-ExtraBold"
        case .black: return "Inter-Black"
        default: return "Inter-Regular"
        }
    }

    /// A text style's weight when none is asked for. Every style is regular
    /// except headline, which the system draws semibold -- so a headline that
    /// came out regular would be the one visible change of this whole switch.
    static func weight(for style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    /// What a text style measures at this platform's default text size.
    ///
    /// Read from the platform rather than written down: a television's body
    /// text is more than twice a phone's, and the point of asking for a style
    /// rather than a size is to get whichever of those is right. Pinned to the
    /// default size so that `relativeTo:` can do the scaling from there without
    /// counting the viewer's text-size setting twice.
    static func size(for style: Font.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: uiStyle(style),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    }

    /// Inter with its figures set to one width.
    ///
    /// Inter's digits are proportional by default -- a 1 is two thirds the
    /// width of a 4 -- so a clock or a running time drawn in it jitters as the
    /// numbers change. Every place that asked the system font for fixed-width
    /// digits gets Inter's `tnum` feature instead, which is the same fix in the
    /// same place.
    static func tabular(_ weight: Font.Weight, size: CGFloat) -> Font {
        guard let font = tabularFont(weight, size: size) else {
            return .system(size: size, weight: weight).monospacedDigit()
        }
        return Font(font)
    }

    /// The same, for a text style, so it still grows with the text-size setting.
    static func tabular(_ weight: Font.Weight, style: Font.TextStyle) -> Font {
        let base = size(for: style)
        guard let font = tabularFont(weight, size: base) else {
            return .system(style, design: .default).monospacedDigit()
        }
        return Font(UIFontMetrics(forTextStyle: uiStyle(style)).scaledFont(for: font))
    }

    private static func tabularFont(_ weight: Font.Weight, size: CGFloat) -> UIFont? {
        guard let base = UIFont(name: face(for: weight), size: size) else { return nil }
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector
            ]]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension Font {
    /// Inter at a fixed point size, which is how `.system(size:)` behaved:
    /// the number on the screen is the number in the code.
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(LineupFonts.face(for: weight), fixedSize: size)
    }

    /// Inter at a text style's size, growing with the viewer's text setting the
    /// way the style it replaces did.
    static func inter(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        .custom(LineupFonts.face(for: weight ?? LineupFonts.weight(for: style)),
                size: LineupFonts.size(for: style), relativeTo: style)
    }

    /// Inter with fixed-width figures, for clocks, scores and running times.
    static func interDigits(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        LineupFonts.tabular(weight, size: size)
    }

    static func interDigits(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        LineupFonts.tabular(weight ?? LineupFonts.weight(for: style), style: style)
    }
}
