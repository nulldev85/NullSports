import SwiftUI

struct MobileSubtitleSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: MobilePlaybackController
    @State private var choosingLanguage = false
    @State private var choosingSize = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                LineupIconTile(symbol: "captions.bubble", size: 32)
                Text("Subtitle Settings").font(.inter(.title3, .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold))
                        .frame(width: 44, height: 44).background(LineupPanelStyle.well, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Close subtitle settings")
            }
            ScrollView {
                VStack(spacing: 16) {
                    Text("This is how your subtitles will look.")
                        .font(.system(size: 18 * controller.subtitlePreferences.scale, weight: .semibold))
                        .multilineTextAlignment(.center).foregroundStyle(.white).padding(10)
                        .background(controller.subtitlePreferences.background ? Color.black.opacity(0.8) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, minHeight: 96)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
                    VStack(spacing: 0) {
                        choice("Preferred Language", value: controller.subtitlePreferences.languageName) { choosingLanguage = true }
                        Divider()
                        choice("Text Size", value: controller.subtitlePreferences.sizeName) { choosingSize = true }
                        Divider()
                        Toggle("Text Background", isOn: Binding(get: { controller.subtitlePreferences.background }, set: { value in
                            var preferences = controller.subtitlePreferences; preferences.background = value
                            controller.setSubtitlePreferences(preferences)
                        })).tint(LineupStyle.highlight).padding(14)
                    }.font(.inter(.body, .semibold)).background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 18))
                    Text("Your preferred language is used when starting the next video and for online subtitle search.")
                        .font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet)
                    VStack(spacing: 12) {
                        Text("Subtitle Timing").font(.inter(.headline))
                        HStack {
                            timingButton("Earlier", symbol: "minus", amount: -0.25)
                            Spacer()
                            Text(String(format: "%+.2f s", controller.subtitleDelaySeconds))
                                .font(.inter(.headline).monospacedDigit()).accessibilityIdentifier("SubtitleDelayValue")
                            Spacer()
                            timingButton("Later", symbol: "plus", amount: 0.25)
                        }
                        Button("Reset Timing") { controller.setSubtitleDelay(0) }.lineupFlatButton()
                            .disabled(controller.subtitleDelaySeconds == 0)
                        Text("Earlier or later by 0.25 seconds. Resets for each video.")
                            .font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet)
                    }.padding(14).background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 18))
                        .disabled(controller.engine == .system)
                    Text(controller.engine == .vlc
                         ? "VLC applies text appearance to the next video. Timing updates immediately."
                         : "Text appearance applies in this player. Image-based captions and Picture in Picture can use their own appearance.")
                        .font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet)
                    if controller.engine == .system {
                        Text("Subtitle timing requires AetherEngine or VLC.").font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet)
                    } else if controller.engine == .aether {
                        Text("Timing adjustments apply in the main player; native Picture in Picture uses the original timing.")
                            .font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet)
                    }
                }
            }
        }.padding(18).foregroundStyle(LineupStyle.text).background(LineupStyle.background.ignoresSafeArea())
            .presentationDetents([.large]).presentationDragIndicator(.visible)
            .lineupChoices("Preferred Language", symbol: "globe", isPresented: $choosingLanguage) {
                MobileSubtitlePreferences.languages.map { code, name in
                    MobileMenuItem(name, id: "language-" + code, isSelected: controller.subtitlePreferences.language == code) {
                        var preferences = controller.subtitlePreferences; preferences.language = code
                        controller.setSubtitlePreferences(preferences)
                    }
                }
            }
            .lineupChoices("Text Size", symbol: "textformat.size", isPresented: $choosingSize) {
                MobileSubtitlePreferences.sizes.map { scale, name in
                    MobileMenuItem(name, isSelected: controller.subtitlePreferences.scale == scale) {
                        var preferences = controller.subtitlePreferences; preferences.scale = scale
                        controller.setSubtitlePreferences(preferences)
                    }
                }
            }
    }
    private func choice(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Text(title); Spacer(); Text(value).foregroundStyle(LineupPanelStyle.quiet); Image(systemName: "chevron.right") }.padding(14) }
            .buttonStyle(.plain)
    }
    private func timingButton(_ title: String, symbol: String, amount: Double) -> some View {
        Button { controller.setSubtitleDelay(controller.subtitleDelaySeconds + amount) } label: {
            Label(title, systemImage: symbol).font(.inter(.subheadline, .semibold)).padding(10)
                .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel("Subtitles " + title.lowercased() + " by a quarter second")
    }
}
