import SwiftUI

/// A channel's past programmes that the provider kept, newest first and by
/// day, to play from the start.
///
/// The list comes from the provider's own table rather than the guide: the
/// guide only reaches back as far as the hour it was fetched, and says
/// nothing of which programmes were kept.
///
/// The same page as the television's, laid out for a hand: the channel at
/// the top, a row of days to jump between, and one list under it with each
/// day's heading pinned while its programmes scroll.
struct MobileCatchUpSheet: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    let stream: XtreamStream
    let onSelect: (CatchUpProgramme) -> Void
    @State private var programmes: [CatchUpProgramme] = []
    @State private var loading = true
    @State private var failed = false
    @State private var chosenDay: Date?

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

    var body: some View {
        NavigationStack {
            ZStack {
                LineupStyle.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if loading {
                        ProgressView().frame(maxHeight: .infinity)
                    } else if programmes.isEmpty {
                        ContentUnavailableView(failed ? "Catch Up unavailable" : "Nothing kept yet",
                            systemImage: failed ? "wifi.exclamationmark" : "clock.arrow.circlepath",
                            description: Text(failed
                                ? "The provider didn't answer. Try again in a moment."
                                : "Programmes from this channel will show here once the provider has kept them."))
                            .frame(maxHeight: .infinity)
                    } else {
                        list
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 64) { loaded in
                    if let image = loaded { image.resizable().scaledToFit() }
                    else { Image(systemName: "tv").foregroundStyle(LineupStyle.secondary) }
                }
                .padding(6)
                .frame(width: 64, height: 44)
                .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("CATCH UP")
                        .font(.inter(.caption2, .bold)).tracking(1.4)
                        .foregroundStyle(LineupStyle.secondary)
                    Text(stream.name)
                        .font(.inter(.title3, .bold)).lineLimit(1)
                        .foregroundStyle(LineupStyle.text)
                        .accessibilityAddTraits(.isHeader)
                    if !programmes.isEmpty {
                        Text("\(programmes.count) programmes over \(days.count == 1 ? "1 day" : "\(days.count) days")")
                            .font(.inter(.caption, .medium))
                            .foregroundStyle(LineupStyle.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if days.count > 1 {
                    dayChips(proxy)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { group in
                            Section {
                                ForEach(group.programmes) { programme in
                                    Button { onSelect(programme) } label: {
                                        MobileCatchUpRow(programme: programme)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Plays it from the start.")
                                }
                            } header: {
                                MobileCatchUpDayHeader(day: group.day, count: group.programmes.count)
                                    .id(group.day)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    /// The days, to jump straight to one; the list stays one list.
    private func dayChips(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days) { group in
                    let chosen = (chosenDay ?? days.first?.day) == group.day
                    Button {
                        chosenDay = group.day
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(group.day, anchor: .top) }
                    } label: {
                        Text(MobileCatchUpFormat.dayTitle(group.day, short: true))
                            .font(.inter(.subheadline, .semibold))
                            .foregroundStyle(chosen ? LineupStyle.background : LineupStyle.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(chosen ? LineupStyle.text : LineupStyle.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }
}

/// A day's heading in the list, pinned while its programmes scroll under it.
private struct MobileCatchUpDayHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(MobileCatchUpFormat.dayTitle(day, short: false).uppercased())
                .font(.inter(.caption, .bold)).tracking(1.4)
                .foregroundStyle(LineupStyle.text)
            Text(day.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                .font(.inter(.caption2, .semibold)).tracking(1)
                .foregroundStyle(LineupStyle.secondary)
            Spacer(minLength: 0)
            Text(count == 1 ? "1 programme" : "\(count) programmes")
                .font(.inter(.caption2, .medium))
                .foregroundStyle(LineupStyle.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 14).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        // Opaque, so rows scrolling up under a pinned heading do not show
        // through it.
        .background(LineupStyle.background)
    }
}

/// One programme in the Catch Up list: when it started and how long it ran,
/// beside what it was. A programme still on says so in red, with how far it
/// has got.
struct MobileCatchUpRow: View {
    let programme: CatchUpProgramme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(programme.start.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(.subheadline, .semibold))
                    .foregroundStyle(LineupStyle.text)
                Text(MobileCatchUpFormat.length(programme.duration))
                    .font(.inter(.caption2, .medium))
                    .foregroundStyle(LineupStyle.secondary)
            }
            .frame(width: 72, alignment: .leading)

            Rectangle().fill(LineupStyle.line).frame(width: 1).frame(maxHeight: 40)

            VStack(alignment: .leading, spacing: 4) {
                if programme.isOnNow {
                    HStack(spacing: 4) {
                        MobileLiveDot()
                        Text("ON NOW").font(.inter(9, .bold)).tracking(1)
                    }
                    .foregroundStyle(LineupStyle.liveStatus)
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
                if programme.isOnNow {
                    MobileCatchUpProgress(fraction: MobileCatchUpFormat.elapsedFraction(programme))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LineupStyle.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(programme.isOnNow ? LineupStyle.focused : LineupStyle.raised,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// How far a programme still on has got, on a quiet track.
private struct MobileCatchUpProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(LineupStyle.text.opacity(0.14))
                Capsule().fill(LineupStyle.liveDot)
                    .frame(width: max(3, proxy.size.width * fraction))
            }
        }
        .frame(height: 3)
    }
}

/// Catch Up's words for days and lengths.
private enum MobileCatchUpFormat {
    static func dayTitle(_ day: Date, short: Bool) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return short ? day.formatted(.dateTime.weekday(.abbreviated).day())
                     : day.formatted(.dateTime.weekday(.wide))
    }

    /// "2 hr", "1 hr 30 min", "45 min"
    static func length(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    static func elapsedFraction(_ programme: CatchUpProgramme, now: Date = Date()) -> Double {
        guard programme.duration > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(programme.start) / programme.duration))
    }
}
