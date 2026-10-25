#if os(tvOS)
import SwiftUI

extension MediaLibrary {
    /// Collections, in a movie's or show's hold menu: the picker of the
    /// viewer's own collections for it.
    func tvCollectionChoice(for item: MediaItem) -> TVChoice? {
        guard ["Movie", "Series"].contains(item.type) else { return nil }
        return TVChoice("Collections", symbol: "folder") { self.collectionSelectionItem = item }
    }
}

/// The viewer's own collections and their servers' own, from Settings ›
/// Library. Collections of the viewer's own are kept on this Apple TV, as the
/// phone keeps its own; a server's are opened as they are, never changed.
struct TVCollectionsScreen: View {
    @Environment(MediaLibrary.self) private var media
    @State private var openedPersonal: UUID?
    @State private var openedServer: MediaItem?
    @State private var newName = ""
    @State private var renaming: TVCollectionRename?
    @State private var deleting: MobileLibraryCollection?

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 64) {
                VStack(alignment: .leading, spacing: 0) {
                    LineupIconTile(symbol: "folder.fill", size: 72)
                    Text("Collections").font(.inter(44, .bold)).padding(.top, 26)
                    Text("Hold Select on a movie or show and choose Collections to add it. Your collections are kept on this Apple TV.")
                        .font(.inter(21)).foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    Text("NEW COLLECTION").font(.inter(17, .heavy)).tracking(1)
                        .foregroundStyle(LineupPanelStyle.caption).padding(.top, 36)
                    TVCollectionNameField(name: $newName, action: "Create") {
                        if media.createCollection(named: newName) != nil { newName = "" }
                    }
                    .padding(.top, 12)
                }
                .frame(width: 520, alignment: .leading)
                list.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 90).padding(.top, 70)
            .foregroundStyle(LineupPresentationStyle.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LineupPresentationStyle.ground.ignoresSafeArea())
            .navigationDestination(item: $openedPersonal) { TVPersonalCollectionScreen(id: $0) }
            .navigationDestination(item: $openedServer) { MediaBrowseDestination(item: $0) }
        }
        .lineupFullScreenCover(item: $renaming) { rename in
            TVCollectionRenameScreen(rename: rename).environment(media)
        }
        .tvChoices("Delete \(deleting?.name ?? "collection")?", symbol: "trash",
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   message: "Its titles stay where they are; only the collection goes.") {
            guard let collection = deleting else { return [] }
            return [TVChoice("Delete Collection", symbol: "trash", isDestructive: true) {
                media.personalCollections.removeAll { $0.id == collection.id }
            }]
        }
        // Holding a title inside a collection offers Collections too.
        .lineupFullScreenCover(item: Bindable(media).collectionSelectionItem) { item in
            TVCollectionPicker(item: item).environment(media)
        }
        .onAppear { media.collectionsScreenShown = true }
        .onDisappear { media.collectionsScreenShown = false }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("MY COLLECTIONS").font(.inter(17, .heavy)).tracking(1).foregroundStyle(LineupPanelStyle.caption)
                if media.personalCollections.isEmpty {
                    Text("None yet. Name one on the left, or hold Select on a movie or show.")
                        .font(.inter(20)).foregroundStyle(LineupPresentationStyle.secondary).padding(.vertical, 10)
                }
                ForEach(media.personalCollections) { collection in
                    TVSelectable(scale: LineupStyle.cardLift, fillRadius: LineupPanelStyle.radius,
                                 action: { openedPersonal = collection.id }) {
                        TVCollectionRow(name: collection.name, detail: Self.count(collection.items.count),
                                        symbol: "folder.fill", covers: Array(collection.items.prefix(3)))
                    }
                    .tvHoldMenu(collection.name, symbol: "folder") {
                        [TVChoice("Rename", symbol: "pencil") {
                            renaming = TVCollectionRename(id: collection.id, name: collection.name)
                         },
                         TVChoice("Delete Collection", symbol: "trash", isDestructive: true) { deleting = collection }]
                    }
                }
                if !media.collections.isEmpty {
                    Text("FROM YOUR SERVERS").font(.inter(17, .heavy)).tracking(1)
                        .foregroundStyle(LineupPanelStyle.caption).padding(.top, 22)
                    ForEach(media.collections, id: \.libraryKey) { collection in
                        TVSelectable(scale: LineupStyle.cardLift, fillRadius: LineupPanelStyle.radius,
                                     action: { openedServer = collection }) {
                            TVCollectionRow(name: collection.name,
                                            detail: media.profiles.first { $0.id == collection.serverID }?.name
                                                ?? "Server collection",
                                            symbol: "externaldrive.fill", server: collection)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).padding(.bottom, 70)
        }
        .scrollIndicators(.hidden)
    }

    static func count(_ titles: Int) -> String { titles == 1 ? "1 title" : "\(titles) titles" }
}

/// One collection in the list: up to three of its posters, or its symbol.
private struct TVCollectionRow: View {
    @Environment(MediaLibrary.self) private var media
    let name: String
    let detail: String
    let symbol: String
    var covers: [MediaItem] = []
    var server: MediaItem? = nil

    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                LineupPresentationStyle.row
                Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(LineupStyle.highlight)
                if !covers.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(covers, id: \.libraryKey) { item in
                            Color.clear.overlay {
                                TVRatedPoster(url: media.betterPosterURL(for: item),
                                              fallback: media.imageURL(for: item, width: 240), width: 80) { image in
                                    if let image { image.resizable().scaledToFill() }
                                }
                            }
                            .clipped()
                        }
                    }
                } else if let server, server.posterURL != nil || server.imageTags?["Primary"] != nil {
                    LineupArtView(url: media.imageURL(for: server, width: 480), width: 240) { image in
                        if let image { image.resizable().scaledToFill() }
                    }
                }
            }
            .frame(width: 240, height: 135)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.inter(25, .bold)).lineLimit(2)
                Text(detail).font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 20, weight: .bold))
                .foregroundStyle(LineupPresentationStyle.secondary)
        }
        .padding(20)
        .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
    }
}

/// A collection of the viewer's own, as a grid of its titles.
private struct TVPersonalCollectionScreen: View {
    @Environment(MediaLibrary.self) private var media
    let id: UUID
    private var collection: MobileLibraryCollection? { media.personalCollections.first { $0.id == id } }

    var body: some View {
        if let collection, !collection.items.isEmpty {
            MediaGridScreen(title: collection.name, items: collection.items)
        } else {
            VStack(spacing: 18) {
                Image(systemName: "folder").font(.system(size: 54)).foregroundStyle(LineupPresentationStyle.secondary)
                Text(collection?.name ?? "Collection").font(.inter(34, .bold))
                Text("Hold Select on a movie or show in Library, then choose Collections to add it here.")
                    .font(.inter(21)).foregroundStyle(LineupPresentationStyle.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 720)
            }
            .foregroundStyle(LineupPresentationStyle.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LineupPresentationStyle.ground.ignoresSafeArea())
        }
    }
}

/// Which of the viewer's collections a movie or show is in, each one
/// switched by Select, and a new one named and added to at once.
struct TVCollectionPicker: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var newName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                TVRatedPoster(url: media.betterPosterURL(for: item), fallback: media.imageURL(for: item, width: 360),
                              width: 240) { image in
                    if let image { image.resizable().scaledToFill() } else { LineupPresentationStyle.row }
                }
                .frame(width: 240, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("COLLECTIONS").font(.inter(17, .heavy)).tracking(1)
                    .foregroundStyle(LineupPanelStyle.caption).padding(.top, 28)
                Text(item.name).font(.inter(36, .bold)).lineLimit(3).padding(.top, 6)
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { dismiss() }) {
                    TVCollectionButtonLabel(title: "Done", prominent: true)
                }
                .frame(width: 220).padding(.top, 30)
            }
            .frame(width: 520, alignment: .leading)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("MY COLLECTIONS").font(.inter(17, .heavy)).tracking(1).foregroundStyle(LineupPanelStyle.caption)
                    ForEach(media.personalCollections) { collection in
                        let included = media.isInCollection(item, collection.id)
                        TVSelectable(scale: LineupStyle.cardLift, fillRadius: 20,
                                     action: { media.setInCollection(!included, item: item, collection: collection.id) },
                                     requestInitialFocus: collection.id == media.personalCollections.first?.id) {
                            HStack(spacing: 18) {
                                LineupIconTile(symbol: "folder.fill", size: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(collection.name).font(.inter(23, .semibold)).lineLimit(1)
                                    Text(TVCollectionsScreen.count(collection.items.count))
                                        .font(.inter(17)).foregroundStyle(LineupPresentationStyle.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(included ? LineupStyle.highlight : LineupPresentationStyle.secondary)
                            }
                            .padding(22)
                            .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .accessibilityValue(included ? "In this collection" : "Not in this collection")
                    }
                    Text("NEW COLLECTION").font(.inter(17, .heavy)).tracking(1)
                        .foregroundStyle(LineupPanelStyle.caption).padding(.top, 22)
                    TVCollectionNameField(name: $newName, action: "Create and Add") {
                        if media.createCollection(named: newName, adding: item) != nil { newName = "" }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10).padding(.bottom, 70)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90).padding(.top, 70)
        .foregroundStyle(LineupPresentationStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
    }
}

/// A name for a collection, typed with the television's keyboard, and the
/// button that makes it.
private struct TVCollectionNameField: View {
    @Binding var name: String
    let action: String
    let submit: () -> Void

    private var valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Collection name", text: $name)
                .font(.inter(23))
                .onSubmit { if valid { submit() } }
            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                         action: { if valid { submit() } }) {
                TVCollectionButtonLabel(title: action, symbol: "folder.badge.plus", prominent: valid)
            }
            .accessibilityHint(valid ? "" : "Type a name first")
        }
    }
}

private struct TVCollectionButtonLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    var symbol: String? = nil
    var prominent = false

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 12) {
            if let symbol { Image(systemName: symbol).font(.system(size: 21, weight: .bold)) }
            Text(title).font(.inter(21, .semibold)).lineLimit(1)
        }
        .foregroundStyle(prominent ? LineupStyle.onHighlight : LineupPresentationStyle.text)
        .padding(.horizontal, 24).frame(maxWidth: .infinity).frame(height: 58)
        .background(prominent ? LineupStyle.highlight : LineupPresentationStyle.row, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// A collection being renamed.
private struct TVCollectionRename: Identifiable {
    let id: UUID
    let name: String
}

private struct TVCollectionRenameScreen: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    let rename: TVCollectionRename
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LineupIconTile(symbol: "pencil", size: 60)
            Text("Rename Collection").font(.inter(40, .bold))
            TVCollectionNameField(name: $name, action: "Save") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = media.personalCollections.firstIndex(where: { $0.id == rename.id }) {
                    media.personalCollections[index].name = trimmed
                }
                dismiss()
            }
        }
        .frame(width: 720, alignment: .leading)
        .foregroundStyle(LineupPresentationStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .onAppear { name = rename.name }
    }
}
#endif
