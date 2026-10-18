#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
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
            button.toolTip = PreviewLyricPresentation.appName + " · " + view.status + L10n.text(" · Click to open the lyrics panel")
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
        title = L10n.text("LyricMate · Lyrics panel")
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
                Text(verbatim: lyrics.title.isEmpty ? L10n.text("Standalone lyrics workspace") : lyrics.title).font(.title3.bold()).lineLimit(2)
                Text(verbatim: lyrics.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            PreviewPlaybackControls(controller: presentation.controller)
            PreviewRollingLyrics(lyrics: lyrics, showsNextLine: settings.showsNextLine, style: .menu)
                .id(lyrics.lyricIdentity).padding(16)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            if !presentation.controller.enabled {
                Button(L10n.text("Enable read-only Spotify following")) { presentation.controller.requestPermission() }
                    .disabled(presentation.controller.connecting || !presentation.controller.allowsPlaybackRead)
            }
            HStack {
                Button(presentation.floatingVisible ? L10n.text("Hide floating lyrics") : L10n.text("Show floating lyrics"), systemImage: "rectangle.on.rectangle") { presentation.toggleFloating() }
                Spacer()
                Button(L10n.text("Open workspace"), systemImage: "macwindow") {
                    presentation.showWorkbench()
                }
            }
            Divider()
            Toggle(L10n.text("Show current lyrics in the menu bar"), isOn: $settings.showsMenuLyrics)
            Toggle(L10n.text("Show next line"), isOn: $settings.showsNextLine)
            Toggle(L10n.text("Lock floating window (click-through)"), isOn: $settings.locked)
                .onChange(of: settings.locked) { presentation.applyLock() }
            Text(settings.locked ? L10n.text("Floating controls are hidden while locked. Unlock, then hover over the lyrics.") : L10n.text("Hover over the floating lyrics to reveal Previous, Play/Pause and Next below them."))
                .font(.caption2).foregroundStyle(.secondary)
            Toggle(L10n.text("Restore Spotify connection at next launch"), isOn: $settings.resumesSpotify)
                .help(L10n.text("Only reconnects to an already-running Spotify; never launches the player or requests new permission automatically"))
            HStack {
                Text(L10n.text("Font size")).frame(width: 64, alignment: .leading)
                Slider(value: $settings.fontSize, in: 20...48, step: 1).accessibilityLabel(L10n.text("Floating lyric font size"))
                Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 28)
            }
            HStack {
                Text(L10n.text("Shadow")).frame(width: 64, alignment: .leading)
                Slider(value: $settings.shadowOpacity, in: 0.35...0.95, step: 0.05).accessibilityLabel(L10n.text("Floating lyric text shadow strength"))
                Text("\(Int((settings.shadowOpacity * 100).rounded()))%").monospacedDigit().frame(width: 36)
            }
            HStack {
                Button(L10n.text("Reset floating position")) { presentation.resetPosition() }.disabled(!presentation.floatingVisible)
                Spacer()
                Button(L10n.text("Quit")) { NSApp.terminate(nil) }
            }.font(.caption)
            Text(L10n.text("Read-only lyric following · Playback controls respond only to clicks")).font(.caption2).foregroundStyle(.secondary)
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
            Text(controller.controlMessage.isEmpty ? L10n.text("Controls only the connected Spotify; never launches the player") : controller.controlMessage)
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
            Button(L10n.text("Open lyrics panel")) { presentation.toggleMenu() }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button(L10n.text("Toggle floating lyrics")) { presentation.toggleFloating() }.keyboardShortcut("f", modifiers: [.command, .option])
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
                            Button(L10n.text("Full text")) { openFullLyrics?() }
                                .font(.system(size: 11)).buttonStyle(.plain)
                                .help(L10n.text("This line is too long; open the workspace to read it in full"))
                                .accessibilityLabel(L10n.text("Long line is not fully visible; open the workspace for full text"))
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
        if displayed.isWaitingToSing { return L10n.text("Waiting to sing: %1$@", String(describing: row.text)) }
        return row.isCurrent ? L10n.text("%1$@, current lyric: %2$@", String(describing: displayed.status), String(describing: row.text)) : L10n.text("Next line: %1$@", String(describing: row.text))
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
        .accessibilityLabel(opacities.isEmpty ? "" : L10n.text("About to sing, %1$@ seconds remaining", String(describing: opacities.filter { $0 > 0 }.count)))
        .accessibilityHidden(opacities.isEmpty)
    }
}
