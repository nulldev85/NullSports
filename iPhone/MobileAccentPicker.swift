import SwiftUI

/// Choosing the phone's accent: ten presets on a colour wheel, any hue
/// between them by dragging round it, and a colour of one's own from the
/// eyedropper in the middle. Nothing changes until Done -- the card at the top
/// shows the app in the colour being tried.
struct MobileAccentPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var mixing = false
    let onChoose: (String) -> Void

    init(hex: String, onChoose: @escaping (String) -> Void) {
        _draft = State(initialValue: LineupAccent.normalized(hex) ?? LineupAccent.red.hex)
        self.onChoose = onChoose
    }

    var body: some View {
        let accent = LineupAccent.accent(forHex: draft)
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    AccentPreviewCard(accent: accent)
                    AccentWheel(hex: $draft, onCustom: { mixing = true })
                        .frame(maxWidth: 320)
                        .padding(.horizontal, 8)
                    VStack(spacing: 4) {
                        Text(accent.name).font(.inter(.title3, .semibold)).foregroundStyle(LineupStyle.text)
                        Text("#" + accent.hex)
                            .font(.interDigits(.subheadline, .medium)).foregroundStyle(LineupStyle.secondary)
                    }
                    .animation(nil, value: draft)
                    Text("Tap a color, or drag around the wheel for any shade between them. The eyedropper mixes one of your own.")
                        .font(.inter(.footnote)).foregroundStyle(LineupStyle.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    if draft != LineupAccent.red.hex {
                        Button("Reset to Red") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { draft = LineupAccent.red.hex }
                        }
                        .font(.inter(.subheadline, .semibold))
                        .foregroundStyle(LineupStyle.text)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(LineupStyle.background)
            .navigationTitle("Accent Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(LineupStyle.text)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onChoose(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(accent.color)
                }
            }
            .sheet(isPresented: $mixing) {
                AccentColorChart(hex: draft) { chosen in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { draft = chosen }
                }
            }
        }
        .presentationBackground(LineupStyle.background)
        .preferredColorScheme(.dark)
    }
}

/// The app in miniature, in the colour being tried: the masthead's bar, a
/// selected tab, a switch that is on, and a button.
private struct AccentPreviewCard: View {
    let accent: LineupAccent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Rectangle().fill(accent.color).frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LINEUP").font(.inter(18, .heavy)).foregroundStyle(LineupStyle.text)
                    Text("LIVE SPORTS").font(.inter(8, .bold)).tracking(2.2).foregroundStyle(LineupStyle.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Example switch", isOn: .constant(true))
                    .labelsHidden()
                    .tint(accent.color)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 22) {
                tab(symbol: "star.fill", selected: true)
                tab(symbol: "square.grid.2x2.fill", selected: false)
                tab(symbol: "sportscourt.fill", selected: false)
                Spacer(minLength: 8)
                Text("WATCH")
                    .font(.inter(12, .bold)).tracking(1.2)
                    .foregroundStyle(accent.onAccent)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(accent.color, in: Capsule())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupStyle.surface, in: shape)
        .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview in \(accent.name)")
    }

    private func tab(symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(selected ? accent.color : LineupStyle.text)
            .opacity(selected ? 1 : 0.38)
            .frame(width: 32, height: 34)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(accent.color).frame(height: 2) }
            }
    }
}

/// Every hue round a ring, the ten presets each where its colour sits on it,
/// and the eyedropper in the middle wearing the colour chosen. Dragging round
/// the ring picks any hue between the presets, settling on one when it passes
/// close by.
private struct AccentWheel: View {
    @Binding var hex: String
    let onCustom: () -> Void
    /// The preset the drag last settled on, for a tick as it does.
    @State private var settled: String?
    @State private var dragging = false

    private static let spectrum = Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 24).map {
        Color(hue: $0, saturation: 0.8, brightness: 1)
    })
    private struct Spot: Identifiable {
        let preset: LineupAccent
        let hue: Double
        var id: String { preset.hex }
    }
    private static let presetHues: [Spot] = LineupAccent.presets.map { Spot(preset: $0, hue: $0.hsb.hue) }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let ring = side * 0.15
            let radius = (side - ring) / 2
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let accent = LineupAccent.accent(forHex: hex)
            ZStack {
                Circle()
                    .strokeBorder(AngularGradient(gradient: Self.spectrum, center: .center,
                                                  startAngle: .degrees(-90), endAngle: .degrees(270)),
                                  lineWidth: ring)
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .overlay(Circle().inset(by: ring).strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .frame(width: side, height: side)
                    .position(center)
                // A hue of the viewer's own, between the presets.
                if !accent.isPreset {
                    Circle()
                        .fill(accent.color)
                        .frame(width: ring * 0.78, height: ring * 0.78)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                        .scaleEffect(dragging ? 1.15 : 1)
                        .position(point(hue: accent.hsb.hue, radius: radius, center: center))
                        .allowsHitTesting(false)
                }
                ForEach(Self.presetHues) { entry in
                    let chosen = entry.preset.hex == hex
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hex = entry.preset.hex }
                    } label: {
                        Circle()
                            .fill(entry.preset.color)
                            .overlay(Circle().strokeBorder(.white, lineWidth: chosen ? 3 : 1.5))
                            .overlay {
                                if chosen {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: ring * 0.26, weight: .bold))
                                        .foregroundStyle(entry.preset.onAccent)
                                }
                            }
                            .frame(width: ring * 0.74, height: ring * 0.74)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1.5)
                            .scaleEffect(chosen ? 1.2 : 1)
                    }
                    .buttonStyle(.plain)
                    .position(point(hue: entry.hue, radius: radius, center: center))
                    .accessibilityLabel(entry.preset.name)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
                Button(action: onCustom) {
                    ZStack {
                        Circle().fill(accent.color)
                        Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        VStack(spacing: 6) {
                            Image(systemName: "eyedropper.halffull")
                                .font(.system(size: side * 0.09, weight: .semibold))
                            Text("CUSTOM").font(.inter(10, .bold)).tracking(1.4)
                        }
                        .foregroundStyle(accent.onAccent)
                    }
                    .frame(width: side * 0.40, height: side * 0.40)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .position(center)
                .accessibilityLabel("Custom color")
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        // Only a drag that starts on the ring turns it.
                        let start = distance(value.startLocation, center)
                        guard start > radius - ring, start < radius + ring else { return }
                        dragging = true
                        choose(at: value.location, center: center)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragging = false }
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .sensoryFeedback(.selection, trigger: settled)
    }

    private func point(hue: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = CGFloat(hue) * 2 * .pi - .pi / 2
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func choose(at location: CGPoint, center: CGPoint) {
        let angle = atan2(location.y - center.y, location.x - center.x)
        var hue = Double((angle + .pi / 2) / (2 * .pi))
        if hue < 0 { hue += 1 }
        // Close by a preset is the preset itself, exactly.
        if let near = Self.presetHues.first(where: { entry in
            let gap = abs(entry.hue - hue)
            return min(gap, 1 - gap) < 0.012
        }) {
            hex = near.preset.hex
            settled = near.preset.hex
        } else {
            hex = LineupAccent.hex(hue: hue, saturation: 0.8, brightness: 1)
            settled = nil
        }
    }
}

/// Mixing a colour of one's own: a field of every shade of a hue, the hues
/// beneath it, and the colour's hex to read or type.
private struct AccentColorChart: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    @State private var hexText: String
    @FocusState private var typing: Bool
    let onUse: (String) -> Void

    init(hex: String, onUse: @escaping (String) -> Void) {
        let accent = LineupAccent.accent(forHex: hex)
        let hsb = accent.hsb
        _hue = State(initialValue: hsb.hue)
        _saturation = State(initialValue: hsb.saturation)
        _brightness = State(initialValue: max(hsb.brightness, AccentShadeField.darkest))
        _hexText = State(initialValue: accent.hex)
        self.onUse = onUse
    }

    private var hex: String { LineupAccent.hex(hue: hue, saturation: saturation, brightness: brightness) }

    var body: some View {
        let accent = LineupAccent.accent(forHex: hex)
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AccentShadeField(hue: hue, saturation: $saturation, brightness: $brightness)
                        .frame(height: 240)
                    AccentHueStrip(hue: $hue)
                        .frame(height: 34)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent.color)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1))
                            .frame(width: 64, height: 48)
                        HStack(spacing: 4) {
                            Text("#").foregroundStyle(LineupStyle.secondary)
                            TextField("FF3347", text: $hexText)
                                .focused($typing)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit(applyTyped)
                        }
                        .font(.interDigits(.body, .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Text("Drag across the field for lighter and deeper shades, and along the strip for the hue.")
                        .font(.inter(.footnote)).foregroundStyle(LineupStyle.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .scrollDisabled(true)
            .background(LineupStyle.background)
            .navigationTitle("Custom Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(LineupStyle.text)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if typing { applyTyped() }
                        onUse(hex)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(accent.color)
                }
            }
            // The field and the strip keep the hex in step; typing waits for
            // Done, so a half-typed code is never read as a colour.
            .onChange(of: hex) { _, value in
                if !typing { hexText = value }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LineupStyle.background)
        .preferredColorScheme(.dark)
    }

    private func applyTyped() {
        guard let typed = LineupAccent.normalized(hexText) else {
            hexText = hex
            return
        }
        let hsb = LineupAccent(name: "Custom", hex: typed).hsb
        withAnimation(.easeOut(duration: 0.2)) {
            hue = hsb.hue
            saturation = hsb.saturation
            brightness = max(hsb.brightness, AccentShadeField.darkest)
        }
        hexText = typed
        typing = false
    }
}

/// Every shade of one hue: paler to the left, deeper towards the bottom.
/// It stops short of black -- an accent darker than this is lost on the
/// charcoal it sits on.
private struct AccentShadeField: View {
    static let darkest = 0.32
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            ZStack {
                LinearGradient(colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(1 - Self.darkest)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .overlay {
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .position(x: CGFloat(saturation) * size.width,
                              y: CGFloat((1 - brightness) / (1 - Self.darkest)) * size.height)
            }
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    saturation = Double(min(max(value.location.x / size.width, 0), 1))
                    let depth = Double(min(max(value.location.y / size.height, 0), 1))
                    brightness = 1 - depth * (1 - Self.darkest)
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Shade")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: brightness = min(brightness + 0.05, 1)
            case .decrement: brightness = max(brightness - 0.05, Self.darkest)
            @unknown default: break
            }
        }
    }
}

/// The hues, left to right, with a knob on the one in the field above.
private struct AccentHueStrip: View {
    @Binding var hue: Double

    private static let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let knob = proxy.size.height
            let track = max(proxy.size.width - knob, 1)
            Capsule()
                .fill(LinearGradient(colors: Self.hues, startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(Color(hue: hue, saturation: 1, brightness: 1))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                        .frame(width: knob, height: knob)
                        .offset(x: CGFloat(hue) * track)
                }
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        hue = Double(min(max((value.location.x - knob / 2) / track, 0), 1))
                    }
                )
        }
        .accessibilityElement()
        .accessibilityLabel("Hue")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: hue = min(hue + 0.02, 1)
            case .decrement: hue = max(hue - 0.02, 0)
            @unknown default: break
            }
        }
    }
}
