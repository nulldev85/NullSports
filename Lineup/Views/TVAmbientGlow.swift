import CoreImage
import SwiftUI

struct TVAmbientGlow: View {
    @ObservedObject var controller: TVPlaybackController
    @Environment(\.scenePhase) private var phase
    @AppStorage(LineupAmbientGlow.preferenceKey) private var enabled = true

    var body: some View {
        GeometryReader { geometry in
            if enabled, phase == .active, controller.isPlaying, controller.error == nil,
               let bands = TVAmbientBands(video: controller.ambientPictureSize,
                                          drawable: controller.surface.bounds.size, host: geometry.size) {
                Strips(controller: controller, bands: bands)
                    .id(controller.ambientGeneration)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Strips: View {
        let controller: TVPlaybackController
        let bands: TVAmbientBands
        @State private var colors: [Color] = []

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                if colors.count == 4 {
                    strip(bands.first, color: colors[bands.horizontal ? 0 : 2],
                          from: bands.horizontal ? .bottom : .trailing, to: bands.horizontal ? .top : .leading)
                    strip(bands.second, color: colors[bands.horizontal ? 1 : 3],
                          from: bands.horizontal ? .top : .leading, to: bands.horizontal ? .bottom : .trailing)
                }
            }
            .transaction { $0.animation = nil }
            .task {
                let reader = UUID()
                defer { controller.releaseFrameOutput(reader: reader) }
                while !Task.isCancelled {
                    if let frame = await controller.captureAmbientFrame(reader: reader), !Task.isCancelled {
                        let next = await TVAmbientColors.read(frame)
                        guard !Task.isCancelled else { return }
                        colors = next
                    }
                    do { try await Task.sleep(for: LineupAmbientGlow.interval) } catch { return }
                }
            }
        }

        private func strip(_ rect: CGRect, color: Color, from: UnitPoint, to: UnitPoint) -> some View {
            LinearGradient(colors: [color.opacity(0.62), .clear], startPoint: from, endPoint: to)
                .animation(.easeInOut(duration: 0.9), value: color)
                .frame(width: rect.width, height: rect.height)
                .clipped()
                .position(x: rect.midX, y: rect.midY)
        }
    }
}

private enum TVAmbientColors {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let rgb = CGColorSpaceCreateDeviceRGB()

    /// Only colours come from this sample. Darkness, credits and subtitles
    /// cannot move the rectangles. Core Image row zero is the bottom edge.
    static func read(_ frame: CapturedVideoFrame) async -> [Color] {
        await Task.detached(priority: .utility) {
            let source: CIImage
            switch frame {
            case .pixelBuffer(let buffer): source = CIImage(cvPixelBuffer: buffer)
            case .image(let image): source = CIImage(cgImage: image)
            }
            let extent = source.extent
            guard extent.width > 0, extent.height > 0 else { return [] as [Color] }
            let side = 8
            let bitmap = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / extent.width, y: CGFloat(side) / extent.height))
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            context.render(bitmap, toBitmap: &pixels, rowBytes: side * 4,
                           bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: rgb)
            func average(_ index: (Int) -> Int) -> Color {
                var red = 0, green = 0, blue = 0
                for n in 0..<side {
                    let i = index(n) * 4
                    red += Int(pixels[i])
                    green += Int(pixels[i + 1])
                    blue += Int(pixels[i + 2])
                }
                let divisor = Double(side * 255)
                return Color(red: Double(red) / divisor, green: Double(green) / divisor, blue: Double(blue) / divisor)
            }
            return [average { (side - 1) * side + $0 }, average { $0 },
                    average { $0 * side }, average { $0 * side + side - 1 }]
        }.value
    }
}
