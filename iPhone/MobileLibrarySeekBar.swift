import SwiftUI

/// Only this small view redraws under the finger, keeping the video host and
/// the rest of the player's controls out of the drag's render loop.
struct MobileLibrarySeekBar: View {
    let controller: MobilePlaybackController
    let progress: MobilePlaybackProgress
    @ObservedObject var preview: MobileSeekPreviewStore
    let onEditingChanged: (Bool) -> Void
    @State private var target: Double?
    @GestureState private var touching = false

    private var shown: Double { target ?? progress.position }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { track in
                let fraction = min(max(shown / max(progress.duration, 1), 0), 1)
                ZStack(alignment: .leading) {
                    LineupProgressBar(value: fraction, height: target == nil ? LineupProgressBar.standardHeight : 12)
                    if target != nil {
                        Circle().fill(Color.white).frame(width: 14, height: 14)
                            .offset(x: fraction * max(0, track.size.width - 14))
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .updating($touching) { _, active, _ in active = true }
                        .onChanged { move(x: $0.location.x, width: track.size.width) }
                        .onEnded { value in
                            move(x: value.location.x, width: track.size.width)
                            finish()
                        }
                )
                .overlay(alignment: .topLeading) {
                    if let target, let info = preview.source?.info {
                        MobileSeekThumbnail(frame: preview.frame, index: info.index(at: target), seconds: target)
                            .frame(width: min(160, track.size.width), height: 112)
                            .offset(x: min(max(0, fraction * track.size.width - 80), max(0, track.size.width - 160)), y: -116)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 44)
            HStack {
                Text(MobilePlaybackProgress.timecode(shown))
                Spacer()
                Text("-" + MobilePlaybackProgress.timecode(max(0, progress.duration - shown)))
            }
            .font(.inter(.caption2, .semibold).monospacedDigit())
            .foregroundStyle(LineupStyle.mediaText.opacity(0.8))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transaction { $0.animation = nil }
        .onChange(of: touching) { _, active in if !active { finish() } }
        .onChange(of: preview.source?.firstTile.url) { _, _ in
            if let target { preview.request(at: target) }
        }
        .onDisappear { finish(resume: false) }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(MobilePlaybackProgress.timecode(shown))
        .accessibilityAdjustableAction { direction in
            finish()
            switch direction {
            case .increment: controller.skip(by: 15)
            case .decrement: controller.skip(by: -15)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }

    private func move(x: CGFloat, width: CGFloat) {
        if target == nil {
            controller.beginScrubbing()
            guard controller.isScrubbing else { return }
            onEditingChanged(true)
        }
        let next = PlaybackSeekPolicy.position(x: Double(x), width: Double(width), duration: progress.duration)
        target = next
        controller.previewScrubbing(at: next)
        preview.request(at: next)
    }

    private func finish(resume: Bool = true) {
        guard let target else { return }
        if resume { controller.endScrubbing(at: target) }
        else { controller.finishScrubbing(resume: false) }
        self.target = nil
        preview.cancel()
        onEditingChanged(false)
    }
}

private struct MobileSeekThumbnail: View {
    let frame: MobileSeekPreviewFrame?
    let index: Int?
    let seconds: Double
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let frame, frame.index == index {
                    Image(uiImage: UIImage(cgImage: frame.image)).resizable().scaledToFit()
                }
            }.frame(height: 90).clipped()
            Text(MobilePlaybackProgress.timecode(seconds)).font(.inter(.caption2, .semibold).monospacedDigit())
                .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 22).background(Color.black)
        }.clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .accessibilityHidden(true)
    }
}
