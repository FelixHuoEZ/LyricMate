import AppKit
import SwiftUI
import Observation

// This test-only entry point never discovers a real player or uses a live HTTP session.
private final class FixturePlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var second = false
    private var playing = false
    private var commandCount = 0
    private var readFailures: [PlaybackReadFailure] = []
    private var afterCommandFailures: [PlaybackReadFailure] = []
    private var commandFailure: PlaybackControlFailure?
    private var generation: Int32 = 1
    let phase: String
    init(phase: String) { self.phase = phase }
    func switchTrack(_ second: Bool) { lock.lock(); defer { lock.unlock() }; self.second = second }
    func arm(_ failures: [PlaybackReadFailure], commandFailure: PlaybackControlFailure? = nil) {
        lock.lock(); defer { lock.unlock() }
        afterCommandFailures = failures
        self.commandFailure = commandFailure
    }
    func replaceProcess() { lock.lock(); defer { lock.unlock() }; generation += 1 }
    var identity: PlaybackProcessIdentity {
        lock.lock(); defer { lock.unlock() }
        return .init(processID: generation, bundleIdentifier: "com.spotify.client", launchDate: nil)
    }
    func snapshot() throws -> PlaybackSnapshot {
        lock.lock(); defer { lock.unlock() }
        if phase == "denied" { throw PlaybackReadFailure.eventFailed(-1743) }
        if phase == "missing" { throw PlaybackReadFailure.missingApplication }
        if !readFailures.isEmpty { throw readFailures.removeFirst() }
        return .init(trackID: second ? "spotify:track:SyntheticB" : "spotify:track:SyntheticA",
                     trackName: second ? "Second Song" : "Song", artistName: "Artist", albumName: "Album",
                     durationMS: 30000, positionMS: 1500, isPlaying: playing)
    }
    func command(_ request: PlaybackControlRequest) throws {
        Thread.sleep(forTimeInterval: 0.15)
        lock.lock(); defer { lock.unlock() }
        commandCount += 1
        if let failure = commandFailure { commandFailure = nil; throw failure }
        readFailures = afterCommandFailures
        afterCommandFailures = []
        switch request.command {
        case .togglePlayback: playing.toggle()
        case .nextTrack: second = true
        case .previousTrack: second = false
        case .backward10, .forward10: break
        }
    }
    var commands: Int { lock.lock(); defer { lock.unlock() }; return commandCount }
}

private final class FixtureHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "fixture.invalid", url.scheme == "https" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = url.path.hasPrefix("/api/get/") ? url.lastPathComponent : nil
        let second = query.contains { ($0.value ?? "").contains("Second Song") } || id == "84" || id == "9"
        func record(_ alternate: Bool) -> [String: Any] {
            ["id": second ? (alternate ? 9 : 84) : (alternate ? 7 : 42),
             "trackName": second ? "Second Song" : "Song", "artistName": "Artist",
             "albumName": alternate ? "Other Album" : "Album", "duration": 30,
             "instrumental": false,
             "syncedLyrics": alternate ? "[00:01.00]Synthetic alternate\n[00:03.00]Synthetic next" :
                "[00:01.00]Synthetic first\n[00:03.00]Synthetic second"]
        }
        let payload: Any
        if url.path == "/api/search" { payload = [record(false), record(true)] }
        else if url.path.hasPrefix("/api/get/"), ["7", "42", "9", "84"].contains(id ?? "") {
            payload = record(id == "7" || id == "9")
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
@Observable
private final class AcceptanceRun {
    struct Check: Codable { let id: String; let passed: Bool }
    struct Report: Codable {
        let phase: String
        let processID: Int32
        let checks: [Check]
        let finished: Bool
        let passed: Bool
    }
    private enum Failure: Error { case check, arguments }
    let workspace: URL
    let suite: String
    let phase: String
    let controller: PreviewController
    let desktop: PreviewDesktopPresentation
    let player: FixturePlayer
    private(set) var checks: [Check] = []
    private(set) var status = "Ready; isolated synthetic data only"
    private(set) var running = false
    private(set) var finished = false
    private let expectedFrame: NSRect?

    init() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        phase = value("--phase") ?? "seed"
        guard ["seed", "restore", "denied", "missing", "recovery"].contains(phase), let path = value("--workspace") else {
            fatalError("Use a documented phase and a new temporary acceptance workspace")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let sharedTemporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("lyricmate-alpha-acceptance."),
              root.lastPathComponent.count < 100,
              [temporary.path, sharedTemporary.path].contains(root.deletingLastPathComponent().path) else {
            fatalError("Acceptance workspace must be a dedicated direct child of a temporary directory")
        }
        workspace = root
        suite = "local.lyricmate.alpha.acceptance." + root.lastPathComponent
        let defaults = UserDefaults(suiteName: suite)!
        expectedFrame = defaults.string(forKey: "presentation.frame").map(NSRectFromString)
        let fixture = FixturePlayer(phase: phase)
        player = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureHTTP.self]
        let session = URLSession(configuration: configuration)
        let manifest = LyricSourceManifest(schemaVersion: 1, apiVersion: 1, name: "Synthetic fixture",
            baseURL: "https://fixture.invalid/", capabilities: ["search", "syncedLyrics"],
            auth: .init(type: "none"), format: .lrclib)
        let provider = try! CustomHTTPSourceProvider(manifest: manifest, client: LyricHTTPClient(session: session), requestDelay: 0)
        let reader = ReadOnlySpotifyReader(snapshotWork: { _, _, _ in try fixture.snapshot() })
        let control = SpotifyPlaybackControl(queue: reader.serializedQueue, work: { try fixture.command($0) })
        let controller = PreviewController(defaults: defaults, builtin: provider,
            localDirectory: root.appendingPathComponent("local-lyrics", isDirectory: true), reader: reader,
            processLookup: { fixture.identity },
            allowsPlaybackControl: true, playbackControl: control,
            makeProvider: { manifest in
                try CustomHTTPSourceProvider(manifest: manifest, client: LyricHTTPClient(session: session), requestDelay: 0)
            })
        self.controller = controller
        desktop = PreviewDesktopPresentation(controller: controller)
    }

    func check(_ id: String, _ passed: @autoclosure () -> Bool) throws {
        let result = passed()
        checks.append(.init(id: id, passed: result))
        if !result { throw Failure.check }
    }
    private func wait(_ id: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(id, condition())
    }
    private func select(_ id: String) throws {
        guard let candidate = controller.session.results.first(where: { $0.sourceSongID == id }) else { throw Failure.check }
        controller.session.select(candidate.id)
    }

    private func snapshot(_ name: String, view: NSView?) throws {
        guard let view, view.window?.isVisible == true,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            try check("native-render-" + name, false); return
        }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let bytes = image.representation(using: .png, properties: [:]) else {
            try check("native-render-" + name, false); return
        }
        try bytes.write(to: workspace.appendingPathComponent(phase + "-" + name + ".png"), options: .atomic)
        try check("native-render-" + name, image.pixelsWide > 100 && image.pixelsHigh > 20)
    }

    func run() async {
        guard !running, !finished else { return }
        running = true; status = "Running isolated native checks"
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if phase == "restore" {
                try check("persisted-settings-loaded", controller.presentationSettings.fontSize == 35 &&
                    controller.presentationSettings.showsFloatingLyrics && !controller.presentationSettings.showsNextLine &&
                    controller.presentationSettings.resumesSpotify)
                try check("sources-loaded", controller.registry.store.sources.count == 1 &&
                    controller.registry.store.sources.first?.isEnabled == false)
            } else {
                try check("fresh-defaults", controller.isolatedDefaults.persistentDomain(forName: suite) == nil)
                try check("fresh-disconnected-empty", !controller.enabled && controller.session.results.isEmpty &&
                    !controller.presentationSettings.showsFloatingLyrics && !controller.presentationSettings.resumesSpotify)
                try check("platforms-not-installed", controller.registry.store.sources.isEmpty && controller.registry.enabledProviders.isEmpty)
            }
            try await Task.sleep(for: .milliseconds(500))
            try snapshot("initial", view: NSApp.windows.first { $0.title == "LyricMate Alpha Acceptance" }?.contentView)
            desktop.startFollowing()
            try check("native-menu-installed", desktop.acceptanceMenuVisible && desktop.acceptanceFollowStarted)
            if phase == "restore" {
                try check("restart-does-not-prompt", !controller.acceptanceAllowsPermissionPrompt)
            } else { controller.requestPermission() }
            if phase == "recovery" {
                try await recovery()
            } else if phase == "denied" || phase == "missing" {
                try await wait("failure-stops-following", until: { !self.controller.enabled })
                try check("unavailable-does-not-highlight", !controller.session.playbackAvailable && controller.session.activeIndex == nil)
                try check("unavailable-controls-disabled", !controller.canControlPlayback && player.commands == 0)
                try check("visible-failure-message", !controller.connection.isEmpty)
                if phase == "denied" { try check("denied-error-classified", controller.connection.contains("-1743")) }
                try await Task.sleep(for: .milliseconds(700))
                try check("no-automatic-retry", !controller.enabled)
            } else {
                try await wait("two-candidates-loaded", until: { self.controller.session.results.count == 2 && !self.controller.session.isSearching })
                if phase == "seed" { try await seed() } else { try await restore() }
                try check("no-source-errors", controller.session.sourceErrors.isEmpty)
                desktop.showFloating()
                try await Task.sleep(for: .milliseconds(200))
                try check("native-transparent-two-line-panel", desktop.acceptancePanel?.isVisible == true &&
                    desktop.acceptancePanel?.isOpaque == false && desktop.acceptancePanel?.hasShadow == false &&
                    desktop.acceptancePanel?.styleMask.contains(.titled) == false)
                desktop.setFloatingHovered(false)
                try check("controls-hidden-without-hover", !desktop.floatingControlsVisible)
                try await Task.sleep(for: .milliseconds(200))
                try snapshot("floating-hidden", view: desktop.acceptancePanel?.contentView)
                desktop.setFloatingHovered(true)
                try check("controls-visible-on-hover", desktop.floatingControlsVisible)
                try await Task.sleep(for: .milliseconds(200))
                try snapshot("floating-controls", view: desktop.acceptancePanel?.contentView)
                desktop.setFloatingHovered(false)
                desktop.settings.locked = true; desktop.applyLock()
                try check("locked-click-through", desktop.acceptancePanel?.ignoresMouseEvents == true && !desktop.floatingControlsVisible)
                desktop.settings.locked = false; desktop.applyLock()
                desktop.toggleMenu()
                try await Task.sleep(for: .milliseconds(150))
                try check("native-menu-panel-visible", desktop.acceptanceMenuShown)
                try snapshot("menu", view: desktop.acceptanceMenuWindow?.contentView)
                desktop.toggleMenu()
                try await command(.togglePlayback)
                try check("command-readback-playing", controller.session.playback?.isPlaying == true)
                try await command(.togglePlayback)
                try check("command-readback-paused", controller.session.playback?.isPlaying == false)
                try check("only-requested-commands", player.commands == 2)
            }
            finished = true; status = "Passed \(checks.count) checks; safe to inspect or quit"
        } catch {
            finished = true; status = "Failed after \(checks.count) checks; inspect the report"
        }
        controller.isolatedDefaults.synchronize()
        let report = Report(phase: phase, processID: ProcessInfo.processInfo.processIdentifier, checks: checks,
                            finished: finished, passed: !checks.isEmpty && checks.allSatisfy(\.passed) && status.hasPrefix("Passed"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let bytes = try? encoder.encode(report) {
            try? bytes.write(to: workspace.appendingPathComponent(phase + ".json"), options: .atomic)
        }
        running = false
        if ProcessInfo.processInfo.arguments.contains("--auto-exit") { NSApp.terminate(nil) }
    }

    private func command(_ command: PlaybackControlCommand) async throws {
        controller.performPlaybackCommand(command)
        try check("command-immediate-feedback", controller.controlBusy && controller.pendingControlCommand == command && !controller.controlMessage.isEmpty)
        try await wait("command-safe-readback-completes", until: { !self.controller.controlBusy })
    }

    private func recovery() async throws {
        try await wait("recovery-initial-read", until: { self.controller.canControlPlayback })
        let recoveredMessage = L10n.text("Spotify playback following recovered; controls reflect the latest read. The command was not resent.")
        func start(_ failures: [PlaybackReadFailure]) async throws {
            player.arm(failures)
            controller.performPlaybackCommand(.nextTrack)
            try await wait("transient-read-discarded", until: { !self.controller.session.playbackAvailable })
        }
        func reconnect() async throws {
            controller.requestPermission()
            try await wait("manual-reconnect", until: { self.controller.canControlPlayback })
        }
        try await start([.trackChanged, .bridgeUnavailable])
        try check("control-waits-for-bounded-recovery", controller.controlBusy && !controller.canControlPlayback)
        controller.performPlaybackCommand(.nextTrack)
        try await wait("safe-recovery-updates-message", until: {
            self.controller.session.playbackAvailable && !self.controller.controlBusy && self.controller.controlMessage == recoveredMessage
        })
        try check("no-resend-or-extra-click", player.commands == 1)
        try check("recovered-new-track", controller.session.playback?.trackID == "spotify:track:SyntheticB")
        let events = controller.acceptanceControlDiagnostics.last?.events ?? []
        try check("failed-readback-retained", events.contains { $0.stage == .readback && $0.status == .failed })
        try check("recovery-recorded-separately", events.contains { $0.stage == .recovery && $0.status == .succeeded })

        try await start([.eventFailed(-1712)])
        try await wait("transient-event-timeout-recovers", until: {
            self.controller.session.playbackAvailable && !self.controller.controlBusy && self.controller.controlMessage == recoveredMessage
        })
        try check("timeout-does-not-resend", player.commands == 2)

        player.arm([], commandFailure: .event(-1743))
        try await command(.togglePlayback)
        let failureMessage = controller.controlMessage
        try check("control-denial-message-preserved", failureMessage == PlaybackControlFailure.event(-1743).message)
        try await Task.sleep(for: .milliseconds(1100))
        try check("ordinary-read-preserves-command-failure", controller.controlMessage == failureMessage && failureMessage != recoveredMessage)
        try await command(.togglePlayback)
        try check("new-command-replaces-old-message", controller.controlMessage != failureMessage && controller.session.playback?.isPlaying == true)

        try await start([.trackChanged])
        player.replaceProcess()
        try await wait("replacement-process-read", until: { self.controller.session.playbackAvailable && !self.controller.controlBusy })
        try check("replacement-process-not-confirmed", controller.controlMessage != recoveredMessage)

        try await start([.trackChanged, .eventFailed(-1743)])
        try await wait("denial-stops-recovery", until: { !self.controller.enabled && !self.controller.controlBusy })
        try check("denial-not-confirmed", controller.controlMessage != recoveredMessage)
        try await reconnect()
        try check("reconnect-does-not-confirm-old-command", controller.controlMessage != recoveredMessage)

        try await start([.trackChanged, .trackChanged, .trackChanged])
        try await wait("recovery-budget-exhausted", until: { !self.controller.enabled && !self.controller.controlBusy })
        try check("exhaustion-not-confirmed", controller.controlMessage != recoveredMessage)
        try await reconnect()
        try await start([.trackChanged])
        desktop.stopFollowing()
        try await wait("cancel-clears-readback", until: { !self.controller.enabled && !self.controller.controlBusy })
        desktop.startFollowing()
        try await reconnect()
        try check("cancelled-command-not-confirmed", controller.controlMessage != recoveredMessage)
        try check("cancelled-recovery-diagnostic", controller.acceptanceControlDiagnostics.last?.events.contains {
            $0.stage == .recovery && $0.status == .cancelled
        } == true)
        try check("exact-command-count", player.commands == 8)
        controller.exportTrace(to: workspace.appendingPathComponent("diagnostics"))
    }

    private func seed() async throws {
        try check("synthetic-recording-valid", controller.session.playback.map { PreviewRecordingPreferences.Recording($0).valid } == true)
        try check("highest-score-selected-first", controller.session.selected?.sourceSongID == "42")
        try select("7"); controller.session.offsetMS = 450
        try select("42"); controller.session.offsetMS = -200
        try select("7")
        try check("version-specific-offset", controller.session.offsetMS == 450)
        player.switchTrack(true)
        try await wait("second-recording-loaded", until: { self.controller.session.playback?.trackName == "Second Song" &&
            self.controller.session.selected?.sourceSongID == "84" && !self.controller.session.isSearching })
        try check("recording-does-not-inherit-offset", controller.session.offsetMS == 0)
        controller.session.offsetMS = 700
        player.switchTrack(false)
        try await wait("original-version-restored", until: { self.controller.session.selected?.sourceSongID == "7" &&
            !self.controller.session.isSearching })
        try check("original-offset-restored", controller.session.offsetMS == 450)
        let manifest = LyricSourceManifest(schemaVersion: 1, apiVersion: 1, name: "Disabled synthetic source",
            baseURL: "https://fixture.invalid/optional/", capabilities: ["search", "syncedLyrics"],
            auth: .init(type: "none"), format: .lyricfeverV1)
        _ = try controller.registry.store.importManifest(JSONEncoder().encode(manifest), enabled: false)
        desktop.settings.fontSize = 35; desktop.settings.shadowOpacity = 0.7
        desktop.settings.showsNextLine = false; desktop.showFloating()
    }

    private func restore() async throws {
        try check("bound-version-not-highest-restored", controller.session.selected?.sourceSongID == "7" &&
            controller.session.rankedResults.first?.sourceSongID == "42")
        try check("offset-restored-after-process-restart", controller.session.offsetMS == 450)
        try await Task.sleep(for: .milliseconds(200))
        if let expectedFrame, let panel = desktop.acceptancePanel {
            try check("floating-position-restored", abs(panel.frame.minX - expectedFrame.minX) < 2 &&
                abs(panel.frame.minY - expectedFrame.minY) < 2)
        } else { try check("floating-position-restored", false) }
        try select("42")
        try check("other-version-offset-restored", controller.session.offsetMS == -200)
        try select("7")
        try check("return-to-bound-version-offset", controller.session.offsetMS == 450)
        player.switchTrack(true)
        try await wait("other-recording-restored", until: { self.controller.session.selected?.sourceSongID == "84" &&
            self.controller.session.playback?.trackName == "Second Song" && !self.controller.session.isSearching })
        try check("other-recording-own-offset-restored", controller.session.offsetMS == 700)
        player.switchTrack(false)
        try await wait("return-to-original-recording", until: { self.controller.session.selected?.sourceSongID == "7" &&
            !self.controller.session.isSearching })
        try check("bound-offset-still-isolated", controller.session.offsetMS == 450)
    }
}

@main
struct SourceAlphaAcceptanceApp: App {
    @NSApplicationDelegateAdaptor(PreviewDesktopAppDelegate.self) private var delegate
    @State private var run = AcceptanceRun()
    var body: some Scene {
        Window("LyricMate Alpha Acceptance", id: "acceptance") {
            VStack(spacing: 0) {
                LyricPreviewView(controller: run.controller, desktop: run.desktop)
                Divider()
                HStack {
                    Text(verbatim: run.phase + ": " + run.status).font(.caption.monospaced())
                    Spacer()
                    Button("Run isolated checks") { Task { await run.run() } }
                        .disabled(run.running || run.finished).accessibilityIdentifier("run-isolated-checks")
                    Button("Quit acceptance app") { NSApp.terminate(nil) }
                        .disabled(run.running).accessibilityIdentifier("quit-acceptance-app")
                }.padding(12)
            }.task {
                if ProcessInfo.processInfo.arguments.contains("--auto-run") { await run.run() }
            }
        }.defaultSize(width: 1040, height: 800)
    }
}
