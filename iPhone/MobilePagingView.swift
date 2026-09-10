import SwiftUI
import UIKit

/// UIKit's interactive paging supplies finger tracking, deceleration and cancellation.
struct MobilePagingView: UIViewControllerRepresentable {
    @Binding var selection: Int
    let pages: [AnyView]
    let allowsPaging: Bool
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> MobilePageController {
        let pager = MobilePageController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        context.coordinator.controllers = pages.map {
            let host = UIHostingController(rootView: $0)
            host.view.backgroundColor = UIColor(LineupStyle.background)
            return host
        }
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.setViewControllers([context.coordinator.controllers[selection]], direction: .forward, animated: false)
        return pager
    }
    func updateUIViewController(_ pager: MobilePageController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        for (index, page) in pages.enumerated() { coordinator.controllers[index].rootView = page }
        pager.pagingEnabled = allowsPaging
        pager.configureGestures()
        coordinator.showSelection(in: pager)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MobilePagingView
        var controllers: [UIHostingController<AnyView>] = []
        var transitioning = false
        var swipeOrigin: Int?
        init(_ parent: MobilePagingView) { self.parent = parent }
        func showSelection(in pager: UIPageViewController) {
            guard !transitioning, let current = pager.viewControllers?.first,
                  let index = controllers.firstIndex(where: { $0 === current }), index != parent.selection else { return }
            transitioning = true
            let target = parent.selection
            pager.setViewControllers([controllers[target]], direction: target > index ? .forward : .reverse,
                                     animated: !parent.reduceMotion) { [weak self, weak pager] _ in
                guard let self, let pager else { return }
                self.transitioning = false
                // Honor the latest tab tap if it arrived during an animation.
                self.showSelection(in: pager)
            }
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard parent.allowsPaging, let index = controllers.firstIndex(where: { $0 === viewController }), index > 0 else { return nil }
            return controllers[index - 1]
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard parent.allowsPaging, let index = controllers.firstIndex(where: { $0 === viewController }), index + 1 < controllers.count else { return nil }
            return controllers[index + 1]
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            swipeOrigin = parent.selection
        }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            guard let visible = pageViewController.viewControllers?.first,
                  let index = controllers.firstIndex(where: { $0 === visible }) else { return }
            let tappedDuringSwipe = swipeOrigin.map { $0 != parent.selection } ?? false
            swipeOrigin = nil
            if tappedDuringSwipe { showSelection(in: pageViewController) }
            else { parent.selection = index }
        }
    }
}

final class MobilePageController: UIPageViewController {
    var pagingEnabled = true
    override var childForStatusBarHidden: UIViewController? { viewControllers?.first }
    override var childForHomeIndicatorAutoHidden: UIViewController? { viewControllers?.first }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configureGestures()
    }
    func configureGestures() {
        guard let pagingScroll = view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
        pagingScroll.isScrollEnabled = pagingEnabled
        // Guide timeline and league-strip drags stay with their horizontal scroll
        // view. Swipe elsewhere (including the header) to switch app pages.
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll !== pagingScroll,
               scroll.contentSize.width > scroll.bounds.width + 1 {
                pagingScroll.panGestureRecognizer.require(toFail: scroll.panGestureRecognizer)
            }
            view.subviews.forEach(visit)
        }
        viewControllers?.forEach { visit($0.view) }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
}
