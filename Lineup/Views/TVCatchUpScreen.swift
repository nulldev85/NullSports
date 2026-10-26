import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

/// A channel's past programmes that the provider kept, to play from the
/// start: the whole screen, the list on the right by day, newest first, and
/// what the focused programme is on the left.
///
/// Focus only ever moves up and down the list. The days are headings in it
/// rather than a rail of their own, so there is nothing for a sideways press
/// to land on by accident and change what is listed.
struct TVCatchUpScreen: View {
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let onSelect: (CatchUpProgramme) -> Void
    @State private var programmes: [CatchUpProgramme] = []
    @State private var loading = true
    @State private var failed = false
    @State private var focused: CatchUpProgramme?

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
        HStack(alignment: .top, spacing: 64) {
            TVCatchUpDetail(stream: stream, programme: focused ?? programmes.first,
                            dayCount: days.count, programmeCount: programmes.count)
                .frame(width: 600)
                .frame(maxHeight: .infinity, alignment: .top)
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90)
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .task {
            do {
                programmes = try await library.catchUpProgrammes(for: stream)
            } catch {
                failed = true
            }
            loading = false
        }
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if programmes.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: failed ? "wifi.exclamationmark" : "clock.arrow.circlepath")
                    .font(.system(size: 44, weight: .regular, design: .rounded))
                    .foregroundStyle(LineupPresentationStyle.secondary)
                Text(failed ? "The provider didn't answer" : "Nothing kept yet")
                    .font(.inter(26, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                Text(failed ? "Try again in a moment."
                            : "Programs from this channel will show here once the provider has kept them.")
                    .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { group in
                        Section {
                            ForEach(group.programmes) { programme in
                                TVSelectable(scale: 1.015, fillRadius: 14,
                                             action: { onSelect(programme) },
                                             onFocusChange: { if $0 { focused = programme } },
                                             requestInitialFocus: programme.id == programmes.first?.id) {
                                    TVCatchUpRow(programme: programme)
                                }
                            }
                        } header: {
                            TVCatchUpDayHeader(day: group.day, count: group.programmes.count)
                        }
                    }
                }
                // Room for a focused row's lift at both ends of the list.
                .padding(.horizontal, 14)
                .padding(.bottom, 80)
            }
        }
    }
}

/// The left of the catch-up screen: the channel, then everything about the
/// programme in focus. Nothing here takes focus.
struct TVCatchUpDetail: View {
    let stream: XtreamStream
    let programme: CatchUpProgramme?
    let dayCount: Int
    let programmeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                ChannelLogo(url: stream.streamIcon, width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("CATCH UP").font(.inter(13, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(stream.name).font(.inter(30, .bold)).foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
            }
            if programmeCount > 0 {
                Text("\(programmeCount) programs over \(dayCount == 1 ? "1 day" : "\(dayCount) days")")
                    .font(.inter(16, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                    .padding(.top, 14)
            }

            Rectangle().fill(LineupStyle.line).frame(height: 1).padding(.vertical, 34)

            if let programme {
                VStack(alignment: .leading, spacing: 16) {
                    Text(TVCatchUpFormat.when(programme))
                        .font(.inter(15, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(programme.title)
                        .font(.inter(40, .bold)).foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(3).minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        TVCatchUpChip(text: TVCatchUpFormat.length(programme.duration))
                        if programme.isOnNow { TVCatchUpOnNow() }
                    }
                    if programme.isOnNow {
                        TVCatchUpProgress(fraction: TVCatchUpFormat.elapsedFraction(programme), height: 10)
                            .frame(maxWidth: 420)
                    }
                    if !programme.detail.isEmpty {
                        Text(programme.detail)
                            .font(.inter(20)).foregroundStyle(LineupPresentationStyle.secondary)
                            .lineSpacing(4)
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A new programme's words replace the last one's at once: an
                // animated swap would trail behind the remote.
                .transaction { $0.animation = nil }
            }

            Spacer(minLength: 24)

            HStack(spacing: 10) {
                Image(systemName: "play.circle")
                Text(programme?.isOnNow == true ? "Select to watch from the start, then catch up to live"
                                                : "Select to watch from the start")
            }
            .font(.inter(17, .medium))
            .foregroundStyle(LineupPresentationStyle.secondary)
            .padding(.bottom, 60)
        }
    }
}

/// A day's heading in the list, pinned while its programmes scroll under it.
struct TVCatchUpDayHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TVCatchUpFormat.dayTitle(day))
                .font(.inter(16, .heavy)).tracking(0.6)
                .foregroundStyle(LineupPresentationStyle.text)
            Text(day.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                .font(.inter(14, .heavy)).tracking(0.6)
                .foregroundStyle(LineupPresentationStyle.secondary)
            Spacer(minLength: 0)
            Text(count == 1 ? "1 program" : "\(count) programs")
                .font(.inter(14, .medium))
                .foregroundStyle(LineupPresentationStyle.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22).padding(.bottom, 12)
        // Opaque, so rows scrolling up under a pinned heading do not show
        // through it.
        .background(LineupPresentationStyle.ground)
    }
}

/// One programme in the catch-up list.
struct TVCatchUpRow: View {
    let programme: CatchUpProgramme

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text(programme.start.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(22, .semibold))
                    .foregroundStyle(LineupPresentationStyle.text)
                Text(TVCatchUpFormat.length(programme.duration))
                    .font(.inter(15, .medium))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
            .frame(width: 128, alignment: .leading)

            Rectangle().fill(LineupStyle.line).frame(width: 1, height: 46)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if programme.isOnNow { TVCatchUpOnNow() }
                    Text(programme.title)
                        .font(.inter(23, .semibold))
                        .foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(1)
                }
                if !programme.detail.isEmpty {
                    Text(programme.detail)
                        .font(.inter(16))
                        .foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(1)
                }
                if programme.isOnNow {
                    TVCatchUpProgress(fraction: TVCatchUpFormat.elapsedFraction(programme), height: 6)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .frame(minHeight: 96)
        .background(programme.isOnNow ? LineupStyle.focused : LineupPresentationStyle.row,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "ON NOW", red: catch-up's one status.
struct TVCatchUpOnNow: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(LineupStyle.liveDot).frame(width: 8, height: 8)
            Text("ON NOW").font(.inter(13, .heavy)).tracking(0.6)
                .foregroundStyle(LineupStyle.liveStatus)
        }
    }
}

struct TVCatchUpChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.inter(15, .semibold))
            .foregroundStyle(LineupPresentationStyle.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(LineupPresentationStyle.row, in: Capsule())
    }
}

/// How far a programme still on has got: the app's progress bar.
struct TVCatchUpProgress: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        LineupProgressBar(value: fraction, height: height)
    }
}

/// The catch-up screen's words for times and lengths.
enum TVCatchUpFormat {
    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide)).uppercased()
    }

    /// "TODAY · 9:00 – 11:00 AM"
    static func when(_ programme: CatchUpProgramme) -> String {
        let day = dayTitle(Calendar.current.startOfDay(for: programme.start))
        let start = programme.start.formatted(date: .omitted, time: .shortened)
        let end = programme.end.formatted(date: .omitted, time: .shortened)
        return "\(day)  ·  \(start) – \(end)"
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
