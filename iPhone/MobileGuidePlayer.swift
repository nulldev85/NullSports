import SwiftUI

/// Both compact and expanded layouts keep this same VLC surface and controller.
/// Resizing must not open a second provider connection or restart the stream.
struct MobileGuidePlayer: View {
    @ObservedObject var controller: MobilePlaybackController
    let stream: XtreamStream
    let program: CurrentProgram?
    let expanded: Bool
    let showsMetadata: Bool
    let videoHeight: CGFloat
    let onClose: () -> Void
    let onExpand: () -> Void
    let onRetry: () -> Void
    @State private var controlsVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                MobileVideoSurface(controller: controller)
                    .contentShape(Rectangle())
                    .onTapGesture { controlsVisible.toggle() }
                    .accessibilityLabel("Video. Tap to show playback controls")
                if let error = controller.error {
                    VStack(spacing: 8) {
                        Text(error).font(.caption).multilineTextAlignment(.center)
                        Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }.padding(.horizontal, 52)
                } else if controller.loading {
                    ProgressView("Opening stream…").font(.caption)
                }
                if controlsVisible {
                    VStack {
                        HStack {
                            control("xmark", label: "Close player", action: onClose)
                            Spacer()
                            control(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                    label: expanded ? "Return to guide" : "Expand player", action: onExpand)
                        }
                        Spacer()
                        HStack {
                            Label(controller.isPlaying ? "LIVE" : "PAUSED", systemImage: "circle.fill")
                                .font(.caption2.bold()).padding(7)
                                .background(.black.opacity(0.65), in: Capsule())
                                .opacity(controller.loading || controller.error != nil ? 0 : 1)
                            Spacer()
                        }
                    }
                    .padding(.horizontal, expanded ? 36 : 8)
                    .padding(.vertical, expanded ? 28 : 8)
                    if !controller.loading && controller.error == nil {
                        control(controller.isPlaying ? "pause.fill" : "play.fill",
                                label: controller.isPlaying ? "Pause" : "Play", size: 56) { controller.toggle() }
                    }
                }
            }
            .frame(height: videoHeight).background(.black).clipped()
            if !expanded && showsMetadata {
                VStack(alignment: .leading, spacing: 7) {
                    Text(stream.name).font(.headline).lineLimit(1)
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(program?.title ?? "Live channel · No guide information")
                            .font(.caption.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(NullSportsStyle.raised, in: RoundedRectangle(cornerRadius: 16))
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .foregroundStyle(NullSportsStyle.lightPurple)
        .background(NullSportsStyle.background)
        .onChange(of: stream.id) { _, _ in controlsVisible = true }
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 44,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size == 56 ? 24 : 18, weight: .bold))
                .frame(width: size, height: size)
                .background(.black.opacity(0.65), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
