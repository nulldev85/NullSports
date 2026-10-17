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
                DataRefreshCapsule(status: status)
                    .transition(reduceMotion ? .opacity
                                : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.18),
                   value: progress.status == nil)
        .allowsHitTesting(false)
    }
}

private struct DataRefreshCapsule: View {
    let status: DataRefreshProgress.Status

    private typealias Metrics = DataRefreshMetrics

    private var detail: String {
        #if os(iOS)
        status.detail
        #else
        "\(status.step.title) · \(status.percent)%"
        #endif
    }

    private var accessibilityDetail: String {
        #if os(iOS)
        status.detail
        #else
        "\(status.step.title), \(status.percent) percent"
        #endif
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.lineGap) {
            Text("Refreshing Data")
                .font(.inter(Metrics.title, .bold))
                .foregroundStyle(Color.white)
                .fixedSize()
            Text(detail)
                .font(.interDigits(Metrics.detail, .semibold))
                .foregroundStyle(Color.white.opacity(0.56))
                .fixedSize()
            #if os(iOS)
            if let percent = status.percent {
                LineupProgressBar(value: Double(percent) / 100, height: Metrics.bar)
                    .frame(width: Metrics.barWidth)
                    .padding(.top, Metrics.barGap)
                    .animation(.easeOut(duration: 0.2), value: percent)
            } else {
                HStack(spacing: 8) {
                    ProgressView().tint(.accentColor).controlSize(.small)
                    Text("In Progress")
                        .font(.inter(12, .medium))
                        .foregroundStyle(Color.white.opacity(0.56))
                }
                .frame(width: Metrics.barWidth, alignment: .leading)
                .padding(.top, Metrics.barGap)
            }
            #else
            LineupProgressBar(value: Double(status.percent) / 100, height: Metrics.bar)
                .frame(width: Metrics.barWidth)
                .padding(.top, Metrics.barGap)
                .animation(.easeOut(duration: 0.35), value: status.percent)
            #endif
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, Metrics.vertical)
        .background(shape.fill(Metrics.fill))
        .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: Metrics.shadow, y: Metrics.shadow / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Refreshing Data")
        .accessibilityValue(accessibilityDetail)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private enum DataRefreshMetrics {
    static let fill = LineupPanelStyle.fill
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
