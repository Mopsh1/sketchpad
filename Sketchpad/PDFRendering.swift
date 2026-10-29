import PDFKit
import UniformTypeIdentifiers

/// Bitmaps of PDF pages for cards: the PDF card's thumbnail and region cards.
enum PDFRendering {
    /// Renders `rect` (page space) of `page` at `scale` pixels per point, shrunk when needed so the
    /// longer side stays within `maxPixels`. A rotated page comes out the way PDFView shows it.
    /// Annotations on the page are drawn too; hide the reader's own highlights first.
    static func render(_ page: PDFPage, rect: CGRect, scale: CGFloat = 2, maxPixels: CGFloat = 2400) -> CGImage? {
        let clipped = rect.intersection(page.bounds(for: .cropBox))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        // Page space → the space draw(with:to:) draws into: crop box moved to the origin, then rotated.
        let shown = clipped.applying(page.transform(for: .cropBox))
        let scale = min(scale, maxPixels / max(shown.width, shown.height))
        let width = Int((shown.width * scale).rounded())
        let height = Int((shown.height * scale).rounded())
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // PDFs assume white paper; transparent areas would show the board's background instead.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / shown.width, y: CGFloat(height) / shown.height)
        context.translateBy(x: -shown.minX, y: -shown.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// `rect` (page space) as PDFView shows it at 100 %, rotation included, in points.
    static func shownSize(of rect: CGRect, on page: PDFPage) -> CGSize {
        rect.intersection(page.bounds(for: .cropBox)).applying(page.transform(for: .cropBox)).size
    }

    /// The whole page, small enough for a card (JPEG keeps it to a few dozen KB in the board file).
    static func thumbnail(of page: PDFPage, maxPixels: CGFloat = 480) -> CGImage? {
        render(page, rect: page.bounds(for: .cropBox), maxPixels: maxPixels)
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A data: URL for the page, which keeps images inside the board file like Excalidraw's own.
    static func dataURL(_ data: Data, type: UTType) -> String {
        "data:\(type.preferredMIMEType ?? "application/octet-stream");base64,\(data.base64EncodedString())"
    }
}
