import SwiftUI

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(.title3, .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.app(.subheadline, .semibold))
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String?
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .eyebrow()
                    .lineLimit(1)
            }
            Text(value)
                .font(.num(size: 24, .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.app(.caption, .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .foregroundStyle(filled ? Theme.onAccent : color)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.14))
            )
    }
}

struct IconBadge: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

/// "1", "2"… for working sets; W / D / F for the special kinds.
struct SetKindBadge: View {
    let kind: SetKind
    let number: Int
    var completed = false
    /// Logged effort, shown as a small tag on the badge.
    var rpe: Double?

    var body: some View {
        let color = Theme.color(for: kind)
        Text(kind.shortLabel ?? "\(number)")
            .font(.num(.subheadline, .semibold))
            .foregroundStyle(color ?? (completed ? Color.primary : Color.secondary))
            .frame(width: 30, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((color ?? Color.secondary).opacity(0.12))
            )
            .overlay(alignment: .topTrailing) {
                if let rpe {
                    Text(Self.rpeText(rpe))
                        .font(.num(size: 9, .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 7, y: -6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let base = kind == .normal ? "Set \(number)" : kind.displayName
        guard let rpe else { return base }
        return "\(base), RPE \(Self.rpeText(rpe))"
    }

    static func rpeText(_ rpe: Double) -> String {
        NumberFormatting.string(rpe, locale: .current, maxFractionDigits: 1, grouping: false)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, color: color)
    }
}

/// The primary button's look: a solid accent slab with a soft lift that
/// settles as it's pressed.
private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        // A tinted lift reads as depth on light backgrounds; on dark ones a
        // neutral shadow does.
        let shadow = colorScheme == .dark ? Color.black.opacity(0.35) : color.opacity(0.28)
        configuration.label
            .font(.app(.headline))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(Theme.onAccent)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color)
                    .overlay(
                        // A faint top sheen keeps the flat color from looking dead.
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center))
                    )
                    .shadow(color: isEnabled ? shadow : .clear, radius: pressed ? 3 : 10, y: pressed ? 1 : 5)
            }
            .brightness(pressed ? -0.06 : 0)
            .scaleEffect(pressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Motion.snappy, value: pressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(.headline))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(color)
            .background(color.opacity(configuration.isPressed ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

struct MuscleTags: View {
    let exercise: Exercise

    var body: some View {
        HStack(spacing: 6) {
            Pill(text: exercise.primaryMuscle.displayName, color: Theme.color(for: exercise.primaryMuscle))
            Text(exercise.equipment.displayName)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Transient message shown at the top of the screen.
struct Toast: Identifiable, Equatable {
    enum Style { case info, success, warning, error }
    let id = UUID()
    var message: String
    var style: Style = .info

    var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch style {
        case .info: return .accentColor
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }
}

struct ToastBanner: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.color)
            Text(toast.message)
                .font(.app(.subheadline, .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .floatingCapsule()
        .padding(.horizontal, 20)
    }
}

/// Circular progress used by timers: a soft track, the arc in the phase
/// color with a faint glow, and a bright dot riding its leading edge.
struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 14
    var glows = false

    var body: some View {
        let clamped = max(0.0001, min(1, progress))
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                Circle()
                    .stroke(color.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: glows ? color.opacity(0.5) : .clear, radius: lineWidth * 1.1)
                if glows {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: lineWidth * 0.55, height: lineWidth * 0.55)
                        .offset(y: -(radius - lineWidth / 2))
                        .rotationEffect(.degrees(360 * clamped))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct EmptyCard: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.app(.headline))
            Text(message)
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension Date {
    var relativeDayText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: Date())).day ?? 0
        if days > 0, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }
}
