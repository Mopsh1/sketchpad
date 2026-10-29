import AppKit
import PDFKit
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.mopshi.Sketchpad", category: "reader")

/// One board window's state beyond the document: what the window toolbar shows about the canvas, and
/// PDF reading — what the reader panel shows, and the link between the reader and the board
/// (CanvasCoordinator) for adding cards and for jumping between a card and its place in the PDF.
///
/// The board is the only record of highlights. The reader draws the quote and region cards it finds in
/// the scene, so deleting or undoing a card removes its highlight; nothing is written into the PDF.
@MainActor @Observable
final class BoardSession {
    struct OpenPDF {
        /// Given to new cards: the opened card's reference, with the file's current location.
        var reference: PDFReference
        let document: PDFDocument
    }

    /// Why the reader shows no PDF for the card that was clicked. Keeps the card, so locating the file
    /// still lands on that card's place.
    struct Problem {
        var card: CardData
        var elementId: String?
        var message: String
        var reference: PDFReference { card.pdf }
    }

    /// Where the reader should go next. Each request gets a new `id`, so asking for the same place twice
    /// still moves the reader back there.
    struct Destination: Equatable {
        let id = UUID()
        var page: Int
        var rects: [PageRect] = []
        /// The card to flash on arrival.
        var elementId: String?
    }

    var isReaderShown = false
    private(set) var current: OpenPDF?
    private(set) var problem: Problem?
    private(set) var destination: Destination?
    /// The quote and region cards of the PDF in the reader.
    private(set) var highlights: [SceneCard] = []
    private(set) var pageIndicator = ""
    var hasTextSelection = false
    /// The canvas as the window toolbar and menus show it (CanvasToolbar.swift), reported by the page.
    var canvasUI = CanvasUI()
    /// Set by Edit ▸ Find while the reader has focus; the reader then focuses its search field.
    private(set) var searchRequest: UUID?

    @ObservationIgnored weak var canvas: CanvasCoordinator?
    /// The reader's PDFView, set while the reader shows one.
    @ObservationIgnored weak var pdfView: PDFView?
    /// The destination a reader last went to. The panel's views are rebuilt when it is shown again, and
    /// the new reader must not jump back there.
    @ObservationIgnored var handledDestination: UUID?
    @ObservationIgnored private var scene = ""
    @ObservationIgnored private var highlightRefresh: Task<Void, Never>?

    // MARK: Toolbar and menus → canvas

    func perform(_ command: CanvasCommand) {
        guard let canvas else { return NSSound.beep() }
        Task { await canvas.run(command) }
    }

    /// View ▸ zoom and Edit ▸ Find act on the PDF while the reader has keyboard focus, on the board
    /// otherwise, like the same keys in the canvas.
    func zoomOrFind(_ command: CanvasCommand) {
        guard readerHasFocus, let pdfView else { return perform(command) }
        switch command {
        case .zoomIn: pdfView.zoomIn(nil)
        case .zoomOut: pdfView.zoomOut(nil)
        case .resetZoom:
            pdfView.autoScales = false
            pdfView.scaleFactor = 1
        case .zoomToFit: pdfView.autoScales = true
        case .search: searchRequest = UUID()
        default: perform(command)
        }
    }

    /// Keyboard focus is in the reader: its PDF, or its search field (the window's only text field
    /// outside the canvas).
    private var readerHasFocus: Bool {
        guard isReaderShown, let pdfView, var view = pdfView.window?.firstResponder as? NSView else { return false }
        if let editor = view as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            view = field
        }
        if view.isDescendant(of: pdfView) { return true }
        return view is NSTextField && canvas?.contains(view) != true
    }

    // MARK: Board → reader

    /// Called whenever the document changes. While a PDF is open its highlights follow the board,
    /// re-read after edits pause so drawing does not parse the scene on every stroke.
    func sceneDidChange(_ scene: String) {
        guard scene != self.scene else { return }
        self.scene = scene
        guard current != nil else { return }
        highlightRefresh?.cancel()
        highlightRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            refreshHighlights()
        }
    }

    private func refreshHighlights() {
        guard let id = current?.reference.id else {
            highlights = []
            return
        }
        let cards = SceneCards.cards(in: scene).filter { $0.data.pdf.id == id && $0.data.kind != .pdf }
        if cards != highlights { highlights = cards }
    }

    /// A card's link was clicked: show its PDF, at the card's place (or where reading stopped, for the
    /// PDF card itself).
    func open(_ card: CardData, elementId: String? = nil) {
        isReaderShown = true
        guard let url = card.pdf.resolve() else {
            logger.notice("PDF not found: \(card.pdf.path, privacy: .public)")
            show(Problem(card: card, elementId: elementId, message: "找不到原檔"))
            return
        }
        if current?.reference.id != card.pdf.id || current?.document.documentURL?.standardizedFileURL != url.standardizedFileURL {
            guard let document = PDFDocument(url: url) else {
                show(Problem(card: card, elementId: elementId, message: "無法開啟這個檔案"))
                return
            }
            guard !document.isLocked else {
                show(Problem(card: card, elementId: elementId, message: "這個 PDF 有密碼保護，目前不支援"))
                return
            }
            let reference = url.path == card.pdf.path
                ? card.pdf
                : PDFReference.make(for: url, id: card.pdf.id, title: card.pdf.title)
            current = OpenPDF(reference: reference, document: document)
            problem = nil
            refreshHighlights()
        }
        if card.kind == .pdf {
            destination = Destination(page: lastPage(of: card.pdf.id) ?? 0)
        } else {
            destination = Destination(page: card.page, rects: card.rects, elementId: elementId)
        }
    }

    private func show(_ problem: Problem) {
        current = nil
        highlights = []
        pageIndicator = ""
        self.problem = problem
    }

    // MARK: Reader → board

    /// The reader moved to another page.
    func readerDidShow(page index: Int, label: String?) {
        guard let current else { return }
        pageIndicator = "\(label ?? String(index + 1)) / \(current.document.pageCount)"
        var pages = UserDefaults.standard.dictionary(forKey: Self.lastPagesKey) as? [String: Int] ?? [:]
        pages[current.reference.id] = index
        UserDefaults.standard.set(pages, forKey: Self.lastPagesKey)
    }

    /// Where reading stopped, per PDF. Kept in the app's defaults rather than the board, which would
    /// otherwise count as edited every time a PDF is read.
    private static let lastPagesKey = "readerLastPages"

    private func lastPage(of pdfId: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: Self.lastPagesKey) as? [String: Int])?[pdfId]
    }

    /// Where reading stopped in the open PDF.
    func resumeDestination() -> Destination? {
        current.map { Destination(page: lastPage(of: $0.reference.id) ?? 0) }
    }

    func revealCard(_ elementId: String) {
        Task { await canvas?.reveal(elementId) }
    }

    /// 檔案 ▸ 插入 PDF⋯
    func chooseAndInsertPDF() async {
        guard let window = canvas?.window else { return }
        // View mode is read-only; the page would refuse the card anyway (bridge.ts).
        guard !canvasUI.viewMode else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "選擇要放進白板的 PDF"
        guard await panel.beginSheetModal(for: window) == .OK else { return }
        await insertPDFs(panel.urls, at: nil)
    }

    /// Adds a PDF card per file: page 1 and the title. `point` is a drop point in the web view.
    func insertPDFs(_ urls: [URL], at point: CGPoint?) async {
        // Ids given out in this batch, which the scene has not caught up with yet.
        var assigned: [String: String] = [:]
        for (index, url) in urls.enumerated() {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0),
                  let image = PDFRendering.thumbnail(of: page),
                  let jpeg = PDFRendering.encode(image, as: .jpeg, quality: 0.8) else {
                logger.error("Could not read \(url.path, privacy: .public) as a PDF")
                NSSound.beep()
                continue
            }
            let title = Self.title(of: document, url: url)
            let path = url.standardizedFileURL.path
            let id = assigned[path] ?? existingId(for: url) ?? UUID().uuidString
            assigned[path] = id
            let card = CardData(kind: .pdf, pdf: PDFReference.make(for: url, id: id, title: title), page: 0)
            let size = CGSize(width: Double(image.width) / 2, height: Double(image.height) / 2)
            let at = point.map { CGPoint(x: $0.x + Double(index) * 24, y: $0.y + Double(index) * 24) }
            await insert(CardSpec(card: card, at: at, image: CardSpec.Image(dataURL: PDFRendering.dataURL(jpeg, type: .jpeg), size: size),
                                  caption: QuoteText.clipped(title, to: 40)))
        }
    }

    /// The id this board already uses for the file at `url`, so a second card for it shares highlights.
    /// Compares where each PDF's reference finds the file now, so a renamed or moved file still matches.
    private func existingId(for url: URL) -> String? {
        let target = url.standardizedFileURL.path
        var checked = Set<String>()
        for card in SceneCards.cards(in: scene) where checked.insert(card.data.pdf.id).inserted {
            let pdf = card.data.pdf
            if pdf.path == url.path || pdf.resolve()?.standardizedFileURL.path == target { return pdf.id }
        }
        return nil
    }

    /// The text selected in the reader becomes a quote card.
    func addSelectionToBoard() async {
        guard let pdfView, let current, let selection = pdfView.currentSelection,
              let text = selection.string.map(QuoteText.normalize), !text.isEmpty else {
            NSSound.beep()
            return
        }
        let document = current.document
        var rects: [PageRect] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                rects.append(PageRect(page: document.index(for: page), rect: bounds))
            }
        }
        guard let first = rects.first else {
            NSSound.beep()
            return
        }
        let label = document.page(at: first.page)?.label ?? String(first.page + 1)
        let card = CardData(kind: .quote, pdf: current.reference, page: first.page, rects: rects, text: text)
        let shown = QuoteText.clipped(text, to: 600) + "\n— " + QuoteText.clipped(current.reference.title, to: 40) + " p." + label
        if await insert(CardSpec(card: card, quote: shown)) != nil {
            pdfView.clearSelection()
        }
    }

    /// An area ⌘-dragged in the reader becomes a region card. `image` is that area rendered; `size` is
    /// the area as the reader shows it, in points.
    func addRegionToBoard(page index: Int, rect: CGRect, image: CGImage, size: CGSize) async {
        guard let current, let png = PDFRendering.encode(image, as: .png) else {
            NSSound.beep()
            return
        }
        // At most 480 pt across on the board; the image keeps its full resolution.
        let fit = min(1, 480 / max(size.width, size.height))
        let card = CardData(kind: .region, pdf: current.reference, page: index, rects: [PageRect(page: index, rect: rect)])
        await insert(CardSpec(card: card, image: CardSpec.Image(dataURL: PDFRendering.dataURL(png, type: .png),
                                                                size: CGSize(width: size.width * fit, height: size.height * fit))))
    }

    /// The reader's 重新指定位置⋯: points this board's cards for the missing PDF at a file the user picks,
    /// then goes on to the card that was clicked.
    func locateMissingPDF() async {
        guard let problem, let window = canvas?.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "「\(problem.reference.title)」現在在哪裡？"
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
        // Check before rewriting every card of this PDF.
        guard let document = PDFDocument(url: url), !document.isLocked else {
            NSSound.beep()
            self.problem?.message = "選的檔案無法開啟"
            return
        }
        let reference = PDFReference.make(for: url, id: problem.reference.id, title: problem.reference.title)
        await canvas?.relinkPDF(id: reference.id, to: reference)
        var card = problem.card
        card.pdf = reference
        open(card, elementId: problem.elementId)
    }

    @discardableResult
    private func insert(_ spec: CardSpec) async -> String? {
        guard let id = await canvas?.insertCard(spec) else {
            NSSound.beep()
            return nil
        }
        return id
    }

    /// The PDF's own title when it looks like one; academic PDFs often carry a placeholder or the name of
    /// the file they were exported from, and Zotero names files after the paper anyway.
    static func title(of document: PDFDocument, url: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        guard let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            title.count >= 8,
            !title.lowercased().hasPrefix("untitled"),
            !title.contains(/\.(docx?|pdf|tex|indd)$/.ignoresCase()) else { return fileName }
        return title
    }
}

/// What CanvasCoordinator hands to `window.sketchpad.insertCard` (`CardSpec` in web/src/cards.ts).
struct CardSpec {
    struct Image {
        var dataURL: String
        /// Size on the board, in points.
        var size: CGSize
    }

    var card: CardData
    /// A drop point in the web view; the middle of the view when nil.
    var at: CGPoint?
    var quote: String?
    var image: Image?
    var caption: String?

    func jsObject() throws -> [String: Any] {
        var spec: [String: Any] = ["card": try card.jsonObject(), "link": card.link]
        if let at { spec["at"] = ["clientX": Double(at.x), "clientY": Double(at.y)] }
        if let quote { spec["quote"] = quote }
        if let image {
            spec["image"] = ["dataURL": image.dataURL, "width": Double(image.size.width), "height": Double(image.size.height)]
        }
        if let caption { spec["caption"] = caption }
        return spec
    }
}
