import Foundation

struct LiveEventChannel: Identifiable, Sendable {
    let stream: XtreamStream
    let program: CurrentProgram?
    let evidence: Int
    let quality: LiveChannelQuality
    var id: Int { stream.id }
}
