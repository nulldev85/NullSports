#if os(tvOS)
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Set Up with iPhone: a code for the phone to scan, and what came of it.
/// The code is new each time the screen opens, and only works while it shows.
struct TVDeviceSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @State private var receiver: DeviceSetupReceiver?
    @State private var codeImage: UIImage?

    private static let context = CIContext()

    var body: some View {
        HStack(alignment: .center, spacing: 90) {
            code
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SET UP WITH IPHONE")
                        .font(.inter(15, .heavy)).tracking(0.8)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text("Bring Lineup over from your iPhone")
                        .font(.inter(46, .bold))
                        .foregroundStyle(LineupPresentationStyle.text)
                    Text("Your IPTV providers, media servers, sign-ins, watch history, favorites and settings come straight across your Wi-Fi. Nothing to type with the remote.")
                        .font(.inter(22))
                        .foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 22) {
                    step(1, "Point your iPhone’s camera at this code, or open Lineup on it and go to Settings › Set Up Apple TV.")
                    step(2, "Check what’s listed, then tap Send.")
                    step(3, "Keep this screen open until it says you’re all set.")
                }
                status
                buttons
            }
            .frame(width: 780, alignment: .leading)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: start)
        .onDisappear { receiver?.stop() }
        .task(id: receiver?.pairing.service) { codeImage = receiver.flatMap { Self.image(for: $0.pairing.url) } }
    }

    private var finished: Bool {
        if case .finished = receiver?.phase { return true }
        return false
    }

    private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.white)
            if let codeImage {
                Image(uiImage: codeImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(36)
            } else {
                ProgressView().tint(.black)
            }
        }
        .frame(width: 520, height: 520)
        .opacity(finished ? 0.2 : 1)
        .animation(.easeOut(duration: 0.3), value: finished)
        .accessibilityLabel("Setup code for your iPhone")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text("\(number)")
                .font(.inter(20, .bold))
                .foregroundStyle(LineupPresentationStyle.text)
                .frame(width: 40, height: 40)
                .background(LineupPresentationStyle.row, in: Circle())
            Text(text)
                .font(.inter(23))
                .foregroundStyle(LineupPresentationStyle.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 16) {
            switch receiver?.phase ?? .starting {
            case .starting:
                ProgressView()
                Text("Getting ready…")
            case .waiting:
                ProgressView()
                Text("Waiting for your iPhone…")
            case .receiving, .settling:
                ProgressView()
                Text("Setting up…")
            case .finished(let applied):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LineupIconTile.green)
                Text(Self.summary(applied))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LineupIconTile.orange)
                Text(message)
            }
        }
        .font(.inter(23, .semibold))
        .foregroundStyle(LineupPresentationStyle.text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 60, alignment: .leading)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 20) {
            switch receiver?.phase ?? .starting {
            case .finished:
                setupButton("Done", primary: true) { dismiss() }
            case .failed:
                setupButton("Try Again", primary: true) { receiver?.restart() }
                setupButton("Cancel") { dismiss() }
            case .receiving, .settling:
                EmptyView()
            default:
                setupButton("Cancel") { dismiss() }
            }
        }
        .frame(height: 66)
    }

    private func setupButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        TVSelectable(scale: 1.025, fillRadius: 16, action: action, requestInitialFocus: primary) {
            Text(title)
                .font(.inter(22, .semibold))
                .foregroundStyle(LineupPresentationStyle.text)
                .frame(width: 230, height: 66)
                .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityAddTraits(.isButton)
    }

    private func start() {
        guard receiver == nil else { return }
        let receiver = DeviceSetupReceiver(
            take: { payload in try DeviceSetup.apply(payload) },
            settle: { [library, media] payload in
                // Loading runs on past this screen: on a TV set up for the
                // first time the Library and Sports tabs take its place as soon
                // as a source arrives.
                Task { await library.restoreCloudSettings() }
                Task {
                    await media.adoptSetup(payload.library)
                    GameReminders.shared.restore()
                }
            })
        self.receiver = receiver
        receiver.start()
    }

    static func summary(_ applied: DeviceSetup.Applied) -> String {
        var parts: [String] = []
        if applied.providers > 0 {
            parts.append(applied.providers == 1 ? "1 IPTV provider" : "\(applied.providers) IPTV providers")
        }
        if applied.servers > 0 {
            parts.append(applied.servers == 1 ? "1 media server" : "\(applied.servers) media servers")
        }
        guard !parts.isEmpty else { return "All set. Your settings are here." }
        return "All set. \(parts.joined(separator: " and ")) came over with your settings."
    }

    private static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 16, y: 16))
        guard let picture = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: picture)
    }
}
#endif
