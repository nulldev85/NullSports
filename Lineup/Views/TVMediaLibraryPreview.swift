import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

#if os(tvOS)
/// Owns the rapidly changing focus preview outside the catalog view tree. A
/// remote move now redraws the two cinematic layers only; it does not ask
/// every shelf and poster to recompute while focus is in motion.
@MainActor
final class TVMediaPreviewState: ObservableObject {
    @Published private(set) var item: MediaItem?
    private var details: [String: MediaItem] = [:]
    private var focusedPosterIDs: Set<String> = []
    private var detailLoad: Task<Void, Never>?

    func setInitial(_ initial: MediaItem?) {
        guard item == nil else { return }
        item = initial.flatMap { details[$0.libraryKey] } ?? initial
    }

    func reset(to initial: MediaItem?) {
        detailLoad?.cancel()
        focusedPosterIDs.removeAll()
        details.removeAll(keepingCapacity: true)
        item = initial
    }

    func focus(_ focusedItem: MediaItem, focused: Bool,
               load: @escaping @MainActor (MediaItem) async -> MediaItem?) {
        let key = focusedItem.libraryKey
        if focused { focusedPosterIDs.insert(key) }
        else { focusedPosterIDs.remove(key) }
        guard focused else { return }
        // Back on the title already shown: whatever was about to replace it
        // is no longer wanted.
        detailLoad?.cancel()
        guard item?.libraryKey != key else { return }
        detailLoad = Task { @MainActor [weak self] in
            // A swipe crosses several titles in a fraction of a second, and
            // each one swapped the whole screen's artwork and words -- a
            // full-screen picture fetched and decoded for a title the remote
            // had already left, while the posters waited behind it. The room
            // changes once the remote has stopped, which on a single press is
            // too soon to notice.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.item = self.details[key] ?? focusedItem
            guard self.details[key] == nil else { return }
            // Rich metadata waits a little longer again.
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard !Task.isCancelled, let loaded = await load(focusedItem),
                  !Task.isCancelled, self.item?.libraryKey == key else { return }
            self.details[key] = loaded
            self.item = loaded
        }
    }

    func rotate(to next: MediaItem,
                load: @escaping @MainActor (MediaItem) async -> MediaItem?) {
        let key = next.libraryKey
        detailLoad?.cancel()
        item = details[key] ?? next
        guard details[key] == nil else { return }
        detailLoad = Task { [weak self] in
            guard let loaded = await load(next), !Task.isCancelled,
                  self?.item?.libraryKey == key else { return }
            self?.details[key] = loaded
            self?.item = loaded
        }
    }
}

/// Artwork stays behind the bounded foreground, so its size cannot move the
/// Library's controls or cover the top navigation.
struct TVMediaLibraryCanvas: View {
    @ObservedObject var preview: TVMediaPreviewState

    var body: some View {
        TVMediaCinematicBackdrop(item: preview.item)
    }
}

/// What the Library's prefetch follows: the shelf shown, and how many there
/// are to fetch from.
struct TVShelfPrefetchKey: Equatable {
    let index: Int
    let count: Int
}

/// Where the Library's remote can be.
enum TVLibraryFocus: Hashable {
    case hero
    case card(Int)
    /// The strip along the top of the shelf, which turns Up from a card
    /// into the shelf before.
    case shelfAbove
}

/// One shelf the Library's row can show.
struct TVLibraryShelf: Identifiable {
    let id: String
    let title: String
    let label: String?
    let items: [MediaItem]
    /// Continue Watching opens a show's page rather than its streams.
    let opensPages: Bool
    let catalog: MediaCatalog?
}

/// The artwork plane behind both Library browsing and the selected-title page.
/// It is fixed while shelves move, so focus changes the room rather than
/// repainting a rectangle behind one row.
struct TVMediaCinematicBackdrop: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem?

    var body: some View {
        // The picture fills the ground and is cut to it. Drawn as an overlay
        // it can't size the ground: filled straight into a stack, a picture
        // not the screen's shape -- a poster where there is no backdrop --
        // made the stack taller than the screen.
        LineupStyle.background
            .overlay {
                if let item {
                    LineupArtView(url: media.backdropURL(for: item, width: 1920)
                                  ?? media.imageURL(for: item, width: 1920), width: 1920) { loaded in
                        if let loaded { loaded.resizable().scaledToFill() }
                        else { Color.clear }
                    }
                    .id(item.libraryKey)
                    .transition(.opacity)
                }
            }
            .clipped()
            .overlay { shade }
            .animation(LibraryHeroRotation.animation(reduceMotion: reduceMotion), value: item?.libraryKey)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// Dark from the left for the words, and from the foot for the shelf.
    private var shade: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.9), location: 0),
                .init(color: .black.opacity(0.58), location: 0.38),
                .init(color: .black.opacity(0.08), location: 0.78),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .clear, location: 0.42),
                .init(color: LineupStyle.background.opacity(0.42), location: 0.7),
                .init(color: LineupStyle.background.opacity(0.88), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Focused-title context that stays above the shelves. Sparse catalog entries
/// show what they have immediately; the detail fetch enriches the same view
/// with logo, cast and metadata without changing its geometry.
struct TVMediaLibraryPreview: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let originalItem: MediaItem?
    private var item: MediaItem? { originalItem.map { media.displayItem($0) } }
    /// Browsing: every title takes the same room, told from the top, so
    /// nothing moves as the remote goes from title to title or as a title's
    /// ratings, details and cast arrive -- each has its place kept for it,
    /// and only what is in it changes. The title page leaves this off and
    /// sits its words on the actions beneath them.
    var steady = false
    var compact = false

    init(item: MediaItem?, steady: Bool = false, compact: Bool = false) {
        originalItem = item
        self.steady = steady
        self.compact = compact
    }
    /// Each title's ratings once found. The hero moves on every few seconds
    /// and comes back round, and a title it has shown keeps its chips.
    @State private var ratings: [String: MediaRatings] = [:]

    var body: some View {
        Group {
            if let item {
                VStack(alignment: steady ? .center : .leading, spacing: compact ? 10 : 13) {
                    titleLockup(item)
                    ratingsRow(item)
                    metadataLine(item)
                    overviewText(item)
                    if steady {
                        Color.clear.frame(height: 44)
                            .overlay(alignment: .center) { castLine(item) }
                    } else {
                        castLine(item)
                    }
                }
                .id(item.libraryKey)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: steady ? nil : .infinity,
                       alignment: steady ? .center : .bottomLeading)
                .padding(.horizontal, 72)
                .padding(.top, steady ? 0 : 112)
                .padding(.bottom, steady ? 0 : 24)
            }
        }
        .animation(LibraryHeroRotation.animation(reduceMotion: reduceMotion), value: item?.libraryKey)
        .task(id: originalItem.map { media.metadataRequestKey(for: $0) }) {
            guard let item else { return }
            await media.resolveMetadata(for: item)
            guard !Task.isCancelled else { return }
            let found = await media.ratings(for: item)
            ratings[item.libraryKey] = found
        }
    }

    @ViewBuilder
    private func titleLockup(_ item: MediaItem) -> some View {
        LineupTitleLogo(item: item, width: 620, height: compact ? 76 : 105,
                        alignment: steady ? .center : .leading) {
            Text(item.name)
                .font(.inter(46, .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(steady ? .center : .leading)
                .shadow(color: .black.opacity(0.72), radius: 12, y: 3)
        }
    }

    @ViewBuilder
    private func ratingsRow(_ item: MediaItem) -> some View {
        let shown = ratings[item.libraryKey] ?? media.knownRatings(for: item)
        if let shown, !shown.isEmpty {
            MediaRatingChips(ratings: shown)
        } else if steady {
            Color.clear.frame(height: MediaRatingMetrics.height)
        }
    }

    @ViewBuilder
    private func metadataLine(_ item: MediaItem) -> some View {
        let parts = metadata(item)
        if !parts.isEmpty || steady {
            Text(parts.isEmpty ? " " : parts.joined(separator: "  ·  "))
                .font(.inter(steady ? 24 : 19, .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .multilineTextAlignment(steady ? .center : .leading)
                .shadow(color: .black.opacity(0.75), radius: 10, y: 2)
        }
    }

    @ViewBuilder
    private func overviewText(_ item: MediaItem) -> some View {
        let overview = item.overview ?? ""
        if !overview.isEmpty || steady {
            Text(overview.isEmpty ? " " : overview)
                .font(.inter(steady ? 26 : 18, .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(compact ? 2 : 3, reservesSpace: steady)
                .multilineTextAlignment(steady ? .center : .leading)
                .frame(maxWidth: steady ? 1080 : 820, alignment: steady ? .center : .leading)
                .shadow(color: .black.opacity(0.75), radius: 10, y: 2)
        }
    }

    /// The year, the genres and the running time, under the ratings.
    private func metadata(_ item: MediaItem) -> [String] {
        [item.productionYear.map(String.init),
         item.genres?.prefix(3).joined(separator: ", "),
         item.formattedRuntime,
         item.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func castLine(_ item: MediaItem) -> some View {
        let actors = Array((item.people ?? [])
            .filter { $0.type?.lowercased() == "actor" }.prefix(3))
        if !actors.isEmpty {
            HStack(spacing: 12) {
                HStack(spacing: -8) {
                    ForEach(actors) { person in
                        LineupArtView(url: media.personImageURL(for: person, of: item), width: 72) { loaded in
                            if let loaded { loaded.resizable().scaledToFill() }
                            else { Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.55)) }
                        }
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.62), in: Circle())
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                    }
                }
                Text(actors.map(\.name).joined(separator: ", "))
                    .font(.inter(steady ? 20 : 15, .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
    }
}
#endif
