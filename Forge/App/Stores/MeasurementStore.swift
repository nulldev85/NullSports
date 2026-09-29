import SwiftUI

/// Body weight and other measurements. Changes show immediately and are
/// saved in the background.
@MainActor
@Observable
final class MeasurementStore {
    private(set) var all: [BodyMeasurement] = []
    /// Entries per kind, oldest first; rebuilt on each change rather than
    /// filtered and sorted on every redraw.
    private var byKind: [MeasurementKind: [BodyMeasurement]] = [:]

    private let database: AppDatabase
    private let feedback: Feedback
    /// Called after measurements change.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var reloadGeneration = 0

    nonisolated static func load(from database: AppDatabase) -> [BodyMeasurement] {
        (try? database.measurements.all()) ?? []
    }

    init(database: AppDatabase, feedback: Feedback, loaded: [BodyMeasurement]) {
        self.database = database
        self.feedback = feedback
        set(loaded)
    }

    private func set(_ entries: [BodyMeasurement]) {
        byKind = Self.group(entries)
        all = entries.sorted { $0.measuredAt < $1.measuredAt }
    }

    /// After a restore or import replaced the data, or a save failed.
    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let database = database
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(from: database) }.value
            guard generation == reloadGeneration else { return }
            withAnimation(Motion.smooth) { set(loaded) }
            onChange?()
        }
    }

    private static func group(_ entries: [BodyMeasurement]) -> [MeasurementKind: [BodyMeasurement]] {
        Dictionary(grouping: entries, by: \.kind).mapValues { list in
            list.sorted { $0.measuredAt < $1.measuredAt }
        }
    }

    func entries(_ kind: MeasurementKind) -> [BodyMeasurement] {
        byKind[kind] ?? []
    }

    func latest(_ kind: MeasurementKind) -> BodyMeasurement? {
        byKind[kind]?.last
    }

    /// Change from the previous entry to the latest.
    func change(_ kind: MeasurementKind) -> Double? {
        let list = entries(kind)
        guard list.count >= 2 else { return nil }
        return list[list.count - 1].value - list[list.count - 2].value
    }

    var trackedKinds: [MeasurementKind] {
        MeasurementKind.allCases.filter { byKind[$0] != nil }
    }

    func save(_ measurement: BodyMeasurement) {
        var entries = all.filter { $0.id != measurement.id }
        entries.append(measurement)
        set(entries)
        onChange?()
        database.writeInBackground({ try $0.measurements.save(measurement) }) { [weak self] result in
            if case .failure(let error) = result {
                self?.feedback.report(error, while: "save the measurement")
                self?.reload()
            }
        }
    }

    func delete(_ id: UUID) {
        guard let removed = all.first(where: { $0.id == id }) else { return }
        set(all.filter { $0.id != id })
        onChange?()
        feedback.show("Entry deleted", style: .info, action: ToastAction(title: "Undo") { [weak self] in
            withAnimation(Motion.smooth) { self?.save(removed) }
        })
        database.writeInBackground({ try $0.measurements.delete(id: id) }) { [weak self] result in
            if case .failure(let error) = result {
                self?.feedback.report(error, while: "delete the measurement")
                self?.reload()
            }
        }
    }
}
