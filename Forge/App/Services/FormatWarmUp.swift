import Foundation

/// The first styled or formatted text an app shows pays a one-time setup
/// cost in Foundation: styled text (such as a live workout clock) first
/// catalogs every text attribute the system knows about, and each date or
/// duration style loads its locale data. Doing it once in the background at
/// launch keeps that cost out of the first workout, history or backup
/// screen the athlete opens. Everything here is thread-safe and cached for
/// the life of the app.
enum FormatWarmUp {
    static func run() {
        let now = Date()
        _ = NSAttributedString(AttributedString("Forge"))
        // Live clocks (`Text(date, style: .timer)`) and durations.
        _ = Duration.seconds(3_723).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        _ = Duration.seconds(83).formatted(.time(pattern: .minuteSecond))
        // Dates as they appear across the app.
        _ = now.formatted(date: .abbreviated, time: .shortened)
        _ = now.formatted(date: .abbreviated, time: .omitted)
        _ = now.formatted(date: .complete, time: .shortened)
        _ = now.formatted(date: .complete, time: .omitted)
        _ = now.formatted(.dateTime.month(.wide).year())
        _ = now.formatted(.dateTime.month(.abbreviated).day())
        _ = now.addingTimeInterval(-3_600).formatted(.relative(presentation: .named))
    }
}
