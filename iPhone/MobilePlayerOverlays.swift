import SwiftUI

/// The channel just tuned to, and what the guide says is on it, as the
/// banner over the picture names them. Worked out once, when the channel
/// changes, by the screen that changed it: the player itself does not read
/// the guide.
struct MobileChannelBannerInfo: Equatable {
    let stream: XtreamStream
    let program: CurrentProgram?
}

/// The channel just moved to, named over the picture for a moment: its mark,
/// its name and what is on. A label, not a control -- it lets every touch
/// through to the picture beneath.
struct MobileChannelBanner: View {
    let info: MobileChannelBannerInfo

    var body: some View {
        HStack(spacing: 12) {
            LineupArtView(url: info.stream.streamIcon.flatMap(URL.init(string:)), width: 56) { loaded in
                if let loaded {
                    loaded.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv").font(.system(size: 17, weight: .light, design: .rounded)).opacity(0.6)
                }
            }
            .frame(width: 48, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let number = info.stream.num {
                        Text(String(number)).font(.interDigits(.caption, .bold))
                            .foregroundStyle(LineupStyle.mediaSecondary)
                    }
                    Text(info.stream.name).font(.inter(.subheadline, .bold)).lineLimit(1)
                }
                if let program = info.program {
                    Text(program.title).font(.inter(.caption, .semibold)).lineLimit(1)
                    Text("\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))")
                        .font(.interDigits(.caption2, .medium))
                        .foregroundStyle(LineupStyle.mediaSecondary)
                }
            }
        }
        .foregroundStyle(LineupStyle.mediaText)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: 340, alignment: .leading)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: Color.black.opacity(0.72))
        .accessibilityElement(children: .combine)
    }
}

/// One of the viewer's teams' games, breaking into the picture: what
/// happened, the league, the score. Tapping it goes to the game; the cross
/// puts it away.
///
/// To VoiceOver it is one element that reads the whole alert, with watching
/// as its action and dismissing as a second one, rather than three pieces
/// that make sense only together.
struct MobileGameAlertBanner: View {
    let alert: GameAlert
    let onWatch: () -> Void
    let onDismiss: () -> Void

    /// "BOS @ NYY", or an event's name.
    static func matchup(_ game: SportsGame) -> String {
        if game.isEvent { return game.eventName ?? game.league.shortName }
        return "\(abbreviation(game.awayAbbreviation, team: game.awayTeam)) \(game.sidesSymbol) \(abbreviation(game.homeAbbreviation, team: game.homeTeam))"
    }

    /// "BOS 21 – NYY 17" once there is a score, else the matchup.
    static func scoreline(_ game: SportsGame) -> String {
        guard !game.isEvent, game.isLive, !game.awayScore.isEmpty, !game.homeScore.isEmpty else {
            return matchup(game)
        }
        return "\(abbreviation(game.awayAbbreviation, team: game.awayTeam)) \(game.awayScore) – "
            + "\(abbreviation(game.homeAbbreviation, team: game.homeTeam)) \(game.homeScore)"
    }

    /// A schedule that gives no abbreviation still leaves the team's name.
    private static func abbreviation(_ given: String, team: String) -> String {
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(team.prefix(3)).uppercased() : trimmed
    }

    var body: some View {
        let game = alert.game
        let scoreline = Self.scoreline(game)
        HStack(spacing: 4) {
            Button(action: onWatch) {
                HStack(spacing: 10) {
                    MobileLeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(LineupStyle.liveDot).frame(width: 6, height: 6)
                            Text(alert.headline.uppercased())
                                .font(.inter(10, .bold)).tracking(1.2)
                                .foregroundStyle(LineupStyle.liveStatus)
                            if !game.status.isEmpty {
                                Text(game.status.uppercased())
                                    .font(.inter(10, .bold)).tracking(0.8)
                                    .foregroundStyle(LineupStyle.mediaSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(scoreline).font(.interDigits(.subheadline, .bold)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold, design: .rounded))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(LineupStyle.mediaText)
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 6)
        .frame(maxWidth: 340, alignment: .leading)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: Color.black.opacity(0.72))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(alert.headline). \(scoreline)\(game.status.isEmpty ? "" : ". \(game.status)")")
        .accessibilityHint("Double-tap to watch.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onWatch() }
        .accessibilityAction(named: Text("Dismiss")) { onDismiss() }
    }
}

/// A recorded channel's timeline, under the player's controls: the programme
/// on now, or the one a recording is playing, from its start to its end. The
/// lighter part has been broadcast and can be played; the solid part runs up
/// to what is on screen. Start Over sits beside it.
///
/// It keeps its own clock for "now", so the part that can be played grows
/// whatever the screen around it redraws at.
struct MobileCatchUpBar: View {
    @ObservedObject var controller: MobilePlaybackController
    /// Inline, under the guide: Start Over as an icon, and nothing behind it
    /// that the badge already says.
    let compact: Bool
    let onStartOver: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { clock in
            content(now: clock.date)
        }
    }

    private func content(now: Date) -> some View {
        HStack(spacing: 10) {
            if controller.canStartOver {
                startOverButton
            }
            timeline(now: now)
        }
        .padding(.leading, controller.canStartOver ? 6 : 12).padding(.trailing, 12)
        .padding(.vertical, 6)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: Color.black.opacity(0.6))
    }

    @ViewBuilder
    private var startOverButton: some View {
        Button(action: onStartOver) {
            Group {
                if compact {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(width: 30, height: 30)
                } else {
                    Label("Start Over", systemImage: "backward.end.fill")
                        .font(.inter(.caption, .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10).frame(height: 30)
                }
            }
            .contentShape(Capsule())
            .lineupGlassControl(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start over")
        .accessibilityHint("Plays this program from its beginning.")
    }

    private func timeline(now: Date) -> some View {
        let span = Self.span(catchUp: controller.catchUp, source: controller.catchUpSource, now: now)
        let position = controller.catchUpPosition ?? now
        let reached = Self.fraction(now, in: span)
        let place = controller.catchUp == nil ? reached : Self.fraction(position, in: span)
        let atLive = controller.catchUp == nil
        let caption = caption(position: position, now: now)
        return VStack(spacing: 5) {
            // As far as the broadcast has got, the part that can be played,
            // in the softer accent; where the picture is, in the accent.
            LineupProgressBar(value: place, reach: reached,
                              height: compact ? 6 : LineupProgressBar.standardHeight)
            HStack(spacing: 6) {
                Text(span.start.formatted(date: .omitted, time: .shortened))
                Spacer(minLength: 0)
                Text(caption)
                    .foregroundStyle(atLive ? LineupStyle.liveStatus : LineupStyle.mediaText)
                Spacer(minLength: 0)
                Text(span.end.formatted(date: .omitted, time: .shortened))
            }
            .font(.interDigits(.caption2, .semibold))
            .foregroundStyle(LineupStyle.mediaSecondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Program timeline")
        .accessibilityValue(caption)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.skip(by: CatchUpPolicy.skip)
            case .decrement: controller.skip(by: -CatchUpPolicy.skip)
            default: break
            }
        }
    }

    /// LIVE, how far behind it, or for a programme from the past how far in.
    private func caption(position: Date, now: Date) -> String {
        guard let catchUp = controller.catchUp else { return "LIVE" }
        if catchUp.programmeEnd <= now.addingTimeInterval(-60), position < catchUp.programmeEnd {
            return MobilePlaybackProgress.timecode(position.timeIntervalSince(catchUp.programmeStart))
        }
        let behind = MobileCatchUpLabel.minutesBehind(position: position, now: now)
        return behind < 1 ? "LIVE" : MobileCatchUpLabel.duration(minutes: behind) + " BEHIND"
    }

    /// What the timeline is drawn across: the recording's programme, the one
    /// on now, or for a channel the guide knows nothing of, the half hour
    /// just gone.
    static func span(catchUp: CatchUpTimeline?, source: CatchUpSource?, now: Date) -> (start: Date, end: Date) {
        if let catchUp { return (catchUp.programmeStart, catchUp.programmeEnd) }
        if let programme = source?.programme(now) { return (programme.start, programme.end) }
        return (now.addingTimeInterval(-1800), now)
    }

    static func fraction(_ time: Date, in span: (start: Date, end: Date)) -> CGFloat {
        let length = span.end.timeIntervalSince(span.start)
        guard length > 0 else { return 0 }
        return CGFloat(min(1, max(0, time.timeIntervalSince(span.start) / length)))
    }
}
