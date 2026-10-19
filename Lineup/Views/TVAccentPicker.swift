#if os(tvOS)
import SwiftUI

/// The phone's accent choices adapted for the remote. The active accent only
/// changes after Done; saved colors use the same storage and limits on both apps.
struct TVAccentPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var hexText: String
    @State private var mixing = false
    @State private var invalidHex = false
    @AppStorage(LineupAccent.savedKey) private var savedRaw = ""
    let onChoose: (String) -> Void

    init(hex: String, onChoose: @escaping (String) -> Void) {
        let start = LineupAccent.normalized(hex) ?? LineupAccent.red.hex
        _draft = State(initialValue: start)
        _hexText = State(initialValue: start)
        self.onChoose = onChoose
    }

    private var accent: LineupAccent { .accent(forHex: draft) }
    private var saved: [String] { LineupAccent.savedList(savedRaw) }
    private var typed: LineupAccent? {
        LineupAccent.normalized(hexText).map { .accent(forHex: $0) }
    }
    private var canSave: Bool {
        guard let typed else { return false }
        return !typed.isPreset && !saved.contains(typed.hex)
    }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)

    var body: some View {
        VStack(spacing: 30) {
            HStack {
                TVAccentButton("Cancel") { dismiss() }.frame(width: 170)
                Spacer()
                Text("Accent Color").font(.inter(36, .bold))
                Spacer()
                TVAccentButton("Done", accent: accent, initialFocus: true) {
                    guard applyHex() else { return }
                    onChoose(draft)
                    dismiss()
                }
                .frame(width: 170)
            }
            .frame(width: 1400)
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(spacing: 24) {
                        panel("Color", symbol: "paintpalette", trailing: accent.name) {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(LineupAccent.presets) { color in
                                    swatch(color.hex, name: color.name)
                                }
                            }
                        }
                        panel("My Colors", symbol: "bookmark") {
                            if saved.isEmpty {
                                Text("Save a custom color to keep it here.")
                                    .font(.inter(20)).foregroundStyle(LineupPanelStyle.quiet)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(saved, id: \.self) { hex in
                                        swatch(hex, name: "#\(hex)")
                                            .tvHoldMenu("#\(hex)", symbol: "paintpalette") {
                                                [TVChoice("Remove from My Colors", symbol: "trash", isDestructive: true) {
                                                    forget(hex)
                                                }]
                                            }
                                    }
                                }
                                Text("Hold a color to remove it.")
                                    .font(.inter(17)).foregroundStyle(LineupPanelStyle.quiet)
                            }
                        }
                    }
                    .frame(width: 686)
                    .focusSection()
                    VStack(spacing: 24) {
                        preview
                        panel("Custom", symbol: "slider.horizontal.3") {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack(spacing: 16) {
                                    Text("Hex").font(.inter(22, .semibold))
                                    TextField("Six hex digits", text: $hexText)
                                        .font(.interDigits(24, .semibold))
                                        .textFieldStyle(.plain).focusEffectDisabled()
                                        .textInputAutocapitalization(.characters)
                                        .autocorrectionDisabled()
                                        .padding(16)
                                        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 14))
                                        .onSubmit { _ = applyHex() }
                                        .accessibilityLabel("Custom color hex code")
                                }
                                if invalidHex {
                                    Text("Enter six hex digits, like FF3347.")
                                        .font(.inter(17)).foregroundStyle(LineupIconTile.red)
                                }
                                TVAccentButton("Mix a Color", symbol: "slider.horizontal.3") {
                                    guard applyHex() else { return }
                                    mixing = true
                                }
                                TVAccentButton(saved.contains(typed?.hex ?? "") ? "Saved to My Colors" : "Save to My Colors",
                                               symbol: "bookmark", accent: accent) {
                                    guard applyHex() else { return }
                                    save(draft)
                                }
                                .disabled(!canSave).opacity(canSave ? 1 : 0.4)
                                TVAccentButton("Reset to Red", symbol: "arrow.uturn.backward") {
                                    choose(LineupAccent.red.hex)
                                }
                            }
                        }
                    }
                    .frame(width: 686)
                    .focusSection()
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
            .frame(width: 1440)
        }
        .foregroundStyle(LineupStyle.text)
        .padding(.top, 56).padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onExitCommand { dismiss() }
        .fullScreenCover(isPresented: $mixing) {
            TVAccentMixer(hex: draft, onChoose: choose).presentationBackground(.clear)
        }
    }

    private func panel<Content: View>(_ title: String, symbol: String, trailing: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                LineupIconTile(symbol: symbol, size: 36)
                Text(title.uppercased()).font(.inter(21, .heavy)).tracking(0.6)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.inter(18, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                }
            }
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
            content()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func swatch(_ hex: String, name: String) -> some View {
        let color = LineupAccent.accent(forHex: hex)
        return TVSelectable(scale: 1.08, fillRadius: 18, action: { choose(hex) }) {
            VStack(spacing: 10) {
                Circle().fill(color.color).frame(width: 54, height: 54)
                    .padding(6)
                    .overlay(Circle().strokeBorder(draft == hex ? .white : .clear, lineWidth: 3))
                    .overlay {
                        if draft == hex {
                            Image(systemName: "checkmark").font(.inter(21, .bold)).foregroundStyle(color.onAccent)
                        }
                    }
                Text(name).font(.inter(14, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(LineupPanelStyle.quiet)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(draft == hex ? [.isButton, .isSelected] : .isButton)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Rectangle().fill(accent.color).frame(width: 5, height: 50)
                VStack(alignment: .leading, spacing: 5) {
                    Text("LINEUP").font(.inter(30, .heavy))
                    Text("LIVE SPORTS").font(.inter(12, .bold)).tracking(3)
                        .foregroundStyle(LineupPanelStyle.quiet)
                }
                Spacer()
                Capsule().fill(accent.color).frame(width: 76, height: 42)
                    .overlay(alignment: .trailing) { Circle().fill(.white).padding(4) }
            }
            HStack(spacing: 30) {
                Image(systemName: "star.fill").foregroundStyle(accent.color)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(accent.color).frame(height: 3).offset(y: 12)
                    }
                Image(systemName: "square.grid.2x2.fill").foregroundStyle(LineupPanelStyle.quiet)
                Image(systemName: "sportscourt.fill").foregroundStyle(LineupPanelStyle.quiet)
                Spacer()
                Text("WATCH").font(.inter(19, .heavy)).tracking(1.5)
                    .foregroundStyle(accent.onAccent)
                    .padding(.horizontal, 26).frame(height: 48)
                    .background(accent.color, in: Capsule())
            }
            .font(.system(size: 28, weight: .bold))
        }
        .padding(30)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview using \(accent.name), #\(draft)")
    }

    private func choose(_ hex: String) {
        guard let value = LineupAccent.normalized(hex) else { return }
        draft = value
        hexText = value
        invalidHex = false
    }

    @discardableResult
    private func applyHex() -> Bool {
        guard let value = LineupAccent.normalized(hexText) else {
            invalidHex = true
            return false
        }
        choose(value)
        return true
    }

    private func save(_ hex: String) {
        guard let value = LineupAccent.normalized(hex), !LineupAccent.accent(forHex: value).isPreset else { return }
        let kept = [value] + saved.filter { $0 != value }
        savedRaw = LineupAccent.joined(Array(kept.prefix(LineupAccent.savedLimit)))
        CloudSettingsSync.shared.localSettingsChanged()
    }

    private func forget(_ hex: String) {
        savedRaw = LineupAccent.joined(saved.filter { $0 != hex })
        CloudSettingsSync.shared.localSettingsChanged()
    }
}

private struct TVAccentButton: View {
    let title: String
    var symbol: String?
    var accent: LineupAccent?
    var initialFocus = false
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, accent: LineupAccent? = nil,
         initialFocus: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.accent = accent
        self.initialFocus = initialFocus
        self.action = action
    }

    var body: some View {
        TVSelectable(scale: 1.025, fillRadius: 16, action: action, requestInitialFocus: initialFocus) {
            HStack(spacing: 14) {
                if let symbol { LineupIconTile(symbol: symbol, size: 32) }
                Text(title).font(.inter(21, .semibold))
            }
            .foregroundStyle(accent?.onAccent ?? LineupStyle.text)
            .frame(maxWidth: .infinity).frame(height: 62)
            .background(accent?.color ?? LineupPanelStyle.well,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// Explicit minus/plus controls let directional presses keep their usual focus
/// navigation. Hue, saturation and brightness are adjusted with Select.
private struct TVAccentMixer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    let onChoose: (String) -> Void

    init(hex: String, onChoose: @escaping (String) -> Void) {
        let hsb = LineupAccent.accent(forHex: hex).hsb
        _hue = State(initialValue: hsb.hue)
        _saturation = State(initialValue: hsb.saturation)
        _brightness = State(initialValue: hsb.brightness)
        self.onChoose = onChoose
    }

    private var accent: LineupAccent {
        .accent(forHex: LineupAccent.hex(hue: hue, saturation: saturation, brightness: brightness))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    LineupIconTile(symbol: "slider.horizontal.3", size: 48)
                    Text("Mix a Color").font(.inter(30, .bold))
                    Spacer()
                    Circle().fill(accent.color).frame(width: 40, height: 40)
                    Text("#\(accent.hex)").font(.interDigits(24, .semibold))
                }
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                shadeField.frame(height: 210)
                adjustment("Hue", value: "\(Int((hue * 360).rounded()))°", progress: hue,
                           decrease: { hue = (hue - 1 / 72 + 1).truncatingRemainder(dividingBy: 1) },
                           increase: { hue = (hue + 1 / 72).truncatingRemainder(dividingBy: 1) })
                adjustment("Saturation", value: "\(Int((saturation * 100).rounded()))%", progress: saturation,
                           decrease: { saturation = max(0, saturation - 0.05) },
                           increase: { saturation = min(1, saturation + 0.05) })
                adjustment("Brightness", value: "\(Int((brightness * 100).rounded()))%", progress: brightness,
                           decrease: { brightness = max(0, brightness - 0.05) },
                           increase: { brightness = min(1, brightness + 0.05) })
                HStack(spacing: 24) {
                    TVAccentButton("Cancel") { dismiss() }
                    TVAccentButton("Use Color", accent: accent, initialFocus: true) {
                        onChoose(accent.hex)
                        dismiss()
                    }
                }
            }
            .padding(36).frame(width: 1000)
            .foregroundStyle(LineupStyle.text)
            .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
            .focusSection()
        }
        .onExitCommand { dismiss() }
    }

    private var shadeField: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .overlay(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    Circle().fill(accent.color).frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .position(x: 14 + saturation * (proxy.size.width - 28),
                                  y: 14 + (1 - brightness) * (proxy.size.height - 28))
                }
        }
        .accessibilityHidden(true)
    }

    private func adjustment(_ title: String, value: String, progress: Double,
                            decrease: @escaping () -> Void, increase: @escaping () -> Void) -> some View {
        HStack(spacing: 20) {
            Text(title).font(.inter(22, .semibold)).frame(width: 150, alignment: .leading)
            TVAccentButton("−", action: decrease).frame(width: 76).accessibilityLabel("Decrease \(title)")
            VStack(spacing: 10) {
                Text(value).font(.interDigits(20, .semibold))
                LineupProgressBar(value: progress, height: 8)
                    .frame(height: 8)
            }
            .frame(maxWidth: .infinity)
            TVAccentButton("+", action: increase).frame(width: 76).accessibilityLabel("Increase \(title)")
        }
    }
}
#endif
