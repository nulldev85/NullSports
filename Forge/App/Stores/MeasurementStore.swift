import SwiftUI

@MainActor
@Observable
final class MeasurementStore {
    private(set) var all: [BodyMeasurement] = []
    /// Entries per kind, oldest first; rebuilt on each load rather than
    /// filtered and sorted on every redraw.
    private var byKind: [MeasurementKind: [BodyMeasurement]] = [:]

    private let database: AppDatabase
    private let feedback: Feedback
    /// Called after measurements change on disk.
    @ObservationIgnored var onChange: (() -> Void)?

    init(database: AppDatabase, feedback: Feedback) {
        self.database = database
        self.feedback = feedback
        reload()
    }

    func reload() {
        do {
            let loaded = try database.measurements.all()
            byKind = Self.group(loaded)
            all = loaded
        } catch {
            feedback.report(error, while: "load your measurements")
        }
        onChange?()
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
        do {
            try database.measurements.save(measurement)
            reload()
        } catch {
            feedback.report(error, while: "save the measurement")
        }
    }

    func delete(_ id: UUID) {
        let removed = all.first { $0.id == id }
        do {
            try database.measurements.delete(id: id)
            reload()
            if let removed {
                feedback.show("Entry deleted", style: .info, action: ToastAction(title: "Undo") { [weak self] in
                    withAnimation(Motion.smooth) { self?.save(removed) }
                })
            }
        } catch {
            feedback.report(error, while: "delete the measurement")
        }
    }
}
