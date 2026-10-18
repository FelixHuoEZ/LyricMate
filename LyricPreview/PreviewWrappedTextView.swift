import AppKit
import CoreText
import SwiftUI

struct PreviewWrappedText: NSViewRepresentable {
    let plan: PreviewWrappedLine
    let color: NSColor
    func makeNSView(context: Context) -> PreviewWrappedTextView { PreviewWrappedTextView() }
    func updateNSView(_ view: PreviewWrappedTextView, context: Context) {
        view.plan = plan; view.textColor = color; view.needsDisplay = true
    }
}

final class PreviewWrappedTextView: NSView {
    var plan = PreviewWrappedLine(fragments: [], fontSize: 30, needsDisclosure: false)
    var textColor = NSColor.white
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        let totalHeight = Double(plan.fragments.count) * plan.lineHeight
        for (index, fragment) in plan.fragments.enumerated() {
            let text = NSMutableAttributedString(attributedString: PreviewLyricWrapping.attributed(fragment, size: plan.fontSize))
            text.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: text.length))
            let line = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0; var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil) - CTLineGetTrailingWhitespaceWidth(line)
            let top = (Double(bounds.height) - totalHeight) / 2 + Double(index) * plan.lineHeight
            let baseline = Double(bounds.height) - top - (plan.lineHeight - Double(ascent + descent)) / 2 - Double(ascent)
            context.textPosition = CGPoint(x: (Double(bounds.width) - width) / 2, y: baseline)
            CTLineDraw(line, context)
        }
    }
}
