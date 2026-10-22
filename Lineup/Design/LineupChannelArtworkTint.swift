import SwiftUI
import UIKit

/// A dark brand-color wash sampled from the channel's cached logo. Both TV
/// Guide layouts use the same subdued treatment as the iPhone channel rows.
struct LineupChannelArtworkTint: View {
    let url: URL?
    let width: CGFloat
    let fallback: Color

    @State private var resolved: ResolvedTint?

    private var pixelSize: Int { LineupArt.pixels(for: width) }
    private var requestKey: String { "\(url?.absoluteString ?? "no-logo")|\(pixelSize)" }

    var body: some View {
        Rectangle()
            .fill(displayColor)
            .task(id: requestKey) {
                guard let url else {
                    resolved = ResolvedTint(key: requestKey, value: nil)
                    return
                }
                let key = requestKey
                let tint = await LineupChannelTintCache.shared.tint(for: url, pixels: pixelSize)
                guard !Task.isCancelled else { return }
                resolved = ResolvedTint(key: key, value: tint)
            }
    }

    private var displayColor: Color {
        guard let resolved, resolved.key == requestKey, let value = resolved.value else { return fallback }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    private struct ResolvedTint {
        let key: String
        let value: UInt32?
    }
}

/// Decodes only through LineupArt's downscaled cache and bounds the number of
/// retained colors. Scrolling the Guide never samples full-size artwork.
private actor LineupChannelTintCache {
    static let shared = LineupChannelTintCache()

    private var colors: [String: UInt32] = [:]
    private var insertionOrder: [String] = []
    private var tasks: [String: Task<UInt32?, Never>] = [:]

    func tint(for url: URL, pixels: Int) async -> UInt32? {
        let key = "\(url.absoluteString)|\(pixels)"
        if let color = colors[key] { return color }

        let task: Task<UInt32?, Never>
        if let existing = tasks[key] {
            task = existing
        } else {
            let started = Task.detached(priority: .utility) { () -> UInt32? in
                guard let image = await LineupArt.load(url, pixels: pixels) else { return nil }
                return LineupChannelTintSampler.sample(image)
            }
            tasks[key] = started
            task = started
        }

        let color = await task.value
        tasks[key] = nil
        guard let color else { return nil }
        if colors[key] == nil {
            colors[key] = color
            insertionOrder.append(key)
        }
        if insertionOrder.count > 512 {
            let expired = insertionOrder.removeFirst()
            colors[expired] = nil
        }
        return color
    }
}

/// Finds the logo's dominant saturated hue while ignoring transparent padding
/// and white lettering, then turns it into a consistent near-black row fill.
private enum LineupChannelTintSampler {
    private static let side = 24
    private static let hueBins = 32

    static func sample(_ image: UIImage) -> UInt32? {
        guard let source = image.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else {
                return false
            }
            context.interpolationQuality = .low
            let scale = min(CGFloat(side) / CGFloat(source.width), CGFloat(side) / CGFloat(source.height))
            let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
            context.draw(source, in: CGRect(x: (CGFloat(side) - size.width) / 2,
                                            y: (CGFloat(side) - size.height) / 2,
                                            width: size.width, height: size.height))
            return true
        }
        guard rendered else { return nil }

        var weights = [Double](repeating: 0, count: hueBins)
        var hueSin = [Double](repeating: 0, count: hueBins)
        var hueCos = [Double](repeating: 0, count: hueBins)
        var saturations = [Double](repeating: 0, count: hueBins)

        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Double(rgba[offset + 3]) / 255
            guard alpha >= 0.28 else { continue }
            let red = min(1, Double(rgba[offset]) / 255 / alpha)
            let green = min(1, Double(rgba[offset + 1]) / 255 / alpha)
            let blue = min(1, Double(rgba[offset + 2]) / 255 / alpha)
            let high = max(red, green, blue)
            let low = min(red, green, blue)
            let delta = high - low
            guard high > 0.08, high < 0.97, delta > 0 else { continue }
            let saturation = delta / high
            guard saturation >= 0.20 else { continue }

            let hue: Double
            if high == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
            } else if high == green {
                hue = ((blue - red) / delta + 2) / 6
            } else {
                hue = ((red - green) / delta + 4) / 6
            }
            let normalizedHue = hue < 0 ? hue + 1 : hue
            let bin = min(hueBins - 1, Int(normalizedHue * Double(hueBins)))
            let weight = alpha * saturation
            weights[bin] += weight
            hueSin[bin] += sin(normalizedHue * 2 * .pi) * weight
            hueCos[bin] += cos(normalizedHue * 2 * .pi) * weight
            saturations[bin] += saturation * weight
        }

        guard let dominant = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[dominant] > 0 else { return 0x242425 }
        var hue = atan2(hueSin[dominant], hueCos[dominant]) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let sourceSaturation = saturations[dominant] / weights[dominant]
        let saturation = min(0.46, max(0.28, sourceSaturation * 0.52))
        return rgb(hue: hue, saturation: saturation, brightness: 0.14)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> UInt32 {
        let sector = hue * 6
        let chroma = brightness * saturation
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let offset = brightness - chroma
        let components: (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: components = (chroma, secondary, 0)
        case 1: components = (secondary, chroma, 0)
        case 2: components = (0, chroma, secondary)
        case 3: components = (0, secondary, chroma)
        case 4: components = (secondary, 0, chroma)
        default: components = (chroma, 0, secondary)
        }
        let red = UInt32(((components.0 + offset) * 255).rounded())
        let green = UInt32(((components.1 + offset) * 255).rounded())
        let blue = UInt32(((components.2 + offset) * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }
}
