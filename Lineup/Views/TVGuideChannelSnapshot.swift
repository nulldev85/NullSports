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
