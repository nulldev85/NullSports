import Foundation

struct MobileSportsCatchUpChannel: Identifiable {
    let profileID: UUID
    let stream: XtreamStream
    var id: String { profileID.uuidString + "|" + String(stream.id) }

    func selection(for program: CatchUpProgramme) -> MobileGameReplaySelection? {
        guard program.streamID == stream.id, stream.hasCatchUp, program.end > program.start else { return nil }
        return .init(profileID: profileID, recording: .init(stream: stream, program: program), usesChannelCatchUp: true)
    }
}

enum MobileSportsCatchUpPolicy {
    /// Input is the existing strict event Channels result, not a league pool
    /// or a team's saved preference. No additional stream connections/probes.
    static func channels(_ matched: [LiveEventChannel], live: Bool, playlist: Bool) -> [XtreamStream] {
        guard live, !playlist else { return [] }
        var seen: Set<Int> = []
        return matched.compactMap { entry in
            entry.stream.hasCatchUp && seen.insert(entry.id).inserted ? entry.stream : nil
        }
    }
}
