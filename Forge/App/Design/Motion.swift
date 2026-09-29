import SwiftUI

/// One vocabulary of motion for the whole app: quick, soft springs that
/// settle without wobble, so things feel calm and responsive at once. With
/// Reduce Motion on, everything becomes a short, bounce-free ease.
@MainActor
enum Motion {
    /// Taps and toggles: checkmarks, buttons, small state flips.
    static var snappy: Animation { reduced ?? .snappy(duration: 0.28) }
    /// Content appearing, moving or resizing: rows, bars, cards.
    static var smooth: Animation { reduced ?? .smooth(duration: 0.38) }
    /// Slower, softer changes: color shifts, backgrounds, things leaving.
    static var gentle: Animation { reduced ?? .smooth(duration: 0.55) }
    /// Emphasis and celebration, with a little bounce.
    static var lively: Animation { reduced ?? .spring(response: 0.45, dampingFraction: 0.7) }
    /// Digits rolling over.
    static var numeric: Animation { reduced ?? .snappy(duration: 0.3) }

    private static var reduced: Animation? {
        UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.2) : nil
    }
}

/// Launch arguments the UI tests pass in.
enum AppEnvironment {
    static let isUITest = ProcessInfo.processInfo.arguments.contains("-ForgeUITest")
}

/// For tappable cards and tiles: sinks slightly under the finger and springs
/// back, like a physical button.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

extension View {
    /// A floating control surface (rest timer, workout bar, toasts): Liquid
    /// Glass on iOS 26, a blurred material with a soft shadow before that.
    @ViewBuilder
    func floatingSurface(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        }
    }

    /// Capsule-shaped floating surface (toasts).
    @ViewBuilder
    func floatingCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        }
    }
}

extension View {
    /// Round control on a dark screen (the timer): a Liquid Glass disc on
    /// iOS 26, a faint white disc before that.
    @ViewBuilder
    func glassCircle(fallbackOpacity: Double = 0.08) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: Circle())
        } else {
            background(Circle().fill(.white.opacity(fallbackOpacity)))
        }
    }
}

extension View {
    /// Rises and fades in once `visible` turns true; `delay` staggers groups.
    func entrance(_ visible: Bool, delay: Double = 0) -> some View {
        opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 14)
            .animation(Motion.smooth.delay(delay), value: visible)
    }
}
