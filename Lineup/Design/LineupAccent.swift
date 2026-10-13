import SwiftUI
import UIKit

/// The one colour the phone lets a viewer choose.
///
/// Everything else stays as it is -- the charcoal ground, the greys, the
/// white type. The accent is what marks the active tab, the chosen filter,
/// the bar beside the masthead, a switch that is on. Red, the colour of the
/// on-air dot, until something else is chosen.
struct LineupAccent: Identifiable, Equatable, Sendable {
    let name: String
    /// Six hex digits, upper case, no `#`.
    let hex: String
    var id: String { hex }

    static let storageKey = "lineup.appearance.accent"
    static let red = LineupAccent(name: "Red", hex: "FF3347")

    /// Ten around the wheel, spaced through the hues so each sits where its
    /// colour is on the ring.
    static let presets: [LineupAccent] = [
        .red,
        LineupAccent(name: "Orange", hex: "FF7A1A"),
        LineupAccent(name: "Gold", hex: "FFC21A"),
        LineupAccent(name: "Lime", hex: "9BE22D"),
        LineupAccent(name: "Green", hex: "2FD27A"),
        LineupAccent(name: "Teal", hex: "18C9C1"),
        LineupAccent(name: "Sky", hex: "2FA8FF"),
        LineupAccent(name: "Blue", hex: "4D6BFF"),
        LineupAccent(name: "Violet", hex: "9B5CFF"),
        LineupAccent(name: "Pink", hex: "FF4FA3")
    ]

    /// The accent stored on this device, Red until one is chosen.
    static var current: LineupAccent {
        accent(forHex: UserDefaults.standard.string(forKey: storageKey))
    }

    /// A preset by its colour, or a colour of the viewer's own.
    static func accent(forHex hex: String?) -> LineupAccent {
        guard let hex = normalized(hex) else { return .red }
        return presets.first { $0.hex == hex } ?? LineupAccent(name: "Custom", hex: hex)
    }

    /// "#ff3347", " FF3347 " and "FF3347" are one colour; anything that is
    /// not six hex digits is none.
    static func normalized(_ hex: String?) -> String? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    var isPreset: Bool { Self.presets.contains { $0.hex == hex } }

    var components: (red: Double, green: Double, blue: Double) {
        let value = UInt32(hex, radix: 16) ?? 0xFF3347
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    var color: Color {
        let c = components
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    /// The same colour, lighter, for a fill that covers area: at full
    /// strength a wash reads as the ground having changed colour.
    var soft: Color {
        let c = components
        return Color(red: c.red + (1 - c.red) * 0.45,
                     green: c.green + (1 - c.green) * 0.45,
                     blue: c.blue + (1 - c.blue) * 0.45)
    }

    /// How light it reads, from 0 to 1.
    var luminance: Double {
        let c = components
        return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
    }

    /// Type set on the accent: near-black on a light one, white on a dark.
    var onAccent: Color {
        luminance > 0.55 ? Color(red: 0.11, green: 0.11, blue: 0.12) : .white
    }

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let c = components
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (Double(hue), Double(saturation), Double(brightness))
    }

    static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(hue: CGFloat(hue.truncatingRemainder(dividingBy: 1)), saturation: CGFloat(saturation),
                brightness: CGFloat(brightness), alpha: 1)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
