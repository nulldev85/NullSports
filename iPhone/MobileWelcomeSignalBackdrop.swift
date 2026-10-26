import SwiftUI

/// Broad, softly lit contours drift above the form. The animation lives in
/// this drawing alone: none of the login fields rebuild for its frames.
struct MobileWelcomeSignalBackdrop: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive || reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(began)
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let w = size.width, h = size.height
                for band in 0..<3 {
                    let phase = time / 16 + Double(band) * 1.8
                    let shift = CGFloat(sin(phase)) * w * 0.055
                    let y = h * (0.08 + CGFloat(band) * 0.13)
                    var curve = Path()
                    curve.move(to: CGPoint(x: -w * 0.3, y: y + h * 0.22))
                    curve.addCurve(to: CGPoint(x: w * 1.3, y: y - h * 0.1),
                        control1: CGPoint(x: w * 0.25 + shift, y: y - h * 0.25),
                        control2: CGPoint(x: w * 0.52 - shift, y: y + h * 0.3))
                    var soft = context
                    soft.addFilter(.blur(radius: 32))
                    soft.stroke(curve, with: .linearGradient(Gradient(colors: [
                        LineupStyle.highlight.opacity(band == 1 ? 0.3 : 0.17),
                        Color.white.opacity(0.07), LineupStyle.highlight.opacity(0.025)
                    ]), startPoint: .zero, endPoint: CGPoint(x: w, y: h * 0.6)),
                        style: StrokeStyle(lineWidth: w * 0.26, lineCap: .round))
                    context.stroke(curve, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.09), .clear]),
                        startPoint: .zero, endPoint: CGPoint(x: w, y: h * 0.5)), lineWidth: 0.7)
                }
            }
        }
        .background(Color(red: 0.025, green: 0.029, blue: 0.035))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
