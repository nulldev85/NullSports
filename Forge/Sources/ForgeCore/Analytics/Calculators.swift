import Foundation

public enum OneRepMax {
    /// Epley estimate; reliable up to about 12 reps.
    public static func epley(weight: Double, reps: Int) -> Double {
        guard reps > 0 else { return 0 }
        if reps == 1 { return weight }
        return weight * (1 + Double(reps) / 30)
    }

    public static func brzycki(weight: Double, reps: Int) -> Double {
        guard reps > 0, reps < 37 else { return 0 }
        if reps == 1 { return weight }
        return weight * 36 / Double(37 - reps)
    }

    /// Estimated 1RM, or nil when the set can't support an estimate.
    public static func estimate(weight: Double, reps: Int) -> Double? {
        guard weight > 0, reps >= 1, reps <= 12 else { return nil }
        return epley(weight: weight, reps: reps)
    }

    /// Weight you could expect to lift for `reps` given a 1RM (inverse Epley).
    public static func weight(forReps reps: Int, oneRepMax: Double) -> Double {
        guard reps > 1 else { return oneRepMax }
        return oneRepMax / (1 + Double(reps) / 30)
    }

    public struct Row: Hashable, Sendable {
        public var percent: Int
        public var weight: Double
        public var reps: Int
    }

    /// Typical percentage chart (100% … 50%).
    public static func table(oneRepMax: Double) -> [Row] {
        let chart: [(Int, Int)] = [(100, 1), (95, 2), (93, 3), (90, 4), (87, 5), (85, 6), (83, 7), (80, 8), (77, 9), (75, 10), (70, 12), (65, 15), (60, 20), (55, 25), (50, 30)]
        return chart.map { Row(percent: $0.0, weight: oneRepMax * Double($0.0) / 100, reps: $0.1) }
    }
}

public struct PlateLoad: Hashable, Sendable {
    /// Plates for one side, heaviest first.
    public var perSide: [Double]
    public var bar: Double
    /// Total that the loaded bar actually weighs.
    public var achieved: Double
    /// target − achieved (0 when exact).
    public var remainder: Double

    public var isExact: Bool { abs(remainder) < 0.001 }
}

public enum PlateCalculator {
    /// Finds the heaviest loading that doesn't exceed `target`, using the
    /// fewest plates, limited by the plates actually available.
    public static func load(target: Double, bar: Double, inventory: [PlateStock]) -> PlateLoad {
        let perSideTarget = (target - bar) / 2
        guard perSideTarget > 0.0001 else {
            return PlateLoad(perSide: [], bar: bar, achieved: bar, remainder: max(0, target - bar))
        }
        let scale = 100.0
        // A tiny epsilon keeps values like 57.5 × 100 = 5749.999… from
        // rounding down a whole unit.
        let goal = Int((perSideTarget * scale + 1e-6).rounded(.down))
        var items: [Int] = []
        for stock in inventory.sorted(by: { $0.weight > $1.weight }) where stock.weight > 0 && stock.pairs > 0 {
            let units = Int((stock.weight * scale).rounded())
            guard units > 0, units <= goal else { continue }
            items.append(contentsOf: Array(repeating: units, count: min(stock.pairs, goal / units)))
        }
        guard goal > 0, !items.isEmpty else {
            return PlateLoad(perSide: [], bar: bar, achieved: bar, remainder: target - bar)
        }
        // best[s] = fewest plates summing exactly to s using the items so far.
        let unreachable = Int.max
        var best = [Int](repeating: unreachable, count: goal + 1)
        best[0] = 0
        var chosen = [[Bool]](repeating: [Bool](repeating: false, count: goal + 1), count: items.count)
        for (index, weight) in items.enumerated() {
            if weight > goal { continue }
            var sum = goal
            while sum >= weight {
                let previous = best[sum - weight]
                if previous != unreachable, previous + 1 < best[sum] {
                    best[sum] = previous + 1
                    chosen[index][sum] = true
                }
                sum -= 1
            }
        }
        var reach = goal
        while reach > 0, best[reach] == unreachable { reach -= 1 }

        // Prefer the conventional heaviest-first loading whenever it reaches
        // the best achievable total; fall back to the exact search otherwise.
        var greedy: [Int] = []
        var greedySum = 0
        for weight in items where greedySum + weight <= goal {
            greedy.append(weight)
            greedySum += weight
        }
        if greedySum == reach {
            let plates = greedy.map { Double($0) / scale }
            let achieved = bar + 2 * plates.reduce(0, +)
            return PlateLoad(perSide: plates, bar: bar, achieved: achieved, remainder: max(0, target - achieved))
        }

        var plates: [Double] = []
        var remaining = reach
        var index = items.count - 1
        while remaining > 0, index >= 0 {
            if chosen[index][remaining] {
                plates.append(Double(items[index]) / scale)
                remaining -= items[index]
            }
            index -= 1
        }
        plates.sort(by: >)
        let achieved = bar + 2 * plates.reduce(0, +)
        return PlateLoad(perSide: plates, bar: bar, achieved: achieved, remainder: max(0, target - achieved))
    }
}

public enum WarmupCalculator {
    public struct Step: Hashable, Sendable {
        public var weight: Double
        public var reps: Int
    }

    /// Classic ramp: empty bar ×10, 40% ×5, 60% ×3, 80% ×2 (rounded to the
    /// loading increment, skipping steps that don't add anything).
    public static func steps(workingWeight: Double, bar: Double, increment: Double) -> [Step] {
        guard workingWeight > bar + increment else { return [] }
        let ramp: [(Double, Int)] = [(0.4, 5), (0.6, 3), (0.8, 2)]
        var steps = [Step(weight: bar, reps: 10)]
        for (fraction, reps) in ramp {
            let raw = workingWeight * fraction
            let rounded = max(bar, (raw / increment).rounded() * increment)
            if rounded > (steps.last?.weight ?? 0), rounded < workingWeight {
                steps.append(Step(weight: rounded, reps: reps))
            }
        }
        return steps
    }
}
