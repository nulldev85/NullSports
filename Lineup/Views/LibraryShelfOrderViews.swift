import SwiftUI

/// Moving the Library's rows into the order the viewer wants them, and
/// naming them as they like.
///
/// The phone drags them, as any list on iPhone is reordered, and a tap
/// renames one. The television has no drag: a row is picked up with Select,
/// carried with up and down, and set down with Select again; holding Select
/// renames it.
struct LibraryShelfOrderSheet: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MediaLibrary.LibraryRow] = []
    /// The row being renamed, and the name being typed for it.
    @State private var renaming: MediaLibrary.LibraryRow?
    @State private var newName = ""
    #if os(tvOS)
    /// The row being carried, if one is.
    @State private var carrying: String?
    @FocusState private var focused: String?
    #endif

    var body: some View {
        #if os(tvOS)
        television
        #else
        phone
        #endif
    }

    private func save() {
        media.saveShelfOrder(rows.map(\.id))
    }

    private func reset() {
        media.resetShelfOrder()
        withAnimation(.easeInOut(duration: 0.25)) { rows = media.libraryRows }
    }

    private func startRenaming(_ row: MediaLibrary.LibraryRow) {
        newName = row.title
        renaming = row
    }

    /// The typed name, or with nothing typed, the row's own back.
    private func rename(_ row: MediaLibrary.LibraryRow, to name: String) {
        let original = row.originalTitle ?? row.title
        media.renameShelf(id: row.id, to: name.trimmingCharacters(in: .whitespaces) == original ? "" : name)
        rows = media.libraryRows
        renaming = nil
    }

    #if !os(tvOS)
    private var phone: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        Button { startRenaming(row) } label: {
                            LibraryShelfOrderRow(row: row)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(LineupStyle.raised)
                    }
                    .onMove { from, to in
                        rows.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                } footer: {
                    Text("Tap a row to rename it, or drag it to move it. Your iPhone and Apple TV share these.")
                        .font(.inter(12))
                        .foregroundStyle(LineupStyle.secondary)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(LineupStyle.background.ignoresSafeArea())
            .navigationTitle("Edit Shelves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset", action: reset).disabled(media.shelfOrder.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction).fontWeight(.semibold)
                }
            }
        }
        .tint(LineupStyle.highlight)
        .onAppear { rows = media.libraryRows }
        .alert("Rename Shelf", isPresented: Binding(get: { renaming != nil },
                                                   set: { if !$0 { renaming = nil } }),
               presenting: renaming) { row in
            TextField(row.originalTitle ?? row.title, text: $newName)
                .textInputAutocapitalization(.words)
            Button("Save") { rename(row, to: newName) }
            if row.title != (row.originalTitle ?? row.title) {
                Button("Use Original Name") { rename(row, to: "") }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { row in
            Text("Originally “\(row.originalTitle ?? row.title)”.")
        }
    }
    #endif

    #if os(tvOS)
    private var television: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EDIT SHELVES").font(.inter(12, .heavy)).tracking(1.6)
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
                    Text(carrying == nil ? "Select a row to move it · hold Select to rename it"
                                         : "Move it up or down, then select to set it down")
                        .font(.inter(22, .semibold)).lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer()
                if carrying == nil, !media.shelfOrder.isEmpty {
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: reset) {
                        LibraryShelfOrderChip(title: "Reset", symbol: "arrow.counterclockwise")
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 22)
            .lineupFocusRegion()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            televisionRow(row, index: index)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 12)
                }
                .onChange(of: rows.map(\.id)) { _, _ in
                    guard let carrying else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(carrying, anchor: .center) }
                }
            }
            .lineupFocusRegion()
        }
        .frame(maxWidth: 1180, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        // Back sets a carried row down where it is; with none carried it
        // closes the screen.
        .onExitCommand {
            if carrying != nil { setDown() } else { dismiss() }
        }
        .onAppear {
            rows = media.libraryRows
            focused = rows.first?.id
        }
        .sheet(item: $renaming) { row in
            TVShelfRenameSheet(row: row, name: $newName,
                               onSave: { rename(row, to: newName) },
                               onRestore: { rename(row, to: "") },
                               onCancel: { renaming = nil })
        }
    }

    private func televisionRow(_ row: MediaLibrary.LibraryRow, index: Int) -> some View {
        let isCarried = carrying == row.id
        let isFocused = focused == row.id
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return LibraryShelfOrderRow(row: row, position: index + 1, carried: isCarried)
            .padding(.horizontal, 22)
            .frame(height: 78)
            .background(isCarried ? LineupStyle.focused : LineupStyle.surface, in: shape)
            .overlay(shape.strokeBorder(isCarried ? LineupStyle.focusEdge : LineupStyle.line,
                                        lineWidth: isCarried ? 2 : 1))
            .lineupFocusLayer(isFocused && !isCarried, in: shape)
            .opacity(carrying == nil || isCarried ? 1 : 0.45)
            .contentShape(shape)
            // While a row is carried it is the only thing that can hold
            // focus, so up and down move the row instead of the focus.
            .focusable(carrying == nil || isCarried)
            .focused($focused, equals: row.id)
            .focusEffectDisabled()
            .onTapGesture {
                if isCarried { setDown() } else { carrying = row.id }
            }
            .contextMenu {
                if carrying == nil {
                    Button("Rename", systemImage: "pencil") { startRenaming(row) }
                }
            }
            .onMoveCommand { direction in
                guard isCarried else { return }
                switch direction {
                case .up: step(row.id, by: -1)
                case .down: step(row.id, by: 1)
                default: break
                }
            }
            .scaleEffect(isCarried ? 1.03 : (isFocused ? LineupStyle.cardLift : 1))
            .lineupShadow(.lifted, on: isCarried)
            .zIndex(isCarried ? 10 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isCarried)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isFocused)
    }

    private func step(_ id: String, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let ids = LibraryShelfOrder.move(rows.map(\.id), from: index, by: offset)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            rows = ids.compactMap { byID[$0] }
        }
    }

    private func setDown() {
        let id = carrying
        carrying = nil
        save()
        focused = id
    }
    #endif
}

/// A row as the reorder screen lists it: what it is, its name, and where
/// it comes from.
private struct LibraryShelfOrderRow: View {
    let row: MediaLibrary.LibraryRow
    var position: Int? = nil
    var carried = false

    var body: some View {
        HStack(spacing: Metrics.gap) {
            Group {
                if let brand = row.brand {
                    MediaServerLogo(brand: brand)
                } else {
                    Image(systemName: row.symbol)
                        .font(.system(size: Metrics.symbolSize, weight: .semibold))
                        .foregroundStyle(LineupStyle.secondary)
                }
            }
            .frame(width: Metrics.iconSize, height: Metrics.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.inter(Metrics.titleSize, .semibold))
                    .foregroundStyle(LineupStyle.text)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.inter(Metrics.detailSize, .medium))
                        .foregroundStyle(LineupStyle.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            #if os(tvOS)
            if carried {
                VStack(spacing: 2) {
                    Image(systemName: "chevron.up")
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LineupStyle.text)
            } else if let position {
                Text("\(position)")
                    .font(.interDigits(18, .semibold))
                    .foregroundStyle(LineupStyle.secondary)
            }
            #endif
        }
        .accessibilityElement(children: .combine)
    }

    private enum Metrics {
        #if os(tvOS)
        static let gap: CGFloat = 18
        static let iconSize: CGFloat = 30
        static let symbolSize: CGFloat = 22
        static let titleSize: CGFloat = 24
        static let detailSize: CGFloat = 16
        #else
        static let gap: CGFloat = 12
        static let iconSize: CGFloat = 22
        static let symbolSize: CGFloat = 16
        static let titleSize: CGFloat = 16
        static let detailSize: CGFloat = 12
        #endif
    }
}

#if os(tvOS)
/// Naming a row on the television: its name to type over, and the way back
/// to its own.
private struct TVShelfRenameSheet: View {
    let row: MediaLibrary.LibraryRow
    @Binding var name: String
    let onSave: () -> Void
    let onRestore: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RENAME SHELF").font(.inter(12, .heavy)).tracking(1.6)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
                Text("Originally “\(row.originalTitle ?? row.title)”")
                    .font(.inter(20)).foregroundStyle(LineupStyle.secondary)
            }
            TextField(row.originalTitle ?? row.title, text: $name)
                .font(.inter(26, .semibold))
                .onSubmit(onSave)
            HStack(spacing: 18) {
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: onSave) {
                    LibraryShelfOrderChip(title: "Save", symbol: "checkmark")
                }
                if row.title != (row.originalTitle ?? row.title) {
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: onRestore) {
                        LibraryShelfOrderChip(title: "Use Original Name", symbol: "arrow.uturn.backward")
                    }
                }
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: onCancel) {
                    LibraryShelfOrderChip(title: "Cancel", symbol: "xmark")
                }
            }
            .lineupFocusRegion()
        }
        .padding(60)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        .onExitCommand(perform: onCancel)
    }
}

/// A small control in the reorder screen's heading.
private struct LibraryShelfOrderChip: View {
    let title: String
    let symbol: String
    @Environment(\.lineupTVSelectableFocused) private var focused

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.inter(20, .semibold))
            .foregroundStyle(LineupStyle.text)
            .padding(.horizontal, 22)
            .frame(height: 50)
            .background(Capsule().fill(LineupStyle.surface))
            .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 1))
            .lineupFocusLayer(focused, in: Capsule())
    }
}
#endif
