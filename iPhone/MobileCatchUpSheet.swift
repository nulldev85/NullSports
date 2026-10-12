import SwiftUI

/// A channel's past programmes that the provider kept, newest first and by
/// day, to play from the start.
///
/// The list comes from the provider's own table rather than the guide: the
/// guide only reaches back as far as the hour it was fetched, and says
/// nothing of which programmes were kept.
struct MobileCatchUpSheet: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    let stream: XtreamStream
    let onSelect: (CatchUpProgramme) -> Void
    @State private var programmes: [CatchUpProgramme] = []
    @State private var loading = true
    @State private var failed = false

    private struct Day: Identifiable {
        let day: Date
        let programmes: [CatchUpProgramme]
        var id: Date { day }
    }

    /// The programmes by the day they started, the latest day first.
    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: programmes) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted(by: >).map { day in
            Day(day: day, programmes: (grouped[day] ?? []).sorted { $0.start > $1.start })
        }
    }

    private func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LineupStyle.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if loading {
                        ProgressView().frame(maxHeight: .infinity)
                    } else if programmes.isEmpty {
                        ContentUnavailableView(failed ? "Catch Up unavailable" : "Nothing to catch up on",
                            systemImage: "clock.arrow.circlepath",
                            description: Text(failed
                                ? "The provider didn't answer. Try again in a moment."
                                : "Nothing from this channel has been kept to watch again yet."))
                            .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(days) { group in
                                Section {
                                    ForEach(group.programmes) { programme in
                                        Button { onSelect(programme) } label: {
                                            MobileCatchUpRow(programme: programme)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityHint("Plays it from the start.")
                                    }
                                } header: { sectionLabel(title(for: group.day)) }
                                    .listRowBackground(LineupRowBackground())
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LineupStyle.background)
        .task {
            do {
                programmes = try await library.catchUpProgrammes(for: stream)
            } catch {
                failed = true
            }
            loading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("CATCH UP")
                .font(.inter(.caption2, .bold)).tracking(1.4)
                .foregroundStyle(LineupStyle.secondary)
            Text(stream.name)
                .font(.inter(.headline, .bold)).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.inter(.caption2, .bold)).tracking(1.4)
            .foregroundStyle(LineupStyle.secondary)
    }
}

/// One programme in the Catch Up list: when it was on, and what it was. The
/// time sits over the title rather than beside it, so a long title and a
/// large type size both still have the width of the row.
struct MobileCatchUpRow: View {
    let programme: CatchUpProgramme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))")
                    .font(.interDigits(.caption, .semibold))
                    .foregroundStyle(LineupStyle.secondary)
                if programme.isOnNow {
                    HStack(spacing: 4) {
                        MobileLiveDot()
                        Text("ON NOW").font(.inter(9, .bold)).tracking(1)
                    }
                    .foregroundStyle(LineupStyle.liveStatus)
                }
            }
            Text(programme.title)
                .font(.inter(.body, .semibold))
                .foregroundStyle(LineupStyle.text)
                .lineLimit(2).multilineTextAlignment(.leading)
            if !programme.detail.isEmpty {
                Text(programme.detail)
                    .font(.inter(.caption))
                    .foregroundStyle(LineupStyle.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
