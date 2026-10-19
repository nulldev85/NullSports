import Foundation

/// Something a channel showed that the provider kept, to be played again.
struct CatchUpProgramme: Identifiable, Hashable, Sendable {
    /// The channel's stream, not its guide ID: catch-up is asked for by stream.
    let streamID: Int
    let title: String
    let detail: String
    let start: Date
    let end: Date

    var id: String { "\(streamID)|\(Int(start.timeIntervalSince1970))" }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    /// Still on: what has been shown of it so far can be played.
    var isOnNow: Bool {
        let now = Date()
        return start <= now && now < end
    }
}

/// One channel's listings from the provider's own table, which -- unlike the
/// guide -- goes back as far as the provider keeps recordings and says which
/// programmes it kept.
///
/// Titles and descriptions arrive base64-encoded on most panels and plain on
/// a few; times arrive twice, as the server's wall clock and as Unix time,
/// and comparing the two gives the server's time zone when it says nothing
/// else about it.
struct XtreamArchiveTable: Decodable, Sendable {
    /// Sports replays require an explicit recorded flag on each completed
    /// listing. A live channel's archive capability alone is not enough.
    func confirmedGameRecordings(for stream: XtreamStream, now: Date = Date()) -> [CatchUpProgramme] {
        guard stream.hasCatchUp else { return [] }
        let oldest = stream.archiveDays > 0 ? now.addingTimeInterval(-Double(stream.archiveDays) * 86_400) : .distantPast
        return listings.filter { $0.hasArchive && $0.end <= now && $0.start >= oldest }
            .map { CatchUpProgramme(streamID: stream.id, title: $0.title, detail: $0.detail, start: $0.start, end: $0.end) }
    }

    struct Listing: Decodable, Sendable {
        let title: String
        let detail: String
        let start: Date
        let end: Date
        let hasArchive: Bool
        /// The server's own wall-clock reading of `start`, when it gave one.
        let localStart: String?

        enum CodingKeys: String, CodingKey {
            case title, description, start, end
            case startTimestamp = "start_timestamp"
            case stopTimestamp = "stop_timestamp"
            case hasArchive = "has_archive"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard let startStamp = values.lenientInt(.startTimestamp),
                  let stopStamp = values.lenientInt(.stopTimestamp), stopStamp > startStamp else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "A listing without times"))
            }
            start = Date(timeIntervalSince1970: TimeInterval(startStamp))
            end = Date(timeIntervalSince1970: TimeInterval(stopStamp))
            title = Self.text(values.lenientString(.title)) ?? "Untitled"
            detail = Self.text(values.lenientString(.description)) ?? ""
            if let flag = try? values.decode(Bool.self, forKey: .hasArchive) {
                hasArchive = flag
            } else {
                hasArchive = (values.lenientInt(.hasArchive) ?? 0) > 0
            }
            localStart = values.lenientString(.start)
        }

        /// Base64 when it decodes to text, and as written when it doesn't.
        private static func text(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            if raw.count % 4 == 0, let data = Data(base64Encoded: raw),
               let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
                return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return raw
        }
    }

    let listings: [Listing]

    enum CodingKeys: String, CodingKey {
        case listings = "epg_listings"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = (try? values.decode([Lenient<Listing>].self, forKey: .listings)) ?? []
        listings = entries.compactMap(\.value)
    }

    /// The server's time zone, from the first listing that gives its start
    /// both ways, to the nearest quarter hour.
    var serverTimeZone: TimeZone? {
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = TimeZone(secondsFromGMT: 0)
        reader.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for listing in listings {
            guard let local = listing.localStart, let wall = reader.date(from: local) else { continue }
            let quarters = (wall.timeIntervalSince(listing.start) / 900).rounded()
            guard abs(quarters) <= 14 * 4 else { continue }
            return TimeZone(secondsFromGMT: Int(quarters) * 900)
        }
        return nil
    }
}

/// How a live channel's recording is played: the channel live to go back
/// to, the recording's address from any minute, and the guide to draw its
/// timeline from. A player holds one while a channel the provider records
/// is on, and plays the recording through it.
struct CatchUpSource {
    let stream: XtreamStream
    /// The channel live, in the order `playbackURLs` gives them.
    let liveURLs: [URL]
    /// The recording from a start until an end, the address to try first
    /// first.
    let addresses: (Date, Date) -> [URL]
    /// What the guide says was on at a time.
    let programme: (Date) -> CurrentProgram?
}

/// Where catch-up is playing from and where it has got to.
///
/// A catch-up stream is asked for from a whole minute -- the address has no
/// finer place -- so what is on screen is that minute plus however far the
/// stream has played. Every position here is a time of day, which is what a
/// programme's timeline and "behind live" are measured in.
struct CatchUpTimeline: Equatable, Sendable {
    /// The programme being watched, which the timeline is drawn across.
    let programmeStart: Date
    let programmeEnd: Date
    let title: String
    /// The minute the open stream starts from.
    let streamStart: Date

    /// What is on screen, given how far into the stream playback has got.
    func position(playedSeconds: TimeInterval) -> Date {
        streamStart.addingTimeInterval(max(0, playedSeconds))
    }

    /// How far along the programme the picture is, from 0 to 1.
    func fraction(at position: Date) -> Double {
        let length = programmeEnd.timeIntervalSince(programmeStart)
        guard length > 0 else { return 0 }
        return min(1, max(0, position.timeIntervalSince(programmeStart) / length))
    }

    /// How far into the programme the live edge has reached, from 0 to 1:
    /// for a programme still on, the part of the bar that can be played.
    func liveFraction(now: Date = Date()) -> Double {
        fraction(at: now)
    }

    /// Whether a programme still being shown has been caught up with.
    func isAtLive(_ position: Date, now: Date = Date()) -> Bool {
        programmeEnd > now && now.timeIntervalSince(position) < CatchUpPolicy.liveTolerance
    }
}

/// The numbers catch-up runs on, in one place.
enum CatchUpPolicy {
    /// Within this of the live edge counts as live: a channel itself plays a
    /// few seconds behind the broadcast, and a catch-up stream can never
    /// quite reach the present.
    static let liveTolerance: TimeInterval = 20
    /// A skip back or forward.
    static let skip: TimeInterval = 10
    /// Paused for longer than this on a channel the provider records, play
    /// resumes from where it was paused rather than at the live edge. A
    /// shorter pause the player's own buffer covers.
    static let resumeFromPauseAfter: TimeInterval = 10
    /// How far behind the broadcast a live channel usually plays, so a pause
    /// or a rewind from live starts catch-up close to what was on screen.
    static let liveLatency: TimeInterval = 8

    /// A time rounded down to its whole minute, which is as finely as a
    /// catch-up address can say where to start.
    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// How many minutes to ask for, from a start to an end, with a minute's
    /// grace at the end so a programme's last moments are not cut.
    static func minutes(from start: Date, to end: Date) -> Int {
        let seconds = end.timeIntervalSince(minute(start))
        return min(24 * 60, max(1, Int((seconds / 60).rounded(.up)) + 1))
    }

    /// "2024-03-09:19-30": a start as catch-up addresses write it, in the
    /// server's own time.
    static func addressStamp(_ date: Date, in zone: TimeZone) -> String {
        let writer = DateFormatter()
        writer.locale = Locale(identifier: "en_US_POSIX")
        writer.timeZone = zone
        writer.dateFormat = "yyyy-MM-dd:HH-mm"
        return writer.string(from: date)
    }
}
