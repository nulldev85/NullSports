import SwiftUI

extension MediaLibrary {
    func collectionMenu(for item: MediaItem) -> MobileMenuItem? {
        guard ["Movie", "Series"].contains(item.type) else { return nil }
        return MobileMenuItem("Collections", symbol: "folder") {
            self.collectionSelectionItem = item
        }
    }
}

struct MobileAddToCollectionView: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let item: MediaItem

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(media.personalCollections) { collection in
                        Toggle(collection.name, isOn: Binding(get: {
                            media.personalCollections.first { $0.id == collection.id }?.items.contains { $0.libraryKey == item.libraryKey } == true
                        }, set: { included in
                            guard let index = media.personalCollections.firstIndex(where: { $0.id == collection.id }) else { return }
                            if included { media.personalCollections[index].add(item) }
                            else { media.personalCollections[index].items.removeAll { $0.libraryKey == item.libraryKey } }
                        }))
                        .tint(LineupStyle.highlight)
                    }
                } header: { Text(item.name).lineupSettingsHeader() }
                  .lineupSettingsRows()
                Section {
                    TextField("Collection name", text: $name).font(.inter(.body))
                    Button("Create and Add", systemImage: "folder.badge.plus") {
                        if media.createCollection(named: name, adding: item) != nil { name = "" }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                } header: { Text("New Collection").lineupSettingsHeader() }
                  .lineupSettingsRows()
            }
            .lineupSettingsList().navigationTitle("Collections").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LineupToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.buttonStyle(LineupBarButtonStyle())
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Server collections keep their original parent IDs and routes. Personal
/// collections keep original source-scoped items and never mutate a server.
struct MobileLibraryCollectionsView: View {
    @Environment(MediaLibrary.self) private var media

    var body: some View {
        List {
            Section {
                Button { media.collectionCreationItem = nil; media.creatingCollection = true } label: {
                    Label("New Collection", systemImage: "folder.badge.plus")
                }
                ForEach(media.personalCollections) { collection in
                    NavigationLink {
                        MobilePersonalCollectionView(id: collection.id)
                    } label: {
                        collectionLabel(collection.name, detail: "\(collection.items.count) titles", symbol: "folder.fill")
                    }
                }
            } header: { Text("My Collections").lineupSettingsHeader() }
              footer: { Text("Hold a movie or show and choose Collections to add it. Collections are saved on this iPhone.").lineupSettingsFooter() }
              .lineupSettingsRows()
            if !media.collections.isEmpty {
                Section {
                    ForEach(media.collections, id: \.libraryKey) { collection in
                        NavigationLink(value: collection) {
                            collectionLabel(collection.name,
                                detail: media.profiles.first { $0.id == collection.serverID }?.name ?? "Server collection",
                                symbol: "externaldrive.fill")
                        }
                    }
                } header: { Text("From Your Servers").lineupSettingsHeader() }
                  .lineupSettingsRows()
            }
        }
        .lineupSettingsList()
        .navigationTitle("Collections").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
    }

    private func collectionLabel(_ name: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            LineupIconTile(symbol: symbol, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.inter(.body, .semibold))
                Text(detail).font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet)
            }
        }.padding(.vertical, 4)
    }
}

struct MobilePersonalCollectionView: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renaming = false
    @State private var deleting = false
    @State private var options = false
    let id: UUID
    private var collection: MobileLibraryCollection? { media.personalCollections.first { $0.id == id } }

    var body: some View {
        Group {
            if let collection, !collection.items.isEmpty {
                MediaGridScreen(title: collection.name, items: collection.items)
            } else {
                ContentUnavailableView("Your Collection", systemImage: "folder",
                    description: Text("Hold a movie or show in Library, then choose Collections to add it here."))
            }
        }
        .background(LineupStyle.background.ignoresSafeArea())
        .navigationTitle(collection?.name ?? "Collection").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LineupToolbarItem(placement: .primaryAction) {
                MobileDropdownButton(isOpen: options, label: "Collection options") { options = true }
            }
        }
        .lineupTextPrompt("Rename Collection", symbol: "folder", isPresented: $renaming,
            text: $name, prompt: "Name", canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80,
            onSave: {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= 80,
                   let index = media.personalCollections.firstIndex(where: { $0.id == id }) {
                    media.personalCollections[index].name = trimmed
                }
            })
        .lineupChoices("Delete collection?", symbol: "trash", isPresented: $deleting) {
            [MobileMenuItem("Delete Collection", isDestructive: true) {
                media.personalCollections.removeAll { $0.id == id }; dismiss()
            }]
        }
        .lineupChoices(collection?.name ?? "Collection", symbol: "folder", isPresented: $options) {
            [MobileMenuItem("Rename", symbol: "pencil") { name = collection?.name ?? ""; renaming = true },
             MobileMenuItem("Delete Collection", symbol: "trash", isDestructive: true) { deleting = true }]
        }
    }
}

/// Compact collection cards lead into a collection instead of another catalog
/// row. No eager fetching of every collection's members on Library startup.
struct MobileLibraryCollectionsRow: View {
    @Environment(MediaLibrary.self) private var media
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LineupIconTile(symbol: "folder.fill", size: 24)
                Text(media.shelfTitle(id: LibraryShelfOrder.collections, default: "Collections").uppercased())
                    .font(.inter(14, .heavy))
                Spacer()
                NavigationLink { MobileLibraryCollectionsView() } label: {
                    Label("See All", systemImage: "chevron.right").font(.inter(14, .bold))
                }.lineupFlatButton()
            }.padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    NavigationLink { MobileLibraryCollectionsView() } label: {
                        tile("My Collections", detail: "Create and organize", symbol: "folder.badge.plus")
                    }.lineupFlatButton()
                    ForEach(media.personalCollections) { collection in
                        NavigationLink { MobilePersonalCollectionView(id: collection.id) } label: {
                            tile(collection.name, detail: "\(collection.items.count) titles", symbol: "folder.fill", covers: Array(collection.items.prefix(3)))
                        }.lineupFlatButton()
                    }
                    ForEach(media.collections.prefix(20), id: \.libraryKey) { collection in
                        NavigationLink(value: collection) {
                            tile(collection.name, detail: "Server collection", symbol: "rectangle.stack.fill", serverCollection: collection)
                        }.lineupFlatButton()
                    }
                }.padding(.horizontal, 18)
            }
        }
        .padding(.vertical, 12)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 18)
    }

    private func tile(_ name: String, detail: String, symbol: String,
                      covers: [MediaItem] = [], serverCollection: MediaItem? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LineupPanelStyle.fill
                Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(LineupStyle.highlight)
                if !covers.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(covers, id: \.libraryKey) { item in
                            Color.clear.overlay {
                                MobileRatedPoster(url: media.betterPosterURL(for: item),
                                    fallback: media.imageURL(for: item, width: 240), pixels: 360) { image in
                                    if let image { image.resizable().scaledToFill() }
                                }
                            }.clipped()
                        }
                    }
                } else if let serverCollection, serverCollection.posterURL != nil || serverCollection.imageTags?["Primary"] != nil {
                    MobileLibraryArtView(url: media.imageURL(for: serverCollection, width: 480), pixels: 480) { image in
                        if let image { image.resizable().scaledToFill() }
                    }
                }
            }
            .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(name).font(.inter(.subheadline, .bold)).lineLimit(2, reservesSpace: true)
            Text(detail).font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
        }
        .frame(width: 205, alignment: .leading).padding(14)
        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundStyle(LineupStyle.text)
    }
}
