import SwiftUI

/// "Refreshing Data", the step under way and how far through the whole
/// refresh it is -- in words and on the app's progress bar -- in a panel at
/// the top of the screen while the app brings
/// its channels, guide and matches up to date. It takes no touches and no
/// focus, and leaves on its own once the refresh has said 100%.
struct DataRefreshPopup: View {
    @EnvironmentObject private var progress: DataRefreshProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let status = progress.status {
                DataRefreshCapsule(status: status, fraction: progress.fraction)
                    .transition(reduceMotion ? .opacity
                                : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.18),
                   value: progress.status == nil)
        .allowsHitTesting(false)
    }
}

struct DataRefreshCapsule: View {
    let status: DataRefreshProgress.Status
    let fraction: Double

    private typealias Metrics = DataRefreshMetrics

    private var detail: String {
        #if os(iOS)
        status.completed ? status.detail : "\(status.step.title) · \(Int((fraction * 100).rounded(.down)))%"
        #else
        status.detail
        #endif
    }

    private var accessibilityDetail: String {
        #if os(iOS)
        detail
        #else
        status.detail
        #endif
    }

    var body: some View {
        #if os(iOS)
        iosToast
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Refreshing Data")
            .accessibilityValue(accessibilityDetail)
            .accessibilityAddTraits(.updatesFrequently)
        #else
        let shape = RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.lineGap) {
            Text("Refreshing Data")
                .font(.inter(Metrics.title, .bold))
                .foregroundStyle(LineupPresentationStyle.text)
                .fixedSize()
            Text(detail)
                .font(.interDigits(Metrics.detail, .semibold))
                .foregroundStyle(LineupPresentationStyle.secondary)
                .fixedSize()
            LineupProgressBar(value: fraction, height: Metrics.bar)
                .frame(width: Metrics.barWidth)
                .padding(.top, Metrics.barGap)
                .animation(.easeOut(duration: 0.35), value: fraction)
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, Metrics.vertical)
        .background(shape.fill(Metrics.fill))
        .overlay(shape.strokeBorder(LineupPresentationStyle.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: Metrics.shadow, y: Metrics.shadow / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Refreshing Data")
        .accessibilityValue(accessibilityDetail)
        .accessibilityAddTraits(.updatesFrequently)
        #endif
    }

    #if os(iOS)
    private var iosToast: some View {
        let clamped = min(1, max(0, fraction))
        let percent = status.completed ? 100 : Int((clamped * 100).rounded(.down))
        let accent = status.completed
            ? Color(red: 0.18, green: 0.80, blue: 0.44)
            : LineupStyle.highlight
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 28, height: 28)
                    if status.completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(accent)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(accent)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(status.completed ? "Guide Up to Date" : "Refreshing Data")
                        .font(.inter(12.5, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(status.completed ? "Ready to watch" : status.step.title)
                        .font(.inter(11, .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text("\(percent)%")
                    .font(.interDigits(12, .heavy))
                    .foregroundStyle(status.completed ? accent : Color.white.opacity(0.92))
                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                    .background(accent.opacity(status.completed ? 0.18 : 0.14), in: Capsule())
                    .contentTransition(.numericText())
            }

            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.11))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.85), accent],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, bar.size.width * clamped))
                }
            }
            .frame(height: 3.5)
            .animation(.easeOut(duration: 0.22), value: clamped)
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(width: 256)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(red: 0.065, green: 0.07, blue: 0.095).opacity(0.84))
            }
        }
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.07)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.9
            )
        )
        .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
    }
    #endif
}

private enum DataRefreshMetrics {
    static let fill = LineupPresentationStyle.card
    #if os(tvOS)
    static let radius: CGFloat = 30
    static let side: CGFloat = 32
    static let vertical: CGFloat = 22
    static let title: CGFloat = 26
    static let detail: CGFloat = 21
    static let lineGap: CGFloat = 3
    static let bar: CGFloat = 10
    static let barWidth: CGFloat = 300
    static let barGap: CGFloat = 10
    static let shadow: CGFloat = 26
    #else
    static let radius: CGFloat = 22
    static let side: CGFloat = 20
    static let vertical: CGFloat = 14
    static let title: CGFloat = 17
    static let detail: CGFloat = 14
    static let lineGap: CGFloat = 2
    static let bar: CGFloat = 7
    static let barWidth: CGFloat = 190
    static let barGap: CGFloat = 7
    static let shadow: CGFloat = 18
    #endif
}
