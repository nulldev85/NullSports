import SwiftUI

/// The countdown beside a timed set's number. Tap to start it (after a
/// short "get ready"), pause or resume; its bar empties as the set's time
/// runs down. With no time planned it counts up instead, like a stopwatch.
struct SetTimerPill: View, Equatable {
    let planned: Double?
    /// This set's timer, while it has one.
    let timer: SetTimerState?
    let completed: Bool
    /// The time logged once the set is done.
    let logged: Double?
    let toggle: () -> Void
    let reset: () -> Void

    nonisolated static func == (lhs: SetTimerPill, rhs: SetTimerPill) -> Bool {
        lhs.planned == rhs.planned
            && lhs.timer == rhs.timer
            && lhs.completed == rhs.completed
            && lhs.logged == rhs.logged
    }

    var body: some View {
        if completed {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(doneText)
        } else {
            Button(action: toggle) {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .contextMenu {
                if timer != nil {
                    Button("Reset Timer", systemImage: "arrow.counterclockwise", action: reset)
                }
            }
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("setTimer")
            .sensoryFeedback(.selection, trigger: timer?.isPaused)
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            SetTimerGlyph(symbol: symbol, tint: tint)
            Group {
                if let timer, !timer.isPaused {
                    SetTimerLiveReadout(timer: timer)
                } else {
                    SetTimerFace(
                        label: staticLabel,
                        labelColor: completed ? Theme.success : (timer == nil ? Color.secondary : Color.primary),
                        bar: staticBar
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var symbol: String {
        if completed { return "checkmark" }
        if let timer { return timer.isPaused ? "play.fill" : "pause.fill" }
        return planned == nil ? "stopwatch" : "play.fill"
    }

    private var tint: Color {
        completed ? Theme.success : Color.accentColor
    }

    private var staticLabel: String {
        if completed { return logged.map { DurationFormat.clock($0) } ?? "Done" }
        if let timer {
            let now = Date()
            if let remaining = timer.remaining(at: now) { return DurationFormat.countdownClock(remaining) }
            return DurationFormat.clock(timer.elapsed(at: now))
        }
        return planned.map { DurationFormat.clock($0) } ?? "0:00"
    }

    private var staticBar: SetTimerBarStyle {
        if completed { return .drained }
        if let timer {
            return timer.duration == nil ? .counting : .remaining(timer.fractionRemaining(at: Date()))
        }
        return planned == nil ? .counting : .ready
    }

    private var doneText: String {
        guard let logged else { return "Done" }
        return "Done, \(SetTimerText.spoken(logged))"
    }

    private var accessibilityText: String {
        if let timer {
            return timer.isPaused ? "Resume timer" : "Pause timer"
        }
        if let planned { return "Start \(SetTimerText.spoken(planned)) timer" }
        return "Start stopwatch"
    }
}

/// How a set timer's bar is drawn.
enum SetTimerBarStyle: Equatable {
    /// Not started: full, quieter.
    case ready
    /// Running or paused: the share of the time left.
    case remaining(Double)
    /// Getting ready: full, waiting to start.
    case gettingReady
    /// A stopwatch has no end to count down to.
    case counting
    /// Done: emptied.
    case drained
}

private struct SetTimerGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.opacity(0.14)))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Time on top, bar beneath.
private struct SetTimerFace: View {
    let label: String
    let labelColor: Color
    let bar: SetTimerBarStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.num(.subheadline, .semibold))
                .monospacedDigit()
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            SetTimerBar(style: bar)
        }
    }
}

/// A running timer: the digits change once a second (on the second), and
/// only the bar is redrawn every frame.
private struct SetTimerLiveReadout: View {
    let timer: SetTimerState

    var body: some View {
        TimelineView(.periodic(from: SetTimerText.tickOrigin(timer), by: 1)) { context in
            let label = SetTimerText.label(timer, at: context.date)
            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(.num(.subheadline, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(timer.leadInRemaining(at: context.date) > 0 ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText(countsDown: timer.duration != nil))
                    .animation(Motion.numeric, value: label)
                SetTimerLiveBar(timer: timer, height: 4)
            }
        }
    }
}

/// The bar of a running timer, redrawn every frame (and nothing else is).
struct SetTimerLiveBar: View {
    let timer: SetTimerState
    var height: CGFloat = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: AppEnvironment.isUITest ? 0.5 : nil, paused: timer.isPaused)) { context in
            SetTimerBar(style: SetTimerText.barStyle(timer, at: context.date), height: height)
        }
        .frame(height: height)
    }
}

struct SetTimerBar: View {
    let style: SetTimerBarStyle
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                if fraction > 0 {
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var fraction: CGFloat {
        switch style {
        case .ready, .gettingReady: return 1
        case .remaining(let value): return CGFloat(max(0, min(1, value)))
        case .counting, .drained: return 0
        }
    }

    private var trackColor: Color {
        style == .drained ? Theme.success.opacity(0.22) : Theme.fill
    }

    private var fillColor: Color {
        switch style {
        case .ready: return Color.accentColor.opacity(0.35)
        case .gettingReady: return Color.accentColor.opacity(0.55)
        default: return Color.accentColor
        }
    }
}

/// The big countdown for the set in progress, floating where the rest
/// timer shows, so it can be read from across the room.
struct SetTimerCard: View {
    let timer: SetTimerState
    let title: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let session = app.session
        TimelineView(.periodic(from: SetTimerText.tickOrigin(timer), by: 1)) { context in
            let now = context.date
            let gettingReady = timer.leadInRemaining(at: now) > 0
            let clock = SetTimerText.clock(timer, at: now)
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gettingReady ? "Get ready" : (timer.isPaused ? "Paused" : title))
                            .font(.num(.caption2, .medium))
                            .tracking(0.9)
                            .textCase(.uppercase)
                            .foregroundStyle(gettingReady ? Color.accentColor : .secondary)
                            .lineLimit(1)
                        Text(clock)
                            .font(.num(size: 30, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(timer.isPaused ? Color.secondary : Color.primary)
                            .contentTransition(.numericText(countsDown: timer.duration != nil || gettingReady))
                            .animation(Motion.numeric, value: clock)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(Motion.smooth) { session.resetSetTimer() }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Reset timer")
                        Button {
                            session.toggleSetTimer(timer.setID)
                        } label: {
                            Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(timer.isPaused ? "Resume timer" : "Pause timer")
                        .accessibilityIdentifier("pauseSetTimer")
                        Button("Done") {
                            withAnimation(Motion.snappy) { session.toggleCompletion(of: timer.setID) }
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.onAccent)
                        .accessibilityIdentifier("finishSetTimer")
                    }
                    .font(.app(.subheadline, .semibold))
                }
                SetTimerLiveBar(timer: timer, height: 5)
            }
            .animation(Motion.smooth, value: gettingReady)
        }
        .padding(14)
        .floatingSurface(cornerRadius: 22)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// Words and numbers for set timers.
enum SetTimerText {
    /// A moment the displayed second changes on, safely in the past, so a
    /// once-a-second timeline ticks exactly as the digits should change.
    static func tickOrigin(_ timer: SetTimerState) -> Date {
        let resumed = timer.resumedAt ?? Date()
        let workStart = resumed.addingTimeInterval(timer.leadIn - timer.banked)
        return workStart.addingTimeInterval(-(timer.leadIn.rounded(.up) + 1))
    }

    /// "Ready 3" while getting ready, then the time left (or, counting up,
    /// the time so far).
    static func label(_ timer: SetTimerState, at date: Date) -> String {
        let leadIn = timer.leadInRemaining(at: date.addingTimeInterval(0.01))
        if leadIn > 0 { return "Ready \(Int(leadIn.rounded(.up)))" }
        return clock(timer, at: date)
    }

    static func clock(_ timer: SetTimerState, at date: Date) -> String {
        // Timeline ticks land exactly on the second; a hair past it keeps
        // rounding from showing the second before.
        let now = date.addingTimeInterval(0.01)
        let leadIn = timer.leadInRemaining(at: now)
        if leadIn > 0 { return "\(Int(leadIn.rounded(.up)))" }
        if let remaining = timer.remaining(at: now) { return DurationFormat.countdownClock(remaining) }
        return DurationFormat.clock(timer.elapsed(at: now))
    }

    static func barStyle(_ timer: SetTimerState, at now: Date) -> SetTimerBarStyle {
        if timer.leadInRemaining(at: now) > 0 { return timer.duration == nil ? .counting : .gettingReady }
        return timer.duration == nil ? .counting : .remaining(timer.fractionRemaining(at: now))
    }

    /// "2 minutes", "45 seconds", "1 minute 30 seconds".
    static func spoken(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        if secs > 0 || minutes == 0 { parts.append(secs == 1 ? "1 second" : "\(secs) seconds") }
        return parts.joined(separator: " ")
    }
}
