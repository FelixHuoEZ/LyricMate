#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class PreviewController {
    let session: LyricPreviewSession
    let registry: LyricSourceRegistry
    let preferences: PreviewRecordingPreferences
    let localLyrics: PreviewLocalLyrics
    let isolatedDefaults: UserDefaults
    let presentationSettings: PreviewPresentationSettings
    let allowsPlaybackRead: Bool
    let allowsPlaybackControl: Bool
    private(set) var controlMessage = ""
    var controlBusy: Bool { controlGate.isBusy || controlReadback != nil }
    var pendingControlCommand: PlaybackControlCommand? { controlGate.pending?.command ?? controlReadback?.request.command }
    var canControlPlayback: Bool {
        allowsPlaybackControl && session.playbackAvailable && session.playback?.isValid == true && !controlBusy
    }
    private(set) var connection = L10n.text("Spotify following is off. You can search and preview lyrics first.")
    var connecting: Bool { readGate.pending != nil }
    var enabled: Bool { readGate.enabled }
    private(set) var readStage = ""
    private(set) var traceMessage = ""
    private(set) var automaticDiagnosticsMessage = ""
    private(set) var sourceSetupMessage = ""
    @ObservationIgnored private let reader: ReadOnlySpotifyReader
    @ObservationIgnored private let playbackControl: SpotifyPlaybackControl
    @ObservationIgnored private let controlDiagnostics = PlaybackControlDiagnostics()
    private var controlGate = PlaybackControlGate()
    private struct ControlReadback {
        let request: PlaybackControlRequest
        var readID: UUID?
    }
    private var controlReadback: ControlReadback?
    @ObservationIgnored private let incidentRecorder: PlaybackIncidentRecorder?
    @ObservationIgnored private let processLookup: (@MainActor () -> PlaybackProcessIdentity?)?
    @ObservationIgnored private var lastTraceKey = ""
    @ObservationIgnored private var trace: [Trace] = []
    private var readGate = PlaybackReadGate()
    @ObservationIgnored private var allowsPermissionPrompt = true
    @ObservationIgnored private var restoredStartup = false
    @ObservationIgnored private var readDiagnostics = PlaybackReadDiagnostics()
    @ObservationIgnored private var processDiscovery = PlaybackProcessDiscovery()
    @ObservationIgnored private var processDiagnostics: [ProcessDiagnostic] = []
    @ObservationIgnored private var lastProcessKey = ""
    @ObservationIgnored private var readRecovery = PlaybackReadRecovery()

    private struct ProcessDiagnostic: Codable {
        let observedAt: Date
        let listed: [PlaybackProcessIdentity]
        let revalidated: PlaybackProcessIdentity?
        let outcome: String
    }

    private struct Trace: Encodable {
        let observedAt: Date
        let trackID: String?
        let trackName: String?
        let artistName: String?
        let positionMS: Double?
        let displayedPositionMS: Double
        let isPlaying: Bool?
        let selectedSource: String?
        let selectedSongName: String?
        let selectedArtistName: String?
        let selectedAlbumName: String?
        let selectedDurationMS: Int?
        let lyricCount: Int
        let activeIndex: Int?
        let activeTimestampMS: Double?
        let offsetMS: Double
        let followsPlayback: Bool
        let playbackAvailable: Bool
        let connection: String
        let readStage: String
        let durationMS: Int?
        let albumName: String?
    }

    init(defaults: UserDefaults = UserDefaults(suiteName: "local.lyricmate.alpha.daily.v1")!,
         builtin: LyricProvider? = nil, allowsPlaybackRead: Bool = true, localDirectory: URL? = nil, installPlatformSources: Bool = false,
         reader: ReadOnlySpotifyReader = ReadOnlySpotifyReader(), processLookup: (@MainActor () -> PlaybackProcessIdentity?)? = nil,
         incidentRecorder: PlaybackIncidentRecorder? = nil,
         allowsPlaybackControl: Bool? = nil, playbackControl: SpotifyPlaybackControl? = nil,
         makeProvider: @escaping @MainActor (LyricSourceManifest) throws -> CustomHTTPSourceProvider = { try CustomHTTPSourceProvider(manifest: $0) }) {
        let manifest = LyricSourceManifest(schemaVersion: 1, apiVersion: 1, name: "LRCLIB", baseURL: "https://lrclib.net/",
                                          capabilities: ["search", "syncedLyrics"], auth: .init(type: "none"), format: .lrclib)
        let base = builtin ?? (try! makeProvider(manifest))
        let sources = LyricSourceRegistry(store: LyricSourceStore(defaults: defaults), makeProvider: makeProvider)
        if installPlatformSources {
            do { try sources.store.installPlatformDefaults() }
            catch { sourceSetupMessage = L10n.text("Platform sources were not added automatically: %1$@. Existing settings were kept; add sources manually if needed.", String(describing: error.localizedDescription)) }
        }
        registry = sources
        let memory = PreviewRecordingPreferences(defaults: defaults)
        preferences = memory
        isolatedDefaults = defaults
        presentationSettings = PreviewPresentationSettings(defaults: defaults)
        let local = PreviewLocalLyrics(directory: localDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.lyricmate.alpha/local-lyrics", isDirectory: true))
        localLyrics = local
        self.allowsPlaybackRead = allowsPlaybackRead
        self.reader = reader
        self.allowsPlaybackControl = allowsPlaybackControl ?? allowsPlaybackRead
        self.playbackControl = playbackControl ?? SpotifyPlaybackControl(queue: reader.serializedQueue)
        self.incidentRecorder = incidentRecorder
        if incidentRecorder != nil { automaticDiagnosticsMessage = L10n.text("Incident diagnostics stay on this Mac: up to 20 records for 7 days.") }
        self.processLookup = processLookup
        session = LyricPreviewSession(providers: [base], providerSnapshot: { [base] + sources.enabledProviders }, preferences: memory, localLyrics: local)
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--song"), arguments.indices.contains(index + 1) { session.trackQuery = arguments[index + 1] }
        if let index = arguments.firstIndex(of: "--artist"), arguments.indices.contains(index + 1) { session.artistQuery = arguments[index + 1] }
    }

    func requestPermission() {
        guard allowsPlaybackRead else { return }
        guard readGate.enable() else { return }
        allowsPermissionPrompt = true
        presentationSettings.resumesSpotify = true
        incidentRecorder?.endRecovery(.manualReconnect)
        readDiagnostics.reset()
        processDiscovery.reset()
        readRecovery.reset()
        readStage = L10n.text("Waiting for the minimal playback-state query")
        session.followsPlayback = true
        connection = L10n.text("Connecting read-only. If macOS asks for permission, you decide whether to allow it.")
    }

    func restoreStartupConnection() {
        guard !restoredStartup else { return }
        restoredStartup = true
        guard allowsPlaybackRead, presentationSettings.resumesSpotify, !enabled, readGate.enable() else { return }
        allowsPermissionPrompt = false
        session.followsPlayback = true
        readStage = L10n.text("Restoring the previous connection without requesting new permission")
        connection = L10n.text("Restoring the Spotify connection; only an already-running player will be read.")
    }

#if PREVIEW_ACCEPTANCE
    var acceptanceAllowsPermissionPrompt: Bool { allowsPermissionPrompt }
#endif

    func follow() async {
        while !Task.isCancelled {
            pollPlaybackIfReady()
            recordTraceIfChanged()
            if let status = incidentRecorder?.store.status {
                automaticDiagnosticsMessage = status.failures > 0 || status.droppedPending > 0
                    ? L10n.text("Automatic diagnostic retention is incomplete; disk-write failures do not interrupt playback following.")
                    : L10n.text("Incident diagnostics stay on this Mac: up to 20 records for 7 days.")
            }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { break }
        }
        if let pending = readGate.pending { incidentRecorder?.outcome(pending.token, .cancelled) }
        if let refresh = controlReadback {
            controlDiagnostics.mark(refresh.request.token, stage: .readback, status: .cancelled)
            controlReadback = nil
        }
        incidentRecorder?.endRecovery(.cancelled)
        readGate.stop()
        session.stop()
    }

    // The timer and control completion share one gate; this is not a second poller.
    private func pollPlaybackIfReady() {
        if controlGate.expire(), let request = controlGate.pending {
            controlDiagnostics.mark(request.token, stage: .deadline, status: .expired)
            controlMessage = L10n.text("Control timed out. The result is unconfirmed; waiting for the original operation without retrying.")
        }
        if enabled {
            if let request = readGate.pending {
                if readGate.expire() {
                    readDiagnostics.recordDeadline(for: request.token, elapsedMS: request.timeoutMS)
                    connection = request.requiresProbe
                        ? L10n.text("Initial read-only connection timed out. Highlighting stopped; no automatic retry.")
                        : L10n.text("Read-only query timed out. Highlighting stopped; bounded recovery will be considered after this query returns.")
                    session.updatePlayback(nil)
                    finishControlReadback(for: request.token, status: .expired)
                }
            } else if controlGate.isBusy {
                // Do not enqueue reads behind a control whose result is still unknown.
            } else if readRecovery.isExpired() {
                incidentRecorder?.endRecovery(.windowExpired)
                readGate.stop()
                connection = L10n.text("Bounded recovery reached its 10-second limit. Highlighting stopped; reconnect manually.")
                session.updatePlayback(nil)
            } else if readRecovery.isReady(), let process = locateSpotify() {
                guard let request = readGate.begin() else { return }
                if let refresh = controlReadback, refresh.readID == nil {
                    controlReadback?.readID = request.token
                    controlDiagnostics.readbackStarted(refresh.request.token, readID: request.token)
                }
                readDiagnostics.begin(request.token)
                reader.read(processID: process.processID, requiresProbe: request.requiresProbe, allowsPermissionPrompt: allowsPermissionPrompt,
                            launchDate: process.launchDate,
                            deadline: request.deadline, incidentRecorder: incidentRecorder, requestID: request.token,
                            progress: { [weak self] diagnostic in
                    Task { @MainActor in
                        guard let self, self.readDiagnostics.progress(diagnostic, for: request.token) else { return }
                        if request.requiresProbe || diagnostic.status == "failed" || diagnostic.status == "missing" {
                            self.readStage = "\(diagnostic.stage) · \(diagnostic.status) · \(diagnostic.elapsedMS) ms"
                        }
                    }
                }) { [weak self, incidentRecorder] result, diagnostics in
                    Task { @MainActor in
                        incidentRecorder?.uiReceived(request.token)
                        guard let self, self.readGate.pending?.token == request.token else {
                            incidentRecorder?.outcome(request.token, .ignored)
                            return
                        }
                        var readbackStatus = PlaybackControlDiagnostics.Status.failed
                        defer {
                            self.finishControlReadback(for: request.token, status: readbackStatus)
                            // An older read may reach the UI after the command callback.
                            // Release it before starting the requested fresh snapshot.
                            if self.controlReadback?.readID == nil, self.controlReadback != nil {
                                self.pollPlaybackIfReady()
                            }
                        }
                        let now = ContinuousClock.now
                        if now >= request.deadline {
                            self.readDiagnostics.recordDeadline(for: request.token, elapsedMS: request.timeoutMS)
                        }
                        guard self.readDiagnostics.complete(diagnostics, for: request.token) else { return }
                        if let last = diagnostics.last {
                            self.readStage = "\(last.stage) · \(last.status) · \(last.elapsedMS) ms"
                        }
                        guard self.readGate.finish(request.token, at: now), !self.readRecovery.isExpired(at: now) else {
                            self.session.updatePlayback(nil)
                            if self.readGate.didExpire(request.token) {
                                let failure: PlaybackReadFailure
                                switch result {
                                case .success: failure = .deadlineExceeded
                                case .failure(let error): failure = error
                                }
                                // Start the window at the timeout, not whenever a blocked event eventually returns.
                                if case .retry = self.readRecovery.failed(failure, initialRead: request.requiresProbe, at: request.deadline),
                                   !self.readRecovery.isExpired(at: now), self.readGate.resumeAfterTimeout(request.token) {
                                    self.connection = L10n.text("Discarded a late result. The old query ended; bounded recovery (%1$@/2), with highlighting paused.", String(describing: self.readRecovery.retryCount))
                                    incidentRecorder?.outcome(request.token, .retryScheduled)
                                    return
                                }
                            }
                            self.readGate.stop()
                            let reason: String
                            if case .failure(let error) = result { reason = (error.errorDescription ?? L10n.text("Read-only query failed.")) + " " }
                            else { reason = "" }
                            self.connection = reason + L10n.text("Discarded a late result. Recovery is unsafe or exhausted; reconnect manually.")
                            incidentRecorder?.outcome(request.token, .stopped)
                            return
                        }
                        switch result {
                        case .success(let snapshot):
                            self.readRecovery.reset()
                            if let refresh = self.controlReadback, refresh.readID != request.token {
                                incidentRecorder?.outcome(request.token, .ignored)
                                return
                            }
                            self.connection = snapshot.isPlaying ? L10n.text("Following Spotify read-only · Playing") : L10n.text("Following Spotify read-only · Paused")
                            self.session.updatePlayback(snapshot)
                            readbackStatus = .succeeded
                            incidentRecorder?.outcome(request.token, .accepted)
                        case .failure(let error):
                            self.session.updatePlayback(nil)
                            switch self.readRecovery.failed(error, initialRead: request.requiresProbe) {
                            case .retry(let delay):
                                self.connection = L10n.text("Read-only query interrupted. Rechecking the process in %1$@ seconds (%2$@/2); highlighting paused.", String(describing: delay.components.seconds), String(describing: self.readRecovery.retryCount))
                                incidentRecorder?.outcome(request.token, .retryScheduled)
                            case .stop:
                                self.readGate.stop()
                                self.connection = (error.errorDescription ?? L10n.text("Read-only connection failed.")) + L10n.text(" Stopped; no automatic retry.")
                                incidentRecorder?.outcome(request.token, .stopped)
                            }
                        }
                    }
                }
            }
        }
        if !enabled, let refresh = controlReadback {
            controlDiagnostics.mark(refresh.request.token, stage: .readbackWait, status: .unavailable)
            controlReadback = nil
            controlMessage = L10n.text("Command returned, but the read connection is unavailable. Playback result is unconfirmed.")
        }
    }

    private func finishControlReadback(for readID: UUID, status: PlaybackControlDiagnostics.Status) {
        guard let refresh = controlReadback, refresh.readID == readID else { return }
        controlDiagnostics.mark(refresh.request.token, stage: .readback, status: status)
        controlReadback = nil
        controlMessage = status == .succeeded
            ? L10n.text("Spotify playback state refreshed; controls reflect the latest read.")
            : L10n.text("Command returned, but state could not be read back. Playback result is unconfirmed; the command was not resent.")
        recordTraceIfChanged()
    }

    func controlAccessibilityLabel(_ command: PlaybackControlCommand) -> String {
        if pendingControlCommand == command { return controlMessage }
        return command == .togglePlayback ? (session.playback?.isPlaying == true ? L10n.text("Pause Spotify") : L10n.text("Play Spotify")) : command.title
    }

    func performPlaybackCommand(_ command: PlaybackControlCommand) {
        guard canControlPlayback, let snapshot = session.playback else { return }
        guard let process = locateSpotify(),
              let request = controlGate.begin(command, process: process, trackID: snapshot.trackID) else { return }
        controlDiagnostics.begin(request)
        controlMessage = L10n.text("Sending: %1$@...", String(describing: command.title))
        playbackControl.send(request, diagnostics: controlDiagnostics) { [weak self] result in
            Task { @MainActor in
                guard let self, self.controlGate.finish(request.token) else { return }
                self.controlDiagnostics.uiReceived(request.token)
                switch result {
                case .success:
                    guard self.allowsPlaybackRead, self.enabled else {
                        self.controlDiagnostics.mark(request.token, stage: .readbackWait, status: .unavailable)
                        self.controlMessage = L10n.text("Command returned; playback following is off. Playback state is unconfirmed.")
                        return
                    }
                    self.controlReadback = .init(request: request)
                    self.controlDiagnostics.mark(request.token, stage: .readbackWait, status: .started)
                    self.controlMessage = L10n.text("Checking Spotify playback state...")
                    self.pollPlaybackIfReady()
                case .failure(let failure): self.controlMessage = failure.message
                }
            }
        }
    }

    private func locateSpotify() -> PlaybackProcessIdentity? {
        if let processLookup { return processLookup() }
        func identity(_ application: NSRunningApplication) -> PlaybackProcessIdentity? {
            guard !application.isTerminated, let bundle = application.bundleIdentifier else { return nil }
            return PlaybackProcessIdentity(processID: application.processIdentifier, bundleIdentifier: bundle,
                                           launchDate: application.launchDate)
        }
        let listed = NSRunningApplication.runningApplications(withBundleIdentifier: PlaybackProcessDiscovery.spotifyBundleID).compactMap(identity)
        let revalidated = processDiscovery.lastIdentity.flatMap {
            NSRunningApplication(processIdentifier: $0.processID).flatMap(identity)
        }
        let decision = processDiscovery.resolve(listed: listed, revalidated: revalidated)
        let outcome: String
        let target: PlaybackProcessIdentity?
        switch decision {
        case .read(let process):
            outcome = listed.contains(process) ? "listed" : "revalidated-pid"
            target = process
        case .waiting:
            outcome = "waiting"
            target = nil
            connection = L10n.text("Spotify process temporarily unconfirmed. Rechecking briefly; highlighting stopped.")
            session.updatePlayback(nil)
        case .unavailable:
            outcome = "unavailable"
            target = nil
            readGate.stop()
            incidentRecorder?.endRecovery(.stopped)
            connection = L10n.text("Spotify process was unconfirmed for 2 seconds. Stopped without launching or controlling it.")
            session.updatePlayback(nil)
        }
        let key = "\(listed)|\(String(describing: revalidated))|\(outcome)"
        if key != lastProcessKey {
            lastProcessKey = key
            processDiagnostics.append(ProcessDiagnostic(observedAt: Date(), listed: listed, revalidated: revalidated, outcome: outcome))
            if processDiagnostics.count > 200 { processDiagnostics.removeFirst(processDiagnostics.count - 200) }
        }
        return target
    }

    func shareDiagnosticsPreview() -> String {
        (try? PreviewShareDiagnostics.preview(reads: readDiagnostics.events + readDiagnostics.failures,
                                              controls: controlDiagnostics.entries)) ?? "{}"
    }

    func saveShareDiagnostics(_ preview: String) {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("local.lyricmate.alpha/diagnostics/share", isDirectory: true)
            try PreviewShareDiagnostics.save(preview, to: directory)
            traceMessage = L10n.text("Redacted diagnostics saved locally. Nothing was uploaded.")
        } catch { traceMessage = L10n.text("Could not save diagnostics.") }
    }

    func exportTrace(to directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.lyricmate.alpha/diagnostics/manual", isDirectory: true)) {
        recordTraceIfChanged(force: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(trace).write(to: directory.appendingPathComponent("playback-trace.json"), options: .atomic)
            try encoder.encode(readDiagnostics.events).write(to: directory.appendingPathComponent("read-diagnostics.json"), options: .atomic)
            try encoder.encode(readDiagnostics.failures).write(to: directory.appendingPathComponent("read-failures.json"), options: .atomic)
            try encoder.encode(processDiagnostics).write(to: directory.appendingPathComponent("process-diagnostics.json"), options: .atomic)
            try encoder.encode(controlDiagnostics.entries).write(to: directory.appendingPathComponent("control-diagnostics.json"), options: .atomic)
            traceMessage = L10n.text("Diagnostics saved locally. They include title, artist, album, track ID and process information; review before sharing. No lyric text or credentials.")
        } catch { traceMessage = L10n.text("Could not save diagnostics.") }
    }

    private func recordTraceIfChanged(force: Bool = false) {
        let key = "\(session.playback?.trackID ?? "")|\(session.playback?.isPlaying ?? false)|\(session.activeIndex ?? -1)|\(session.selectedID?.uuidString ?? "")|\(session.playbackAvailable)|\(session.offsetMS)|\(session.followsPlayback)|\(connection)"
        guard force || key != lastTraceKey else { return }
        lastTraceKey = key
        let playback = session.playback
        let selected = session.selected
        let index = session.activeIndex
        trace.append(Trace(observedAt: Date(), trackID: playback?.trackID, trackName: playback?.trackName,
                           artistName: playback?.artistName, positionMS: playback?.positionMS, displayedPositionMS: session.displayedPositionMS,
                           isPlaying: playback?.isPlaying, selectedSource: selected?.lyricType, selectedSongName: selected?.songName,
                           selectedArtistName: selected?.artistName, selectedAlbumName: selected?.albumName, selectedDurationMS: selected?.durationMS,
                           lyricCount: selected?.lyrics.count ?? 0, activeIndex: index,
                           activeTimestampMS: index.map { selected!.lyrics[$0].startTimeMS }, offsetMS: session.offsetMS,
                           followsPlayback: session.followsPlayback, playbackAvailable: session.playbackAvailable,
                           connection: connection, readStage: readStage,
                           durationMS: playback?.durationMS, albumName: playback?.albumName))
        if trace.count > 200 { trace.removeFirst(trace.count - 200) }
    }
}

@MainActor
private final class PreviewQueryFocusReturn {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?

    func capture() {
        window = NSApp.keyWindow
        let current = window?.firstResponder
        // AppKit shares a field editor; retain the owning input, not that editor.
        responder = (current as? NSTextView)?.delegate as? NSResponder ?? current
    }

    func restore(after notification: Notification? = nil) {
        if let notification, (notification.object as? NSWindow) !== window { return }
        DispatchQueue.main.async { [weak window, weak responder] in
            guard let window, let responder, window.attachedSheet == nil,
                  (responder as? NSView)?.window === window else { return }
            window.makeFirstResponder(responder)
        }
    }
}

struct LyricPreviewView: View {
    @Bindable var controller: PreviewController
    var desktop: PreviewDesktopPresentation? = nil
    @State private var autoScroll = true
    @State private var showSources = false
    @State private var showFiles = false
    private struct ShareDiagnosticsPreview: Identifiable {
        let id = UUID()
        let text: String
    }
    @State private var pendingShareDiagnostics: ShareDiagnosticsPreview?
    @State private var confirmFullDiagnostics = false
    private enum QueryFocus: Hashable { case track, artist }
    @FocusState private var queryFocus: QueryFocus?
    @State private var returnQueryFocus: QueryFocus = .track
    @State private var lastQueryFocus: QueryFocus = .track
    @State private var queryFocusReturn = PreviewQueryFocusReturn()
    private let paper = Color(red: 0.96, green: 0.94, blue: 0.88)
    private let ink = Color(red: 0.12, green: 0.19, blue: 0.17)
    private let accent = Color(red: 0.74, green: 0.22, blue: 0.12)

    var body: some View {
        @Bindable var session = controller.session
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(PreviewLyricPresentation.appName).font(.custom("Avenir Next Demi Bold", size: 12)).tracking(3)
                    Text(session.playback?.trackName ?? L10n.text("Lyrics workspace")).font(.custom("Avenir Next", size: 28)).bold()
                    Text(session.playback.map { "\($0.artistName) · \($0.albumName)" } ?? L10n.text("Standalone alpha · Existing applications are unchanged"))
                        .font(.caption).foregroundStyle(ink.opacity(0.7))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text(controller.connection).font(.caption)
                    if !controller.readStage.isEmpty { Text(controller.readStage).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    if !controller.enabled && controller.allowsPlaybackRead {
                        Button(L10n.text("Enable read-only Spotify following")) { controller.requestPermission() }
                            .disabled(controller.connecting)
                        Text(L10n.text("Following can automatically send song title and artist to enabled lyric services. They also receive your IP address; local imports stay offline."))
                            .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 340)
                    }
                    Text(L10n.text("No login credentials · Playback changes only on clicks · Local imports stay offline")).font(.caption2).foregroundStyle(.secondary)
                    Text(Self.versionLabel).font(.caption2.monospaced()).accessibilityIdentifier("preview-version")
                    if let desktop {
                        Button(desktop.floatingVisible ? L10n.text("Hide floating lyrics") : L10n.text("Show floating lyrics"), systemImage: "rectangle.on.rectangle") { desktop.toggleFloating() }
                    }
                }
            }.padding(24)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("01 / Find a recording version")).font(.headline)
                    TextField(L10n.text("Song title"), text: $session.trackQuery).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.text("Search song title"))
                        .focused($queryFocus, equals: .track)
                    TextField(L10n.text("Artist (optional)"), text: $session.artistQuery).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.text("Search artist (optional)"))
                        .focused($queryFocus, equals: .artist)
                    HStack {
                        Button(session.isSearching ? L10n.text("Searching sources...") : L10n.text("Search lyrics")) { session.search() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(session.isSearching || session.trackQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if session.isSearching { ProgressView().controlSize(.small) }
                    }
                    Button(L10n.text("Manage lyric sources")) { openSources() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    Button(L10n.text("Local lyrics and backups")) { openFiles() }.keyboardShortcut("f", modifiers: [.command, .shift])
                    Text(session.status).font(.caption).foregroundStyle(.secondary)
                    if !session.matchingMessage.isEmpty { Text(session.matchingMessage).font(.caption).foregroundStyle(.secondary) }
                    ForEach(session.sourceErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(accent) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(session.rankedResults) { result in
                                Button { session.select(result.id) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(result.songName).font(.headline)
                                        Text(result.artistName).font(.subheadline)
                                        if !session.artistQuery.isEmpty, PreviewRecordingMatcher.artistRelation(result.artistName, session.artistQuery) == nil {
                                            Text(L10n.text("Different artist / cover: provisional match; timing may not fit this recording"))
                                                .font(.caption2).foregroundStyle(accent)
                                        }
                                        let match = session.matchAssessment(for: result)
                                        Text(L10n.text("Match score %1$@/100%2$@", String(describing: match.score), String(describing: session.recommendedID == result.id ? L10n.text(" · Recommended") : "")))
                                            .font(.caption.monospaced()).foregroundStyle(accent)
                                            .help(match.explanation + L10n.text("; the score is not a synchronization accuracy percentage."))
                                        if result.requiresManualSelection { Text(L10n.text("Recording metadata is unverified; preview only, without automatic saving")).font(.caption2).foregroundStyle(accent) }
                                        if result.requiresManualSelection, session.playbackAvailable,
                                           result.sourceSongID == AMLLSource.recordingID(session.playback?.trackID) {
                                            Text(L10n.text("Spotify recording IDs match; duration and audible synchronization remain unverified")).font(.caption2).foregroundStyle(accent)
                                        }
                                        if PreviewRecordingMatcher.artistRelation(result.artistName, session.artistQuery) == .searchLabel {
                                            Text(L10n.text("Artist search-alias candidate; recording identity is unconfirmed")).font(.caption2).foregroundStyle(accent)
                                        }
                                        Text(result.albumName.isEmpty ? L10n.text("Unknown album") : result.albumName).font(.caption).lineLimit(2)
                                        Text(L10n.text("%1$@ · %2$@ · %3$@ lines", String(describing: result.lyricType), String(describing: result.durationMS.map { Self.time(Double($0)) } ?? L10n.text("Unknown duration")), String(describing: result.lyrics.count)))
                                            .font(.caption.monospaced())
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(session.selectedID == result.id ? accent.opacity(0.12) : .white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(session.selectedID == result.id ? accent : .clear, lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text(L10n.text("Valid timed lyrics load at the highest score available so far; higher scores replace them, including 100. Source order breaks ties. Manual choices, offsets and revalidated saved choices take priority. A score is not synchronization accuracy; low-scoring or unverified versions are provisional."))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(20).frame(minWidth: 280, idealWidth: 310, maxWidth: 350)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("02 / Follow line by line")).font(.headline)
                        Spacer()
                        Toggle(L10n.text("Auto-scroll"), isOn: $autoScroll).toggleStyle(.checkbox)
                    }
                    if let selected = session.selected {
                        let activeIndex = session.activeIndex
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(Array(selected.lyrics.enumerated()), id: \.element.id) { index, line in
                                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                                            Text(Self.time(line.startTimeMS)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 45)
                                            Text(line.words.isEmpty ? "♪" : line.words)
                                                .font(.custom("Avenir Next", size: activeIndex == index ? 30 : 23))
                                                .fontWeight(activeIndex == index ? .bold : .regular)
                                                .foregroundStyle(activeIndex == index ? accent : ink.opacity(0.45))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 5).id(index)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityAddTraits(.isStaticText)
                                        .accessibilityLabel("\(activeIndex == index ? L10n.text("Current line") : L10n.text("Lyric line")) \(index + 1)，\(Self.time(line.startTimeMS))，\(line.words)")
                                    }
                                }.padding(.vertical, 80)
                            }
                            .onChange(of: session.activeIndex) { _, index in
                                guard autoScroll else { return }
                                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(index ?? 0, anchor: index == nil ? .top : .center) }
                            }
                            .onChange(of: session.selectedID, initial: true) {
                                if let index = session.activeIndex { proxy.scrollTo(index, anchor: .center) }
                            }
                            .onChange(of: autoScroll) {
                                if autoScroll, let index = session.activeIndex { proxy.scrollTo(index, anchor: .center) }
                            }
                        }
                        .id(selected.id)
                    } else {
                        ContentUnavailableView(session.unselectedLyricsTitle, systemImage: "text.alignleft", description: Text(session.unselectedLyricsDetail))
                    }
                    Divider()
                    HStack {
                        Toggle(L10n.text("Follow playback"), isOn: $session.followsPlayback).toggleStyle(.switch)
                        Text("\(Self.time(session.displayedPositionMS)) / \(Self.time(Double(session.displayedDurationMS ?? 0)))")
                            .monospacedDigit()
                        Spacer()
                        Text(session.activeIndex.map { L10n.text("Current line %1$@", String(describing: $0 + 1)) }
                             ?? (session.followsPlayback && !session.playbackAvailable ? L10n.text("No valid playback position")
                                 : session.selected == nil ? session.unselectedLyricsTitle : L10n.text("Before the first line")))
                            .font(.caption)
                    }
                    if !session.followsPlayback {
                        Slider(value: $session.previewPositionMS, in: 0...Double(max(1, session.displayedDurationMS ?? 300000)))
                            .accessibilityLabel(L10n.text("Preview position (does not change Spotify)"))
                        Text(L10n.text("The manual cursor only checks display and seeking; it does not change the player.")) .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(L10n.text("Lyric offset %1$@ ms", String(describing: Int(session.offsetMS)))).font(.caption.monospaced()).frame(width: 145, alignment: .leading)
                        Slider(value: $session.offsetMS, in: -10000...10000, step: 50).accessibilityLabel(L10n.text("Lyric offset"))
                        Button(L10n.text("Reset")) { session.offsetMS = 0 }.keyboardShortcut("0", modifiers: .command)
                    }
                    HStack {
                        Button(L10n.text("50 ms earlier")) { session.offsetMS -= 50 }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                        Button(L10n.text("50 ms later")) { session.offsetMS += 50 }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                        Text(L10n.text("Command-Option-Left / Right to adjust; Command-0 to reset")).font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(session.memoryMessage).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("Forget this track")) { session.forgetCurrentChoice() }.disabled(!session.playbackAvailable)
                    }
                    Text(L10n.text("Positive offsets delay highlighting. Synchronization is line-by-line, not word timing, singing emphasis or breath notation.")) .font(.caption2).foregroundStyle(.secondary)
                }.padding(24).frame(minWidth: 480)
            }
            Divider()
            HStack {
                Text(L10n.text("LyricMate / Lyrics workspace")).font(.caption.monospaced())
#if PREVIEW_ACCEPTANCE
                Text(verbatim: "Focus: \(String(describing: queryFocus)) / last: \(lastQueryFocus) / return: \(returnQueryFocus)").font(.caption2)
#endif
                Spacer()
                Text(controller.traceMessage).font(.caption2)
                Button(L10n.text("Preview redacted diagnostics")) {
                    pendingShareDiagnostics = ShareDiagnosticsPreview(text: controller.shareDiagnosticsPreview())
                }
                Button(L10n.text("Full local diagnostics...")) { confirmFullDiagnostics = true }
            }.padding(12)
            if !controller.automaticDiagnosticsMessage.isEmpty {
                Text(controller.automaticDiagnosticsMessage).font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .foregroundStyle(ink).tint(accent)
        .background(LinearGradient(colors: [paper, Color(red: 0.90, green: 0.93, blue: 0.89)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(minWidth: 860, minHeight: 660)
        .sheet(isPresented: $showSources, onDismiss: restoreQueryFocus) {
            PreviewSourcesView(registry: controller.registry, changed: { session.sourcesChanged() }, setupMessage: controller.sourceSetupMessage,
                               initialTrack: session.trackQuery, initialArtist: session.artistQuery)
        }
        .sheet(isPresented: $showFiles, onDismiss: restoreQueryFocus) { PreviewFilesView(controller: controller) }
        .sheet(item: $pendingShareDiagnostics) { preview in
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Preview redacted diagnostics")).font(.headline)
                Text(L10n.text("Only diagnostic stages, statuses, control actions, timings and numeric errors are included. No song, source URL, process ID, request ID, absolute time or lyrics. Review before sharing; saving does not upload."))
                    .font(.caption)
                ScrollView {
                    Text(verbatim: preview.text).font(.caption.monospaced()).foregroundStyle(.primary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("redacted-diagnostics-preview")
                }
                HStack {
                    Button(L10n.text("Cancel")) { pendingShareDiagnostics = nil }
                    Spacer()
                    Button(L10n.text("Save reviewed copy locally")) {
                        controller.saveShareDiagnostics(preview.text)
                        pendingShareDiagnostics = nil
                    }
                }
            }.padding(20).frame(width: 640, height: 480)
        }
        .alert(L10n.text("Save detailed diagnostics locally?"), isPresented: $confirmFullDiagnostics) {
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Save sync diagnostics")) { controller.exportTrace() }
        } message: {
            Text(L10n.text("Detailed diagnostics contain song metadata, playback history, timestamps and process information. Keep them private. Use the redacted preview for public feedback."))
        }
        .defaultFocus($queryFocus, returnQueryFocus)
        .onChange(of: queryFocus) { _, focus in
            if let focus { lastQueryFocus = focus }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { notification in
            queryFocusReturn.restore(after: notification)
        }
#if PREVIEW_ACCEPTANCE
        .task { if desktop == nil { await controller.follow() } }
#endif
    }

    private func openSources() {
        queryFocusReturn.capture()
        returnQueryFocus = queryFocus ?? lastQueryFocus
        showSources = true
    }
    private func openFiles() {
        queryFocusReturn.capture()
        returnQueryFocus = queryFocus ?? lastQueryFocus
        showFiles = true
    }
    private func restoreQueryFocus() {
        queryFocus = returnQueryFocus
        queryFocusReturn.restore()
    }
    private static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("Development build")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(version) (\(build))"
    }

    private static func time(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "--:--" }
        let seconds = max(0, Int(milliseconds / 1000))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

#if !PREVIEW_ACCEPTANCE
@main
struct LyricPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDesktopAppDelegate.self) private var appDelegate
    @State private var desktop = PreviewDesktopPresentation(controller: PreviewController(installPlatformSources: false, incidentRecorder: PlaybackIncidentRecorder()))
    var body: some Scene {
        Window(L10n.text("LyricMate · Lyrics workspace"), id: "workbench") { PreviewWorkbenchRoot(presentation: desktop) }
            .defaultSize(width: 1040, height: 760)
            .commands { PreviewDesktopCommands(presentation: desktop) }
    }
}
#endif
