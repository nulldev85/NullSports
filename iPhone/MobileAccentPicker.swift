import SwiftUI

/// Choosing the phone's accent: ten presets on a colour wheel, any hue
/// between them by dragging round it, and a colour of one's own from the
/// eyedropper in the middle. Nothing changes until Done -- the card at the top
/// shows the app in the colour being tried.
struct MobileAccentPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var mixing = false
    /// The code in the field, which the draft only takes when it is a colour.
    @State private var hexText: String
    @FocusState private var typingHex: Bool
    /// Colours of the viewer's own, kept to come back to, newest first.
    @AppStorage(LineupAccent.savedKey) private var savedRaw = ""
    let onChoose: (String) -> Void

    init(hex: String, onChoose: @escaping (String) -> Void) {
        let start = LineupAccent.normalized(hex) ?? LineupAccent.red.hex
        _draft = State(initialValue: start)
        _hexText = State(initialValue: start)
        self.onChoose = onChoose
    }

    private var saved: [String] { LineupAccent.savedList(savedRaw) }

    var body: some View {
        let accent = LineupAccent.accent(forHex: draft)
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    AccentPreviewCard(accent: accent)
                    AccentWheel(hex: $draft, onCustom: { mixing = true })
                        .frame(maxWidth: 330)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    VStack(spacing: 12) {
                        Text(accent.name).font(.inter(.title3, .semibold)).foregroundStyle(LineupStyle.text)
                            .animation(nil, value: draft)
                        hexEntry(accent)
                    }
                    if !saved.isEmpty {
                        savedRow
                    }
                    Text("Tap a color or turn the dial for any shade between. Tap the center to mix your own.")
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
                        if typingHex { applyHex() }
                        onChoose(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(accent.color)
                }
            }
            // The wheel and the chart keep the code in step; typing waits for
            // Apply, so a half-typed code is never read as a colour.
            .onChange(of: draft) { _, value in
                if !typingHex { hexText = value }
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

extension MobileAccentPicker {
    /// The code of the colour being tried, to read, or to type one in and
    /// keep among the saved colours.
    fileprivate func hexEntry(_ accent: LineupAccent) -> some View {
        let valid = LineupAccent.normalized(hexText) != nil
        let canSave = !accent.isPreset && !saved.contains(accent.hex)
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text("#").foregroundStyle(LineupStyle.secondary)
                TextField("FF3347", text: $hexText)
                    .focused($typingHex)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .onSubmit(applyHex)
                    .onChange(of: hexText) { _, value in
                        // Six digits at most, and only ever hex.
                        let cleaned = String(value.uppercased().filter(\.isHexDigit).prefix(6))
                        if cleaned != value { hexText = cleaned }
                    }
                if typingHex {
                    Button("Apply", action: applyHex)
                        .font(.inter(.subheadline, .semibold))
                        .foregroundStyle(valid ? LineupStyle.text : LineupStyle.secondary)
                        .disabled(!valid)
                }
            }
            .font(.interDigits(.body, .semibold))
            .foregroundStyle(LineupStyle.text)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .frame(maxWidth: 230)
            .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button {
                if typingHex { applyHex() }
                save(draft)
            } label: {
                Label("Save", systemImage: "plus")
                    .font(.inter(.subheadline, .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSave || typingHex ? LineupStyle.text : LineupStyle.secondary)
            .disabled(!(canSave || typingHex))
            .accessibilityLabel("Save this color")
        }
    }

    /// The colours kept, newest first: a tap tries one, a long press offers
    /// to forget it.
    fileprivate var savedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SAVED")
                .font(.inter(.caption2, .bold)).tracking(1.4)
                .foregroundStyle(LineupStyle.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(saved, id: \.self) { hex in
                        let swatch = LineupAccent.accent(forHex: hex)
                        let chosen = hex == draft
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { draft = hex }
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .overlay(Circle().strokeBorder(.white, lineWidth: chosen ? 3 : 1))
                                .overlay {
                                    if chosen {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(swatch.onAccent)
                                    }
                                }
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { forget(hex) }
                        }
                        .accessibilityLabel("Saved color #\(hex)")
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            Text("Touch and hold a saved color to remove it.")
                .font(.inter(.caption)).foregroundStyle(LineupStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The typed code, as the colour being tried -- or, if it is not a
    /// colour, the field put back to the one that is.
    fileprivate func applyHex() {
        if let typed = LineupAccent.normalized(hexText) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { draft = typed }
            hexText = typed
        } else {
            hexText = draft
        }
        typingHex = false
    }

    fileprivate func save(_ hex: String) {
        guard let hex = LineupAccent.normalized(hex),
              !LineupAccent.presets.contains(where: { $0.hex == hex }) else { return }
        let kept = [hex] + saved.filter { $0 != hex }
        withAnimation(.easeOut(duration: 0.2)) {
            savedRaw = LineupAccent.joined(Array(kept.prefix(LineupAccent.savedLimit)))
        }
        CloudSettingsSync.shared.localSettingsChanged()
    }

    fileprivate func forget(_ hex: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            savedRaw = LineupAccent.joined(saved.filter { $0 != hex })
        }
        CloudSettingsSync.shared.localSettingsChanged()
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

/// The accent dial, set out like a watch face: the ten presets round a dark
/// face where the hours would be, the track that joins them holding every
/// shade between, a chapter ring of fine ticks, and the colour chosen in the
/// middle -- a tap there mixes one of your own.
///
/// It is turned as much as tapped. Dragging round the track moves through the
/// shades with a light click every six degrees, as a bezel would, and settles
/// on a preset with a firmer one as it passes. The selection ring travels
/// round the dial to what is chosen, the short way, rather than jumping.
private struct AccentWheel: View {
    @Binding var hex: String
    let onCustom: () -> Void
    /// The selection ring's place in degrees from the top, kept unwrapped so
    /// it always goes the short way round.
    @State private var ringAngle: Double = 0
    @State private var dragging = false
    /// The detent the drag is on, for the light click as it moves.
    @State private var detent = 0
    /// The preset the dial last settled on, for the firmer one.
    @State private var settled: String?

    private static let presets = LineupAccent.presets
    private static var step: Double { 360 / Double(presets.count) }
    private static let detents = 60
    /// Every shade between the presets, which is what the track draws and
    /// what a drag along it chooses.
    private static let track = Gradient(stops:
        presets.enumerated().map { Gradient.Stop(color: $0.element.color, location: Double($0.offset) / Double(presets.count)) }
        + [Gradient.Stop(color: presets[0].color, location: 1)])

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let trackRadius = side / 2 - side * 0.085
            let gem = side * 0.092
            let accent = LineupAccent.accent(forHex: hex)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                face(side: side)
                // The track: the presets, and every shade between them.
                Circle()
                    .stroke(AngularGradient(gradient: Self.track, center: .center,
                                            startAngle: .degrees(-90), endAngle: .degrees(270)),
                            lineWidth: side * 0.03)
                    .frame(width: trackRadius * 2, height: trackRadius * 2)
                    .overlay(
                        Circle().stroke(.black.opacity(0.4), lineWidth: 0.75)
                            .frame(width: trackRadius * 2 + side * 0.03, height: trackRadius * 2 + side * 0.03)
                    )
                chapterRing(side: side, trackRadius: trackRadius)
                    .allowsHitTesting(false)
                ForEach(Array(Self.presets.enumerated()), id: \.element.id) { index, preset in
                    Button {
                        choose(preset, at: index)
                    } label: {
                        AccentGem(color: preset.color)
                            .frame(width: gem, height: gem)
                            .scaleEffect(preset.hex == hex ? 1.08 : 1)
                    }
                    .buttonStyle(AccentPressStyle())
                    .position(point(degrees: Double(index) * Self.step, radius: trackRadius, center: center))
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(preset.hex == hex ? .isSelected : [])
                }
                selection(accent: accent, gem: gem, trackRadius: trackRadius)
                    .position(center)
                    .allowsHitTesting(false)
                centre(accent: accent, side: side)
                    .position(center)
            }
            .contentShape(Circle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        // Only a drag that starts on the track turns the dial.
                        let start = hypot(value.startLocation.x - center.x, value.startLocation.y - center.y)
                        guard start > trackRadius - side * 0.12, start < side / 2 + side * 0.06 else { return }
                        if !dragging { dragging = true }
                        turn(to: value.location, center: center)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .sensoryFeedback(.selection, trigger: detent)
        .sensoryFeedback(trigger: settled) { _, new in
            new == nil ? nil : SensoryFeedback.impact(weight: .medium, intensity: 0.7)
        }
        .onAppear { ringAngle = Self.angle(for: hex) }
        .onChange(of: hex) { _, value in
            guard !dragging else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                ringAngle = unwrapped(Self.angle(for: value))
            }
        }
    }

    /// The dark face, lit a little from above, sitting a step proud of the
    /// sheet.
    private func face(side: CGFloat) -> some View {
        Circle()
            .fill(LineupStyle.surface)
            .overlay(
                Circle().fill(RadialGradient(colors: [.white.opacity(0.06), .clear],
                                             center: UnitPoint(x: 0.5, y: 0.22),
                                             startRadius: 0, endRadius: side * 0.7))
            )
            .overlay(Circle().strokeBorder(LineupStyle.line, lineWidth: 1))
            .overlay(
                // The inner face the colour sits on.
                Circle().strokeBorder(LineupStyle.line, lineWidth: 1)
                    .frame(width: side * 0.56, height: side * 0.56)
            )
            .shadow(color: .black.opacity(0.55), radius: 22, y: 12)
    }

    /// Fine ticks inside the track, as a watch's chapter ring has, every six
    /// degrees, with the presets' places left to the presets.
    private func chapterRing(side: CGFloat, trackRadius: CGFloat) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = trackRadius - side * 0.055
            for index in 0..<Self.detents where index % (Self.detents / Self.presets.count) != 0 {
                let radians = Double(index) / Double(Self.detents) * 2 * .pi - .pi / 2
                let half = index % 3 == 0
                let inner = outer - side * (half ? 0.03 : 0.018)
                var tick = Path()
                tick.move(to: CGPoint(x: center.x + cos(radians) * inner, y: center.y + sin(radians) * inner))
                tick.addLine(to: CGPoint(x: center.x + cos(radians) * outer, y: center.y + sin(radians) * outer))
                context.stroke(tick, with: .color(.white.opacity(half ? 0.3 : 0.16)),
                               style: StrokeStyle(lineWidth: half ? 1.4 : 1, lineCap: .round))
            }
        }
    }

    /// A thin ring round what is chosen, set off from it by a gap. Between
    /// the presets it carries a bead of the shade itself.
    private func selection(accent: LineupAccent, gem: CGFloat, trackRadius: CGFloat) -> some View {
        ZStack {
            if !accent.isPreset {
                AccentGem(color: accent.color)
                    .frame(width: gem * (dragging ? 1.12 : 0.9), height: gem * (dragging ? 1.12 : 0.9))
            }
            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: gem + 14, height: gem + 14)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dragging)
        .offset(y: -trackRadius)
        .rotationEffect(.degrees(ringAngle))
    }

    /// The colour chosen, as a lens in the middle of the face, with the
    /// eyedropper on it: a tap mixes a colour of one's own.
    private func centre(accent: LineupAccent, side: CGFloat) -> some View {
        let lens = side * 0.27
        return Button(action: onCustom) {
            VStack(spacing: side * 0.028) {
                ZStack {
                    AccentGem(color: accent.color)
                    Image(systemName: "eyedropper.halffull")
                        .font(.system(size: lens * 0.3, weight: .semibold))
                        .foregroundStyle(accent.onAccent.opacity(0.92))
                }
                .frame(width: lens, height: lens)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                Text("MIX YOUR OWN")
                    .font(.inter(9, .bold)).tracking(1.6)
                    .foregroundStyle(LineupStyle.secondary)
            }
        }
        .buttonStyle(AccentPressStyle())
        .accessibilityLabel("Mix a custom color")
    }

    private func point(degrees: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let radians = CGFloat(degrees) * .pi / 180 - .pi / 2
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    /// The nearest way round to `target`, from where the ring is now.
    private func unwrapped(_ target: Double) -> Double {
        var angle = target
        while angle - ringAngle > 180 { angle -= 360 }
        while angle - ringAngle < -180 { angle += 360 }
        return angle
    }

    private func choose(_ preset: LineupAccent, at index: Int) {
        settled = preset.hex
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            hex = preset.hex
            ringAngle = unwrapped(Double(index) * Self.step)
        }
    }

    /// The shade under the finger: a preset when it is close to one, else
    /// the mix of the two either side, as the track draws it.
    private func turn(to location: CGPoint, center: CGPoint) {
        let radians = atan2(location.y - center.y, location.x - center.x)
        var turn = Double((radians + .pi / 2) / (2 * .pi))
        if turn < 0 { turn += 1 }
        let mark = Int((turn * Double(Self.detents)).rounded()) % Self.detents
        if mark != detent { detent = mark }
        let scaled = turn * Double(Self.presets.count)
        let index = Int(scaled) % Self.presets.count
        let fraction = scaled - Double(Int(scaled))
        let snap = 0.08
        if fraction < snap || fraction > 1 - snap {
            let landed = fraction < snap ? index : (index + 1) % Self.presets.count
            if settled != Self.presets[landed].hex { settled = Self.presets[landed].hex }
            hex = Self.presets[landed].hex
            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.85)) {
                ringAngle = unwrapped(Double(landed) * Self.step)
            }
        } else {
            settled = nil
            hex = Self.mix(Self.presets[index], Self.presets[(index + 1) % Self.presets.count], fraction)
            withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.9)) {
                ringAngle = unwrapped(turn * 360)
            }
        }
    }

    /// Two presets mixed as the track mixes them.
    private static func mix(_ a: LineupAccent, _ b: LineupAccent, _ amount: Double) -> String {
        let x = a.components, y = b.components
        func byte(_ from: Double, _ to: Double) -> Int { Int(((from + (to - from) * amount) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(x.red, y.red), byte(x.green, y.green), byte(x.blue, y.blue))
    }

    /// Where a colour sits on the dial: a preset at its place, any other at
    /// the shade of the track nearest it.
    private static func angle(for hex: String) -> Double {
        if let index = presets.firstIndex(where: { $0.hex == hex }) { return Double(index) * step }
        let target = LineupAccent.accent(forHex: hex).components
        var best = (angle: 0.0, distance: Double.infinity)
        for degree in 0..<360 {
            let scaled = Double(degree) / 360 * Double(presets.count)
            let index = Int(scaled) % presets.count
            let shade = LineupAccent(name: "", hex: mix(presets[index], presets[(index + 1) % presets.count],
                                                       scaled - Double(Int(scaled)))).components
            let distance = pow(shade.red - target.red, 2) + pow(shade.green - target.green, 2)
                + pow(shade.blue - target.blue, 2)
            if distance < best.distance { best = (Double(degree), distance) }
        }
        return best.angle
    }
}

/// A swatch with a little depth: the colour, a soft highlight towards the
/// top, and a dark rim to lift it off the face.
private struct AccentGem: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .overlay(
                Circle().fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0), .black.opacity(0.12)],
                                             startPoint: .top, endPoint: .bottom))
            )
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
            .overlay(Circle().inset(by: 1).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
    }
}

/// Gives a little under the finger, as a physical control would.
private struct AccentPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
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
