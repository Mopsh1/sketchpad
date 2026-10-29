// Renders the Sketchpad app icon (violet tile + a tilted sheet with a hand-drawn box, circle and
// arrow on it) at every size the macOS AppIcon set needs.
// Usage: swift Scripts/make-icon.swift Sketchpad/Assets.xcassets/AppIcon.appiconset
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: make-icon.swift <AppIcon.appiconset directory>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let s = CGFloat(pixels)

    // Apple's macOS icon grid: the tile fills ~824/1024 of the canvas, leaving room for a shadow.
    let inset = s * 0.094
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035,
                 color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.41, green: 0.40, blue: 0.86, alpha: 1).setFill()
    tilePath.fill()
    cg.restoreGState()

    cg.saveGState()
    tilePath.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.58, green: 0.56, blue: 0.96, alpha: 1),
                        NSColor(calibratedRed: 0.34, green: 0.32, blue: 0.80, alpha: 1)])!
        .draw(in: tile, angle: -90)
    cg.restoreGState()

    let w = tile.width
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + x * w, y: tile.minY + y * w)
    }

    // The sheet, tilted a little like paper dropped on a desk.
    cg.saveGState()
    cg.translateBy(x: tile.midX, y: tile.midY)
    cg.rotate(by: -0.10)
    cg.translateBy(x: -tile.midX, y: -tile.midY)
    let sheet = CGRect(origin: point(0.18, 0.17), size: CGSize(width: 0.64 * w, height: 0.66 * w))
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02,
                 color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
    NSBezierPath(roundedRect: sheet, xRadius: 0.04 * w, yRadius: 0.04 * w).fill()
    cg.restoreGState()

    // Ink strokes: a box, a circle and the arrow joining them.
    let ink = NSColor(calibratedRed: 0.14, green: 0.13, blue: 0.30, alpha: 1)
    ink.setStroke()
    func stroked(_ path: NSBezierPath) {
        path.lineWidth = 0.035 * w
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
    stroked(NSBezierPath(roundedRect: CGRect(origin: point(0.27, 0.52), size: CGSize(width: 0.24 * w, height: 0.19 * w)),
                         xRadius: 0.03 * w, yRadius: 0.03 * w))
    stroked(NSBezierPath(ovalIn: CGRect(origin: point(0.50, 0.24), size: CGSize(width: 0.22 * w, height: 0.20 * w))))

    let arrow = NSBezierPath()
    arrow.move(to: point(0.42, 0.50))
    arrow.curve(to: point(0.53, 0.40), controlPoint1: point(0.42, 0.44), controlPoint2: point(0.47, 0.40))
    stroked(arrow)
    let head = NSBezierPath()
    head.move(to: point(0.47, 0.44))
    head.line(to: point(0.535, 0.40))
    head.line(to: point(0.48, 0.355))
    stroked(head)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        guard let data = render(pixels: size * scale) else {
            print("failed to render \(name)")
            exit(1)
        }
        try! data.write(to: outDir.appendingPathComponent(name))
        print("wrote \(name)")
    }
}
