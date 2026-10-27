import AVFoundation
import SwiftUI
import Vision
import VisionKit

/// Set Up Apple TV: reads the code an Apple TV shows, lists what goes with it,
/// and sends it. Opened from Settings, or by the Camera app with the code it
/// read.
struct MobileDeviceSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @State private var pairing: DeviceSetupPairing?
    @State private var phase: Phase = .ready
    @State private var scanning = false
    @State private var cameraDenied = false

    enum Phase: Equatable {
        case ready
        case sending
        case sent
        case failed(String)
    }

    init(pairing: DeviceSetupPairing? = nil) {
        _pairing = State(initialValue: pairing)
    }

    private var hasSources: Bool { !library.profiles.isEmpty || !media.profiles.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if let pairing {
                    confirmation(pairing)
                } else {
                    instructions
                }
            }
            .lineupSettingsList()
            .navigationTitle("Set Up Apple TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LineupToolbarItem(placement: .cancellationAction) {
                    Button(phase == .sent ? "Done" : "Cancel") { dismiss() }
                        .buttonStyle(LineupBarButtonStyle())
                        .disabled(phase == .sending)
                }
            }
        }
        .interactiveDismissDisabled(phase == .sending)
        .fullScreenCover(isPresented: $scanning) { scanner }
    }

    // MARK: Before a code

    @ViewBuilder private var instructions: some View {
        Section {
            step(1, "On your Apple TV, open Lineup and choose Set Up with iPhone. It’s on the first screen, and at the top of Settings.")
            step(2, "Scan the code the TV shows.")
            step(3, "Check what’s listed here, then tap Send.")
        }
        .lineupSettingsRows()
        Section {
            if DataScannerViewController.isSupported {
                Button(action: scan) {
                    row("Scan Code", symbol: "qrcode.viewfinder")
                }
            } else {
                row("Use the Camera app to scan the code on the TV", symbol: "camera")
            }
        } footer: {
            Text(cameraDenied
                 ? "Lineup can’t use the camera. Turn it on in Settings › Lineup, or scan the code with the Camera app instead."
                 : "The Camera app can scan the code too. It opens here.")
                .lineupSettingsFooter()
        }
        .lineupSettingsRows()
    }

    // MARK: With a code

    @ViewBuilder private func confirmation(_ pairing: DeviceSetupPairing) -> some View {
        Section {
            ForEach(library.profiles) { profile in
                row(profile.name, symbol: "antenna.radiowaves.left.and.right", detail: "IPTV")
            }
            ForEach(media.profiles) { profile in
                row(profile.name, symbol: "play.square.stack", detail: "Media server")
            }
            if media.isMDBListConnected { row("MDBList", symbol: "list.star", detail: "Lists and tracking") }
            if media.seerr.isConnected { row("Seerr", symbol: "tray.and.arrow.down", detail: "Requests") }
            if media.localTrackingEnabled, !media.localPlayback.isEmpty {
                row("Watch history", symbol: "clock.arrow.circlepath", detail: "Continue Watching and watched marks")
            }
            row("Favorites, My Teams and settings", symbol: "star.square.on.square")
        } header: {
            Text("Sending to \(pairing.service)").lineupSettingsHeader()
        } footer: {
            Text("Passwords and sign-ins are locked with the code on your TV and go straight to it over your Wi-Fi. Watch history joins the TV’s own: nothing it has watched is lost, and where both have played a title, the later play wins.")
                .lineupSettingsFooter()
        }
        .lineupSettingsRows()
        Section {
            switch phase {
            case .ready:
                Button { send(to: pairing) } label: {
                    row("Send to Apple TV", symbol: "paperplane.fill")
                }
                .disabled(!hasSources)
            case .sending:
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Sending…").font(.inter(17, .medium))
                }
            case .sent:
                row("All set. Your Apple TV has everything.", symbol: "checkmark.circle.fill", tint: LineupIconTile.green)
            case .failed(let message):
                row(message, symbol: "exclamationmark.triangle.fill", tint: LineupIconTile.orange)
                Button(action: startOver) { row("Scan Again", symbol: "qrcode.viewfinder") }
            }
        } footer: {
            if !hasSources {
                Text("Add an IPTV provider or a media server on this iPhone first.").lineupSettingsFooter()
            }
        }
        .lineupSettingsRows()
    }

    // MARK: Rows

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.inter(15, .bold))
                .frame(width: 28, height: 28)
                .background(LineupPresentationStyle.row, in: Circle())
            Text(text).font(.inter(16))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(LineupStyle.text)
        .padding(.vertical, 4)
    }

    private func row(_ title: String, symbol: String, detail: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 14) {
            LineupIconTile(symbol: symbol, size: 30, tint: tint)
            Text(title)
                .font(.inter(17, .medium))
                .foregroundStyle(LineupStyle.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.inter(15)).foregroundStyle(LineupPanelStyle.listValue).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func scan() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scanning = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) { scanning = true } else { cameraDenied = true }
            }
        default:
            cameraDenied = true
        }
    }

    private func startOver() {
        phase = .ready
        pairing = nil
        if DataScannerViewController.isSupported { scan() }
    }

    private func send(to pairing: DeviceSetupPairing) {
        phase = .sending
        media.flushLocalPlayback()
        let payload = DeviceSetup.capture(library: DeviceSetupPayload.LibraryChoices(media))
        Task {
            do {
                try await DeviceSetupSender.send(payload, pairing: pairing)
                phase = .sent
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription
                                ?? DeviceSetupError.unreachable.errorDescription ?? "")
            }
        }
    }

    private var scanner: some View {
        ZStack(alignment: .top) {
            MobileSetupCodeScanner { found in
                pairing = found
                phase = .ready
                scanning = false
            }
            .ignoresSafeArea()
            HStack {
                Text("Point at the code on your TV")
                    .font(.inter(17, .semibold))
                Spacer()
                Button("Cancel") { scanning = false }
                    .buttonStyle(LineupBarButtonStyle())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.black.opacity(0.55))
        }
        .background(Color.black)
    }
}

/// The camera, looking for a setup code.
private struct MobileSetupCodeScanner: UIViewControllerRepresentable {
    let onFound: (DeviceSetupPairing) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (DeviceSetupPairing) -> Void
        private var found = false

        init(onFound: @escaping (DeviceSetupPairing) -> Void) { self.onFound = onFound }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !found else { return }
            for item in addedItems {
                guard case .barcode(let code) = item, let text = code.payloadStringValue,
                      let url = URL(string: text), let pairing = DeviceSetupPairing(url: url) else { continue }
                found = true
                onFound(pairing)
                return
            }
        }
    }
}
