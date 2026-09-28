import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var month = Date()
    @State private var selectedDay: Date?
    @State private var showingCalendar = true
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let calendar = app.settings.calendar
            let filtered = filteredSummaries(calendar: calendar)
            List {
                if showingCalendar, query.isEmpty {
                    Section {
                        MonthCalendar(month: $month, selectedDay: $selectedDay, workoutDays: Stats.workoutDays(app.history.summaries, calendar: calendar), calendar: calendar)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    } footer: {
                        HistoryMonthFooter(month: month, summaries: app.history.summaries, calendar: calendar)
                    }
                }

                if app.history.summaries.isEmpty {
                    Section {
                        ContentUnavailableView("No workouts yet", systemImage: "calendar.badge.plus", description: Text("Finished workouts and timer sessions show up here with every set, rep and minute."))
                    }
                } else if filtered.isEmpty {
                    Section {
                        Text(selectedDay != nil ? "No workouts on this day." : "No workouts match “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(groupByMonth(filtered, calendar: calendar), id: \.start) { group in
                        Section {
                            ForEach(group.items) { summary in
                                NavigationLink {
                                    WorkoutDetailView(workoutID: summary.id)
                                } label: {
                                    WorkoutSummaryRow(summary: summary, prCount: app.history.records.prCount(in: summary.id))
                                }
                                .accessibilityIdentifier("historyWorkout")
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        app.history.delete(summary.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("History")
            .searchable(text: $query, prompt: "Search workouts, exercises, notes")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selectedDay != nil {
                        Button("Show All") { selectedDay = nil }
                    }
                    Button {
                        withAnimation { showingCalendar.toggle() }
                    } label: {
                        Image(systemName: showingCalendar ? "calendar.circle.fill" : "calendar.circle")
                    }
                    .accessibilityLabel("Toggle calendar")
                }
            }
        }
    }

    private func filteredSummaries(calendar: Calendar) -> [WorkoutSummary] {
        var items = app.history.summaries
        if let day = selectedDay {
            items = items.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
        }
        let key = ExerciseSearchIndex.normalize(query)
        if !key.isEmpty {
            items = items.filter { summary in
                ExerciseSearchIndex.normalize(summary.name).contains(key)
                    || ExerciseSearchIndex.normalize(summary.notes).contains(key)
                    || summary.exerciseNames.contains { ExerciseSearchIndex.normalize($0).contains(key) }
                    || summary.timerSummaries.contains { ExerciseSearchIndex.normalize($0).contains(key) }
            }
        }
        return items
    }

    private struct MonthGroup {
        let start: Date
        let title: String
        let items: [WorkoutSummary]
    }

    private func groupByMonth(_ items: [WorkoutSummary], calendar: Calendar) -> [MonthGroup] {
        var groups: [Date: [WorkoutSummary]] = [:]
        for item in items {
            let start = calendar.dateInterval(of: .month, for: item.startedAt)?.start ?? item.startedAt
            groups[start, default: []].append(item)
        }
        return groups.keys.sorted(by: >).map { start in
            let items = groups[start] ?? []
            let title = start.formatted(.dateTime.month(.wide).year())
            return MonthGroup(start: start, title: "\(title) · \(items.count) \(items.count == 1 ? "workout" : "workouts")", items: items)
        }
    }
}

struct HistoryMonthFooter: View {
    let month: Date
    let summaries: [WorkoutSummary]
    let calendar: Calendar
    @Environment(AppModel.self) private var app

    var body: some View {
        let interval = calendar.dateInterval(of: .month, for: month)
        let totals = Stats.totals(summaries, from: interval?.start, to: interval?.end)
        if totals.workouts > 0 {
            Text("\(totals.workouts) workouts · \(DurationFormat.compact(totals.duration)) · \(app.settings.units.volume(totals.volume))")
        }
    }
}

struct WorkoutSummaryRow: View {
    let summary: WorkoutSummary
    var prCount = 0
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if summary.kind == .timer {
                    Image(systemName: "timer")
                        .foregroundStyle(Color.accentColor)
                }
                Text(summary.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(summary.startedAt.relativeDayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label(DurationFormat.compact(summary.duration), systemImage: "clock")
                if summary.volume > 0 {
                    Label(app.settings.units.volume(summary.volume), systemImage: "scalemass")
                }
                if summary.setCount > 0 {
                    Label("\(summary.setCount) sets", systemImage: "checkmark.circle")
                }
                if prCount > 0 {
                    Label("\(prCount) PR\(prCount == 1 ? "" : "s")", systemImage: "trophy.fill")
                        .foregroundStyle(Theme.record)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())
            if !summary.exerciseNames.isEmpty {
                Text(exerciseLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            ForEach(summary.timerSummaries, id: \.self) { text in
                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var exerciseLine: String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for name in summary.exerciseNames {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { name in
            let count = counts[name] ?? 1
            return count > 1 ? "\(name) ×\(count)" : name
        }.joined(separator: ", ")
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// Month grid with a dot on every day that has a workout.
struct MonthCalendar: View {
    @Binding var month: Date
    @Binding var selectedDay: Date?
    let workoutDays: Set<Date>
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    shift(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 30)
                }
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button {
                    shift(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: 30)
                }
            }
            .buttonStyle(.borderless)

            let symbols = weekdaySymbols
            HStack(spacing: 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 36)
                    }
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -40 { shift(1) }
                    if value.translation.width > 40 { shift(-1) }
                }
        )
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let hasWorkout = workoutDays.contains(calendar.startOfDay(for: day))
        let isToday = calendar.isDateInToday(day)
        return Button {
            if isSelected {
                selectedDay = nil
            } else {
                selectedDay = day
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : Color.primary))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isSelected ? Color.accentColor : (hasWorkout ? Color.accentColor.opacity(0.16) : Color.clear)))
                Circle()
                    .fill(hasWorkout ? Color.accentColor : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (hasWorkout ? ", workout logged" : ""))
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            result.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private func shift(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            withAnimation(.snappy) { month = next }
        }
    }
}
