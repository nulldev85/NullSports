import Foundation

/// Makes sure no workout is ever left stranded "in progress".
///
/// Only one workout can be open at a time. If the database holds more than
/// one (an earlier workout that was never finished or discarded — say the
/// app was closed while it failed to reopen), only the newest could ever be
/// shown and the others would silently vanish from sight. Instead they are
/// finished on the spot: anything with input is saved to History, keeping
/// every set that has numbers in it; truly empty ones are removed.
public enum UnfinishedWorkouts {
    public struct Outcome: Sendable {
        /// The workout to reopen, if any.
        public var active: Workout?
        /// Earlier unfinished workouts that were saved to History.
        public var recovered: [Workout]
        /// Empty unfinished workouts that were removed.
        public var removedEmpty: Int
    }

    public static func resolve(in database: AppDatabase) throws -> Outcome {
        let unfinished = try database.workouts.activeWorkouts()
        guard let newest = unfinished.first else {
            return Outcome(active: nil, recovered: [], removedEmpty: 0)
        }
        var recovered: [Workout] = []
        var removed = 0
        for stranded in unfinished.dropFirst() {
            if stranded.hasUserInput {
                // It ended when it was last touched, not now.
                let endedAt = max(stranded.startedAt, stranded.updatedAt)
                let finished = WorkoutFactory.finalize(stranded, completeRemaining: false, keepEnteredSets: true, now: endedAt)
                try database.workouts.save(finished)
                recovered.append(finished)
            } else {
                try database.workouts.purge(workoutID: stranded.id)
                removed += 1
            }
        }
        return Outcome(active: newest, recovered: recovered, removedEmpty: removed)
    }
}
