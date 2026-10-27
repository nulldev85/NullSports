import Foundation
import AetherEngine

public struct AetherSourceQuality: Sendable {
    public let width: Int
    public let height: Int
    /// Aether's display-normalized rate, not the raw container rational.
    /// In pinned 7.49.0, an exact 24 stays 24; the rest of the film window
    /// returns 23.976.
    public let frameRate: Double?
}

/// Synchronous demuxing stays outside the main actor and behind the FFmpeg
/// framework boundary. The engine closes its input before returning, including
/// cancellation and deadline failures. No player or audio session is created.
public enum AetherSourceProbe {
    public static func quality(url: URL, timeout: TimeInterval) async throws -> AetherSourceQuality {
        let cancellation = ProbeCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            let result = try AetherEngine.probe(url: url,
                limits: ProbeLimits(timeBudget: timeout), cancellation: cancellation)
            return AetherSourceQuality(width: Int(result.videoWidth), height: Int(result.videoHeight),
                                       frameRate: result.videoFrameRate)
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: { cancellation.cancel() })
    }
}
