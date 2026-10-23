import UIKit

/// Finger travel, rather than content-offset KVO, keeps refreshes, safe-area
/// changes, programmatic jumps and deceleration from toggling the navigation.
struct MobileNavigationScrollDirection {
    private var previous = CGPoint.zero
    private var horizontal: Bool?
    private var travel: CGFloat = 0

    mutating func sample(translation: CGPoint, distanceFromTop: CGFloat) -> Bool? {
        let delta = translation.y - previous.y
        previous = translation
        if horizontal == nil, max(abs(translation.x), abs(translation.y)) >= 8 {
            horizontal = abs(translation.x) > abs(translation.y)
        }
        guard horizontal == false else { return nil }
        if distanceFromTop <= 1 {
            travel = 0
            return false
        }
        // Reset at a reversal so a short upward movement restores the bar
        // even during the same long downward drag. Ignore subpixel jitter.
        guard abs(delta) >= 0.5 else { return nil }
        if (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        if travel >= 12 { return false }
        if travel <= -28, distanceFromTop > 8 { return true }
        return nil
    }
}

/// Observe existing scroll recognizers without replacing their delegates or
/// competing with a shelf swipe, Guide timeline, refresh, slider or player.
@MainActor
final class MobileNavigationScrollObserver: NSObject, UIGestureRecognizerDelegate {
    var onChange: ((Bool) -> Void)?
    private(set) var isCompact = false
    private weak var tabs: UITabBarController?
    private var selection: Int?
    private var requestedEnabled = false
    private var keyboardVisible = false
    private var enabled: Bool { requestedEnabled && !keyboardVisible }
    private struct Entry {
        weak var scroll: UIScrollView?
        var direction = MobileNavigationScrollDirection()
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private lazy var discovery: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer()
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func update(tabs: UITabBarController?, selection: Int, enabled: Bool) {
        if self.tabs !== tabs || self.selection != selection || requestedEnabled != enabled {
            removeScrollTargets()
            expand()
        }
        self.tabs = tabs
        self.selection = selection
        requestedEnabled = enabled
        if discovery.view !== tabs?.viewIfLoaded {
            discovery.view?.removeGestureRecognizer(discovery)
            tabs?.viewIfLoaded?.addGestureRecognizer(discovery)
        }
        discovery.isEnabled = self.enabled
    }

    func detach() {
        removeScrollTargets()
        discovery.view?.removeGestureRecognizer(discovery)
        tabs = nil
        requestedEnabled = false
        expand()
    }

    func expand() { setCompact(false) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let view = touch.view { discoverScrollViews(from: view) }
        // This recognizer only discovers the touched scroll ancestry. It
        // rejects every touch before recognition, and never delays controls.
        return false
    }

    func discoverScrollViews(from touchedView: UIView) {
        guard enabled, let root = tabs?.selectedViewController?.viewIfLoaded,
              touchedView.isDescendant(of: root), tabs?.presentedViewController == nil else { return }
        entries = entries.filter { $0.value.scroll != nil }
        var ancestor: UIView? = touchedView
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled {
                let pan = scroll.panGestureRecognizer
                let key = ObjectIdentifier(pan)
                if entries[key] == nil {
                    entries[key] = Entry(scroll: scroll)
                    pan.addTarget(self, action: #selector(scrollPanDidChange(_:)))
                }
            }
            if view === root { break }
            ancestor = view.superview
        }
    }

    @objc func scrollPanDidChange(_ pan: UIPanGestureRecognizer) {
        guard let scroll = entries[ObjectIdentifier(pan)]?.scroll else { return }
        receivePanInput(from: scroll, phase: pan.state, translation: pan.translation(in: discovery.view))
    }

    func receivePanInput(from scroll: UIScrollView, phase: UIGestureRecognizer.State, translation: CGPoint) {
        let pan = scroll.panGestureRecognizer
        let key = ObjectIdentifier(pan)
        guard enabled, var entry = entries[key], entry.scroll === scroll,
              let root = tabs?.selectedViewController?.viewIfLoaded,
              scroll.isDescendant(of: root), scroll.window != nil,
              scroll.isScrollEnabled, tabs?.presentedViewController == nil else { return }
        switch phase {
        case .began:
            entry.direction = MobileNavigationScrollDirection()
        case .changed: break
        default:
            entry.direction = MobileNavigationScrollDirection()
            entries[key] = entry
            return
        }
        let insets = scroll.adjustedContentInset
        let range = scroll.contentSize.height + insets.top + insets.bottom - scroll.bounds.height
        // Horizontal shelves may bounce vertically but do not have a vertical
        // scroll range. The nested Guide's vertical list still qualifies.
        guard range > 1, scroll.bounds.height > 0 else { return }
        let distance = scroll.contentOffset.y + insets.top
        if let compact = entry.direction.sample(translation: translation, distanceFromTop: distance) {
            setCompact(compact)
        }
        entries[key] = entry
    }

    private func setCompact(_ compact: Bool) {
        guard isCompact != compact else { return }
        isCompact = compact
        onChange?(compact)
    }

    private func removeScrollTargets() {
        for entry in entries.values {
            entry.scroll?.panGestureRecognizer.removeTarget(self, action: #selector(scrollPanDidChange(_:)))
        }
        entries.removeAll()
    }

    @objc private func keyboardWillShow() {
        keyboardVisible = true
        discovery.isEnabled = false
        removeScrollTargets()
        expand()
    }

    @objc private func keyboardWillHide() {
        keyboardVisible = false
        discovery.isEnabled = enabled
    }
}
