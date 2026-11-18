import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class FolderSyncModel {
    private(set) var folderName: String?
    private(set) var busy = false
    private(set) var message = "Choose an iCloud Drive or other Files folder to connect this notebook."
    private(set) var lastSync: Date?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var identityProblem: String?
    @ObservationIgnored private let engine: FolderSyncEngine
    private var bookmarkURL: URL { directory.appending(path: "sync-bookmark.data") }

    init(directory: URL) {
        self.directory = directory
        do { self.engine = FolderSyncEngine(directory: directory, deviceID: try SyncDeviceIdentity.load()) }
        catch { self.engine = FolderSyncEngine(directory: directory); self.identityProblem = error.localizedDescription }
        if FileManager.default.fileExists(atPath: bookmarkURL.path) {
            do {
                var stale = false
                let data = try Data(contentsOf: bookmarkURL)
                let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale { try saveBookmark(url) }
                folder = url; folderName = url.lastPathComponent
                message = "Waiting to sync."
            } catch { message = "Folder access expired. Choose the sync folder again. Your local notes are safe." }
        }
    }
    func connect(_ url: URL) {
        guard !busy else { return }
        do {
            try saveBookmark(url)
            folder = url; folderName = url.lastPathComponent
            message = "Connected. Sync will start when your notes are saved."
        } catch { message = "Couldn't connect to that folder: \(error.localizedDescription)" }
    }
    private func saveBookmark(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bookmark.write(to: bookmarkURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func disconnect() {
        guard !busy else { return }
        do {
            if FileManager.default.fileExists(atPath: bookmarkURL.path) { try FileManager.default.removeItem(at: bookmarkURL) }
            folder = nil; folderName = nil; lastSync = nil
            message = "Disconnected. Local notes and the cloud folder have been kept."
        } catch { message = error.localizedDescription }
    }
    func synchronize(_ notebook: NotebookModel) async {
        guard let folder, !busy, notebook.loadState == .ready else { return }
        if let identityProblem { message = "Couldn't identify this device for sync: " + identityProblem; return }
        if notebook.canImportSync { notebook.saveAll() }
        guard !notebook.hasPendingInk else { message = "Waiting for local changes to save."; return }
        busy = true; defer { busy = false }
        let revision = notebook.localRevision
        let allowsPull = notebook.canImportSync
        do {
            let plan = try await engine.exchange(folder: folder, allowsPull: allowsPull)
            if !plan.writes.isEmpty {
                guard allowsPull, notebook.canImportSync, notebook.localRevision == revision, !notebook.hasPendingInk else {
                    message = "Uploaded saved notes. Incoming changes will open when you return home."
                    return
                }
                try SyncTransaction.apply(plan.writes, to: directory)
                notebook.didImportSync()
            }
            lastSync = .now
            message = plan.conflicts > 0 ? "Synced. Kept \(plan.conflicts) conflict copy/copies; both edits are available."
                : allowsPull ? "Synced with the selected folder." : "Uploaded saved notes. Incoming changes open from home."
        } catch {
            message = "Sync paused: \(error.localizedDescription) Your notes stay on this device. It will retry while the app is open."
        }
    }
}

struct SyncSettingsView: View {
    let notebook: NotebookModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Sync folder") {
                    if let folder = notebook.sync.folderName { Label(folder, systemImage: "folder.badge.icloud") }
                    Button(notebook.sync.folderName == nil ? "Choose Cloud Folder…" : "Change Folder…") { choosing = true }
                        .disabled(notebook.sync.busy).accessibilityIdentifier("chooseSyncFolder")
                    Text("Choose the same folder in Files on each device. iCloud Drive is the default choice; another provider must support folder access.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Status") {
                    if notebook.sync.busy { ProgressView("Syncing…") }
                    Text(notebook.sync.message).accessibilityIdentifier("syncStatus")
                    if let date = notebook.sync.lastSync { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                    Button("Sync Now") { Task { await notebook.sync.synchronize(notebook) } }
                        .disabled(notebook.sync.folderName == nil || notebook.sync.busy).accessibilityIdentifier("syncNow")
                }
                Section {
                    Text("Saved notes sync while Jibiji is open. Incoming changes are applied at home, so a remote edit cannot interrupt your writing. Concurrent edits become conflict copies. Provider upload/download timing and network access affect delivery.")
                    Text("The folder contains editable Jibiji data and readable PDF copies for other devices. Your home background stays private to this device.")
                }.font(.footnote).foregroundStyle(.secondary)
                if notebook.sync.folderName != nil {
                    Section { Button("Disconnect", role: .destructive) { notebook.sync.disconnect() }.disabled(notebook.sync.busy) }
                }
            }
            .navigationTitle("Cloud Sync")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { notebook.sync.connect(url); Task { await notebook.sync.synchronize(notebook) } }
            }
        }
    }
}
