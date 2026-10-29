import PDFKit
import Testing
@testable import Sketchpad

@MainActor
struct PDFRenderingTests {
    /// The red block drawn on the test page, in page space.
    private static let red = CGRect(x: 20, y: 10, width: 40, height: 20)

    /// A 200 × 100 pt page, white, with `red` filled red.
    private func makePage() throws -> PDFPage {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(Self.red)
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data)?.page(at: 0))
    }

    /// RGBA of the pixel at (x, y), counted from the image's top left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes
    }

    private func isRed(_ rgba: [UInt8]) -> Bool { rgba[0] > 200 && rgba[1] < 60 && rgba[2] < 60 }
    private func isWhite(_ rgba: [UInt8]) -> Bool { rgba[0] > 240 && rgba[1] > 240 && rgba[2] > 240 }

    @Test func rendersTheRegionAtTwicePointSize() throws {
        let image = try #require(PDFRendering.render(try makePage(), rect: Self.red))
        #expect(image.width == 80 && image.height == 40)
        #expect(isRed(pixel(image, 40, 20)))
    }

    @Test func areasOutsideTheBlockAreWhitePaper() throws {
        let image = try #require(PDFRendering.render(try makePage(), rect: CGRect(x: 120, y: 50, width: 40, height: 40)))
        #expect(isWhite(pixel(image, 40, 40)))
    }

    @Test func followsThePageRotation() throws {
        let page = try makePage()
        page.rotation = 90
        let image = try #require(PDFRendering.render(page, rect: Self.red))
        // Turned a quarter: the 40 × 20 pt block is now 20 × 40 pt on screen.
        #expect(image.width == 40 && image.height == 80)
        #expect(isRed(pixel(image, 20, 40)))
    }

    @Test func keepsTheLongerSideWithinTheLimit() throws {
        let image = try #require(PDFRendering.thumbnail(of: try makePage(), maxPixels: 100))
        #expect(image.width == 100 && image.height == 50)
    }

    @Test func isNilForAnAreaOffThePage() throws {
        #expect(PDFRendering.render(try makePage(), rect: CGRect(x: 500, y: 500, width: 10, height: 10)) == nil)
    }
}
