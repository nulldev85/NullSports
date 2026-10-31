import SwiftUI
import UIKit

struct TVTickerEntry {
    let game: SportsGame
    let spacing: Double
}

/// One bounded SwiftUI strip; Core Animation moves it without a per-frame
/// SwiftUI callback. A task advances one cell about every twelve seconds.
struct TVScoreTicker: UIViewControllerRepresentable {
    let events: [SportsGame]
    let active: Bool
    let content: ([TVTickerEntry]) -> AnyView

    func makeUIViewController(context: Context) -> TVScoreTickerController {
        TVScoreTickerController(content: content)
    }

    func updateUIViewController(_ controller: TVScoreTickerController, context: Context) {
        controller.update(events: events, active: active, content: content)
    }

    static func dismantleUIViewController(_ controller: TVScoreTickerController, coordinator: ()) {
        controller.pause()
    }
}

@MainActor
final class TVScoreTickerController: UIViewController {
    static let animationKey = "score-crawl"
    private let strip = UIHostingController(rootView: AnyView(EmptyView()))
    private var content: ([TVTickerEntry]) -> AnyView
    private var events: [SportsGame] = []
    private var cursor = 0
    private var progress = 0.0
    private var active = false
    private var visible = false
    private var viewport = CGSize.zero
    private var advanceTask: Task<Void, Never>?
    private(set) var renderedEntries: [TVTickerEntry] = []
    var hasScheduledAdvance: Bool { advanceTask != nil }
    var animationCount: Int { strip.view.layer.animationKeys()?.count ?? 0 }

    init(content: @escaping ([TVTickerEntry]) -> AnyView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        addChild(strip)
        strip.view.backgroundColor = .clear
        strip.view.isOpaque = false
        view.addSubview(strip.view)
        strip.didMove(toParent: self)
        renderWindow()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard viewport != view.bounds.size else { return }
        pause()
        viewport = view.bounds.size
        renderWindow()
        resume()
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); visible = true; resume() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); visible = false; pause() }

    func update(events updated: [SportsGame], active: Bool,
                content: @escaping ([TVTickerEntry]) -> AnyView) {
        self.content = content
        loadViewIfNeeded()
        if updated != events {
            pause()
            let currentID = events.indices.contains(cursor) ? events[cursor].id : nil
            let replacement = currentID.flatMap { id in updated.firstIndex { $0.id == id } }
            cursor = replacement ?? 0
            if replacement == nil { progress = 0 }
            events = updated
            renderWindow()
        }
        self.active = active
        if active { resume() } else { pause() }
    }

    func pause() {
        let wasAdvancing = advanceTask != nil
        advanceTask?.cancel()
        advanceTask = nil
        guard isViewLoaded else { return }
        let layer = strip.view.layer
        if wasAdvancing || layer.animation(forKey: Self.animationKey) != nil {
            progress = max(0, -Double(layer.presentation()?.transform.m41 ?? layer.transform.m41))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.transform = CATransform3DMakeTranslation(-CGFloat(progress), 0, 0)
        CATransaction.commit()
    }

    private func renderWindow() {
        guard isViewLoaded else { return }
        let indices = TVTickerWindow.indices(count: events.count, start: cursor, viewportWidth: Double(view.bounds.width))
        renderedEntries = indices.map {
            TVTickerEntry(game: events[$0], spacing: TVTickerWindow.stride(at: $0, count: events.count) - TVTickerWindow.cardWidth)
        }
        let width = indices.reduce(0.0) { $0 + TVTickerWindow.stride(at: $1, count: events.count) }
        strip.rootView = content(renderedEntries)
        strip.view.bounds = CGRect(x: 0, y: 0, width: max(view.bounds.width, CGFloat(width)), height: view.bounds.height)
        strip.view.center = CGPoint(x: strip.view.bounds.width / 2, y: view.bounds.height / 2)
    }

    private func resume() {
        guard active, visible, isViewLoaded, view.window != nil, view.bounds.width > 0,
              !events.isEmpty, advanceTask == nil else { return }
        let distance = TVTickerWindow.stride(at: cursor, count: events.count)
        progress = min(progress, distance)
        let duration = max(0.01, (distance - progress) / TVTickerWindow.speed)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -progress
        animation.toValue = -distance
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.view.layer.transform = CATransform3DMakeTranslation(-CGFloat(distance), 0, 0)
        strip.view.layer.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
        advanceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, !Task.isCancelled, self.active, self.view.window != nil, !self.events.isEmpty else { return }
            self.advanceTask = nil
            self.cursor = (self.cursor + 1) % self.events.count
            self.progress = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.strip.view.layer.removeAnimation(forKey: Self.animationKey)
            self.strip.view.layer.transform = CATransform3DIdentity
            self.renderWindow()
            self.strip.view.layoutIfNeeded()
            CATransaction.commit()
            self.resume()
        }
    }
}
