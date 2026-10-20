import Foundation

struct MobileGameReplayRecording: Identifiable, Sendable {
    let stream: XtreamStream
    let program: CatchUpProgramme
    var id: String { program.id }
}

struct MobileGameReplay: Identifiable, Sendable {
    let teams: [FollowedTeam]
    var recordings: [MobileGameReplayRecording]
    var start: Date { recordings.map(\.program.start).min() ?? .distantPast }
    var id: String { teams.map(\.id).sorted().joined(separator: ",") + "|" + String(Int(start.timeIntervalSince1970)) }
    var title: String { teams.map(\.name).joined(separator: " vs ") }
}

struct MobileGameReplaySelection: Identifiable {
    let profileID: UUID
    let recording: MobileGameReplayRecording
    var usesChannelCatchUp = false
    var id: String { profileID.uuidString + "|" + recording.id }
}

enum MobileGameReplayPolicy {
    struct Team: Sendable {
        let value: FollowedTeam
        let aliases: Set<String>
        init(_ team: FollowedTeam) {
            value = team
            aliases = EventChannelEvidence.Team(name: team.name, abbreviation: team.abbreviation, nicknames: true).aliases
        }
    }

    static func isVisible(myTeams: Bool, league: SportsLeague?) -> Bool {
        myTeams && (league == nil || league == .nfl)
    }

    private static let blocked = ["highlights", "recap", "preview", "pregame", "pre game", "postgame", "post game",
        "press conference", "interview", "documentary", "talk show", "news", "analysis", "countdown",
        "good morning", "total access", "draft", "combine", "madden", "redzone", "red zone", "whip around",
        "radio", "audio", "college", "ncaa", "ncaaf"].map(ProfessionalChannelMatcher.pad)

    private static func text(_ text: String) -> String {
        ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(text))
    }

    private static func matches(_ text: String, teams: [Team]) -> [Team] {
        teams.filter { !$0.aliases.isEmpty && $0.aliases.contains(where: text.contains) }
    }

    /// Only archive-enabled NFL channels. Dedicated channels for other teams
    /// are excluded before making a request; generic NFL feeds can contain any
    /// followed team's game and are checked by their recorded program titles.
    static func candidates(streams: [XtreamStream], categories: [XtreamCategory],
                           followed: Set<String>, teams: [Team]) -> [XtreamStream] {
        let names = Dictionary(categories.map { ($0.id, $0.categoryName) }, uniquingKeysWith: { first, _ in first })
        return streams.filter { stream in
            guard !Task.isCancelled, stream.hasCatchUp else { return false }
            let context = text(stream.name + " " + (names[stream.categoryID ?? ""] ?? ""))
            guard context.contains(" nfl "), !blocked.contains(where: context.contains) else { return false }
            let named = matches(context, teams: teams)
            return named.isEmpty || named.contains { followed.contains($0.value.id) }
        }.sorted { $0.id < $1.id }
    }

    static func available(_ program: CatchUpProgramme, stream: XtreamStream, now: Date) -> Bool {
        guard stream.hasCatchUp, program.streamID == stream.id,
              program.start.timeIntervalSince1970.isFinite, program.end.timeIntervalSince1970.isFinite,
              program.end > program.start, program.end <= now else { return false }
        // A partially expired recording cannot be replayed from its beginning.
        return stream.archiveDays <= 0 || program.start >= now.addingTimeInterval(-Double(stream.archiveDays) * 86_400)
    }

    static func replays(recordings: [MobileGameReplayRecording], followed: Set<String>, teams: [Team], now: Date) -> [MobileGameReplay] {
        var result: [MobileGameReplay] = []
        var seen: Set<String> = []
        for recording in recordings.sorted(by: { $0.program.start > $1.program.start }) {
            let program = recording.program
            guard available(program, stream: recording.stream, now: now), seen.insert(recording.id).inserted else { continue }
            // A team channel by itself is not proof of which game it recorded.
            // Require a two-team matchup in each individual archived listing.
            var description = program.title
            if EventChannelEvidence.isGenericTitle(program.title, league: "nfl") { description = program.detail }
            let padded = text(description)
            guard !blocked.contains(where: padded.contains) else { continue }
            let named = matches(padded, teams: teams)
            let separator = EventChannelEvidence.namesMatchup(description)
                || [" @ ", " - ", " – ", " / "].contains(where: description.contains)
            guard separator, named.count == 2, named.contains(where: { followed.contains($0.value.id) }) else { continue }
            let participants = named.map(\.value).sorted { $0.id < $1.id }
            if let index = result.firstIndex(where: { replay in
                replay.teams.map(\.id) == participants.map(\.id)
                    && abs(replay.start.timeIntervalSince(program.start)) <= 10 * 60
            }) {
                result[index].recordings.append(recording)
            } else {
                result.append(MobileGameReplay(teams: participants, recordings: [recording]))
            }
        }
        return result.sorted { $0.start > $1.start }
    }
}
