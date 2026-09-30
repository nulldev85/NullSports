import Charts
import SwiftUI

struct ProgressDashboardView: View {
    @Environment(AppModel.self) private var app
    @State private var period: Period = .twelveWeeks
    @State private var chartMetric: ChartMetric = .workouts
    /// Charts are laid out a moment after the tab first appears (in the
    /// space kept for them), so switching to it is instant.
    @State private var chartsReady = false

    enum Period: String, CaseIterable, Identifiable {
        case fourWeeks = "4W"
        case twelveWeeks = "12W"
        case sixMonths = "6M"
        case year = "1Y"
        case all = "All"

        var id: String { rawValue }

        var weeks: Int? {
            switch self {
            case .fourWeeks: return 4
            case .twelveWeeks: return 12
            case .sixMonths: return 26
            case .year: return 52
            case .all: return nil
            }
        }
    }

    enum ChartMetric: String, CaseIterable, Identifiable {
        case workouts = "Workouts"
        case duration = "Time"
        case volume = "Volume"
        case sets = "Sets"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            let calendar = app.settings.calendar
            let digest = app.history.digest
            let start = startDate(calendar: calendar)
            let totals = digest.totals(since: start)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .sensoryFeedback(.selection, trigger: period)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        StatTile(title: "Workouts", value: "\(totals.workouts)", detail: averagePerWeek(totals, start: start), symbol: "figure.strengthtraining.traditional")
                        StatTile(title: "Time", value: DurationFormat.compact(totals.duration), detail: totals.workouts > 0 ? "\(DurationFormat.compact(totals.duration / Double(totals.workouts))) avg" : nil, symbol: "clock")
                        StatTile(title: "Volume", value: app.settings.units.volume(totals.volume), symbol: "scalemass")
                        StatTile(title: "Streak", value: "\(digest.weekStreak()) wk", detail: "Weeks in a row", symbol: "flame.fill", tint: Theme.sand)
                    }

                    weeklyChart(digest: digest)
                    muscleSection(start: start, digest: digest)
                    recordsSection
                    bodySection
                }
                .padding(16)
                .animation(Motion.smooth, value: period)
                .animation(Motion.smooth, value: chartMetric)
            }
            .background { CanvasBackdrop() }
            .task {
                guard !chartsReady else { return }
                await Task.yield()
                withAnimation(Motion.gentle) { chartsReady = true }
            }
            .navigationTitle("Progress")
            .stallContext("Progress")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("openSettings")
                }
            }
        }
    }

    private func startDate(calendar: Calendar) -> Date? {
        guard let weeks = period.weeks else { return nil }
        let thisWeek = Stats.weekStart(of: Date(), calendar: calendar)
        return calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)
    }

    private func averagePerWeek(_ totals: PeriodTotals, start: Date?) -> String? {
        let weeks: Double
        if let start {
            weeks = max(1, Date().timeIntervalSince(start) / (7 * 86_400))
        } else if let first = app.history.digest.firstWorkoutDate {
            weeks = max(1, Date().timeIntervalSince(first) / (7 * 86_400))
        } else {
            return nil
        }
        return "\(NumberFormatting.string(Double(totals.workouts) / weeks, locale: .current, maxFractionDigits: 1, grouping: false)) per week"
    }

    // MARK: Weekly chart

    private func weeklyChart(digest: HistoryDigest) -> some View {
        let weeks = min(period.weeks ?? 26, 26)
        let buckets = digest.weekly(weeks: weeks)
        let goal = app.settings.value.weeklyGoal
        let units = app.settings.units
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Weekly")
                    .font(.app(.title3, .semibold))
                Spacer()
                Picker("Metric", selection: $chartMetric) {
                    ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if chartsReady {
                weeklyBars(buckets: buckets, weeks: weeks, goal: goal, units: units)
                    .transition(.opacity)
            } else {
                Color.clear.frame(height: 190)
            }
            Text(chartCaption(units: units))
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func weeklyBars(buckets: [WeekBucket], weeks: Int, goal: Int, units: UnitPreferences) -> some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Week", bucket.start, unit: .weekOfYear),
                    y: .value(chartMetric.rawValue, value(of: bucket, units: units))
                )
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .cornerRadius(6)
            }
            if chartMetric == .workouts, goal > 0 {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal \(goal)")
                            .font(.num(.caption2))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: weeks > 12 ? 4 : 2)) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.num(.caption2, .regular))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().font(.num(.caption2, .regular))
            }
        }
        .frame(height: 190)
    }

    private func value(of bucket: WeekBucket, units: UnitPreferences) -> Double {
        switch chartMetric {
        case .workouts: return Double(bucket.totals.workouts)
        case .duration: return bucket.totals.duration / 3600
        case .volume: return units.weight.fromKilograms(bucket.totals.volume)
        case .sets: return Double(bucket.totals.sets)
        }
    }

    private func chartCaption(units: UnitPreferences) -> String {
        switch chartMetric {
        case .workouts: return "Workouts per week"
        case .duration: return "Hours trained per week"
        case .volume: return "Volume (\(units.weight.symbol)) per week — weight × reps of working sets"
        case .sets: return "Working sets per week"
        }
    }

    // MARK: Muscles

    private func muscleSection(start: Date?, digest: HistoryDigest) -> some View {
        let shares = digest.muscleShares(since: start).prefix(10)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Muscles Trained")
                .font(.app(.title3, .semibold))
            if shares.isEmpty {
                Text("Log workouts to see which muscles you're training.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else if !chartsReady {
                Color.clear.frame(height: CGFloat(shares.count) * 28 + 10)
            } else {
                Chart(Array(shares)) { share in
                    BarMark(
                        x: .value("Sets", share.sets),
                        y: .value("Muscle", share.muscle.displayName)
                    )
                    .foregroundStyle(Theme.color(for: share.muscle).opacity(0.85))
                    .cornerRadius(6)
                    .annotation(position: .trailing) {
                        Text(NumberFormatting.string(share.sets, locale: .current, maxFractionDigits: 1, grouping: false))
                            .font(.num(.caption2))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel().font(.app(.caption, .medium))
                    }
                }
                .frame(height: CGFloat(shares.count) * 28 + 10)
                .transition(.opacity)
            }
            if !shares.isEmpty {
                Text("Working sets. Secondary muscles count as half a set.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    // MARK: Records

    private var recordsSection: some View {
        let recent = app.history.recentRecords.prefix(6)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Records")
                    .font(.app(.title3, .semibold))
                Spacer()
                NavigationLink("See All") {
                    AllRecordsView()
                }
                .font(.app(.subheadline, .semibold))
            }
            if recent.isEmpty {
                Text("Beat a previous best and it'll show up here.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(recent)) { record in
                RecordRow(record: record, tracking: app.library.exercise(record.exerciseID)?.tracking ?? .weightReps)
                Divider()
            }
        }
        .cardStyle()
    }

    // MARK: Body

    private var bodySection: some View {
        let weights = app.measurements.entries(.bodyWeight)
        return NavigationLink {
            MeasurementsView()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Body")
                        .font(.app(.title3, .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                if let latest = weights.last {
                    HStack(alignment: .firstTextBaseline) {
                        Text(app.settings.units.weight(latest.value))
                            .font(.num(size: 28, .semibold))
                            .foregroundStyle(.primary)
                        if let change = app.measurements.change(.bodyWeight) {
                            Text((change >= 0 ? "+" : "−") + app.settings.units.weight(abs(change)))
                                .font(.app(.subheadline, .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(latest.measuredAt.relativeDayText)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    if weights.count > 1, !chartsReady {
                        Color.clear.frame(height: 70)
                    } else if weights.count > 1 {
                        Chart(weights.suffix(30)) { entry in
                            LineMark(x: .value("Date", entry.measuredAt), y: .value("Weight", app.settings.units.weight.fromKilograms(entry.value)))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Color.accentColor)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartXAxis(.hidden)
                        .frame(height: 70)
                    }
                } else {
                    Text("Track body weight, body fat and measurements.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("measurementsLink")
    }
}

struct AllRecordsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let grouped = groupedRecords
        List {
            if grouped.isEmpty {
                ContentUnavailableView("No records yet", systemImage: "trophy", description: Text("Records are set when you beat a previous best."))
            }
            ForEach(grouped, id: \.exercise.id) { group in
                Section(group.exercise.name) {
                    ForEach(group.records) { record in
                        RecordRow(record: record, tracking: group.exercise.tracking, showsExercise: false)
                    }
                }
            }
        }
        .canvasBackground()
        .navigationTitle("Personal Records")
        .stallContext("Records")
    }

    private var groupedRecords: [(exercise: Exercise, records: [PersonalRecord])] {
        app.history.records.best.keys
            .compactMap { id -> (exercise: Exercise, records: [PersonalRecord])? in
                guard let exercise = app.library.exercise(id) else { return nil }
                let records = app.history.records.records(for: id)
                return records.isEmpty ? nil : (exercise: exercise, records: records)
            }
            .sorted { $0.exercise.name < $1.exercise.name }
    }
}
