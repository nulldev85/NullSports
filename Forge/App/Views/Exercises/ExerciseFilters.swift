import SwiftUI

enum LibraryScope: String, CaseIterable, Identifiable {
    case all = "All"
    case recent = "Recent"
    case favorites = "Favorites"
    case custom = "Custom"

    var id: String { rawValue }
}

/// Horizontal row of filter menus (muscle, equipment, type).
struct ExerciseFilterBar: View {
    @Binding var filter: ExerciseSearchIndex.Filter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterMenu(
                    title: filter.muscles.isEmpty ? "Muscle" : summary(filter.muscles.map(\.displayName)),
                    active: !filter.muscles.isEmpty
                ) {
                    Button("Any Muscle") { filter.muscles = [] }
                    Divider()
                    ForEach(MuscleGroup.allCases.filter { $0 != .other }) { muscle in
                        toggleButton(muscle.displayName, isOn: filter.muscles.contains(muscle)) {
                            toggle(&filter.muscles, muscle)
                        }
                    }
                }
                filterMenu(
                    title: filter.equipment.isEmpty ? "Equipment" : summary(filter.equipment.map(\.displayName)),
                    active: !filter.equipment.isEmpty
                ) {
                    Button("Any Equipment") { filter.equipment = [] }
                    Divider()
                    ForEach(Equipment.allCases) { equipment in
                        toggleButton(equipment.displayName, isOn: filter.equipment.contains(equipment)) {
                            toggle(&filter.equipment, equipment)
                        }
                    }
                }
                filterMenu(
                    title: filter.categories.isEmpty ? "Type" : summary(filter.categories.map(\.displayName)),
                    active: !filter.categories.isEmpty
                ) {
                    Button("Any Type") { filter.categories = [] }
                    Divider()
                    ForEach(ExerciseCategory.allCases) { category in
                        toggleButton(category.displayName, isOn: filter.categories.contains(category)) {
                            toggle(&filter.categories, category)
                        }
                    }
                }
                if !filter.isEmpty {
                    Button {
                        filter = ExerciseSearchIndex.Filter()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.app(.subheadline, .medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .animation(Motion.snappy, value: filter)
        }
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func summary(_ names: [String]) -> String {
        let sorted = names.sorted()
        return sorted.count > 1 ? "\(sorted[0]) +\(sorted.count - 1)" : (sorted.first ?? "")
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    private func toggleButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func filterMenu<Content: View>(title: String, active: Bool, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.app(.caption2, .semibold))
            }
            .font(.app(.subheadline, .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Theme.onAccent : Color.primary)
            .background(Capsule().fill(active ? Color.accentColor : Theme.fill))
        }
        .menuActionDismissBehavior(.disabled)
    }
}

struct ExerciseRowLabel: View {
    let exercise: Exercise
    var isFavorite = false
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: Theme.symbol(for: exercise.category), color: Theme.color(for: exercise.primaryMuscle), size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(exercise.name)
                        .font(.app(.body, .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if exercise.isCustom {
                        Pill(text: "Custom", color: .accentColor)
                    }
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.app(.caption))
                            .foregroundStyle(Theme.sand)
                    }
                }
                Text(detail ?? "\(exercise.primaryMuscle.displayName) · \(exercise.equipment.displayName)")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
