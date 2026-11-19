import SwiftUI

/// Someone in a Silo title, to open their page.
struct MobileSiloPersonRoute: Hashable {
    let profileID: UUID
    let personID: String
    let name: String
}

/// A cast member's page, as Silo's own app has it: their photo and story, and
/// everything of theirs on the server.
struct MobileSiloPersonScreen: View {
    @Environment(MediaLibrary.self) private var media
    let route: MobileSiloPersonRoute
    @State private var person: SiloPerson?
    @State private var failed: String?
    @State private var pushed: MediaItem?
    @State private var expanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let bio = person?.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(bio).font(.inter(15)).foregroundStyle(LineupStyle.text.opacity(0.86))
                            .lineLimit(expanded ? nil : 5)
                        Button(expanded ? "Less" : "More") { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
                            .font(.inter(14, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                    }
                    .padding(.horizontal, 16)
                }
                titles
            }
            .padding(.top, 12).padding(.bottom, 60)
        }
        .tint(LineupStyle.text)
        .background(LineupStyle.background.ignoresSafeArea())
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .task(id: route) { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            LineupArtView(url: person?.photoURL, width: 110) { loaded in
                if let loaded {
                    loaded.resizable().scaledToFill()
                } else {
                    ZStack {
                        LineupStyle.surface
                        Text(route.name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
                                .map(String.init).joined())
                            .font(.inter(30, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                    }
                }
            }
            .frame(width: 110, height: 146)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(person?.name ?? route.name).font(.inter(26, .heavy)).foregroundStyle(LineupStyle.text)
                    .lineLimit(2).minimumScaleFactor(0.8)
                ForEach(facts, id: \.self) { fact in
                    Text(fact).font(.inter(14, .medium)).foregroundStyle(LineupPanelStyle.quiet)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    /// "Born Nov 11, 1974 · Los Angeles", and when they died.
    private var facts: [String] {
        guard let person else { return [] }
        var lines: [String] = []
        let born = person.born.flatMap(Self.day).map { "Born " + $0 }
        let place = person.birthplace?.trimmingCharacters(in: .whitespaces)
        let first = [born, place?.isEmpty == false ? place : nil].compactMap { $0 }.joined(separator: " · ")
        if !first.isEmpty { lines.append(first) }
        if let died = person.died.flatMap(Self.day) { lines.append("Died " + died) }
        return lines
    }

    private static func day(_ text: String) -> String? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.date(from: String(text.prefix(10)))?.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private var titles: some View {
        if let person {
            if person.titles.isEmpty {
                Text("Nothing else of theirs is on this server.")
                    .font(.inter(15)).foregroundStyle(LineupPanelStyle.quiet).padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("On Your Server").font(.inter(22, .heavy)).foregroundStyle(LineupStyle.text)
                        .padding(.horizontal, 16)
                    LazyVGrid(columns: MobileServerLibraryGrid.columns, spacing: 22) {
                        ForEach(person.titles, id: \.libraryKey) { item in
                            MediaItemCard(item: item)
                                .lineupHoldMenu(item.name, symbol: "film", items: { media.cardMenuItems(for: item) }) {
                                    pushed = item
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        } else if let failed {
            Text(failed).font(.inter(15)).foregroundStyle(LineupPanelStyle.quiet)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(32)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        }
    }

    private func load() async {
        guard person == nil else { return }
        guard let profile = media.profiles.first(where: { $0.id == route.profileID }),
              let client = media.siloClient(for: profile) else {
            failed = "This Silo server isn't connected anymore."
            return
        }
        do {
            var found = try await client.siloPerson(id: route.personID)
            found = SiloPerson(id: found.id, name: found.name, bio: found.bio, born: found.born, died: found.died,
                               birthplace: found.birthplace, photoURL: found.photoURL,
                               titles: found.titles.map { $0.servedBy(profile.id) })
            person = found
        } catch {
            failed = "Couldn't load \(route.name)'s page. " + error.localizedDescription
        }
    }
}
