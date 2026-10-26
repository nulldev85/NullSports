import SwiftUI

/// The app's type is SF Pro Rounded, the system's own rounded face, on both
/// platforms. It needs no files: the system draws every weight itself, keeps
/// figures in step with `.monospacedDigit()`, and follows the viewer's text
/// size. UIKit text gets the same face from `roundedUIFont`.
enum LineupFonts {
    /// A text style's weight when none is asked for. Every style is regular
    /// except headline, which the system draws semibold.
    static func weight(for style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }
}

extension Font {
    // The helpers keep the names they had when the app shipped its own face,
    // so every call site stays as it was.

    /// The app's face at a fixed point size: the number on the screen is the
    /// number in the code.
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// The app's face at a text style's size, growing with the viewer's text
    /// setting.
    static func inter(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        .system(style, design: .rounded, weight: weight ?? LineupFonts.weight(for: style))
    }

    /// With fixed-width figures, for clocks, scores and running times.
    static func interDigits(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func interDigits(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        .system(style, design: .rounded, weight: weight ?? LineupFonts.weight(for: style)).monospacedDigit()
    }
}
