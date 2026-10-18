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
    private(set) var connection = "只读接入未启用；可以先搜索、预览歌词。"
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
            catch { sourceSetupMessage = "未自动添加平台来源：\(error.localizedDescription)；原配置已保留，可在源管理手动添加。" }
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
        if incidentRecorder != nil { automaticDiagnosticsMessage = "故障现场自动保存在本机；最多 20 份、7 天。" }
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
        readStage = "等待最小播放状态查询"
        session.followsPlayback = true
        connection = "正在只读接入；如出现系统权限提示，请由你决定。"
    }

    func restoreStartupConnection() {
        guard !restoredStartup else { return }
        restoredStartup = true
        guard allowsPlaybackRead, presentationSettings.resumesSpotify, !enabled, readGate.enable() else { return }
        allowsPermissionPrompt = false
        session.followsPlayback = true
        readStage = "恢复上次连接；不请求新权限"
        connection = "正在恢复上次的 Spotify 连接；只读取已运行的播放器。"
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
                    ? "自动诊断留存不完整；播放跟随不受写盘失败影响。"
                    : "故障现场自动保存在本机；最多 20 份、7 天。"
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
            controlMessage = "控制响应超时；结果未确认，等待原操作返回，不自动重试。"
        }
        if enabled {
            if let request = readGate.pending {
                if readGate.expire() {
                    readDiagnostics.recordDeadline(for: request.token, elapsedMS: request.timeoutMS)
                    connection = request.requiresProbe
                        ? "初次只读接入超时；高亮已停止，不自动重试。"
                        : "只读查询超时；高亮已停止，等待本次查询返回后评估有限恢复。"
                    session.updatePlayback(nil)
                    finishControlReadback(for: request.token, status: .expired)
                }
            } else if controlGate.isBusy {
                // Do not enqueue reads behind a control whose result is still unknown.
            } else if readRecovery.isExpired() {
                incidentRecorder?.endRecovery(.windowExpired)
                readGate.stop()
                connection = "有限恢复已到 10 秒上限；高亮已停止，需要手动重新连接。"
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
                                    self.connection = "迟到结果已丢弃；旧查询已结束，有限恢复中（\(self.readRecovery.retryCount)/2），暂不高亮。"
                                    incidentRecorder?.outcome(request.token, .retryScheduled)
                                    return
                                }
                            }
                            self.readGate.stop()
                            let reason: String
                            if case .failure(let error) = result { reason = (error.errorDescription ?? "只读查询失败。") + " " }
                            else { reason = "" }
                            self.connection = reason + "迟到结果已丢弃；无法安全恢复或已达恢复上限，请手动重新连接。"
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
                            self.connection = snapshot.isPlaying ? "只读跟随 Spotify · 播放中" : "只读跟随 Spotify · 已暂停"
                            self.session.updatePlayback(snapshot)
                            readbackStatus = .succeeded
                            incidentRecorder?.outcome(request.token, .accepted)
                        case .failure(let error):
                            self.session.updatePlayback(nil)
                            switch self.readRecovery.failed(error, initialRead: request.requiresProbe) {
                            case .retry(let delay):
                                self.connection = "只读查询短暂中断；\(delay.components.seconds) 秒后重新核验进程（\(self.readRecovery.retryCount)/2），暂不高亮。"
                                incidentRecorder?.outcome(request.token, .retryScheduled)
                            case .stop:
                                self.readGate.stop()
                                self.connection = (error.errorDescription ?? "只读接入失败。") + " 已停止，不自动重试。"
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
            controlMessage = "指令已返回，但读取连接不可用；播放结果尚未确认。"
        }
    }

    private func finishControlReadback(for readID: UUID, status: PlaybackControlDiagnostics.Status) {
        guard let refresh = controlReadback, refresh.readID == readID else { return }
        controlDiagnostics.mark(refresh.request.token, stage: .readback, status: status)
        controlReadback = nil
        controlMessage = status == .succeeded
            ? "已刷新 Spotify 播放状态；按钮以实时读取为准。"
            : "指令已返回，但状态回读未成功；播放结果尚未确认，不重发指令。"
        recordTraceIfChanged()
    }

    func controlAccessibilityLabel(_ command: PlaybackControlCommand) -> String {
        if pendingControlCommand == command { return controlMessage }
        return command == .togglePlayback ? (session.playback?.isPlaying == true ? "暂停 Spotify" : "播放 Spotify") : command.title
    }

    func performPlaybackCommand(_ command: PlaybackControlCommand) {
        guard canControlPlayback, let snapshot = session.playback else { return }
        guard let process = locateSpotify(),
              let request = controlGate.begin(command, process: process, trackID: snapshot.trackID) else { return }
        controlDiagnostics.begin(request)
        controlMessage = "正在发送：\(command.title)…"
        playbackControl.send(request, diagnostics: controlDiagnostics) { [weak self] result in
            Task { @MainActor in
                guard let self, self.controlGate.finish(request.token) else { return }
                self.controlDiagnostics.uiReceived(request.token)
                switch result {
                case .success:
                    guard self.allowsPlaybackRead, self.enabled else {
                        self.controlDiagnostics.mark(request.token, stage: .readbackWait, status: .unavailable)
                        self.controlMessage = "指令已返回；读取连接未启用，播放状态尚未确认。"
                        return
                    }
                    self.controlReadback = .init(request: request)
                    self.controlDiagnostics.mark(request.token, stage: .readbackWait, status: .started)
                    self.controlMessage = "正在核对 Spotify 播放状态…"
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
            connection = "暂时未确认 Spotify 进程；正在短暂复核，高亮已停止。"
            session.updatePlayback(nil)
        case .unavailable:
            outcome = "unavailable"
            target = nil
            readGate.stop()
            incidentRecorder?.endRecovery(.stopped)
            connection = "连续 2 秒未确认 Spotify 进程；已停止，不启动或控制它。"
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
            traceMessage = "已保存本机诊断；含歌名、歌手、专辑、歌曲标识与进程信息，分享前请审查。不含歌词正文或凭据。"
        } catch { traceMessage = "诊断记录保存失败。" }
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
                    Text(session.playback?.trackName ?? "歌词预览工作台").font(.custom("Avenir Next", size: 28)).bold()
                    Text(session.playback.map { "\($0.artistName) · \($0.albumName)" } ?? "独立测试版 · 不修改正式应用")
                        .font(.caption).foregroundStyle(ink.opacity(0.7))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text(controller.connection).font(.caption)
                    if !controller.readStage.isEmpty { Text(controller.readStage).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    if !controller.enabled && controller.allowsPlaybackRead {
                        Button("启用只读跟随 Spotify") { controller.requestPermission() }
                            .disabled(controller.connecting)
                    }
                    Text("无登录凭据 · 仅点击按钮控制播放 · 本地导入不联网").font(.caption2).foregroundStyle(.secondary)
                    Text(Self.versionLabel).font(.caption2.monospaced()).accessibilityIdentifier("preview-version")
                    if let desktop {
                        Button(desktop.floatingVisible ? "隐藏悬浮歌词" : "显示悬浮歌词", systemImage: "rectangle.on.rectangle") { desktop.toggleFloating() }
                    }
                }
            }.padding(24)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("01 / 查找录音版本").font(.headline)
                    TextField("歌名", text: $session.trackQuery).textFieldStyle(.roundedBorder).accessibilityLabel("搜索歌名")
                        .focused($queryFocus, equals: .track)
                    TextField("歌手（可选）", text: $session.artistQuery).textFieldStyle(.roundedBorder).accessibilityLabel("搜索歌手（可选）")
                        .focused($queryFocus, equals: .artist)
                    HStack {
                        Button(session.isSearching ? "搜索中…" : "搜索歌词") { session.search() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(session.isSearching || session.trackQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if session.isSearching { ProgressView().controlSize(.small) }
                    }
                    Button("管理歌词源") { openSources() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("本地歌词与备份") { openFiles() }.keyboardShortcut("f", modifiers: [.command, .shift])
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
                                            Text("歌手不同 / 其他翻唱：临时匹配，时间轴可能不适合当前录音")
                                                .font(.caption2).foregroundStyle(accent)
                                        }
                                        let match = session.matchAssessment(for: result)
                                        Text("匹配分 \(match.score)/100\(session.recommendedID == result.id ? " · 推荐" : "")")
                                            .font(.caption.monospaced()).foregroundStyle(accent)
                                            .help(match.explanation + "；分数不是同步准确率。")
                                        if result.requiresManualSelection { Text("来源录音资料未核实，可临时显示，不自动记忆").font(.caption2).foregroundStyle(accent) }
                                        if result.requiresManualSelection, session.playbackAvailable,
                                           result.sourceSongID == AMLLSource.recordingID(session.playback?.trackID) {
                                            Text("Spotify 录音 ID 一致；时长与听感仍未验证").font(.caption2).foregroundStyle(accent)
                                        }
                                        if PreviewRecordingMatcher.artistRelation(result.artistName, session.artistQuery) == .searchLabel {
                                            Text("歌手搜索别名候选，录音身份未确认").font(.caption2).foregroundStyle(accent)
                                        }
                                        Text(result.albumName.isEmpty ? "专辑未知" : result.albumName).font(.caption).lineLimit(2)
                                        Text("\(result.lyricType) · \(result.durationMS.map { Self.time(Double($0)) } ?? "时长未知") · \(result.lyrics.count) 行")
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
                    Text("找到有效时间轴歌词即按当前最高分先载入，后到更高分自动替换，包括 100 分；同分按来源顺序。人工选择、偏移和已核验记忆优先。分数不是同步准确率，低分或版本未确认的候选仅临时显示。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(20).frame(minWidth: 280, idealWidth: 310, maxWidth: 350)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("02 / 逐行跟随").font(.headline)
                        Spacer()
                        Toggle("自动滚动", isOn: $autoScroll).toggleStyle(.checkbox)
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
                                        .accessibilityLabel("\(activeIndex == index ? "当前行" : "歌词行") \(index + 1)，\(Self.time(line.startTimeMS))，\(line.words)")
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
                        Toggle("实时跟随", isOn: $session.followsPlayback).toggleStyle(.switch)
                        Text("\(Self.time(session.displayedPositionMS)) / \(Self.time(Double(session.displayedDurationMS ?? 0)))")
                            .monospacedDigit()
                        Spacer()
                        Text(session.activeIndex.map { "当前第 \($0 + 1) 行" }
                             ?? (session.followsPlayback && !session.playbackAvailable ? "无有效播放进度"
                                 : session.selected == nil ? session.unselectedLyricsTitle : "尚未到第一行"))
                            .font(.caption)
                    }
                    if !session.followsPlayback {
                        Slider(value: $session.previewPositionMS, in: 0...Double(max(1, session.displayedDurationMS ?? 300000)))
                            .accessibilityLabel("预览游标（不改变 Spotify）")
                        Text("手动游标仅用于检查呈现和回跳，不改变播放器。") .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("歌词偏移 \(Int(session.offsetMS)) ms").font(.caption.monospaced()).frame(width: 145, alignment: .leading)
                        Slider(value: $session.offsetMS, in: -10000...10000, step: 50).accessibilityLabel("歌词偏移")
                        Button("归零") { session.offsetMS = 0 }.keyboardShortcut("0", modifiers: .command)
                    }
                    HStack {
                        Button("提前 50 ms") { session.offsetMS -= 50 }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                        Button("延后 50 ms") { session.offsetMS += 50 }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                        Text("⌘⌥← / → 调整，⌘0 归零").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(session.memoryMessage).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("忘记此歌曲") { session.forgetCurrentChoice() }.disabled(!session.playbackAvailable)
                    }
                    Text("正值延后高亮；这是逐行同步，不是逐字、重音或换气标注。") .font(.caption2).foregroundStyle(.secondary)
                }.padding(24).frame(minWidth: 480)
            }
            Divider()
            HStack {
                Text("LyricMate / 独立歌词工作台").font(.caption.monospaced())
#if PREVIEW_ACCEPTANCE
                Text(verbatim: "Focus: \(String(describing: queryFocus)) / last: \(lastQueryFocus) / return: \(returnQueryFocus)").font(.caption2)
#endif
                Spacer()
                Text(controller.traceMessage).font(.caption2)
                Button("保存同步诊断") { controller.exportTrace() }
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
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
        Window("LyricMate · 独立歌词工作台", id: "workbench") { PreviewWorkbenchRoot(presentation: desktop) }
            .defaultSize(width: 1040, height: 760)
            .commands { PreviewDesktopCommands(presentation: desktop) }
    }
}
#endif
