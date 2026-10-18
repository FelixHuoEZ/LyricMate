import AppKit
import SwiftUI
import Observation

@MainActor
final class PreviewDesktopAppDelegate: NSObject, NSApplicationDelegate {
    static var isTerminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isTerminating = true
        return .terminateNow
    }
}

@MainActor
@Observable
final class PreviewDesktopPresentation: NSObject {
    let controller: PreviewController
    let settings: PreviewPresentationSettings
    private(set) var floatingVisible = false
    private(set) var floatingHovered = false
    private(set) var floatingMetrics = PreviewFloatingTextMetrics()
    @ObservationIgnored let floatingText = PreviewLyricWrapCache()
    @ObservationIgnored private var panel: PreviewFloatingPanel?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var menuPanel: PreviewMenuPanel?
    @ObservationIgnored var openWorkbench: (() -> Void)?

    init(controller: PreviewController) {
        self.controller = controller
        settings = controller.presentationSettings
        super.init()
    }

    var lyrics: PreviewLyricPresentation { PreviewLyricPresentation(session: controller.session) }
    var floatingControlsVisible: Bool {
        return PreviewFloatingLayoutPolicy.showsControls(hovered: floatingHovered, locked: settings.locked,
                                                         visible: floatingVisible)
    }
    func setFloatingHovered(_ value: Bool) { floatingHovered = value && !settings.locked }

    func startFollowing() {
        installMenuBar()
        guard followTask == nil else { return }
        controller.restoreStartupConnection()
        if settings.showsFloatingLyrics { showFloating() }
        // App lifetime, not the workbench's visibility, owns the single read loop.
        followTask = Task { [controller] in await controller.follow() }
    }

    func stopFollowing() {
        followTask?.cancel(); followTask = nil
        menuPanel?.orderOut(nil); menuPanel = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func installMenuBar() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggleMenu)
        item.button?.imagePosition = .imageLeading
        statusItem = item
        observeMenuTitle()
    }

    private func observeMenuTitle() {
        guard let button = statusItem?.button else { return }
        withObservationTracking {
            let view = lyrics
            button.title = " " + view.menuTitle(showsLyrics: settings.showsMenuLyrics)
            button.image = NSImage(systemSymbolName: view.mode == .paused ? "pause.circle" : "music.note.list", accessibilityDescription: PreviewLyricPresentation.appName)
            button.toolTip = PreviewLyricPresentation.appName + " · " + view.status + " · 点击打开歌词面板"
            button.setAccessibilityLabel("\(PreviewLyricPresentation.appName)，\(view.status)，\(view.menuTitle(showsLyrics: settings.showsMenuLyrics))")
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMenuTitle() }
        }
    }

    @objc func toggleMenu() {
        installMenuBar()
        if menuPanel?.isVisible == true {
            menuPanel?.orderOut(nil)
#if PREVIEW_ACCEPTANCE
            acceptanceMenuChange?()
#endif
            return
        }
        if menuPanel == nil {
            menuPanel = PreviewMenuPanel(content: PreviewMenuBarContent(presentation: self))
        }
        menuPanel?.present(anchor: statusItem?.button?.window?.frame)
#if PREVIEW_ACCEPTANCE
        acceptanceMenuChange?()
#endif
    }

    func showWorkbench() { menuPanel?.orderOut(nil); openWorkbench?() }

    func toggleFloating() { floatingVisible ? hideFloating() : showFloating() }
    func showFloating() {
        if panel == nil {
            let window = PreviewFloatingPanel(settings: settings, textLayout: floatingText, content: PreviewFloatingLyrics(presentation: self),
                                              onHover: { [weak self] in self?.setFloatingHovered($0) })
            window.onClose = { [weak self] in
                self?.floatingVisible = false; self?.floatingHovered = false
                if !PreviewDesktopAppDelegate.isTerminating { self?.settings.showsFloatingLyrics = false }
            }
            window.onLayout = { [weak self] metrics in
                if self?.floatingMetrics != metrics { self?.floatingMetrics = metrics }
            }
            panel = window
        }
        floatingVisible = true
        settings.showsFloatingLyrics = true
        synchronizeFloatingLayout()
        panel?.applyLock()
        panel?.orderFrontRegardless()
    }
    func hideFloating() {
        panel?.orderOut(nil); floatingVisible = false; floatingHovered = false; settings.showsFloatingLyrics = false
    }
    func applyLock() { floatingHovered = false; panel?.applyLock() }
    func synchronizeFloatingLayout() { panel?.updateLyrics(controller.session.selected, waitingToSing: lyrics.isWaitingToSing) }
    func resetPosition() { panel?.restorePosition(reset: true) }

#if PREVIEW_ACCEPTANCE
    var acceptancePanel: PreviewFloatingPanel? { panel }
    var acceptanceFollowStarted: Bool { followTask != nil }
    var acceptanceMenuTitle: String? { statusItem?.button?.title }
    var acceptanceMenuVisible: Bool { statusItem?.isVisible == true }
    var acceptanceMenuShown: Bool { menuPanel?.isVisible == true }
    var acceptanceMenuWindow: NSWindow? { menuPanel }
    var acceptanceStatusFrame: String? { statusItem?.button?.window.map { NSStringFromRect($0.frame) } }
    @ObservationIgnored var acceptanceMenuChange: (() -> Void)?
#endif
}

@MainActor
final class PreviewMenuPanel: NSWindow, NSWindowDelegate {
    init(content: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 370, height: 690),
                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        title = "LyricMate · 歌词面板"
        identifier = NSUserInterfaceItemIdentifier("preview-menu-lyrics")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isReleasedWhenClosed = false
        isMovable = false
        hidesOnDeactivate = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        contentView = NSHostingView(rootView: content)
        delegate = self
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { orderOut(nil) }
    func present(anchor: NSRect?) {
        let screen = anchor.flatMap { anchor in NSScreen.screens.first { $0.frame.intersects(anchor) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 370, height: min(690, visible.height - 16))
        setContentSize(size)
        let x = min(visible.maxX - frame.width - 8, max(visible.minX + 8, (anchor?.midX ?? visible.maxX) - frame.width / 2))
        setFrameOrigin(NSPoint(x: x, y: visible.maxY - frame.height - 6))
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

struct PreviewMenuBarContent: View {
    @Bindable var presentation: PreviewDesktopPresentation
    private let accent = Color(red: 0.91, green: 0.68, blue: 0.42)

    var body: some View {
        @Bindable var settings = presentation.settings
        let lyrics = presentation.lyrics
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "music.note.list").foregroundStyle(accent)
                Text(PreviewLyricPresentation.appName).font(.headline)
                Spacer()
                Text(lyrics.status).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: lyrics.title.isEmpty ? "独立歌词工作台" : lyrics.title).font(.title3.bold()).lineLimit(2)
                Text(verbatim: lyrics.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            PreviewPlaybackControls(controller: presentation.controller)
            PreviewRollingLyrics(lyrics: lyrics, showsNextLine: settings.showsNextLine, style: .menu)
                .id(lyrics.lyricIdentity).padding(16)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            if !presentation.controller.enabled {
                Button("启用只读跟随 Spotify") { presentation.controller.requestPermission() }
                    .disabled(presentation.controller.connecting || !presentation.controller.allowsPlaybackRead)
            }
            HStack {
                Button(presentation.floatingVisible ? "隐藏悬浮歌词" : "显示悬浮歌词", systemImage: "rectangle.on.rectangle") { presentation.toggleFloating() }
                Spacer()
                Button("打开工作台", systemImage: "macwindow") {
                    presentation.showWorkbench()
                }
            }
            Divider()
            Toggle("菜单栏显示当前歌词", isOn: $settings.showsMenuLyrics)
            Toggle("显示下一句", isOn: $settings.showsNextLine)
            Toggle("锁定悬浮窗（鼠标穿透）", isOn: $settings.locked)
                .onChange(of: settings.locked) { presentation.applyLock() }
            Text(settings.locked ? "悬浮播放按钮已隐藏：先取消锁定，再将鼠标移入歌词区域。" : "将鼠标移入悬浮歌词区域，下方显示上一首、播放/暂停、下一首。")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("下次启动恢复 Spotify 连接", isOn: $settings.resumesSpotify)
                .help("只恢复已运行的 Spotify；不会自动启动播放器或弹出新的权限请求")
            HStack {
                Text("字号").frame(width: 46, alignment: .leading)
                Slider(value: $settings.fontSize, in: 20...48, step: 1).accessibilityLabel("悬浮歌词字号")
                Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 28)
            }
            HStack {
                Text("阴影").frame(width: 46, alignment: .leading)
                Slider(value: $settings.shadowOpacity, in: 0.35...0.95, step: 0.05).accessibilityLabel("悬浮歌词文字阴影强度")
                Text("\(Int((settings.shadowOpacity * 100).rounded()))%").monospacedDigit().frame(width: 36)
            }
            HStack {
                Button("重置悬浮位置") { presentation.resetPosition() }.disabled(!presentation.floatingVisible)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }.font(.caption)
            Text("歌词只读跟随 · 播放控制仅响应按钮点击").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 370)
        }
        .scrollIndicators(.hidden)
        .preferredColorScheme(.dark)
    }
}

struct PreviewPlaybackControls: View {
    @Bindable var controller: PreviewController
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                control(.backward10, symbol: "gobackward.10")
                control(.previousTrack, symbol: "backward.end.fill")
                control(.togglePlayback, symbol: controller.session.playback?.isPlaying == true ? "pause.fill" : "play.fill", prominent: true)
                control(.nextTrack, symbol: "forward.end.fill")
                control(.forward10, symbol: "goforward.10")
            }.frame(maxWidth: .infinity)
            if let snapshot = controller.session.playback, controller.session.playbackAvailable {
                ProgressView(value: min(snapshot.positionMS, Double(snapshot.durationMS)), total: Double(max(1, snapshot.durationMS)))
                    .tint(.secondary)
                HStack {
                    Text(time(snapshot.positionMS))
                    Spacer()
                    Text(time(Double(snapshot.durationMS)))
                }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(controller.controlMessage.isEmpty ? "仅控制已连接的 Spotify，不自动启动播放器" : controller.controlMessage)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func control(_ command: PlaybackControlCommand, symbol: String, prominent: Bool = false) -> some View {
        Button { controller.performPlaybackCommand(command) } label: {
            PreviewPlaybackControlLabel(symbol: symbol, pending: controller.pendingControlCommand == command)
                .font(.system(size: prominent ? 21 : 17, weight: .semibold))
                .frame(width: prominent ? 44 : 34, height: prominent ? 44 : 34)
                .background(.white.opacity(prominent ? 0.12 : 0), in: Circle())
        }
        .buttonStyle(.plain).disabled(!controller.canControlPlayback)
        .help(command.title)
        .accessibilityLabel(controller.controlAccessibilityLabel(command))
    }
    private func time(_ milliseconds: Double) -> String {
        let seconds = Int(max(0, milliseconds) / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct PreviewDesktopCommands: Commands {
    let presentation: PreviewDesktopPresentation
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("打开歌词面板") { presentation.toggleMenu() }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("显示或隐藏悬浮歌词") { presentation.toggleFloating() }.keyboardShortcut("f", modifiers: [.command, .option])
        }
    }
}

struct PreviewWorkbenchRoot: View {
    @Bindable var presentation: PreviewDesktopPresentation
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        LyricPreviewView(controller: presentation.controller, desktop: presentation)
            .onAppear {
                presentation.openWorkbench = { openWindow(id: "workbench"); NSApp.activate(ignoringOtherApps: true) }
                presentation.startFollowing()
            }
    }
}

struct PreviewFloatingLyrics: View {
    @Bindable var presentation: PreviewDesktopPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let lyrics = presentation.lyrics
        let settings = presentation.settings
        let controlsVisible = presentation.floatingControlsVisible
        VStack(spacing: 0) {
            PreviewRollingLyrics(lyrics: lyrics, showsNextLine: settings.showsNextLine,
                                 style: .floating(metrics: presentation.floatingMetrics, cache: presentation.floatingText),
                                 openFullLyrics: { presentation.showWorkbench() })
                .id(lyrics.lyricIdentity)
            if !settings.locked {
                PreviewFloatingPlaybackControls(controller: presentation.controller)
                    .frame(height: PreviewFloatingLayoutPolicy.controlsHeight)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    .disabled(!controlsVisible)
                    .accessibilityHidden(!controlsVisible)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: controlsVisible)
            }
        }
        .shadow(color: .black.opacity(settings.shadowOpacity), radius: 1, x: 0, y: 1)
        .shadow(color: .black.opacity(settings.shadowOpacity), radius: 3)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onChange(of: lyrics.lyricIdentity) { presentation.synchronizeFloatingLayout() }
        .onChange(of: lyrics.isWaitingToSing) { presentation.synchronizeFloatingLayout() }
        .onChange(of: settings.fontSize) { presentation.synchronizeFloatingLayout() }
        .onChange(of: settings.showsNextLine) { presentation.synchronizeFloatingLayout() }
        .preferredColorScheme(.dark)
    }
}

struct PreviewFloatingPlaybackControls: View {
    @Bindable var controller: PreviewController
    var body: some View {
        HStack(spacing: 18) {
            control(.previousTrack, symbol: "backward.end.fill")
            control(.togglePlayback, symbol: controller.session.playback?.isPlaying == true ? "pause.fill" : "play.fill")
            control(.nextTrack, symbol: "forward.end.fill")
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.top, 4)
    }
    private func control(_ command: PlaybackControlCommand, symbol: String) -> some View {
        Button { controller.performPlaybackCommand(command) } label: {
            PreviewPlaybackControlLabel(symbol: symbol, pending: controller.pendingControlCommand == command)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.canControlPlayback)
        .help(controller.controlMessage.isEmpty ? command.title : controller.controlMessage)
        .accessibilityLabel(controller.controlAccessibilityLabel(command))
    }
}

struct PreviewPlaybackControlLabel: View {
    let symbol: String
    let pending: Bool
    var body: some View {
        ZStack {
            Image(systemName: symbol).opacity(pending ? 0 : 1)
            if pending { ProgressView().controlSize(.small).accessibilityHidden(true) }
        }
    }
}

struct PreviewRollingLyrics: View {
    enum Style { case menu, floating(metrics: PreviewFloatingTextMetrics, cache: PreviewLyricWrapCache) }
    let lyrics: PreviewLyricPresentation
    let showsNextLine: Bool
    let style: Style
    let openFullLyrics: (() -> Void)?
    @State private var displayed: PreviewLyricPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reducesMotion: Bool {
        #if PREVIEW_MOTION_ACCEPTANCE
        return PreviewMotionAcceptance.shared.reduceMotionOverride ?? reduceMotion
        #else
        return reduceMotion
        #endif
    }

    init(lyrics: PreviewLyricPresentation, showsNextLine: Bool, style: Style, openFullLyrics: (() -> Void)? = nil) {
        self.lyrics = lyrics; self.showsNextLine = showsNextLine; self.style = style
        self.openFullLyrics = openFullLyrics
        _displayed = State(initialValue: lyrics)
    }

    private var floatingFontSize: Double? {
        if case let .floating(metrics, _) = style { return metrics.fontSize }
        return nil
    }

    private var viewportHeight: Double? {
        guard case let .floating(metrics, _) = style else { return nil }
        return metrics.viewportHeight(showsNextLine: displayed.usesTwoRows(showsNextLine: showsNextLine))
    }

    var body: some View {
        track
        .frame(maxWidth: .infinity, alignment: floatingFontSize == nil ? .leading : .center)
        .clipped()
        .onChange(of: lyrics) { previous, current in
            let push = showsNextLine && !reducesMotion && current.pushesUp(from: previous)
            #if PREVIEW_MOTION_ACCEPTANCE
            if floatingFontSize != nil { PreviewMotionAcceptance.shared.recordTransition(current: current, push: push, reduced: reducesMotion) }
            #endif
            var transaction = Transaction(animation: push ? .timingCurve(0.22, 0.61, 0.36, 1,
                                                                          duration: PreviewLyricPresentation.transitionDuration) : nil)
            transaction.disablesAnimations = !push
            withTransaction(transaction) { displayed = current }
        }
    }

    @ViewBuilder private var track: some View {
        if case let .floating(metrics, _) = style {
            let stride = metrics.stride
            ZStack(alignment: .top) {
                // Explicit offsets keep promotion directional, independent of changing row metrics.
                ForEach(displayed.rows(showsNextLine: showsNextLine)) { row in
                    floatingRow(row)
                        .offset(y: row.isCurrent ? 0 : stride)
                        .transition(.asymmetric(insertion: .offset(y: stride), removal: .offset(y: -stride)))
                }
            }
            .frame(height: viewportHeight.map { CGFloat($0) }, alignment: .top)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(displayed.rows(showsNextLine: showsNextLine)) { row in
                    lyricRow(row)
                        .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder private func floatingRow(_ row: PreviewLyricPresentation.Row) -> some View {
        if case let .floating(metrics, cache) = style {
            if row.isCountdown {
                PreviewCountdownDots(opacities: lyrics.countdownDots)
                    .frame(width: metrics.width - 20, height: metrics.blockHeight)
            } else {
                let plan = cache.plan(row.text)
                let ratio = row.isCurrent ? 1.0 : metrics.nextScale
                let color = row.isCurrent ? NSColor(srgbRed: 0.98, green: 0.83, blue: 0.62, alpha: 1)
                    : NSColor.white.withAlphaComponent(0.78)
                HStack(spacing: 6) {
                    Color.clear.frame(width: 28).accessibilityHidden(true)
                    PreviewWrappedText(plan: plan, color: color)
                        .frame(width: metrics.textWidth, height: metrics.blockHeight)
                        .scaleEffect(ratio)
                        .frame(height: metrics.blockHeight * ratio)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(rowLabel(row))
                    Group {
                        if (row.isCurrent || displayed.isWaitingToSing) && plan.needsDisclosure {
                            Button("全文") { openFullLyrics?() }
                                .font(.system(size: 11)).buttonStyle(.plain)
                                .help("这句过长，打开工作台查看完整歌词")
                                .accessibilityLabel("长句未完整显示，打开工作台查看全文")
                        } else { Color.clear.accessibilityHidden(true) }
                    }.frame(width: 28)
                }
                .frame(height: metrics.blockHeight * ratio)
            }
        }
    }

    @ViewBuilder private func lyricRow(_ row: PreviewLyricPresentation.Row) -> some View {
        if row.isCountdown {
            PreviewCountdownDots(opacities: lyrics.countdownDots)
                .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
        } else {
            let rowSize = row.isCurrent ? 22.0 : 16
            let accent = Color(red: 0.91, green: 0.68, blue: 0.42)
            Text(verbatim: row.text)
                .font(.system(size: rowSize, weight: row.isCurrent ? .semibold : .regular, design: .rounded))
                .foregroundStyle(row.isCurrent ? accent : .white.opacity(0.78))
                .multilineTextAlignment(.leading)
                .lineLimit(row.isCurrent ? 3 : 2)
                .accessibilityLabel(rowLabel(row))
        }
    }

    private func rowLabel(_ row: PreviewLyricPresentation.Row) -> String {
        if displayed.isWaitingToSing { return "待开唱：\(row.text)" }
        return row.isCurrent ? "\(displayed.status)，当前歌词：\(row.text)" : "下一句：\(row.text)"
    }
}

struct PreviewCountdownDots: View {
    let opacities: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle().frame(width: 5, height: 5)
                    .opacity(opacities.indices.contains(index) ? opacities[index] : 0)
            }
        }
        .foregroundStyle(Color(red: 0.98, green: 0.83, blue: 0.62))
        .animation(reduceMotion ? nil : .linear(duration: 0.15), value: opacities)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(opacities.isEmpty ? "" : "即将开唱，剩余 \(opacities.filter { $0 > 0 }.count) 秒")
        .accessibilityHidden(opacities.isEmpty)
    }
}
