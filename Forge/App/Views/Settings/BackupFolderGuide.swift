import SwiftUI

/// Shown before the system folder picker, which doesn't explain itself:
/// tapping a folder only goes into it, and "Open" picks the folder you're
/// in. It also starts in Forge's own folder, the one place backups
/// shouldn't go.
struct BackupFolderGuide: View {
    let proceed: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Choose where backups go")
                            .font(.app(.title2, .bold))
                        Text("Pick a folder in iCloud Drive. Every backup is copied there too, so your data is safe even if Forge is deleted.")
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        GuideStep(number: 1, title: "Go to iCloud Drive", detail: "If you don't see it, tap Browse at the bottom, then iCloud Drive.")
                        GuideStep(number: 2, title: "Open the folder you want", detail: "Tap a folder to go inside it. To make a new one, tap ••• at the top, then New Folder.")
                        GuideStep(number: 3, title: "Tap Open at the top right", detail: "That picks the folder you're in. Forge copies each backup there from then on.")
                    }
                    Label("Any folder in iCloud Drive works, even one named Forge. Just not On My iPhone › Forge: that's Forge's own folder, and it's deleted along with the app.", systemImage: "info.circle.fill")
                        .font(.app(.footnote, .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .background(Theme.canvas)
            .safeAreaInset(edge: .bottom) {
                Button {
                    proceed()
                    dismiss()
                } label: {
                    Text("Choose Folder")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .accessibilityIdentifier("openFolderPicker")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .stallContext("Backup folder guide")
        }
        .accessibilityIdentifier("backupFolderGuide")
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.num(.subheadline, .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.app(.body, .semibold))
                Text(detail)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// The backup-folder guide, then the system folder picker once the guide
    /// has closed (it can't open over it); `onPick` gets the chosen folder.
    func backupFolderGuide(isPresented: Binding<Bool>, onPick: @escaping (URL) -> Void) -> some View {
        modifier(BackupFolderGuidePresenter(isPresented: isPresented, onPick: onPick))
    }
}

private struct BackupFolderGuidePresenter: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (URL) -> Void
    @State private var proceeding = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                guard proceeding else { return }
                proceeding = false
                FolderPicker.shared.present(onPick: onPick)
            }) {
                BackupFolderGuide { proceeding = true }
            }
    }
}
