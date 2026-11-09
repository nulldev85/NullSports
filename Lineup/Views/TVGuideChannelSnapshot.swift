import Foundation

struct TVGuideChannelSnapshot: Sendable {
    let streams: [XtreamStream]
    let positions: [Int: Int]
    static let empty = Self(streams: [], positions: [:])

    static func load(_ streams: [XtreamStream], query: GuideChannelList.Query) async throws -> Self {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            let filtered = try GuideChannelList.build(streams, query: query)
            var positions: [Int: Int] = [:]
            for (index, stream) in filtered.enumerated() {
                try Task.checkCancellation()
                if positions[stream.id] == nil { positions[stream.id] = index }
            }
            return Self(streams: filtered, positions: positions)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    struct Preview: Sendable {
        let stream: XtreamStream
        let program: CurrentProgram
    }

    static func preview(in streams: [XtreamStream], programs: [String: [CurrentProgram]], now: Date) async throws -> Preview? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { () throws -> Preview? in
            for stream in streams {
                try Task.checkCancellation()
                if let id = stream.epgChannelID,
                   let program = programs[id]?.first(where: { $0.start <= now && now < $0.end }) {
                    return Preview(stream: stream, program: program)
                }
            }
            return nil
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

/// Focus navigation and row drawing share the same sorted, visible listings.
/// Keep only recently needed channels from the current half-hour and guide.
@MainActor final class TVGuideProgramWindow {
    private struct Window: Equatable {
        let library: ObjectIdentifier
        let revision: Int
        let start: Date
        let end: Date
    }

    private var window: Window?
    private var channels: [String: [CurrentProgram]] = [:]

    func programs(channel: String, library: ObjectIdentifier, revision: Int, start: Date, end: Date,
                  listings: () -> [CurrentProgram]) -> [CurrentProgram] {
        let next = Window(library: library, revision: revision, start: start, end: end)
        if window != next {
            window = next
            channels.removeAll(keepingCapacity: true)
        }
        if let existing = channels[channel] { return existing }
        let visible = listings().filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
        if channels.count >= 256 { channels.removeAll(keepingCapacity: true) }
        channels[channel] = visible
        return visible
    }
}
