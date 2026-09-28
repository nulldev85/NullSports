import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// A color with its own light- and dark-mode values.
    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }
}

extension Color {
    /// A color with its own light- and dark-mode values.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: .dynamic(light: light, dark: dark))
    }
}

struct AccentOption: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
}

/// Forge's palette: calm mineral neutrals, a sage accent and a handful of
/// muted hues. Every color adapts to light and dark mode; the light values
/// are deep enough for white text, the dark values light enough for ink.
enum Theme {
    // MARK: Neutrals

    /// Screen background behind cards and lists.
    static let canvas = Color(light: 0xF2F3EF, dark: 0x0D1012)
    /// Cards. Matches list rows so custom cards and lists read as one surface.
    static let surface = Color(.secondarySystemGroupedBackground)
    /// Input wells, chips and other recessed fills.
    static let fill = Color(light: 0xE9ECE7, dark: 0x252B2F)
    /// Hairlines and chart grid lines.
    static let line = Color(light: 0xDDE1DB, dark: 0x2C3337)
    /// Primary text; secondary text derives from it.
    static let inkUIColor = UIColor.dynamic(light: 0x15191B, dark: 0xE7ECEA)
    static let ink = Color(uiColor: inkUIColor)
    /// Text and symbols drawn on an accent fill.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x0D1012)
    /// The full-screen timer's backdrop, dark in either mode.
    static let night = Color(uiColor: UIColor(hex: 0x0A0D0F))

    // MARK: Hues

    static let sage = Color(light: 0x2F7D6D, dark: 0x7DD3BA)
    static let mist = Color(light: 0x3D6E9E, dark: 0x93B8E6)
    static let lavender = Color(light: 0x6A5DC4, dark: 0xB6ABF7)
    static let sky = Color(light: 0x1D7C92, dark: 0x86D0E2)
    static let moss = Color(light: 0x5C7E2C, dark: 0xBBD88C)
    static let sand = Color(light: 0x8A6D2B, dark: 0xE2C98C)
    static let rose = Color(light: 0xA84558, dark: 0xF2A0AF)
    static let slate = Color(light: 0x4F5D64, dark: 0xAEBAC0)

    // MARK: Meaning

    static let success = sage
    static let warning = sand
    static let danger = rose
    static let record = sand

    static let warmup = sand
    static let drop = lavender
    static let failure = rose

    static let prepare = sand
    static let work = sage
    static let rest = mist
    static let setRest = lavender

    // MARK: Accent

    static let defaultAccentID = "sage"

    static let accents: [AccentOption] = [
        AccentOption(id: "sage", name: "Sage", color: sage),
        AccentOption(id: "mist", name: "Mist", color: mist),
        AccentOption(id: "lavender", name: "Lavender", color: lavender),
        AccentOption(id: "sky", name: "Sky", color: sky),
        AccentOption(id: "moss", name: "Moss", color: moss),
        AccentOption(id: "sand", name: "Sand", color: sand),
        AccentOption(id: "rose", name: "Rose", color: rose),
        AccentOption(id: "slate", name: "Slate", color: slate),
    ]

    /// Colors saved by earlier versions, mapped to their calmer successors.
    private static let aliases: [String: String] = [
        "ember": "sage", "volt": "moss", "ocean": "mist", "crimson": "rose",
        "violet": "lavender", "mint": "sage", "gold": "sand",
    ]

    /// The current name for a stored color ID.
    static func canonicalID(_ id: String) -> String {
        aliases[id] ?? id
    }

    static func accentOption(_ id: String) -> AccentOption {
        let canonical = canonicalID(id)
        return accents.first { $0.id == canonical } ?? accents[0]
    }

    static func accent(named id: String) -> Color {
        accentOption(id).color
    }

    // MARK: Tags

    /// Colors for folders and routines (same family as the accents).
    static var tagColors: [AccentOption] { accents }

    static func tagColor(_ id: String?) -> Color? {
        guard let id else { return nil }
        let canonical = canonicalID(id)
        return tagColors.first { $0.id == canonical }?.color
    }

    // MARK: Lookups

    static func color(for phase: TimerPhase.Kind) -> Color {
        switch phase {
        case .prepare: return prepare
        case .work: return work
        case .rest: return rest
        case .setRest: return setRest
        }
    }

    static func color(for kind: SetKind) -> Color? {
        switch kind {
        case .normal: return nil
        case .warmup: return warmup
        case .drop: return drop
        case .failure: return failure
        }
    }

    static func color(for muscle: MuscleGroup) -> Color {
        switch muscle.region {
        case .push: return rose
        case .pull: return mist
        case .legs: return sage
        case .core: return sand
        case .other: return lavender
        }
    }

    static func symbol(for category: ExerciseCategory) -> String {
        switch category {
        case .strength: return "dumbbell.fill"
        case .cardio: return "figure.run"
        case .plyometric: return "figure.jumprope"
        case .olympic: return "figure.strengthtraining.traditional"
        case .strongman: return "figure.strengthtraining.functional"
        case .calisthenics: return "figure.gymnastics"
        case .mobility: return "figure.flexibility"
        case .sport: return "sportscourt.fill"
        }
    }
}

extension View {
    /// Card surface used across the app.
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The calm canvas behind lists and forms, instead of the system gray.
    func canvasBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.canvas)
    }
}
