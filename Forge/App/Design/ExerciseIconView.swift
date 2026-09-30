import SwiftUI
import UIKit

/// An exercise's picture on a small glossy tile, tinted by its main muscle:
/// its equipment, or for bodyweight work the movement itself.
struct ExerciseIconBadge: View {
    let exercise: Exercise
    var size: CGFloat = 40

    var body: some View {
        let color = Theme.color(for: exercise.primaryMuscle)
        ExerciseIconImage(icon: exercise.icon, size: size * 0.66)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background {
                // The same glossy tile as the app's icon badges.
                let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                shape
                    .fill(LinearGradient(colors: [color.opacity(0.20), color.opacity(0.09)], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(colors: [Theme.cardRim.opacity(0.9), Theme.cardRim.opacity(0)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75
                        )
                    )
            }
            .accessibilityHidden(true)
    }
}

/// The picture alone, `size` points square, in the foreground style.
struct ExerciseIconImage: View {
    let icon: ExerciseIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .glyph(let glyph):
            GlyphView(glyph: glyph)
                .frame(width: size, height: size)
        case .symbol(let names, let fallback):
            if let name = SystemSymbols.firstAvailable(names) {
                Image(systemName: name)
                    .font(.system(size: size * 0.78, weight: .medium))
                    .frame(width: size, height: size)
            } else {
                GlyphView(glyph: fallback)
                    .frame(width: size, height: size)
            }
        }
    }
}

/// Draws one of Forge's exercise pictograms (a 24-point grid scaled to fit).
struct GlyphView: View {
    let glyph: ExerciseGlyph

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let origin = CGPoint(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            func point(_ p: GlyphPoint) -> CGPoint {
                CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
            }
            func line(_ points: [GlyphPoint]) -> Path {
                var path = Path()
                path.addLines(points.map(point))
                return path
            }
            func shape(_ points: [GlyphPoint]) -> Path {
                var path = line(points)
                path.closeSubpath()
                return path
            }
            func disc(_ center: GlyphPoint, _ radius: Double) -> Path {
                let c = point(center)
                let r = radius * scale
                return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double) -> Path {
                let corner = point(GlyphPoint(x: x, y: y))
                return Path(
                    roundedRect: CGRect(x: corner.x, y: corner.y, width: width * scale, height: height * scale),
                    cornerRadius: radius * scale,
                    style: .circular
                )
            }
            func style(_ width: Double) -> StrokeStyle {
                StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round)
            }
            // "Clear" steps erase what's underneath, leaving the thin gaps
            // that separate a near limb from the body behind it.
            var eraser = context
            eraser.blendMode = .clear
            for op in glyph.ops {
                switch op {
                case .stroke(let points, let width):
                    context.stroke(line(points), with: .foreground, style: style(width))
                case .clearStroke(let points, let width):
                    eraser.stroke(line(points), with: .color(.black), style: style(width))
                case .fill(let points):
                    context.fill(shape(points), with: .foreground)
                case .clearFill(let points):
                    eraser.fill(shape(points), with: .color(.black))
                case .disc(let center, let radius):
                    context.fill(disc(center, radius), with: .foreground)
                case .clearDisc(let center, let radius):
                    eraser.fill(disc(center, radius), with: .color(.black))
                case .roundedRect(let x, let y, let width, let height, let radius):
                    context.fill(rect(x, y, width, height, radius), with: .foreground)
                case .clearRoundedRect(let x, let y, let width, let height, let radius):
                    eraser.fill(rect(x, y, width, height, radius), with: .color(.black))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Which system symbols this iOS version has (newer sport figures may be
/// missing on older versions), looked up once each.
@MainActor
enum SystemSymbols {
    private static var known: [String: Bool] = [:]

    static func firstAvailable(_ names: [String]) -> String? {
        names.first { name in
            if let found = known[name] { return found }
            let found = UIImage(systemName: name) != nil
            known[name] = found
            return found
        }
    }
}
