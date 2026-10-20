#if os(tvOS)
import SwiftUI

/// Find Subtitles Online, from OpenSubtitles: the releases in one language
/// for the title playing, newest first as the service ranks them. Select
/// one and it is added to the picture and chosen. The phone's sheet, across
/// the screen.
struct TVOnlineSubtitlesScreen: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let identity: () async -> MobileSubtitleIdentity?
    let onSelect: (Data, MobileOnlineSubtitle) async throws -> Void
    @StateObject private var results = MobileSubtitleResults()
    @AppStorage("Lineup.subtitles.language.v1") private var language = "en"
    @State private var choosingLanguage = false
    @State private var loading = true
    @State private var error: String?
    @State private var downloading: Int?
    @State private var downloadTask: Task<Void, Never>?
    @State private var resolved: MobileSubtitleIdentity?
    @State private var retry = 0

    private static let languages = [("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt-br", "Portuguese (Brazil)"), ("pt-pt", "Portuguese (Portugal)"),
        ("ja", "Japanese"), ("ko", "Korean"), ("ar", "Arabic"), ("hi", "Hindi"), ("zh-cn", "Chinese (Simplified)"),
        ("zh-tw", "Chinese (Traditional)")]

    private var languageName: String { Self.languages.first { $0.0 == language }?.1 ?? language }

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                LineupIconTile(symbol: "captions.bubble", size: 72)
                Text("Find Subtitles Online").font(.inter(40, .bold)).padding(.top, 26)
                Text(name).font(.inter(23, .semibold)).foregroundStyle(LineupStyle.secondary)
                    .lineLimit(3).padding(.top, 8)
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                    if downloading == nil { choosingLanguage = true }
                }) {
                    TVSubtitleButtonLabel(title: languageName, symbol: "globe")
                }
                .padding(.top, 30)
                if let error {
                    Text(error).font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 24)
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                        if downloading == nil { retry += 1 }
                    }) {
                        TVSubtitleButtonLabel(title: "Try Again", symbol: "arrow.clockwise")
                    }
                    .padding(.top, 14)
                }
                Spacer(minLength: 20)
                Text("Subtitles provided by OpenSubtitles.com. Choose the release that matches your video.")
                    .font(.inter(17)).foregroundStyle(LineupPanelStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 520, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            list.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90).padding(.vertical, 70)
        .foregroundStyle(LineupStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.background.ignoresSafeArea())
        .tvChoices("Subtitle Language", symbol: "globe", isPresented: $choosingLanguage) {
            Self.languages.map { code, name in
                TVChoice(name, id: code, isSelected: code == language) { language = code }
            }
        }
        .task(id: language + "|" + String(retry)) { await search() }
        .onDisappear { downloadTask?.cancel(); results.cancel() }
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            VStack(spacing: 18) {
                ProgressView().tint(LineupStyle.text)
                Text("Finding subtitles…").font(.inter(21)).foregroundStyle(LineupPanelStyle.quiet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.visible.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "captions.bubble").font(.system(size: 44)).foregroundStyle(LineupPanelStyle.quiet)
                Text(error == nil ? "No releases in \(languageName)" : "Nothing to show")
                    .font(.inter(26, .semibold))
                Text("Try another language.").font(.inter(19)).foregroundStyle(LineupStyle.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(results.visible) { subtitle in
                        TVSelectable(scale: LineupStyle.cardLift, fillRadius: 20,
                                     action: { download(subtitle) },
                                     requestInitialFocus: subtitle.id == results.visible.first?.id) {
                            row(subtitle)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10).padding(.bottom, 70)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func row(_ subtitle: MobileOnlineSubtitle) -> some View {
        HStack(spacing: 20) {
            LineupIconTile(symbol: "captions.bubble", size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(subtitle.title).font(.inter(22, .semibold)).multilineTextAlignment(.leading).lineLimit(3)
                Text([subtitle.language.uppercased(), subtitle.hearingImpaired ? "Hearing impaired" : nil,
                      subtitle.foreignOnly ? "Foreign parts only" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.inter(17)).foregroundStyle(LineupPanelStyle.quiet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if downloading == subtitle.id {
                ProgressView().tint(LineupStyle.text)
            } else {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 36))
                    .foregroundStyle(LineupStyle.highlight)
            }
        }
        .padding(22)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func search() async {
        loading = true; error = nil; results.replace([])
        defer { if !Task.isCancelled { loading = false } }
        do {
            let exact: MobileSubtitleIdentity
            if let resolved { exact = resolved } else {
                guard let found = await identity() else { throw MobileSubtitleFailure.identity }
                try Task.checkCancellation(); resolved = found; exact = found
            }
            let rows = try await MobileOpenSubtitles.shared.search(exact, language: language)
            try Task.checkCancellation(); results.replace(rows)
        } catch {
            if !Task.isCancelled {
                self.error = (error as? MobileSubtitleFailure)?.localizedDescription
                    ?? MobileSubtitleFailure.unavailable.localizedDescription
            }
        }
    }

    private func download(_ subtitle: MobileOnlineSubtitle) {
        guard downloading == nil else { return }
        downloading = subtitle.id; error = nil
        downloadTask = Task { @MainActor in
            defer { downloading = nil }
            do {
                let data = try await MobileOpenSubtitles.shared.download(subtitle)
                try Task.checkCancellation()
                try await onSelect(data, subtitle)
                try Task.checkCancellation()
                dismiss()
            } catch {
                if !Task.isCancelled {
                    self.error = (error as? MobileSubtitleFailure)?.localizedDescription
                        ?? MobileSubtitleFailure.unavailable.localizedDescription
                }
            }
        }
    }
}

/// How subtitles look, in which language they open, and this title's
/// timing: the phone's subtitle settings, across the screen.
struct TVSubtitleSettingsScreen: View {
    @ObservedObject var controller: TVPlaybackController
    @State private var choosingLanguage = false

    private var preferences: MobileSubtitlePreferences { controller.subtitlePreferences }

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                LineupIconTile(symbol: "textformat.size", size: 72)
                Text("Subtitle Settings").font(.inter(40, .bold)).padding(.top, 26)
                Text(controller.subtitleLooksApplyNextTitle
                     ? "VLC sets the size and background as a video opens: they apply from the next one. Timing changes at once."
                     : "Size and background change at once. Picture-based subtitles keep their own look.")
                    .font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            .frame(width: 520, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    caption("SIZE")
                    HStack(spacing: 12) {
                        ForEach(MobileSubtitlePreferences.sizes, id: \.0) { scale, name in
                            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                                var next = preferences
                                next.scale = scale
                                controller.setSubtitlePreferences(next)
                            }, requestInitialFocus: scale == preferences.scale) {
                                TVSubtitleButtonLabel(title: name, prominent: scale == preferences.scale)
                            }
                        }
                    }
                    switchRow("Background", symbol: "rectangle.fill", isOn: preferences.background) {
                        var next = preferences
                        next.background.toggle()
                        controller.setSubtitlePreferences(next)
                    }
                    .padding(.top, 8)
                    caption("LANGUAGE").padding(.top, 14)
                    TVSelectable(scale: LineupStyle.cardLift, fillRadius: 20, action: { choosingLanguage = true }) {
                        settingRow(preferences.languageName, symbol: "globe",
                                   detail: "Opened with each title where it has them")
                    }
                    caption("TIMING").padding(.top, 14)
                    HStack(spacing: 16) {
                        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                            controller.setSubtitleDelay(controller.subtitleDelaySeconds - 0.25)
                        }) {
                            TVSubtitleButtonLabel(title: "Earlier", symbol: "minus")
                        }
                        Text(String(format: "%+.2f s", controller.subtitleDelaySeconds))
                            .font(.interDigits(28, .bold)).frame(minWidth: 150)
                            .contentTransition(.numericText())
                        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                            controller.setSubtitleDelay(controller.subtitleDelaySeconds + 0.25)
                        }) {
                            TVSubtitleButtonLabel(title: "Later", symbol: "plus")
                        }
                        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                            controller.setSubtitleDelay(0)
                        }) {
                            TVSubtitleButtonLabel(title: "Reset")
                        }
                    }
                    Text("Earlier or later by a quarter of a second. It resets for each video.")
                        .font(.inter(18)).foregroundStyle(LineupPanelStyle.quiet)
                }
                .padding(.horizontal, 14).padding(.vertical, 10).padding(.bottom, 70)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90).padding(.top, 70)
        .foregroundStyle(LineupStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: controller.subtitleDelaySeconds)
        .tvChoices("Subtitle Language", symbol: "globe", isPresented: $choosingLanguage) {
            MobileSubtitlePreferences.languages.map { code, name in
                TVChoice(name, id: code.isEmpty ? "default" : code, isSelected: code == preferences.language) {
                    var next = preferences
                    next.language = code
                    controller.setSubtitlePreferences(next)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.inter(17, .heavy)).tracking(1).foregroundStyle(LineupPanelStyle.caption)
    }

    private func switchRow(_ title: String, symbol: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        TVSelectable(scale: LineupStyle.cardLift, fillRadius: 20, action: toggle) {
            HStack(spacing: 20) {
                LineupIconTile(symbol: symbol, size: 42)
                Text(title).font(.inter(23, .semibold))
                Spacer()
                Text(isOn ? "On" : "Off").font(.inter(22))
                    .foregroundStyle(isOn ? LineupStyle.highlight : LineupPanelStyle.quiet)
            }
            .padding(22)
            .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func settingRow(_ value: String, symbol: String, detail: String) -> some View {
        HStack(spacing: 20) {
            LineupIconTile(symbol: symbol, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.inter(23, .semibold))
                Text(detail).font(.inter(17)).foregroundStyle(LineupPanelStyle.quiet)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 16, weight: .bold))
                .foregroundStyle(LineupPanelStyle.quiet)
        }
        .padding(22)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct TVSubtitleButtonLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    var symbol: String? = nil
    var prominent = false

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).font(.system(size: 20, weight: .bold)) }
            Text(title).font(.inter(21, .semibold)).lineLimit(1)
        }
        .foregroundStyle(prominent ? LineupStyle.onHighlight : LineupStyle.text)
        .padding(.horizontal, 22).frame(height: 58)
        .background(prominent ? LineupStyle.highlight : LineupPanelStyle.well, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}
#endif
