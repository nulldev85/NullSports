import Foundation

/// Audio hardware changes may wait for a route or an earlier deactivation.
/// Keep their order without making the UI thread wait for the serial queue.
@MainActor
final class MobileAudioSessionWork {
    private let queue = DispatchQueue(label: "Lineup.audioSession", qos: .userInitiated)
    private let activateHardware: @Sendable () throws -> Void
    private let deactivateHardware: @Sendable () -> Void
    private var holders: [ObjectIdentifier: UUID] = [:]
    var holderCount: Int { holders.count }

    init(activate: @escaping @Sendable () throws -> Void,
         deactivate: @escaping @Sendable () -> Void) {
        activateHardware = activate
        deactivateHardware = deactivate
    }

    func activate(for holder: AnyObject) async throws {
        let owner = ObjectIdentifier(holder), request = UUID()
        // Reserve before yielding, so Stop can release a pending activation.
        // A failed older request must not remove a newer lease for this owner.
        holders[owner] = request
        let activate = activateHardware
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do { try activate(); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } catch {
            if holders[owner] == request {
                holders[owner] = nil
                // Other queued activations may have lost their owners while
                // this operation was waiting. Leave no orphan audio session.
                if holders.isEmpty { enqueueDeactivation() }
            }
            throw error
        }
    }

    func deactivate(for holder: AnyObject) {
        guard holders.removeValue(forKey: ObjectIdentifier(holder)) != nil, holders.isEmpty else { return }
        enqueueDeactivation()
    }

    private func enqueueDeactivation() {
        let deactivate = deactivateHardware
        queue.async { deactivate() }
    }

    /// Await already queued hardware changes without occupying the UI actor.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
