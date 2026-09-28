import SwiftUI
import UniformTypeIdentifiers

struct BackupsView: View {
    @Environment(AppModel.self) private var app
    @State private var exportURL: URL?
    @State private var csvURL: URL?
    @State private var showingImporter = false
    @State private var importerMode: ImporterMode = .backupFile

    enum ImporterMode {
        case backupFile, folder
    }
    @State private var pendingImport: BackupArchive?
    @State private var restoring: BackupManager.Snapshot?
    @State private var errorMessage: String?
    @State private var restoreBlocked: String?

    var body: some View {
        let data = app.dataSafety
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your data is protected", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("Every set is written to disk the moment you log it. Forge also keeps daily snapshots on this iPhone and exports a full backup file you can keep anywhere.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        statusLine("Last snapshot", data.snapshots.map(\.date).max().map { $0.formatted(date: .abbreviated, time: .shortened) }
                            ?? (app.settings.value.autoBackupEnabled ? "When you leave the app" : "Off"))
                        statusLine("Last backup file", data.lastExportDate.map { $0.formatted(date: .abbreviated, time: .shortened) }
                            ?? (app.settings.value.autoExportEnabled ? "When you leave the app" : "Off"))
                        statusLine("Backup folder", data.exportFolderName ?? "Files › On My iPhone › Forge")
                    }
                    .font(.caption)
                }
                .padding(.vertical, 6)
            }

            Section {
                Button {
                    do {
                        exportURL = try data.makeExportFile()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export Backup File", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("exportBackup")
                Button {
                    do {
                        csvURL = try data.makeCSVFile()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export Sets as CSV", systemImage: "tablecells")
                }
                Button {
                    if let reason = restoreBlockedReason {
                        restoreBlocked = reason
                        return
                    }
                    importerMode = .backupFile
                    showingImporter = true
                } label: {
                    Label("Restore from Backup File", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Backup File")
            } footer: {
                Text("A backup file contains everything: workouts, routines, folders, custom exercises, measurements, timers and settings. Saved to iCloud Drive or another device, it survives even deleting the app.")
            }

            Section {
                Toggle("Automatic Backup Files", isOn: app.settings.binding(\.autoExportEnabled))
                Button {
                    importerMode = .folder
                    showingImporter = true
                } label: {
                    Label(data.exportFolderName == nil ? "Also Save to a Folder…" : "Change Folder…", systemImage: "folder.badge.plus")
                }
                if data.exportFolderName != nil {
                    Button("Stop Saving to \(data.exportFolderName ?? "Folder")", role: .destructive) {
                        data.clearExportFolder()
                    }
                }
                Button {
                    data.exportNow()
                } label: {
                    HStack {
                        Label("Back Up Now", systemImage: "arrow.clockwise.icloud")
                        if data.isExporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(data.isExporting)
            } header: {
                Text("Automatic Backup Files")
            } footer: {
                Text("Once a day (and after workouts) Forge writes a backup file to Files › On My iPhone › Forge › Backups, keeping the last 7. Pick an iCloud Drive folder to keep copies off this iPhone too — the best protection if the app is ever deleted or reinstalled.")
            }

            Section {
                Toggle("Daily Snapshots", isOn: app.settings.binding(\.autoBackupEnabled))
                Button {
                    data.createSnapshot()
                } label: {
                    Label("Create Snapshot Now", systemImage: "camera.metering.center.weighted")
                }
                ForEach(data.snapshots) { snapshot in
                    Button {
                        if let reason = restoreBlockedReason {
                            restoreBlocked = reason
                        } else {
                            restoring = snapshot
                        }
                    } label: {
                        SnapshotRow(snapshot: snapshot, summary: data.summary(of: snapshot))
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            data.delete(snapshot)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Snapshots on This iPhone")
            } footer: {
                Text("Snapshots are full copies of your data, made daily and before any update or restore. Tap one to restore it — your current data is snapshotted first, so a restore can always be undone.")
            }
        }
        .navigationTitle("Backups & Export")
        .onAppear { data.refresh() }
        .sheet(item: Binding(get: { exportURL.map(ShareableFile.init) }, set: { exportURL = $0?.url })) { file in
            ShareSheet(items: [file.url])
        }
        .sheet(item: Binding(get: { csvURL.map(ShareableFile.init) }, set: { csvURL = $0?.url })) { file in
            ShareSheet(items: [file.url])
        }
        // One importer for both uses: SwiftUI only honors a single
        // fileImporter per view.
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: importerMode == .folder ? [.folder] : [.json, .data]) { result in
            switch (importerMode, result) {
            case (.folder, .success(let url)):
                data.setExportFolder(url)
            case (.backupFile, .success(let url)):
                do {
                    pendingImport = try data.readArchive(at: url)
                } catch {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            case (_, .failure(let error)):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Replace all data with this backup?",
            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace My Data", role: .destructive) {
                if let archive = pendingImport { data.applyImport(archive) }
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            if let archive = pendingImport {
                Text("The backup from \(archive.exportedAt.formatted(date: .abbreviated, time: .shortened)) has \(archive.completedWorkoutCount) workouts and \(archive.activeRoutineCount) routines. Your current data is saved as a snapshot first, so you can undo this.")
            }
        }
        .confirmationDialog(
            "Restore this snapshot?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore Snapshot", role: .destructive) {
                if let snapshot = restoring { data.restore(snapshot) }
                restoring = nil
            }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            if let snapshot = restoring {
                Text("Your data will be replaced with the snapshot from \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). Your current data is snapshotted first.")
            }
        }
        .alert("Can't Restore Yet", isPresented: Binding(get: { restoreBlocked != nil }, set: { if !$0 { restoreBlocked = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreBlocked ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// A restore replaces everything, so it waits until nothing is in
    /// progress that would be mixed into the restored data.
    private var restoreBlockedReason: String? {
        if app.session.workout != nil {
            return "Finish or discard the workout in progress first, so it isn't mixed into the restored data."
        }
        if app.timers.active != nil {
            return "Close the running timer first."
        }
        return nil
    }

    private func statusLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

struct SnapshotRow: View {
    let snapshot: BackupManager.Snapshot
    let summary: BackupManager.SnapshotSummary?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(snapshot.reason.displayName)
                    if let summary {
                        Text("· \(summary.workouts) workouts · \(summary.routines) routines")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct ShareableFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// UIKit share sheet (lets the athlete save to Files, AirDrop, etc.).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
