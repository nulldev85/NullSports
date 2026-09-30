import SwiftUI

// How everything in Forge answers a finger: it sinks quickly and firmly
// while pressed, then springs back with a hint of overshoot when let go.
// Every style here shares that one motion, so buttons, rows, cards and
// icons all feel like the same material. Only size and opacity change
// (never layout), so nothing around a pressed control moves.

extension Motion {
    /// Pressing down: quick and firm, no bounce.
    static var pressDown: Animation {
        UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.1) : .spring(duration: 0.16, bounce: 0)
    }

    /// Letting go: back up with a little overshoot.
    static var pressRelease: Animation {
        UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.32)
    }
}

/// Sinks while pressed and springs back after. With Reduce Motion on it
/// dims instead of changing size.
struct PressEffect: ViewModifier {
    let isPressed: Bool
    /// The size while held.
    var scale: CGFloat = 0.97
    /// How much it fades while held.
    var dim: Double = 0.06
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? scale : 1)
            .opacity(isPressed ? 1 - (reduceMotion ? max(dim, 0.3) : dim) : 1)
            .animation(isPressed ? Motion.pressDown : Motion.pressRelease, value: isPressed)
    }
}

extension View {
    func pressEffect(_ isPressed: Bool, scale: CGFloat = 0.97, dim: Double = 0.06) -> some View {
        modifier(PressEffect(isPressed: isPressed, scale: scale, dim: dim))
    }
}

/// Cards, tiles, icons and anything that draws its own shape: the whole
/// thing sinks. `tinted` colors the label with the accent, as the default
/// button style would.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var tinted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ButtonTint(role: configuration.role, tinted: tinted))
            .contentShape(Rectangle())
            .pressEffect(configuration.isPressed, scale: scale)
    }
}

extension ButtonStyle where Self == PressableStyle {
    /// Cards and tiles.
    static var pressable: PressableStyle { PressableStyle() }
    /// Small icon buttons: they sink deeper, and wear the accent.
    static var pressableIcon: PressableStyle { PressableStyle(scale: 0.86, tinted: true) }
    /// Text and inline buttons outside lists, in the accent.
    static var pressableText: PressableStyle { PressableStyle(scale: 0.94, tinted: true) }
}

/// A list row that does something when tapped (a button or a navigation
/// link): its content sinks into a soft well that appears under the finger,
/// while the row's card stays put. The whole row stays tappable. Action rows
/// keep the accent a list gives them (red when destructive); navigation rows
/// (`tinted: false`) keep their own colors.
struct RowPressStyle: ButtonStyle {
    var alignment: Alignment = .leading
    var tinted = true

    func makeBody(configuration: Configuration) -> some View {
        RowPressBody(configuration: configuration, alignment: alignment, tinted: tinted)
    }
}

extension ButtonStyle where Self == RowPressStyle {
    /// An action row: a button in a list, in the accent.
    static var row: RowPressStyle { RowPressStyle() }
    /// A navigation row: keeps its own colors.
    static var navigationRow: RowPressStyle { RowPressStyle(tinted: false) }
}

private struct RowPressBody: View {
    let configuration: ButtonStyleConfiguration
    let alignment: Alignment
    let tinted: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .modifier(ButtonTint(role: configuration.role, tinted: tinted))
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.pressWell)
                    .padding(.horizontal, -10)
                    .padding(.vertical, -6)
                    .opacity(pressed ? 1 : 0)
            }
            .pressEffect(pressed, scale: 0.975, dim: 0)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Draws the label as is and reports whether it's pressed, so a larger
/// surface around it (a card that holds another button too) can sink as
/// one with `pressEffect`.
struct PressReportingStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

/// Capsule buttons (the rest timer's −15 / +15 / Skip, "Not Now"…), in place
/// of the system's bordered styles so they press like everything else.
/// `prominent` fills the capsule with the accent (red when destructive).
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var prominentPill: PillButtonStyle { PillButtonStyle(prominent: true) }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let pressed = configuration.isPressed
        let destructive = configuration.role == .destructive
        let shape = Capsule(style: .continuous)
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .foregroundStyle(prominent ? AnyShapeStyle(Theme.onAccent) : destructive ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Color.accentColor))
            .background {
                if prominent {
                    shape
                        .fill(destructive ? Theme.danger : Color.accentColor)
                        // The same glossy top and rim as the primary button.
                        .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)))
                        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.36), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                } else {
                    shape.fill((destructive ? Theme.danger : Color.accentColor).opacity(0.14))
                }
            }
            .contentShape(shape)
            .pressEffect(pressed, scale: 0.94, dim: 0.08)
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini, .small: return 10
        case .large, .extraLarge: return 18
        default: return 14
        }
    }

    private var verticalPadding: CGFloat {
        switch controlSize {
        case .mini, .small: return 5
        case .large, .extraLarge: return 12
        default: return 8
        }
    }
}

/// The label color a tinted style gives a button: the accent, or red when
/// it's destructive. Untinted buttons keep the colors they set themselves.
private struct ButtonTint: ViewModifier {
    let role: ButtonRole?
    let tinted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !tinted {
            content
        } else if role == .destructive {
            content.foregroundStyle(Theme.danger)
        } else {
            content.foregroundStyle(Color.accentColor)
        }
    }
}
