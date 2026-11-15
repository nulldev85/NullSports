#if os(tvOS)
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Set Up with iPhone: a code for the phone to scan, and what came of it.
/// The code is new each time the screen opens, and only works while it shows.
///
/// Drawn the way the app's own sheets are: dark cards on the near-black
/// ground, a tinted tile beside each heading, the app's capsule buttons. The
/// code stays black on white, the only way every phone's camera reads it.
struct TVDeviceSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @State private var receiver: DeviceSetupReceiver?
    @State private var codeImage: UIImage?
    @FocusState private var focusedButton: SetupButton?

    private enum SetupButton: Hashable { case done, tryAgain, cancel }

    private var phase: DeviceSetupReceiver.Phase { receiver?.phase ?? .starting }

    private var finished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// The code has been used: the setup is arriving or loading.
    private var busy: Bool { phase == .receiving || phase == .settling }

    var body: some View {
        HStack(alignment: .center, spacing: 72) {
            codePanel
            VStack(alignment: .leading, spacing: 34) {
                heading
                steps
                status
                buttons
            }
            .frame(width: 820, alignment: .leading)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45), value: phase)
        .animation(.easeOut(duration: 0.3), value: codeImage != nil)
        .defaultFocus($focusedButton, .cancel)
        .onChange(of: phase) { _, phase in focusedButton = Self.primary(for: phase) }
        .onAppear(perform: start)
        .onDisappear {
            receiver?.stop()
            DeviceSetupHold.shared.keepsWelcome = false
        }
        .task(id: receiver?.pairing.service) {
            guard let url = receiver?.pairing.url else { return }
            // Made away from the screen, so the remote's focus never waits
            // on it.
            let image = await Task.detached(priority: .userInitiated) { Self.image(for: url) }.value
            guard !Task.isCancelled else { return }
            codeImage = image
        }
    }

    // MARK: The code

    private var codePanel: some View {
        VStack(spacing: 28) {
            ZStack {
                if finished {
                    VStack(spacing: 22) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 84, weight: .bold, design: .rounded))
                            .foregroundStyle(LineupIconTile.green)
                            .frame(width: 184, height: 184)
                            .background(LineupIconTile.green.opacity(0.15), in: Circle())
                        Text("All set")
                            .font(.inter(36, .heavy))
                            .foregroundStyle(LineupPresentationStyle.text)
                    }
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                } else {
                    codeTile.transition(.opacity)
                }
            }
            .frame(width: 420, height: 420)
            VStack(spacing: 6) {
                Text("THIS APPLE TV")
                    .font(.inter(15, .heavy)).tracking(1.2)
                    .foregroundStyle(LineupPresentationStyle.secondary)
                Text(receiver?.pairing.service ?? " ")
                    .font(.inter(22, .semibold))
                    .foregroundStyle(LineupPresentationStyle.text)
                    .lineLimit(1)
            }
        }
        .padding(44)
        .lineupPresentationSurface(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(finished ? "All set" : "Setup code for your iPhone, \(receiver?.pairing.service ?? "")")
    }

    private var codeTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.white)
            if let codeImage {
                Image(uiImage: codeImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(30)
                    .transition(.opacity)
            } else {
                ProgressView().tint(.black)
            }
        }
        // Used once the setup is arriving: it no longer works.
        .opacity(busy ? 0.25 : 1)
        .overlay {
            if busy {
                ProgressView()
                    .scaleEffect(1.5)
                    .transition(.opacity)
            }
        }
    }

    // MARK: The words

    private var heading: some View {
        HStack(alignment: .top, spacing: 22) {
            LineupIconTile(symbol: "iphone", size: 64, tint: LineupStyle.highlight)
            VStack(alignment: .leading, spacing: 10) {
                Text("Set Up with iPhone")
                    .font(.inter(44, .heavy))
                    .foregroundStyle(LineupPresentationStyle.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Your IPTV providers, media servers, sign-ins, watch history, favorites and settings come across your Wi-Fi. Nothing to type with the remote.")
                    .font(.inter(22, .medium))
                    .foregroundStyle(LineupPresentationStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1, "Point your iPhone’s camera at the code, or open Lineup on it and go to Settings › Set Up Apple TV.",
                 done: busy || finished)
            Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1).padding(.leading, 86)
            step(2, "Check what’s listed, then tap Send.", done: busy || finished)
            Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1).padding(.leading, 86)
            step(3, "Keep this screen open until it says you’re all set.", done: finished)
        }
        .lineupPresentationSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func step(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(spacing: 22) {
            ZStack {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(LineupIconTile.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)")
                        .font(.inter(20, .heavy))
                        .foregroundStyle(LineupStyle.highlight)
                        .transition(.opacity)
                }
            }
            .frame(width: 44, height: 44)
            .background((done ? LineupIconTile.green : LineupStyle.highlight).opacity(0.15), in: Circle())
            Text(text)
                .font(.inter(22, .medium))
                .foregroundStyle(done ? LineupPresentationStyle.secondary : LineupPresentationStyle.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "")
    }

    private var status: some View {
        HStack(spacing: 18) {
            ZStack {
                switch phase {
                case .finished:
                    LineupIconTile(symbol: "checkmark", size: 40, tint: LineupIconTile.green)
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    LineupIconTile(symbol: "exclamationmark.triangle", size: 40, tint: LineupIconTile.orange)
                        .transition(.scale.combined(with: .opacity))
                default:
                    ProgressView().transition(.opacity)
                }
            }
            .frame(width: 40, height: 40)
            Text(statusText)
                .font(.inter(22, .semibold))
                .foregroundStyle(LineupPresentationStyle.text)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(minHeight: 80)
        .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch phase {
        case .starting: "Getting ready…"
        case .waiting: "Waiting for your iPhone…"
        case .receiving: "Receiving your setup…"
        case .settling: "Loading your channels and library…"
        case .finished(let applied): Self.summary(applied)
        case .failed(let message): message
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 20) {
            switch phase {
            case .finished:
                Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                    .focused($focusedButton, equals: .done)
            case .failed:
                Button { receiver?.restart() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    .focused($focusedButton, equals: .tryAgain)
                Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                    .focused($focusedButton, equals: .cancel)
            case .receiving, .settling:
                EmptyView()
            default:
                Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                    .focused($focusedButton, equals: .cancel)
            }
        }
        .lineupButtonStyle()
        .frame(height: 70, alignment: .leading)
    }

    private static func primary(for phase: DeviceSetupReceiver.Phase) -> SetupButton? {
        switch phase {
        case .finished: .done
        case .failed: .tryAgain
        case .receiving, .settling: nil
        default: .cancel
        }
    }

    private func start() {
        guard receiver == nil else { return }
        // On a TV with nothing yet, this screen covers the first one: keep
        // that there until Done, or the first provider to arrive swaps it
        // for the tabs and takes this screen with it.
        if !library.hasProfile && !media.hasProfile { DeviceSetupHold.shared.keepsWelcome = true }
        let receiver = DeviceSetupReceiver(
            take: { payload in try DeviceSetup.apply(payload) },
            settle: { [library, media] payload, applied in
                // Everything the setup wrote is read again, as at launch, and
                // loaded: the providers, the servers with any new sign-ins,
                // the Library's choices. The screen says All set once that's
                // done, or after a minute, when the loading carries on behind.
                let sports = Task { await library.adoptSetup() }
                let shelves = Task {
                    await media.adoptSetup(payload.library, renamed: applied.renamed)
                    GameReminders.shared.restore()
                }
                await Self.wait(for: Task { await sports.value; await shelves.value }, atMost: .seconds(60))
            })
        self.receiver = receiver
        receiver.start()
    }

    /// Waits for `work`, or for `limit`, whichever comes first. The work
    /// isn't stopped either way.
    private static func wait(for work: Task<Void, Never>, atMost limit: Duration) async {
        let once = DeviceSetupOnce()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task {
                await work.value
                once.run { done.resume() }
            }
            Task {
                try? await Task.sleep(for: limit)
                once.run { done.resume() }
            }
        }
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

    nonisolated(unsafe) private static let context = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated private static func image(for url: URL) -> UIImage? {
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
