import SwiftUI

/// Hue runs around the circumference; saturation travels from the neutral
/// center to the rim. Brightness has a separate, precise slider.
struct MobileAccentWheel: View {
    @Binding var hex: String
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    @GestureState private var touching = false

    init(hex: Binding<String>) {
        _hex = hex
        let hsb = LineupAccent.accent(forHex: hex.wrappedValue).hsb
        _hue = State(initialValue: hsb.hue)
        _saturation = State(initialValue: hsb.saturation)
        _brightness = State(initialValue: hsb.brightness)
    }
    private var selected: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }
    private var generated: String { LineupAccent.hex(hue: hue, saturation: saturation, brightness: brightness) }
    private static let spectrum = (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }

    var body: some View {
        VStack(spacing: 22) {
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                let radius = max(1, side / 2 - 18)
                ZStack {
                    Circle().fill(AngularGradient(colors: Self.spectrum, center: .center))
                    Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                        startRadius: 0, endRadius: radius))
                    Circle().fill(.black.opacity(1 - brightness))
                    Circle().strokeBorder(.white.opacity(0.13), lineWidth: 1)
                    Circle().fill(selected).frame(width: touching ? 32 : 28, height: touching ? 32 : 28)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                        .position(x: side / 2 + radius * CGFloat(saturation * cos(hue * .pi * 2)),
                                  y: side / 2 + radius * CGFloat(saturation * sin(hue * .pi * 2)))
                }
                .frame(width: side, height: side)
                .contentShape(Circle())
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        let point = MobileAccentWheelGeometry.selection(at: value.location, side: side, previousHue: hue)
                        hue = point.hue; saturation = point.saturation; hex = generated
                    })
                .accessibilityElement()
                .accessibilityLabel("Color wheel")
                .accessibilityValue("Hue \(Int(hue * 360)) degrees, saturation \(Int(saturation * 100)) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: hue = (hue + 1 / 36).truncatingRemainder(dividingBy: 1)
                    case .decrement: hue = (hue + 1 - 1 / 36).truncatingRemainder(dividingBy: 1)
                    @unknown default: break
                    }
                    hex = generated
                }
                .accessibilityIdentifier("lineup.accent.wheel")
                .accessibilityAction(named: "Increase saturation") { saturation = min(1, saturation + 0.05); hex = generated }
                .accessibilityAction(named: "Decrease saturation") { saturation = max(0, saturation - 0.05); hex = generated }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 300)
            VStack(spacing: 10) {
                HStack {
                    Text("Brightness").foregroundStyle(LineupPresentationStyle.secondary)
                    Spacer()
                    Text("\(Int((brightness * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(LineupPresentationStyle.text)
                }.font(.inter(.caption, .semibold))
                Slider(value: Binding(get: { brightness }, set: { brightness = $0; hex = generated }), in: 0...1)
                    .tint(selected).accessibilityLabel("Color brightness")
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: hex) { _, value in
            guard value != generated else { return }
            let hsb = LineupAccent.accent(forHex: value).hsb
            if hsb.saturation > 0 { hue = hsb.hue }
            saturation = hsb.saturation; brightness = hsb.brightness
        }
    }
}

enum MobileAccentWheelGeometry {
    static func selection(at point: CGPoint, side: CGFloat, previousHue: Double) -> (hue: Double, saturation: Double) {
        guard side.isFinite, side > 36, point.x.isFinite, point.y.isFinite else { return (previousHue, 0) }
        let x = Double(point.x - side / 2), y = Double(point.y - side / 2)
        let distance = hypot(x, y)
        let hue = distance < 0.001 ? previousHue : (atan2(y, x) / (.pi * 2) + 1).truncatingRemainder(dividingBy: 1)
        return (hue, min(1, distance / Double(side / 2 - 18)))
    }
}
