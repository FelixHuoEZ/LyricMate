import AppKit
import SwiftUI

@MainActor
final class PreviewFloatingPanel: NSPanel, NSWindowDelegate {
    private let settings: PreviewPresentationSettings
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var song: SongResult?
    private var waitingToSing = false
    private let textLayout: PreviewLyricWrapCache
    var onLayout: ((PreviewFloatingTextMetrics) -> Void)?
    var onClose: (() -> Void)?
    var allowsLyricDragging: Bool { !settings.locked }

    init(settings: PreviewPresentationSettings, textLayout: PreviewLyricWrapCache, content: some View, onHover: @escaping (Bool) -> Void) {
        self.settings = settings
        self.textLayout = textLayout
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "LyricMate · 悬浮歌词"
        identifier = NSUserInterfaceItemIdentifier("preview-floating-lyrics")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        acceptsMouseMovedEvents = true
        hasShadow = false
        minSize = NSSize(width: 1, height: 40)
        maxSize = NSSize(width: 1200, height: 600)
        let hosting = PreviewHoverHostingView(rootView: content.ignoresSafeArea())
        hosting.onHover = onHover
        contentView = hosting
        delegate = self
        restorePosition()
        synchronizeLayout()
        applyLock()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func applyLock() {
        ignoresMouseEvents = settings.locked
        isMovableByWindowBackground = false
        dragStartMouse = nil
        dragStartOrigin = nil
        synchronizeLayout()
    }

    func updateLyrics(_ song: SongResult?, waitingToSing: Bool = false) {
        self.song = song
        self.waitingToSing = waitingToSing
        synchronizeLayout()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where allowsLyricDragging:
            if PreviewFloatingLayoutPolicy.startsDrag(y: event.locationInWindow.y, locked: settings.locked) {
                dragStartMouse = NSEvent.mouseLocation
                dragStartOrigin = frame.origin
            } else {
                dragStartMouse = nil
                dragStartOrigin = nil
            }
        case .leftMouseDragged where allowsLyricDragging:
            if let start = dragStartMouse, let origin = dragStartOrigin {
                let mouse = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
                return
            }
        case .leftMouseUp:
            dragStartMouse = nil
            dragStartOrigin = nil
        default: break
        }
        super.sendEvent(event)
    }

    func synchronizeLayout() {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The autoclosure is evaluated only when candidate, font or screen width changes.
        textLayout.configure(identity: song?.id, texts: (song?.lyrics ?? []).map { PreviewLyricPresentation.displayText($0.words) },
                             fontSize: settings.fontSize, screenWidth: visible.width)
        let metrics = textLayout.metrics
        onLayout?(metrics)
        let width = metrics.width
        let height = ceil(metrics.viewportHeight(showsNextLine: settings.showsNextLine || waitingToSing) + 14 + (settings.locked ? 0 : PreviewFloatingLayoutPolicy.controlsHeight))
        let x = min(visible.maxX - width - 16, max(visible.minX + 16, frame.midX - width / 2))
        let y = min(visible.maxY - height, max(visible.minY, frame.minY))
        let target = NSRect(x: x, y: y, width: width, height: height)
        if frame != target { setFrame(target, display: true) }
        savePosition()
    }

    func restorePosition(reset: Bool = false) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = settings.savedFrame.map(NSRectFromString)
        if !reset, let saved, [saved.minX, saved.minY, saved.width, saved.height].allSatisfy({ $0.isFinite }),
           saved.width >= 100, saved.width <= maxSize.width,
           saved.height >= minSize.height, saved.height <= maxSize.height,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersection(saved).width >= 100 && $0.visibleFrame.intersection(saved).height >= 60 }) {
            setFrame(saved, display: false)
        } else {
            setFrame(NSRect(x: visible.midX - 360, y: visible.minY + 70, width: 720, height: 100), display: false)
        }
        synchronizeLayout()
        savePosition()
    }

    func windowDidMove(_ notification: Notification) { savePosition() }
    func windowDidResize(_ notification: Notification) { savePosition() }
    func windowDidChangeScreen(_ notification: Notification) { synchronizeLayout() }
    func windowWillClose(_ notification: Notification) { savePosition(); onClose?() }
    private func savePosition() { settings.savedFrame = NSStringFromRect(frame) }
}

// SwiftUI onHover can miss events over embedded AppKit text in a nonactivating panel.
@MainActor
private final class PreviewHoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseMoved(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
