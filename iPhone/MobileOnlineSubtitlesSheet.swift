import SwiftUI
import UIKit
import Combine

struct MobileSubtitleSearchInput: UIViewRepresentable {
    let results: MobileSubtitleResults
    func makeCoordinator() -> Coordinator { Coordinator(results) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "Filter releases"
        field.textColor = .white
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for:
            UIFont(name: LineupFonts.face(for: .regular), size: 17) ?? .systemFont(ofSize: 17))
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.spellCheckingType = .no; field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        field.accessibilityIdentifier = "OnlineSubtitleReleaseFilter"
        field.accessibilityLabel = "Filter subtitle releases"
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) { /* never rewrite an active editing buffer */ }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        let results: MobileSubtitleResults
        init(_ results: MobileSubtitleResults) { self.results = results }
        @objc func edited(_ field: UITextField) { results.filter(field.text ?? "") }
        func textFieldShouldClear(_ field: UITextField) -> Bool { results.filter(""); return true }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { field.resignFirstResponder(); return true }
    }
}

struct MobileOnlineSubtitlesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let identity: () async -> MobileSubtitleIdentity?
    var showsPiPLimitation = false
    let onSelect: (Data, MobileOnlineSubtitle) async throws -> Void
    @StateObject private var results = MobileSubtitleResults()
    @AppStorage("Lineup.subtitles.language.v1") private var language = "en"
    @State private var languagesOpen = false
    @State private var loading = true
    @State private var error: String?
    @State private var downloading: Int?
    @State private var downloadTask: Task<Void, Never>?
    @State private var resolved: MobileSubtitleIdentity?
    @State private var retry = 0
    private static let languages = [("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt-br", "Portuguese (Brazil)"), ("pt-pt", "Portuguese (Portugal)"),
        ("ja", "Japanese"), ("ko", "Korean"), ("ar", "Arabic"), ("hi", "Hindi"), ("zh-cn", "Chinese (Simplified)"), ("zh-tw", "Chinese (Traditional)")]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                LineupIconTile(symbol: "captions.bubble", size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find Subtitles").font(.inter(.title3, .bold))
                    Text(name).font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(2)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
                    .background(LineupPanelStyle.well, in: Circle()) }
                    .buttonStyle(.plain).accessibilityLabel("Close subtitle search")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(LineupPanelStyle.quiet)
                MobileSubtitleSearchInput(results: results)
            }.padding(.horizontal, 14).frame(height: 44).background(LineupPanelStyle.fill, in: Capsule())
            Button { languagesOpen = true } label: {
                HStack { Text(Self.languages.first { $0.0 == language }?.1 ?? language); Image(systemName: "chevron.down") }
                    .lineupChip(true)
            }.buttonStyle(.plain).disabled(downloading != nil)
            if let error {
                PlaybackEngineText(error, style: .caption).font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet)
                Button("Try Again") { retry += 1 }.lineupFlatButton().disabled(downloading != nil)
            }
            if loading {
                ProgressView("Finding subtitles…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if results.visible.isEmpty {
                            Text("No matching releases. Try another language or clear the release filter.")
                                .font(.inter(.callout)).foregroundStyle(LineupPanelStyle.quiet).padding(.vertical, 28)
                        }
                        ForEach(results.visible) { subtitle in
                            Button { download(subtitle) } label: { row(subtitle) }
                                .buttonStyle(MobileCardButtonStyle()).disabled(downloading != nil)
                        }
                    }
                }.scrollDismissesKeyboard(.interactively)
            }
            Text("Subtitles provided by OpenSubtitles.com. Choose a release matching your video.")
                .font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet)
            if showsPiPLimitation {
                Text("Downloaded captions are available in this player, but not in Picture in Picture for this playback.")
                    .font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet)
            }
        }
        .padding(18).foregroundStyle(LineupStyle.text).background(LineupStyle.background.ignoresSafeArea())
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .lineupChoices("Subtitle Language", symbol: "globe", isPresented: $languagesOpen) {
            Self.languages.map { code, name in MobileMenuItem(name, id: code, isSelected: code == language) { language = code } }
        }
        .task(id: language + "|" + String(retry)) { await search() }
        .onDisappear { downloadTask?.cancel(); results.cancel() }
    }

    private func row(_ subtitle: MobileOnlineSubtitle) -> some View {
        HStack(spacing: 12) {
            LineupIconTile(symbol: "captions.bubble", size: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(subtitle.title).font(.inter(.subheadline, .semibold)).multilineTextAlignment(.leading).lineLimit(3)
                Text([subtitle.language.uppercased(), subtitle.hearingImpaired ? "Hearing impaired" : nil,
                      subtitle.foreignOnly ? "Foreign parts only" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if downloading == subtitle.id { ProgressView() }
            else { Image(systemName: "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(LineupStyle.highlight) }
        }.padding(14).background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 18))
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
            if !Task.isCancelled { self.error = (error as? MobileSubtitleFailure)?.localizedDescription ?? MobileSubtitleFailure.unavailable.localizedDescription }
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
                if !Task.isCancelled { self.error = (error as? MobileSubtitleFailure)?.localizedDescription ?? MobileSubtitleFailure.unavailable.localizedDescription }
            }
        }
    }
}
