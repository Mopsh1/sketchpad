import AppKit

/// Lies over the reader's PDFView and takes the mouse only while ⌘ is held, for marking an area of a
/// page (a figure, a formula) to put on the board. Without ⌘, hit testing passes straight through to
/// the PDFView. An overlay rather than a PDFView subclass: PDFKit handles the mouse in private subviews,
/// so overriding PDFView's own mouse methods is unreliable.
final class RegionSelectOverlay: NSView {
    /// The marked area, in this view's coordinates.
    var onSelect: ((NSRect) -> Void)?
    weak var pdfView: NSView?

    private var start: NSPoint?
    private let marquee = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        marquee.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        marquee.strokeColor = NSColor.controlAccentColor.cgColor
        marquee.lineWidth = 1
        marquee.lineDashPattern = [4, 3]
        layer?.addSublayer(marquee)
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSEvent.modifierFlags.contains(.command) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        marquee.path = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        marquee.path = CGPath(rect: Self.rect(start, location(of: event)), transform: nil)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            marquee.path = nil
        }
        guard let start else { return }
        let rect = Self.rect(start, location(of: event))
        // A ⌘-click, not a drag.
        guard rect.width >= 8, rect.height >= 8 else { return }
        onSelect?(rect)
    }

    // With ⌘ held the overlay is hit; keep ⌘-scrolling and pinching working on the page.
    override func scrollWheel(with event: NSEvent) {
        pdfView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        pdfView?.magnify(with: event)
    }

    /// The pointer, held inside the PDF area when the drag goes past it (over the thumbnails, say).
    private func location(of event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
