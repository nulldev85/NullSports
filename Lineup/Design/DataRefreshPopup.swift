import SwiftUI

/// "Refreshing Data", the step under way and how far through the whole
/// refresh it is, in a capsule at the top of the screen while the app brings
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

    var body: some View {
        HStack(spacing: Metrics.gap) {
            DataRefreshSpinner(fraction: Double(status.percent) / 100)
                .frame(width: Metrics.spinner, height: Metrics.spinner)
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text("Refreshing Data")
                    .font(.inter(Metrics.title, .bold))
                    .foregroundStyle(Color.white)
                Text("\(status.step.title) · \(status.percent)%")
                    .font(.interDigits(Metrics.detail, .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.leading, Metrics.leading)
        .padding(.trailing, Metrics.trailing)
        .frame(height: Metrics.height)
        .background(Capsule().fill(Metrics.fill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: Metrics.shadow, y: Metrics.shadow / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Refreshing Data")
        .accessibilityValue("\(status.step.title), \(status.percent) percent")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A ring with a bright arc chasing round it. With motion reduced it stands
/// still and fills to the percentage instead.
private struct DataRefreshSpinner: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ring = DataRefreshMetrics.ring
        let arc = Circle()
            .trim(from: 0, to: reduceMotion ? max(0.03, fraction) : 0.3)
            .stroke(AngularGradient(colors: [Color.white.opacity(0), Color.white],
                                    center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(108)),
                    style: StrokeStyle(lineWidth: ring, lineCap: .round))
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: ring)
            if reduceMotion {
                arc.rotationEffect(.degrees(-90))
            } else {
                // Its own turn, which nothing else that changes as the
                // pop-up slides in or its text grows can be caught up in.
                arc.keyframeAnimator(initialValue: 0.0, repeating: true) { arc, angle in
                    arc.rotationEffect(.degrees(angle))
                } keyframes: { _ in
                    LinearKeyframe(360.0, duration: 0.9)
                }
            }
        }
        .padding(ring / 2)
    }
}

private enum DataRefreshMetrics {
    static let fill = Color(red: 0.055, green: 0.06, blue: 0.07).opacity(0.97)
    #if os(tvOS)
    static let height: CGFloat = 92
    static let leading: CGFloat = 28
    static let trailing: CGFloat = 38
    static let gap: CGFloat = 20
    static let spinner: CGFloat = 40
    static let ring: CGFloat = 4
    static let title: CGFloat = 26
    static let detail: CGFloat = 21
    static let lineGap: CGFloat = 3
    static let shadow: CGFloat = 26
    #else
    static let height: CGFloat = 60
    static let leading: CGFloat = 20
    static let trailing: CGFloat = 26
    static let gap: CGFloat = 14
    static let spinner: CGFloat = 26
    static let ring: CGFloat = 3
    static let title: CGFloat = 17
    static let detail: CGFloat = 14
    static let lineGap: CGFloat = 2
    static let shadow: CGFloat = 18
    #endif
}
