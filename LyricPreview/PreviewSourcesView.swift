#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import SwiftUI
import UniformTypeIdentifiers

struct PreviewSourcesView: View {
    let registry: LyricSourceRegistry
    let changed: () -> Void
    var setupMessage = ""
    var initialTrack = ""
    var initialArtist = ""
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var jsonText = ""
    @State private var pendingData: Data?
    @State private var pendingManifest: LyricSourceManifest?
    @State private var confirmImport = false
    @State private var confirmEnable = false
    @State private var confirmRemove = false
    @State private var enabling: LyricSourceConfiguration?
    @State private var removing: LyricSourceConfiguration?
    @State private var message = ""
    @State private var testTrack = ""
    @State private var testArtist = ""
    @State private var testing: UUID?
    @State private var testTask: Task<Void, Never>?
    @State private var statuses: [UUID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("Lyric sources")).font(.title2.bold())
                Spacer()
                Button(L10n.text("Close source manager")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Form {
                Section(L10n.text("Import compatible services")) {
                    Text(L10n.text("Kugou, NetEase, Kuwo, QQ Music and Migu use fixed public lyric endpoints and can be enabled below. Only credential-free HTTPS JSON configurations are accepted; Liuyin/LX JavaScript is not executed. Built-in LRCLIB remains available."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Import JSON file")) { importing = true }
                    ForEach(PlatformLyricSource.allCases, id: \.rawValue) { platform in
                        Button(L10n.text("Add %1$@ lyric source", String(describing: platform.name))) {
                            if let data = try? JSONEncoder().encode(platform.manifest) { prepare(data) }
                        }.disabled(registry.store.sources.contains { $0.manifest.apiFormat == platform.format })
                    }
                    Text(L10n.text("Lyrics only, with no audio playback or downloads. These are not official open APIs and may change or rate-limit requests. Integration does not guarantee coverage. Valid timed lyrics load by score and upgrade as results arrive; Migu has unknown durations and is preview-only, without automatic saving."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Add AMLL community fallback")) {
                        let manifest = LyricSourceManifest(schemaVersion: 1, apiVersion: 1, name: L10n.text("AMLL community library"), baseURL: AMLLSource.baseURL,
                                                           capabilities: ["search", "syncedLyrics"], auth: .init(type: "none"), format: .amllTTML)
                        if let data = try? JSONEncoder().encode(manifest) { prepare(data) }
                    }
                    Text(L10n.text("Uses AMLL's public GitHub index and TTML files without login. Community versions need confirmation and have unknown durations; only line-by-line display is supported. The repository's CC0 does not replace lyric rights; this app does not bundle lyrics."))
                        .font(.caption).foregroundStyle(.secondary)
                    Link(L10n.text("AMLL source and contributors"), destination: URL(string: "https://github.com/amll-dev/amll-ttml-db")!)
                    DisclosureGroup(L10n.text("Paste JSON configuration")) {
                        TextEditor(text: $jsonText).font(.caption.monospaced()).frame(height: 90)
                            .accessibilityLabel(L10n.text("Source JSON configuration"))
                        Button(L10n.text("Check pasted configuration")) { prepare(Data(jsonText.utf8)) }.disabled(jsonText.isEmpty)
                    }
                    if !message.isEmpty { Text(message).font(.caption).accessibilityIdentifier("source-message") }
                    if let error = registry.store.loadError { Text(error).foregroundStyle(.red) }
                    if !setupMessage.isEmpty { Text(setupMessage).foregroundStyle(.red) }
                }
                Section(L10n.text("Licensed services (not connected)")) {
                    Text(L10n.text("Musixmatch and LyricFind require official keys, timed-lyric access and display terms. They are not configured; no requests or unofficial tokens are used."))
                        .font(.caption).foregroundStyle(.secondary)
                    Link(L10n.text("Official Musixmatch developer portal"), destination: URL(string: "https://developer.musixmatch.com/")!)
                    Link(L10n.text("Official LyricFind lyric services"), destination: URL(string: "https://www.lyricfind.com/products/lyric-display")!)
                }
                Section(L10n.text("Added sources")) {
                    Text(L10n.text("Saved %1$@ sources, %2$@ enabled.", String(describing: registry.store.sources.count), String(describing: registry.store.sources.filter(\.isEnabled).count)))
                        .font(.caption.monospaced())
                    if registry.store.sources.isEmpty { Text(L10n.text("No custom sources yet. Importing a configuration does not verify the service.")) }
                    ForEach(registry.store.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(source.manifest.name, isOn: Binding(get: {
                                    registry.store.sources.first(where: { $0.id == source.id })?.isEnabled ?? false
                                }, set: { enabled in
                                    if enabled { enabling = source; confirmEnable = true }
                                    else { mutate { try registry.store.setEnabled(source.id, false) } }
                                })).toggleStyle(.switch)
                                Spacer()
                                Button(L10n.text("Test %1$@", String(describing: source.manifest.name))) { test(source) }
                                    .disabled(testing != nil || testTrack.isEmpty)
                                Button(L10n.text("Delete %1$@", String(describing: source.manifest.name)), role: .destructive) { removing = source; confirmRemove = true }
                                    .disabled(testing == source.id)
                            }
                            Text(PlatformLyricSource(rawValue: source.manifest.apiFormat.rawValue)?.domains ?? source.manifest.baseURL)
                                .font(.caption).textSelection(.enabled)
                            Text(statuses[source.id] ?? L10n.text("Not tested. Testing checks search and lyric retrieval, not recording synchronization."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(L10n.text("Time-bounded connection test")) {
                    TextField(L10n.text("Test song title"), text: $testTrack)
                    TextField(L10n.text("Test artist (optional)"), text: $testArtist)
                    Text(L10n.text("Testing sends this title and artist to the service, even if the source is off. Search and lyric retrieval for one candidate share an 8-second budget (Kugou also needs index and download requests). Current lyrics are not replaced."))
                        .font(.caption).foregroundStyle(.secondary)
                    if testing != nil { Button(L10n.text("Cancel source test")) { testTask?.cancel() } }
                }
                Text(L10n.text("Sources run in order: built-in LRCLIB, then imported sources. Settings changes clear candidates and require a new search. Only this app's configuration is saved here."))
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
        }
        .frame(minWidth: 650, minHeight: 650)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                prepare(try file.read(upToCount: 64 * 1024 + 1) ?? Data())
            } catch { message = error.localizedDescription }
        }
        .alert(L10n.text("Confirm lyric source import"), isPresented: $confirmImport) {
            Button(L10n.text("Import and enable")) { importPending(enabled: true) }
            Button(L10n.text("Import without enabling")) { importPending(enabled: false) }
            Button(L10n.text("Cancel import"), role: .cancel) { pendingManifest = nil; pendingData = nil }
        } message: {
            Text(L10n.text("%1$@\n%2$@\n%3$@ Importing alone makes no requests.", String(describing: pendingManifest?.name ?? ""), String(describing: pendingManifest?.baseURL ?? ""), String(describing: requestNotice(pendingManifest))))
        }
        .alert(L10n.text("Enable source?"), isPresented: $confirmEnable) {
            Button(L10n.text("Confirm enabling")) {
                if let source = enabling { mutate { try registry.store.setEnabled(source.id, true) } }
                enabling = nil
            }
            Button(L10n.text("Cancel enabling"), role: .cancel) { enabling = nil }
        } message: { Text("\(enabling?.manifest.baseURL ?? "")\n\(requestNotice(enabling?.manifest))") }
        .alert(L10n.text("Delete source from this app?"), isPresented: $confirmRemove) {
            Button(L10n.text("Confirm source deletion"), role: .destructive) {
                if let source = removing { mutate { try registry.store.remove(source.id) }; statuses[source.id] = nil }
                removing = nil
            }
            Button(L10n.text("Cancel deletion"), role: .cancel) { removing = nil }
        } message: { Text(L10n.text("Only %1$@'s configuration in this app will be deleted; other editions are unchanged.", String(describing: removing?.manifest.name ?? ""))) }
        .onAppear { testTrack = initialTrack; testArtist = initialArtist }
        .onDisappear { testTask?.cancel() }
    }

    private func prepare(_ data: Data) {
        do { pendingManifest = try LyricSourceManifest.decode(data); pendingData = data; confirmImport = true }
        catch { message = error.localizedDescription }
    }
    private func requestNotice(_ manifest: LyricSourceManifest?) -> String {
        if let format = manifest?.apiFormat, let platform = PlatformLyricSource(rawValue: format.rawValue) {
            return L10n.text("Sends title, artist and platform song ID to %1$@ for lyrics only; no account, token or local file is sent.", String(describing: platform.domains))
        }
        return manifest?.apiFormat == .amllTTML
            ? L10n.text("After enabling, reads the public index, matches title and artist locally, then requests TTML by community ID. No account, token or local file is sent.")
            : L10n.text("After enabling, sends the search title and artist to this service. No account, token or local file is sent.")
    }
    private func importPending(enabled: Bool) {
        defer { pendingManifest = nil; pendingData = nil }
        guard let data = pendingData else { return }
        mutate { _ = try registry.store.importManifest(data, enabled: enabled) }
    }
    private func mutate(_ operation: () throws -> Void) {
        testTask?.cancel()
        do { try operation(); changed(); message = L10n.text("Configuration saved. Return to the workspace and search again.") }
        catch { message = error.localizedDescription }
    }
    private func test(_ source: LyricSourceConfiguration) {
        let track = testTrack.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = testArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !track.isEmpty else { return }
        testing = source.id
        statuses[source.id] = L10n.text("Testing with only the test title and artist...")
        testTask = Task { @MainActor in
            defer { testing = nil }
            do {
                let provider = try registry.provider(for: source)
                let success = try await withLyricDeadline(seconds: 8) {
                    let songs = try await provider.searchCandidates(trackName: track, artistName: artist)
                    guard let song = songs.first(where: {
                        $0.hasSyncedLyrics && PreviewRecordingMatcher.normalized($0.trackName) == PreviewRecordingMatcher.normalized(track)
                            && (artist.isEmpty || PreviewRecordingMatcher.artistRelation($0.artistName, artist) == .normalized)
                    }) else { return false }
                    return LyricFetchPipeline.isValid(try await provider.lyrics(for: song))
                }
                try Task.checkCancellation()
                statuses[source.id] = success ? L10n.text("Connection, search and timed-lyric retrieval passed. Recording version and audible synchronization are unverified.") : L10n.text("Connected, but no matching valid timeline was retrieved.")
            } catch is CancellationError { statuses[source.id] = L10n.text("Test canceled.") }
            catch PlatformLyricError.untimedLyrics { statuses[source.id] = L10n.text("Connected and searched successfully, but this candidate has no lyric timing and cannot be synchronized.") }
            catch { statuses[source.id] = L10n.text("Source test failed: %1$@. This does not prove lyrics are unavailable.", String(describing: error.localizedDescription)) }
        }
    }
}
