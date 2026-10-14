#if os(iOS)
import UIKit
import AVKit
import Combine
import AetherEngine

/// AVKit runs the floating window. Both Aether renderers expose a real content
/// source; no second connection, screen recording, or VLC frame capture is used.
@MainActor
final class AetherPictureInPicture: NSObject, AVPictureInPictureControllerDelegate,
                                    AVPictureInPictureSampleBufferPlaybackDelegate {
    private weak var session: AetherPlaybackSession?
    private var controller: AVPictureInPictureController?
    private var softwareSource: SoftwarePiPSource?
    private var layerID: ObjectIdentifier?
    private var subscriptions = Set<AnyCancellable>()
    private var skipTask: Task<Void, Never>?
    private var transitioning = false
    private(set) var route: String?

    init(session: AetherPlaybackSession) {
        self.session = session
        super.init()
        Publishers.CombineLatest(session.engine.$currentAVPlayer, session.engine.$softwarePiPSource)
            .receive(on: DispatchQueue.main).sink { [weak self] _, _ in self?.refresh() }
            .store(in: &subscriptions)
        session.engine.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.controller?.invalidatePlaybackState()
            guard self.isActive, let session = self.session else { return }
            if session.engine.state == .playing { session.pictureInPictureTransportChanged(playing: true) }
            if session.engine.state == .paused { session.pictureInPictureTransportChanged(playing: false) }
        }.store(in: &subscriptions)
    }

    var isPossible: Bool { controller?.isPictureInPicturePossible == true }
    var isActuallyActive: Bool { controller?.isPictureInPictureActive == true }
    var isActive: Bool { transitioning || controller?.isPictureInPictureActive == true }

    func refresh() {
        guard let session, session.isOpen else { return }
        // Keep AVKit's current source through loading and renderer transitions.
        guard session.phase != .loading, !isActive,
              AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source: AVPictureInPictureController.ContentSource
        let newID: ObjectIdentifier
        let newRoute: String
        if let layer = session.engine.nativePlayerLayer {
            newID = ObjectIdentifier(layer)
            newRoute = "Native"
            guard newID != layerID else { return }
            softwareSource = nil
            source = .init(playerLayer: layer)
        } else if let software = session.engine.softwarePiPSource {
            newID = ObjectIdentifier(software.layer)
            newRoute = "Sample buffer"
            guard newID != layerID else { return }
            softwareSource = software
            source = .init(sampleBufferDisplayLayer: software.layer, playbackDelegate: self)
        } else { return }
        controller = AVPictureInPictureController(contentSource: source)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        layerID = newID
        route = newRoute
    }

    func toggle() {
        refresh()
        guard let controller else { return }
        if isActive { controller.stopPictureInPicture() }
        else if controller.isPictureInPicturePossible { controller.startPictureInPicture() }
    }

    func stop() {
        skipTask?.cancel(); skipTask = nil
        controller?.delegate = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller = nil
        softwareSource = nil
        layerID = nil
        route = nil
        transitioning = false
        session?.engine.pictureInPictureActive = false
        session?.engine.setNativeSubtitleRendering(false)
    }

    private func changed(active: Bool) {
        transitioning = active
        session?.engine.pictureInPictureActive = active
        session?.engine.setNativeSubtitleRendering(active)
        session?.onPictureInPictureChange?(active)
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        changed(active: true)
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        changed(active: true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }
        changed(active: false)
        session?.onPictureInPictureClosed?()
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard controller === self.controller else { return }
        changed(active: false)
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        guard controller === self.controller else { completion(false); return }
        // Lineup retains its player screen behind PiP.
        completion(session?.surface.window != nil)
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard controller === self.controller else { return }
        if playing { session?.play() } else { session?.pause() }
        session?.pictureInPictureTransportChanged(playing: playing)
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        softwareSource?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        softwareSource?.isPaused ?? true
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        skipTask?.cancel()
        guard controller === self.controller, let session, interval.seconds.isFinite else { completionHandler(); return }
        let target = max(0, session.position + interval.seconds)
        skipTask = Task { [weak self] in
            defer { completionHandler() }
            guard let self, self.session === session, !Task.isCancelled else { return }
            await session.engine.seek(to: target)
        }
    }
}
#endif
