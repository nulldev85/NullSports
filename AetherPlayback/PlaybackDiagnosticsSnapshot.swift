import Foundation

/// Existing engine counters only. No URLs, headers, credentials or extra probes.
public struct PlaybackDiagnosticsSnapshot: Equatable, Sendable {
    public var route: String?
    public var decoder: String?
    public var bytesRead: Int64?
    public var displayedFrames: Int?
    public var droppedFrames: Int?
    public var nativeBufferSeconds: Double?
    public var decodedVideoSeconds: Double?
    public var sourceWindowBytes: Int?
    public var networkMbps: Double?
    public var frameDelaySeconds: Double?
    public var nativeFrameRecoveryEnabled: Bool

    public init(route: String? = nil, decoder: String? = nil, bytesRead: Int64? = nil,
                displayedFrames: Int? = nil, droppedFrames: Int? = nil,
                nativeBufferSeconds: Double? = nil, decodedVideoSeconds: Double? = nil,
                sourceWindowBytes: Int? = nil, networkMbps: Double? = nil,
                frameDelaySeconds: Double? = nil, nativeFrameRecoveryEnabled: Bool = false) {
        self.route = route
        self.decoder = decoder
        self.bytesRead = bytesRead
        self.displayedFrames = displayedFrames
        self.droppedFrames = droppedFrames
        self.nativeBufferSeconds = nativeBufferSeconds
        self.decodedVideoSeconds = decodedVideoSeconds
        self.sourceWindowBytes = sourceWindowBytes
        self.networkMbps = networkMbps
        self.frameDelaySeconds = frameDelaySeconds
        self.nativeFrameRecoveryEnabled = nativeFrameRecoveryEnabled
    }
}
