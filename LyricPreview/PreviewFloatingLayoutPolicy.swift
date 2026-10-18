import Foundation

enum PreviewFloatingLayoutPolicy {
    static let defaultWidth = 720.0
    static let maximumWidth = 1200.0
    // Text padding and balanced disclosure gutters keep lyrics centered.
    static let horizontalChrome = 88.0
    static let controlsHeight = 40.0

    static func width(textWidth: Double, screenWidth: Double) -> Double {
        let screen = screenWidth.isFinite && screenWidth > 0 ? screenWidth : 1440
        let limit = max(1, min(maximumWidth, screen - 32))
        let text = textWidth.isFinite ? max(0, textWidth) : 0
        return min(limit, max(min(defaultWidth, limit), ceil(text + horizontalChrome)))
    }

    static func height(fontSize: Double, showsNextLine: Bool, locked: Bool) -> Double {
        let size = fontSize.isFinite ? min(48, max(20, fontSize)) : 30
        let lyrics = size * 1.45 + (showsNextLine ? max(16, size * 0.72) * 1.45 + 5 : 0)
        return ceil(lyrics + 14 + (locked ? 0 : controlsHeight))
    }

    static func showsControls(hovered: Bool, locked: Bool, visible: Bool) -> Bool {
        hovered && !locked && visible
    }

    static func startsDrag(y: Double, locked: Bool) -> Bool {
        !locked && y.isFinite && y >= controlsHeight + 7
    }
}
