import SwiftUI

struct AccentOption: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
}

enum Theme {
    static let accents: [AccentOption] = [
        AccentOption(id: "ember", name: "Ember", color: Color(red: 1.00, green: 0.42, blue: 0.16)),
        AccentOption(id: "volt", name: "Volt", color: Color(red: 0.72, green: 0.93, blue: 0.16)),
        AccentOption(id: "ocean", name: "Ocean", color: Color(red: 0.15, green: 0.56, blue: 1.00)),
        AccentOption(id: "crimson", name: "Crimson", color: Color(red: 0.93, green: 0.19, blue: 0.29)),
        AccentOption(id: "violet", name: "Violet", color: Color(red: 0.58, green: 0.36, blue: 0.98)),
        AccentOption(id: "mint", name: "Mint", color: Color(red: 0.16, green: 0.82, blue: 0.64)),
        AccentOption(id: "gold", name: "Gold", color: Color(red: 1.00, green: 0.76, blue: 0.16)),
        AccentOption(id: "rose", name: "Rose", color: Color(red: 1.00, green: 0.40, blue: 0.66)),
    ]

    static func accent(named id: String) -> Color {
        accents.first { $0.id == id }?.color ?? accents[0].color
    }

    /// Tags for routines and folders.
    static let tagColors: [(id: String, color: Color)] = accents.map { (id: $0.id, color: $0.color) }
        + [(id: "slate", color: Color(red: 0.55, green: 0.58, blue: 0.64))]

    static func tagColor(_ id: String?) -> Color? {
        guard let id else { return nil }
        return tagColors.first { $0.id == id }?.color
    }

    static let work = Color(red: 0.20, green: 0.80, blue: 0.40)
    static let rest = Color(red: 0.20, green: 0.55, blue: 1.00)
    static let prepare = Color(red: 1.00, green: 0.70, blue: 0.10)
    static let warmup = Color(red: 1.00, green: 0.70, blue: 0.10)
    static let drop = Color(red: 0.58, green: 0.36, blue: 0.98)
    static let failure = Color(red: 0.93, green: 0.19, blue: 0.29)
    static let record = Color(red: 1.00, green: 0.76, blue: 0.16)

    static func color(for phase: TimerPhase.Kind) -> Color {
        switch phase {
        case .prepare: return prepare
        case .work: return work
        case .rest, .setRest: return rest
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
        case .push: return Color(red: 1.00, green: 0.45, blue: 0.20)
        case .pull: return Color(red: 0.20, green: 0.58, blue: 1.00)
        case .legs: return Color(red: 0.25, green: 0.80, blue: 0.45)
        case .core: return Color(red: 0.95, green: 0.75, blue: 0.15)
        case .other: return Color(red: 0.62, green: 0.45, blue: 0.95)
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

extension Font {
    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension View {
    /// Card surface used across the app.
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
