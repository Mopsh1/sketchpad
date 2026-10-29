import AppKit
import UniformTypeIdentifiers
import WebKit

/// The board's web view, taking PDF files dropped on it. A PDF card refers to the original file, and
/// the page only ever sees a dropped file's contents, never where it is; Excalidraw would also reject
/// a PDF as an invalid file. So PDF drags are handled here and never reach WebKit. Everything else
/// (images, .excalidraw files, text) goes to WebKit as before. A drag holding both PDFs and other
/// files counts as a PDF drag; the other files are left out.
///
/// draggingEnded and concludeDragOperation are not overridden: WKWebView may not implement them, so
/// calling super there could crash. draggingEntered resets the state for every new drag anyway.
final class BoardWebView: WKWebView {
    /// Dropped PDFs and the drop point, in web view (CSS) pixels from the top left.
    var onDropPDFs: (([URL], CGPoint) -> Void)?
    private var isPDFDrag = false

    private func pdfURLs(in info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.pdf.identifier],
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isPDFDrag = !pdfURLs(in: sender).isEmpty
        return isPDFDrag ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isPDFDrag ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if isPDFDrag {
            isPDFDrag = false
        } else {
            super.draggingExited(sender)
        }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isPDFDrag || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isPDFDrag else { return super.performDragOperation(sender) }
        isPDFDrag = false
        let point = convert(sender.draggingLocation, from: nil)
        onDropPDFs?(pdfURLs(in: sender), CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
        return true
    }
}
