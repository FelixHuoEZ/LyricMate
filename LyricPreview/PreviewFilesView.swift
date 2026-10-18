#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import SwiftUI
import UniformTypeIdentifiers

struct PreviewJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PreviewFilesView: View {
    let controller: PreviewController
    @Environment(\.dismiss) private var dismiss
    private enum Kind { case lrc, backup }
    @State private var kind: Kind = .lrc
    @State private var importing = false
    @State private var exporting = false
    @State private var document: PreviewJSONDocument?
    @State private var captured: PlaybackSnapshot?
    @State private var pendingLocal: PreviewLocalLyrics.Import?
    @State private var pendingRestore: PreviewBackup.Plan?
    @State private var confirmLocal = false
    @State private var confirmRestore = false
    @State private var message = ""
    @State private var showLibrary = false

    var body: some View {
        VStack {
            HStack { Text(L10n.text("Local lyrics and configuration backups")).font(.title2.bold()); Spacer(); Button(L10n.text("Close file manager")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
            Form {
                Section(L10n.text("Local LRC lyrics")) {
                    Button(L10n.text("Manage local lyric library")) { showLibrary = true }
                    Text(controller.session.playback.map { L10n.text("Current recording: %1$@ / %2$@\n%3$@", String(describing: $0.trackName), String(describing: $0.artistName), String(describing: $0.trackID)) } ?? L10n.text("Enable read-only following first to identify a Spotify recording."))
                    Button(L10n.text("Import local LRC")) {
                        captured = controller.session.playback; kind = .lrc; importing = true
                    }.disabled(!controller.session.playbackAvailable)
                    Button(L10n.text("Use local lyrics for this recording")) { useLocal() }.disabled(!controller.session.playbackAvailable)
                    Text(L10n.text("UTF-8 LRC, at most 1 MiB. Timing and any title/artist headers must validate; confirm the version if headers are absent. After confirmation, the file is copied to the separate local library without network access: one file per recording, at most 200 files and 32 MiB total."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("Configuration and recording choices")) {
                    Text(L10n.text("%1$@ sources / %2$@ saved recording choices", String(describing: controller.registry.store.sources.count), String(describing: controller.preferences.entries.count)))
                    Button(L10n.text("Export configuration backup")) {
                        do { document = PreviewJSONDocument(data: try PreviewBackup.export(sources: controller.registry.store, preferences: controller.preferences)); exporting = true }
                        catch { message = error.localizedDescription }
                    }
                    Button(L10n.text("Restore configuration backup")) { kind = .backup; importing = true }
                    Button(L10n.text("Undo last configuration restore")) {
                        if let data = controller.isolatedDefaults.data(forKey: PreviewBackup.undoKey) { prepareRestore(data) }
                    }.disabled(controller.isolatedDefaults.data(forKey: PreviewBackup.undoKey) == nil)
                    Text(L10n.text("Backups contain service addresses, recording names, IDs, candidate fingerprints and offsets, but no credentials, lyric text or local lyric files. They are saved only where you choose. Reimport LRC files on a new Mac; missing files or changed candidates do not blindly restore offsets."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Restore replaces this app's configuration and keeps the previous configuration for undo. All sources remain off until individually confirmed. Restore itself makes no requests and does not modify other editions."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).font(.caption).accessibilityIdentifier("files-message") }
            }.formStyle(.grouped)
        }.frame(minWidth: 650, minHeight: 560)
        .sheet(isPresented: $showLibrary) { PreviewLibraryView(controller: controller) }
        .fileImporter(isPresented: $importing, allowedContentTypes: kind == .lrc ? [UTType(filenameExtension: "lrc") ?? .plainText] : [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let limit = kind == .lrc ? 1024 * 1024 : PreviewBackup.maximumBytes
                let data = try file.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw LyricSourceError.responseTooLarge }
                if kind == .lrc {
                    guard url.pathExtension.lowercased() == "lrc", let captured, controller.session.playbackAvailable else { throw LyricSourceError.invalidResponse }
                    pendingLocal = try controller.localLyrics.prepare(data, playback: captured)
                    confirmLocal = true
                } else { prepareRestore(data) }
            } catch { message = L10n.text("File not imported: %1$@", String(describing: error.localizedDescription)) }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Lyric-Preview-settings") { result in
            switch result {
            case .success: message = L10n.text("Configuration backup saved, without lyric text or credentials.")
            case .failure(let error): message = error.localizedDescription
            }
        }
        .alert(L10n.text("Bind local lyrics?"), isPresented: $confirmLocal) {
            Button(L10n.text("Confirm local lyric binding")) {
                defer { pendingLocal = nil }
                do {
                    guard let value = pendingLocal, controller.session.playbackAvailable, let current = controller.session.playback else { throw FetchError.staleTrack }
                    let candidate = try controller.localLyrics.install(value, current: current)
                    controller.session.presentLocal(candidate); controller.session.select(candidate.id)
                    message = L10n.text("Local lyrics bound and saved without a network request.")
                } catch { message = L10n.text("Binding incomplete: %1$@", String(describing: error.localizedDescription)) }
            }
            Button(L10n.text("Cancel binding"), role: .cancel) { pendingLocal = nil }
        } message: {
            Text(L10n.text("%1$@ / %2$@\n%3$@\nThe file will be copied to the separate local library, replacing this recording's previous local file. Headers and timing do not prove audible synchronization. Confirm that this is the same recording version. Other apps and the network are unaffected.", String(describing: pendingLocal?.recording.title ?? ""), String(describing: pendingLocal?.recording.artist ?? ""), String(describing: pendingLocal?.recording.id ?? "")))
        }
        .alert(L10n.text("Preview configuration restore"), isPresented: $confirmRestore) {
            Button(L10n.text("Restore with sources off")) {
                defer { pendingRestore = nil }
                do {
                    guard let plan = pendingRestore else { throw LyricSourceError.invalidResponse }
                    try PreviewBackup.restore(plan, sources: controller.registry.store, preferences: controller.preferences, defaults: controller.isolatedDefaults)
                    controller.session.sourcesChanged()
                    message = L10n.text("Configuration restored with all sources off. Previous configuration can be restored by undo; no network request was made.")
                } catch { message = L10n.text("Restore incomplete: %1$@", String(describing: error.localizedDescription)) }
            }
            Button(L10n.text("Cancel restore"), role: .cancel) { pendingRestore = nil }
        } message: {
            Text(L10n.text("Replace %1$@ current sources / %2$@ choices with %3$@ sources / %4$@ choices.\n%5$@\nNo lyric files are imported; all sources stay off; the previous configuration is kept.", String(describing: controller.registry.store.sources.count), String(describing: controller.preferences.entries.count), String(describing: pendingRestore?.payload.sources.count ?? 0), String(describing: pendingRestore?.payload.preferences.count ?? 0), String(describing: pendingRestore?.payload.sources.map { $0.manifest.baseURL }.joined(separator: "\n") ?? "")))
        }
    }
    private func prepareRestore(_ data: Data) {
        do { pendingRestore = try PreviewBackup.prepare(data, sources: controller.registry.store, preferences: controller.preferences); confirmRestore = true }
        catch { message = L10n.text("Backup not accepted: %1$@", String(describing: error.localizedDescription)) }
    }
    private func useLocal() {
        do {
            if controller.session.loadRememberedLocal() {
                message = L10n.text("Revalidated and restored local lyrics and the original offset without a network request.")
                return
            }
            guard controller.session.playbackAvailable, let snapshot = controller.session.playback,
                  let candidate = try controller.localLyrics.candidate(for: snapshot) else { message = L10n.text("No local lyrics are bound to this recording."); return }
            controller.session.presentLocal(candidate); controller.session.select(candidate.id)
            message = L10n.text("Local lyrics loaded for this recording without a network request.")
        } catch { message = error.localizedDescription }
    }
}
