import SwiftUI

/// Choosing the phone's accent, laid out like any other settings sheet: the
/// app in the colour being tried, the ten presets as plain swatches, then a
/// colour of one's own by its code or from the mixer, and the ones kept.
/// Nothing changes until Done.
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
                VStack(alignment: .leading, spacing: 18) {
                    AccentPreviewCard(accent: accent)
                    section("Color", symbol: "paintpalette", trailing: accent.isPreset ? accent.name : nil) {
                        swatchGrid
                    }
                    section("Custom", symbol: "slider.horizontal.3") {
                        VStack(spacing: 0) {
                            hexRow
                            Divider().overlay(LineupStyle.line).padding(.leading, 16)
                            mixRow(accent)
                            Divider().overlay(LineupStyle.line).padding(.leading, 16)
                            saveRow(accent)
                        }
                    }
                    if !saved.isEmpty {
                        section("My colors", symbol: "bookmark", footer: "Touch and hold one to remove it.") {
                            savedRow
                        }
                    }
                    if draft != LineupAccent.red.hex {
                        Button("Reset to Red") { choose(LineupAccent.red.hex) }
                            .font(.inter(.subheadline, .medium))
                            .foregroundStyle(LineupStyle.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
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
            // The swatches and the mixer keep the code in step; typing waits
            // for Return, so a half-typed code is never read as a colour.
            .onChange(of: draft) { _, value in
                if !typingHex { hexText = value }
            }
            .sheet(isPresented: $mixing) {
                AccentColorChart(hex: draft) { chosen in choose(chosen) }
            }
        }
        .presentationBackground(LineupStyle.background)
        .preferredColorScheme(.dark)
    }
}

extension MobileAccentPicker {
    /// A panel with the app's header in it -- icon, caption, hairline -- the
    /// content under that, and a line under the panel.
    fileprivate func section<Content: View>(_ title: String, symbol: String, trailing: String? = nil,
                                            footer: String? = nil,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                LineupPanelHeader(title: title, systemImage: symbol) {
                    if let trailing {
                        Text(trailing).font(.inter(.footnote, .semibold))
                            .foregroundStyle(LineupPanelStyle.quiet)
                    }
                }
                .padding(.top, 15).padding(.bottom, 11)
                .padding(.horizontal, LineupPanelStyle.inset)
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                    .padding(.horizontal, LineupPanelStyle.inset)
                content()
            }
            .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
            if let footer {
                Text(footer)
                    .font(.inter(.footnote))
                    .foregroundStyle(LineupStyle.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    fileprivate func choose(_ hex: String) {
        withAnimation(.easeOut(duration: 0.18)) { draft = hex }
    }

    /// The ten presets, five to a row.
    fileprivate var swatchGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 14) {
            ForEach(LineupAccent.presets) { preset in
                Button { choose(preset.hex) } label: {
                    AccentSwatch(color: preset.color, selected: preset.hex == draft)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(preset.hex == draft ? .isSelected : [])
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
    }

    /// The colour's code, to read or to type a new one.
    fileprivate var hexRow: some View {
        HStack(spacing: 12) {
            Text("Hex").foregroundStyle(LineupStyle.text)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
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
                    .fixedSize()
            }
            .font(.interDigits(.body, .medium))
            .foregroundStyle(LineupStyle.text)
        }
        .font(.inter(.body))
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    /// Into the mixer, with the colour being tried beside it.
    fileprivate func mixRow(_ accent: LineupAccent) -> some View {
        Button { mixing = true } label: {
            HStack(spacing: 12) {
                Text("Mix a color").foregroundStyle(LineupStyle.text)
                Spacer(minLength: 8)
                Circle().fill(accent.color).frame(width: 22, height: 22)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(LineupStyle.secondary)
            }
            .font(.inter(.body))
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Keeps a colour of one's own among My colors.
    fileprivate func saveRow(_ accent: LineupAccent) -> some View {
        let canSave = !accent.isPreset && !saved.contains(accent.hex)
        return Button {
            if typingHex { applyHex() }
            save(draft)
        } label: {
            HStack {
                Text(saved.contains(accent.hex) ? "Saved to My Colors" : "Save to My Colors")
                Spacer()
            }
            .font(.inter(.body))
            .foregroundStyle(canSave || typingHex ? accent.color : LineupStyle.secondary)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!(canSave || typingHex))
    }

    /// The colours kept, newest first: a tap tries one, a long press offers
    /// to forget it.
    fileprivate var savedRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(saved, id: \.self) { hex in
                    Button { choose(hex) } label: {
                        AccentSwatch(color: LineupAccent.accent(forHex: hex).color, selected: hex == draft)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) { forget(hex) }
                    }
                    .accessibilityLabel("Saved color #\(hex)")
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
    }

    /// The typed code, as the colour being tried -- or, if it is not a
    /// colour, the field put back to the one that is.
    fileprivate func applyHex() {
        if let typed = LineupAccent.normalized(hexText) {
            choose(typed)
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

/// One colour: a flat dot, and a ring around it, clear of its edge, when it
/// is the one chosen.
private struct AccentSwatch: View {
    let color: Color
    let selected: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 34, height: 34)
            .padding(4)
            .overlay(Circle().strokeBorder(selected ? LineupStyle.text : .clear, lineWidth: 2))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// The app in miniature, in the colour being tried: the masthead's bar, a
/// selected tab, a switch that is on, and a button.
private struct AccentPreviewCard: View {
    let accent: LineupAccent

    var body: some View {
        let shape = LineupPanelStyle.shape
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
        .background(LineupPanelStyle.fill, in: shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview in \(accent.name)")
    }

    private func tab(symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, design: .rounded))
            .foregroundStyle(selected ? accent.color : LineupStyle.text)
            .opacity(selected ? 1 : 0.38)
            .frame(width: 32, height: 34)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(accent.color).frame(height: 2) }
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
