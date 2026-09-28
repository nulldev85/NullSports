import Foundation

/// The built-in exercise library, shipped as JSON in the app bundle.
/// Identifiers are permanent: history and routines refer to them forever.
public struct ExerciseCatalog: Sendable {
    public let version: Int
    public let exercises: [Exercise]

    public init(version: Int, exercises: [Exercise]) {
        self.version = version
        self.exercises = exercises
    }

    struct Entry: Decodable {
        var id: String
        var name: String
        var primary: MuscleGroup
        var secondary: [MuscleGroup]?
        var equipment: Equipment
        var category: ExerciseCategory?
        var tracking: TrackingType?
        var aliases: [String]?
        var instructions: String?
    }

    struct File: Decodable {
        var version: Int
        var exercises: [Entry]
    }

    public static func load(from data: Data) throws -> ExerciseCatalog {
        let file = try JSONDecoder().decode(File.self, from: data)
        let exercises = file.exercises.map { entry in
            Exercise(
                id: entry.id,
                name: entry.name,
                primaryMuscle: entry.primary,
                secondaryMuscles: entry.secondary ?? [],
                equipment: entry.equipment,
                category: entry.category ?? .strength,
                tracking: entry.tracking ?? .weightReps,
                aliases: entry.aliases ?? [],
                instructions: entry.instructions ?? "",
                isCustom: false
            )
        }
        return ExerciseCatalog(version: file.version, exercises: exercises)
    }

    public static func load(contentsOf url: URL) throws -> ExerciseCatalog {
        try load(from: Data(contentsOf: url))
    }
}

/// Fast, forgiving search: case/diacritic-insensitive, ignores punctuation
/// ("pushup" finds "Push-Up"), matches aliases ("RDL", "OHP"), muscles and
/// equipment, and ranks name-prefix matches first.
public struct ExerciseSearchIndex: Sendable {
    struct Item: Sendable {
        var exercise: Exercise
        var nameKey: String
        var nameCompact: String
        var nameWords: [String]
        var aliasKeys: [String]
        var aliasCompacts: [String]
        var extraKeys: String
    }

    private let items: [Item]

    public init(exercises: [Exercise]) {
        items = exercises.map { exercise in
            let nameKey = Self.normalize(exercise.name)
            let aliasKeys = exercise.aliases.map(Self.normalize)
            let extras = ([exercise.primaryMuscle.displayName, exercise.equipment.displayName, exercise.category.displayName]
                + exercise.secondaryMuscles.map(\.displayName)).map(Self.normalize).joined(separator: " ")
            return Item(
                exercise: exercise,
                nameKey: nameKey,
                nameCompact: nameKey.replacingOccurrences(of: " ", with: ""),
                nameWords: nameKey.split(separator: " ").map(String.init),
                aliasKeys: aliasKeys,
                aliasCompacts: aliasKeys.map { $0.replacingOccurrences(of: " ", with: "") },
                extraKeys: extras
            )
        }
    }

    public var exercises: [Exercise] { items.map(\.exercise) }

    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var output = ""
        output.reserveCapacity(folded.count)
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                output.append(" ")
                lastWasSpace = true
            }
        }
        if output.hasSuffix(" ") { output.removeLast() }
        return output.lowercased()
    }

    public struct Filter: Hashable, Sendable {
        public var muscles: Set<MuscleGroup> = []
        public var equipment: Set<Equipment> = []
        public var categories: Set<ExerciseCategory> = []

        public init(muscles: Set<MuscleGroup> = [], equipment: Set<Equipment> = [], categories: Set<ExerciseCategory> = []) {
            self.muscles = muscles
            self.equipment = equipment
            self.categories = categories
        }

        public var isEmpty: Bool { muscles.isEmpty && equipment.isEmpty && categories.isEmpty }

        func matches(_ exercise: Exercise) -> Bool {
            if !muscles.isEmpty, !muscles.contains(exercise.primaryMuscle), muscles.isDisjoint(with: exercise.secondaryMuscles) {
                return false
            }
            if !equipment.isEmpty, !equipment.contains(exercise.equipment) { return false }
            if !categories.isEmpty, !categories.contains(exercise.category) { return false }
            return true
        }
    }

    /// Matching exercises, best matches first. With an empty query the
    /// original (alphabetical) order is kept.
    public func search(_ query: String, filter: Filter = Filter()) -> [Exercise] {
        let normalizedQuery = Self.normalize(query)
        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")

        var scored: [(score: Int, length: Int, name: String, exercise: Exercise)] = []
        for item in items where filter.matches(item.exercise) {
            if tokens.isEmpty {
                scored.append((0, 0, item.nameKey, item.exercise))
                continue
            }
            var allMatch = true
            for token in tokens {
                let found = item.nameKey.contains(token)
                    || item.nameCompact.contains(token)
                    || item.aliasKeys.contains(where: { $0.contains(token) })
                    || item.aliasCompacts.contains(where: { $0.contains(token) })
                    || item.extraKeys.contains(token)
                if !found {
                    allMatch = false
                    break
                }
            }
            if !allMatch {
                // Last chance: the whole query typed without spaces.
                guard compactQuery.count >= 3,
                      item.nameCompact.contains(compactQuery) || item.aliasCompacts.contains(where: { $0.contains(compactQuery) })
                else { continue }
            }
            let score: Int
            if item.nameKey.hasPrefix(normalizedQuery) || item.nameCompact.hasPrefix(compactQuery) {
                score = 0
            } else if item.aliasKeys.contains(where: { $0 == normalizedQuery }) || item.aliasCompacts.contains(where: { $0 == compactQuery }) {
                score = 1
            } else if let first = tokens.first, item.nameWords.contains(where: { $0.hasPrefix(first) }) {
                score = 2
            } else if item.aliasKeys.contains(where: { $0.hasPrefix(normalizedQuery) }) {
                score = 3
            } else if item.nameKey.contains(normalizedQuery) {
                score = 4
            } else {
                score = 5
            }
            scored.append((score, item.nameKey.count, item.nameKey, item.exercise))
        }
        if tokens.isEmpty {
            return scored.map(\.exercise)
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return lhs.name < rhs.name
        }
        return scored.map(\.exercise)
    }
}
