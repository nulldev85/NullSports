import SwiftUI
import UIKit

struct MobileLibraryShelfMetrics: Equatable {
    let width: CGFloat
    let ratio: CGFloat
    let titleHeight: CGFloat
    let metadataHeight: CGFloat
    var cardHeight: CGFloat { width / ratio + titleHeight + metadataHeight + 20 }
    var height: CGFloat { cardHeight + 16 }
}

/// Kept in SwiftUI state without publishing every scroll pixel back through
/// the Library. A lazy vertical stack may recreate the native row later.
final class MobileLibraryShelfPosition {
    var key: String?
    var distance: CGFloat = 0
    var offset: CGFloat = 0
}

struct MobileLibraryShelf: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.mobileHoldMenu) private var holdMenu
    @ScaledMetric(relativeTo: .subheadline) private var titleHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .caption2) private var metadataHeight: CGFloat = 16
    @State private var position = MobileLibraryShelfPosition()
    let items: [MediaItem]
    let shape: MediaArtShape
    var width: CGFloat? = nil
    let onSelect: (MediaItem) -> Void

    var body: some View {
        let metrics = MobileLibraryShelfMetrics(width: width ?? (shape.isPoster ? 150 : 232),
            ratio: shape.ratio, titleHeight: titleHeight, metadataHeight: metadataHeight)
        MobileLibraryShelfView(items: items, shape: shape, metrics: metrics, media: media,
            position: position, holdMenu: holdMenu, onSelect: onSelect)
            .frame(height: metrics.height)
    }
}

/// Fixed-size, recycled cells let UIKit handle horizontal momentum and tap
/// cancellation. Late artwork/title updates cannot resize the scroll content.
struct MobileLibraryShelfView: UIViewRepresentable {
    let items: [MediaItem]
    let shape: MediaArtShape
    let metrics: MobileLibraryShelfMetrics
    let media: MediaLibrary
    let position: MobileLibraryShelfPosition
    let holdMenu: MobileHoldMenu?
    let onSelect: (MediaItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ view: UICollectionView, coordinator: Coordinator) {
        coordinator.scrollViewDidScroll(view)
        (view as? MobileLibraryCollectionView)?.didLayout = nil
        view.prefetchDataSource = nil
        view.delegate = nil
        view.dataSource = nil
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
                             UICollectionViewDataSourcePrefetching {
        private var owner: MobileLibraryShelfView
        private var items: [MediaItem] = []
        private var metrics: MobileLibraryShelfMetrics?
        private var shape: MediaArtShape?
        private var restoring = false
        private var needsRestore = false
        weak var collection: UICollectionView?

        init(_ owner: MobileLibraryShelfView) { self.owner = owner }

        func makeCollectionView() -> UICollectionView {
            let layout = UICollectionViewFlowLayout()
            layout.scrollDirection = .horizontal
            layout.estimatedItemSize = .zero
            layout.minimumLineSpacing = 14
            layout.sectionInset = UIEdgeInsets(top: 8, left: LineupPanelStyle.inset,
                                              bottom: 8, right: LineupPanelStyle.inset)
            let view = MobileLibraryCollectionView(frame: .zero, collectionViewLayout: layout)
            view.backgroundColor = .clear
            view.showsHorizontalScrollIndicator = false
            view.contentInsetAdjustmentBehavior = .never
            view.isDirectionalLockEnabled = true
            view.delaysContentTouches = false
            view.selfSizingInvalidation = .disabled
            view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "poster")
            view.dataSource = self
            view.delegate = self
            view.prefetchDataSource = self
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.minimumPressDuration = 0.4
            hold.allowableMovement = 10
            view.addGestureRecognizer(hold)
            collection = view
            view.didLayout = { [weak self] in self?.didLayout() }
            update(owner, initial: true)
            return view
        }

        func update(_ next: MobileLibraryShelfView, initial: Bool = false) {
            guard let collection else { return }
            owner = next // Actions always use the current screen and item.
            let geometryChanged = metrics != next.metrics || shape != next.shape
            let dataChanged = items != next.items
            guard initial || geometryChanged || dataChanged else {
                for cell in collection.visibleCells {
                    if let path = collection.indexPath(for: cell), items.indices.contains(path.item) {
                        setAccessibility(cell, item: items[path.item])
                    }
                }
                return
            }
            if !initial { rememberPosition() }
            let oldKeys = items.map(\.libraryKey)
            let newKeys = next.items.map(\.libraryKey)
            let changed = next.items.indices.filter { index in
                items.indices.contains(index) && items[index] != next.items[index]
            }
            items = next.items
            metrics = next.metrics
            shape = next.shape
            restoring = true
            UIView.performWithoutAnimation {
                if geometryChanged, let layout = collection.collectionViewLayout as? UICollectionViewFlowLayout {
                    layout.itemSize = CGSize(width: next.metrics.width, height: next.metrics.cardHeight)
                }
                if initial || geometryChanged || oldKeys != newKeys {
                    needsRestore = true
                    collection.reloadData()
                    if collection.bounds.width > 0, collection.bounds.height > 0 {
                        collection.layoutIfNeeded()
                        didLayout()
                    }
                } else if !changed.isEmpty {
                    collection.reconfigureItems(at: changed.map { IndexPath(item: $0, section: 0) })
                }
            }
            restoring = false
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
            let item = items[indexPath.item]
            let size = owner.metrics
            let shape = owner.shape
            let media = owner.media
            cell.contentConfiguration = UIHostingConfiguration {
                MediaItemCard(item: item, shape: shape)
                    .environment(media)
                    .frame(width: size.width, height: size.cardHeight, alignment: .topLeading)
                    .id(item.libraryKey)
                    .allowsHitTesting(false)
            }.margins(.all, 0)
            cell.backgroundColor = .clear
            setAccessibility(cell, item: item)
            cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "More") { [weak self] _ in
                self?.showMenu(key: item.libraryKey) ?? false
            }]
            return cell
        }

        private func setAccessibility(_ cell: UICollectionViewCell, item: MediaItem) {
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = owner.media.displayItem(item).name
            cell.accessibilityValue = owner.media.cardPlayback(for: item,
                asShow: item.isSeries || (owner.shape.isPoster && item.type == "Episode"))?.spoken
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard items.indices.contains(indexPath.item) else { return }
            owner.onSelect(items[indexPath.item])
        }

        @objc func held(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let collection,
                  let index = collection.indexPathForItem(at: gesture.location(in: collection)),
                  items.indices.contains(index.item) else { return }
            if showMenu(key: items[index.item].libraryKey) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }

        @discardableResult private func showMenu(key: String) -> Bool {
            guard let item = items.first(where: { $0.libraryKey == key }), let menu = owner.holdMenu else { return false }
            let choices = owner.media.cardMenuItems(for: item)
            guard !choices.isEmpty else { return false }
            menu.present(owner.media.displayItem(item).name, symbol: item.type == "Episode" ? "tv" : "film",
                         message: nil, items: choices)
            return true
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            // Only nearby cells requested by the scroll view, rather than six
            // posters in every shelf competing with visible artwork at launch.
            for path in indexPaths.prefix(4) where items.indices.contains(path.item) {
                let art = MediaItemCard.art(for: items[path.item], shape: owner.shape, in: owner.media,
                                           scale: collectionView.traitCollection.displayScale)
                LineupArt.prefetch(art.url, pixels: art.pixels)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !restoring, !needsRestore { rememberPosition() }
        }

        func didLayout() {
            guard needsRestore, let collection, collection.bounds.width > 0,
                  collection.bounds.height > 0, collection.bounds.height >= owner.metrics.height - 1 else { return }
            needsRestore = false
            let wasRestoring = restoring
            restoring = true
            restorePosition()
            restoring = wasRestoring
        }

        private func rememberPosition() {
            guard let collection else { return }
            owner.position.offset = collection.contentOffset.x
            guard let first = collection.collectionViewLayout.layoutAttributesForElements(in: collection.bounds)?
                .filter({ $0.representedElementCategory == .cell && $0.frame.maxX > collection.contentOffset.x })
                .min(by: { $0.frame.minX < $1.frame.minX }), items.indices.contains(first.indexPath.item) else { return }
            owner.position.key = items[first.indexPath.item].libraryKey
            owner.position.distance = collection.contentOffset.x - first.frame.minX
        }

        private func restorePosition() {
            guard let collection else { return }
            var offset = owner.position.offset
            if let key = owner.position.key, let index = items.firstIndex(where: { $0.libraryKey == key }),
               let attributes = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
                offset = attributes.frame.minX + owner.position.distance
            }
            collection.setContentOffset(CGPoint(x: max(0, min(offset,
                max(0, collection.contentSize.width - collection.bounds.width))), y: 0), animated: false)
        }
    }
}

final class MobileLibraryCollectionView: UICollectionView {
    var didLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}
