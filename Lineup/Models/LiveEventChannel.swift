import Foundation

struct LiveEventChannel: Codable, Identifiable, Sendable {
    let stream: XtreamStream
    let program: CurrentProgram?
    let evidence: Int
    let quality: LiveChannelQuality
    /// A tennis tournament's coverage taking turns with other tournaments'
    /// (see `SportsLibrary.sharesCoverage`).
    var sharedCoverage = false
    var id: Int { stream.id }
}
