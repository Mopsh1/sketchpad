import PDFKit
import SwiftUI

/// The reader panel beside a board: the PDF a card links to, with search, outline, page thumbnails
/// and zoom. Selected text (⌘B) and ⌘-dragged areas go onto the board as cards.
struct PDFReaderView: View {
    let session: BoardSession
    @State private var showsThumbnails = false
    @State private var showsOutline = false
    @State private var search = ReaderSearch()

    var body: some View {
        Group {
            if let current = session.current {
                VStack(spacing: 0) {
                    header(current)
                    Divider()
                    ReaderCanvas(session: session, document: current.document, showsThumbnails: showsThumbnails,
                                 highlights: session.highlights, destination: session.destination)
                    Divider()
                    Text("選取文字後按 ⌘B 加到白板；按住 ⌘ 拖曳可框選區域")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } else if let problem = session.problem {
                ContentUnavailableView {
                    Label(problem.message, systemImage: "doc.questionmark")
                } description: {
                    VStack {
                        Text(problem.reference.title)
                        Text(problem.reference.path).font(.caption).textSelection(.enabled)
                    }
                } actions: {
                    Button("重新指定位置⋯") { Task { await session.locateMissingPDF() } }
                }
            } else {
                ContentUnavailableView {
                    Label("還沒有開啟 PDF", systemImage: "doc.richtext")
                } description: {
                    Text("點白板上 PDF 卡片的連結圖示來閱讀，或先插入一份 PDF。")
                } actions: {
                    Button("插入 PDF⋯") { Task { await session.chooseAndInsertPDF() } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Out here rather than on the PDF branch, which goes away while a problem is shown: results
        // from one document must never be stepped through in another.
        .onChange(of: session.current.map { ObjectIdentifier($0.document) }) {
            search.reset(pdfView: session.pdfView)
        }
        .overlay(alignment: .topTrailing) {
            if session.current == nil {
                iconButton("xmark", "關閉閱讀面板") { session.isReaderShown = false }
                    .padding(8)
            }
        }
    }

    private func header(_ current: BoardSession.OpenPDF) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                iconButton("sidebar.left", "頁面縮圖") { showsThumbnails.toggle() }
                iconButton("list.bullet", "目錄") { showsOutline = true }
                    .disabled((current.document.outlineRoot?.numberOfChildren ?? 0) == 0)
                    .popover(isPresented: $showsOutline, arrowEdge: .bottom) {
                        OutlineList(outline: current.document.outlineRoot) { destination in
                            session.pdfView?.go(to: destination)
                            showsOutline = false
                        }
                    }
                Text(current.reference.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(current.reference.path)
                    .padding(.horizontal, 4)
                Spacer(minLength: 0)
                iconButton("minus.magnifyingglass", "縮小") { session.pdfView?.zoomOut(nil) }
                iconButton("plus.magnifyingglass", "放大") { session.pdfView?.zoomIn(nil) }
                iconButton("arrow.left.and.right", "符合寬度") { session.pdfView?.autoScales = true }
                iconButton("text.badge.plus", "把選取的文字加到白板（⌘B）") {
                    Task { await session.addSelectionToBoard() }
                }
                .disabled(!session.hasTextSelection)
                iconButton("xmark", "關閉閱讀面板") { session.isReaderShown = false }
            }
            HStack(spacing: 4) {
                TextField("搜尋", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search.submit(in: current.document, pdfView: session.pdfView) }
                if search.hasSearched {
                    if search.results.isEmpty {
                        Text("沒有結果").foregroundStyle(.secondary)
                    } else {
                        Text("\(search.index + 1)/\(search.results.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        iconButton("chevron.up", "上一個") { search.step(-1, pdfView: session.pdfView) }
                        iconButton("chevron.down", "下一個") { search.step(1, pdfView: session.pdfView) }
                    }
                }
                Spacer(minLength: 4)
                Text(session.pageIndicator)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func iconButton(_ systemImage: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// The reader's search: every match tinted, Return steps through them.
@MainActor @Observable
final class ReaderSearch {
    var query = ""
    private(set) var results: [PDFSelection] = []
    private(set) var index = 0
    private(set) var hasSearched = false
    @ObservationIgnored private var searchedQuery = ""

    func submit(in document: PDFDocument, pdfView: PDFView?) {
        if query == searchedQuery, !results.isEmpty {
            step(1, pdfView: pdfView)
            return
        }
        searchedQuery = query
        results = query.isEmpty ? [] : document.findString(query, withOptions: [.caseInsensitive])
        results.forEach { $0.color = .findHighlightColor }
        index = 0
        hasSearched = !query.isEmpty
        pdfView?.highlightedSelections = results.isEmpty ? nil : results
        show(in: pdfView)
    }

    func step(_ delta: Int, pdfView: PDFView?) {
        guard !results.isEmpty else { return }
        index = (index + delta + results.count) % results.count
        show(in: pdfView)
    }

    func reset(pdfView: PDFView?) {
        query = ""
        searchedQuery = ""
        results = []
        index = 0
        hasSearched = false
        pdfView?.highlightedSelections = nil
    }

    private func show(in pdfView: PDFView?) {
        guard let pdfView, results.indices.contains(index) else { return }
        pdfView.setCurrentSelection(results[index], animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }
}

private struct OutlineItem: Identifiable {
    let id = UUID()
    let label: String
    let destination: PDFDestination?
    let children: [OutlineItem]?

    static func items(of outline: PDFOutline?) -> [OutlineItem] {
        guard let outline else { return [] }
        return (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let children = items(of: child)
            return OutlineItem(label: child.label ?? "", destination: child.destination,
                               children: children.isEmpty ? nil : children)
        }
    }
}

private struct OutlineList: View {
    let outline: PDFOutline?
    let go: (PDFDestination) -> Void
    // Built once per popover, so the list keeps what is expanded while the reader updates.
    @State private var items: [OutlineItem] = []

    var body: some View {
        List(items, children: \.children) { item in
            Button(item.label) {
                if let destination = item.destination { go(destination) }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 320, height: 420)
        .onAppear { items = OutlineItem.items(of: outline) }
    }
}

// MARK: - The PDF itself

private struct ReaderCanvas: NSViewRepresentable {
    let session: BoardSession
    let document: PDFDocument
    let showsThumbnails: Bool
    let highlights: [SceneCard]
    let destination: BoardSession.Destination?

    func makeCoordinator() -> ReaderCoordinator {
        ReaderCoordinator(session: session)
    }

    func makeNSView(context: Context) -> ReaderContainerView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: ReaderContainerView, context: Context) {
        view.showsThumbnails = showsThumbnails
        context.coordinator.show(document, highlights: highlights, destination: destination)
    }
}

/// Page thumbnails (optional), the PDFView, and the ⌘-drag overlay on top of it.
final class ReaderContainerView: NSView {
    let pdfView = ReaderPDFView(frame: .zero)
    let thumbnails = PDFThumbnailView(frame: .zero)
    let overlay = RegionSelectOverlay(frame: .zero)

    var showsThumbnails = false {
        didSet { if showsThumbnails != oldValue { needsLayout = true } }
    }

    /// After every layout pass, so the reader can go somewhere once the panel has a size.
    var onLayout: (() -> Void)?

    init() {
        super.init(frame: .zero)
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = CGSize(width: 72, height: 96)
        thumbnails.backgroundColor = .windowBackgroundColor
        overlay.pdfView = pdfView
        addSubview(thumbnails)
        addSubview(pdfView)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        let thumbnailWidth: CGFloat = showsThumbnails ? 104 : 0
        thumbnails.isHidden = !showsThumbnails
        thumbnails.frame = NSRect(x: 0, y: 0, width: thumbnailWidth, height: bounds.height)
        pdfView.frame = NSRect(x: thumbnailWidth, y: 0, width: max(0, bounds.width - thumbnailWidth), height: bounds.height)
        overlay.frame = pdfView.frame
        onLayout?()
    }
}

/// Adds 加到白板 to the context menu when text is selected.
final class ReaderPDFView: PDFView {
    var onAddSelection: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let text = currentSelection?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = NSMenuItem(title: "加到白板", action: #selector(addSelection), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func addSelection() {
        onAddSelection?()
    }
}

/// Draws the board's quote and region cards as highlights, follows destinations from the board, and
/// turns ⌘-drags and clicks on highlights into board actions. The highlights are annotations on the
/// in-memory PDFDocument only; nothing writes the document back to its file.
@MainActor
final class ReaderCoordinator: NSObject {
    private let session: BoardSession
    private weak var container: ReaderContainerView?
    /// Highlights drawn per card element, with the card data they were drawn from.
    private var drawn: [String: (card: CardData, annotations: [PDFAnnotation])] = [:]
    /// Where to go once the PDFView has a size. A panel that has just opened is still zero wide, and
    /// PDFView cannot scroll to a page then.
    private var waiting: BoardSession.Destination?

    /// Marks the reader's own highlights (the value is the card's element id). The document outlives
    /// this coordinator, since the panel's views are rebuilt each time it is shown, so a new reader
    /// finds and removes what an earlier one drew instead of drawing everything twice.
    private static let cardKey = PDFAnnotationKey(rawValue: "/SketchpadCard")

    init(session: BoardSession) {
        self.session = session
    }

    func makeView() -> ReaderContainerView {
        let view = ReaderContainerView()
        let pdfView = view.pdfView
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.delegate = self
        pdfView.onAddSelection = { [weak self] in
            guard let session = self?.session else { return }
            Task { await session.addSelectionToBoard() }
        }
        view.overlay.onSelect = { [weak self] rect in self?.regionSelected(rect) }
        view.onLayout = { [weak self] in self?.goWhenSized() }

        // Plain clicks only, so dragging to select text still starts on a highlight.
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        pdfView.addGestureRecognizer(click)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        session.pdfView = pdfView
        container = view
        return view
    }

    func show(_ document: PDFDocument, highlights: [SceneCard], destination: BoardSession.Destination?) {
        guard let pdfView = container?.pdfView else { return }
        var pending = destination.flatMap { $0.id == session.handledDestination ? nil : $0 }
        if pdfView.document !== document {
            pdfView.document = document
            drawn = [:]
            Self.removeOwnAnnotations(from: document)
            // A reader rebuilt for a document already being read carries on where reading stopped.
            if pending == nil { pending = session.resumeDestination() }
        }
        draw(highlights, in: document)
        if let pending {
            if let destination { session.handledDestination = destination.id }
            waiting = pending
            // Let a newly set document get laid out first; a panel still opening gets there in layout().
            Task { [weak self] in
                await Task.yield()
                self?.goWhenSized()
            }
        }
    }

    private func goWhenSized() {
        guard let waiting, let pdfView = container?.pdfView,
              pdfView.bounds.width > 1, pdfView.bounds.height > 1 else { return }
        self.waiting = nil
        go(to: waiting)
    }

    private static func removeOwnAnnotations(from document: PDFDocument) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.value(forAnnotationKey: cardKey) != nil {
                page.removeAnnotation(annotation)
            }
        }
    }

    private func go(to destination: BoardSession.Destination) {
        guard let pdfView = container?.pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        pdfView.layoutDocumentView()
        let target = destination.rects.first { $0.page == destination.page } ?? destination.rects.first
        if let target, let page = document.page(at: target.page) {
            pdfView.go(to: target.rect, on: page)
        } else if let page = document.page(at: min(max(destination.page, 0), document.pageCount - 1)) {
            pdfView.go(to: page)
        }
        if let id = destination.elementId, let annotations = drawn[id]?.annotations, !annotations.isEmpty {
            blink(annotations, in: pdfView)
        }
    }

    private func blink(_ annotations: [PDFAnnotation], in pdfView: PDFView) {
        Task {
            for visible in [false, true, false, true, false, true] {
                annotations.forEach { $0.shouldDisplay = visible }
                Set(annotations.compactMap(\.page)).forEach { pdfView.annotationsChanged(on: $0) }
                try? await Task.sleep(for: .milliseconds(160))
            }
        }
    }

    private func draw(_ cards: [SceneCard], in document: PDFDocument) {
        let wanted = Dictionary(cards.map { ($0.elementId, $0.data) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in drawn where wanted[id] != entry.card {
            entry.annotations.forEach { $0.page?.removeAnnotation($0) }
            drawn[id] = nil
        }
        for (id, card) in wanted where drawn[id] == nil {
            drawn[id] = (card, Self.addAnnotations(for: card, elementId: id, to: document))
        }
    }

    private static func addAnnotations(for card: CardData, elementId: String, to document: PDFDocument) -> [PDFAnnotation] {
        card.rects.compactMap { item in
            guard let page = document.page(at: item.page) else { return nil }
            let annotation: PDFAnnotation
            switch card.kind {
            case .quote:
                annotation = PDFAnnotation(bounds: item.rect, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
                // Relative to the bounds' origin, in PDF quad point order: top left, top right,
                // bottom left, bottom right.
                let width = item.rect.width, height = item.rect.height
                annotation.quadrilateralPoints = [NSPoint(x: 0, y: height), NSPoint(x: width, y: height),
                                                  NSPoint(x: 0, y: 0), NSPoint(x: width, y: 0)].map { NSValue(point: $0) }
            case .region:
                annotation = PDFAnnotation(bounds: item.rect.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
                annotation.color = .systemOrange
                let border = PDFBorder()
                border.lineWidth = 1.5
                border.style = .dashed
                border.dashPattern = [4, 3]
                annotation.border = border
            case .pdf:
                return nil
            }
            annotation.shouldPrint = false
            annotation.setValue(elementId, forAnnotationKey: cardKey)
            page.addAnnotation(annotation)
            return annotation
        }
    }

    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        guard let pdfView = container?.pdfView else { return }
        let point = recognizer.location(in: pdfView)
        guard let page = pdfView.page(for: point, nearest: false) else { return }
        let pagePoint = pdfView.convert(point, to: page)
        let hit = drawn.first { _, entry in
            entry.annotations.contains { $0.page === page && $0.bounds.contains(pagePoint) }
        }
        if let id = hit?.key { session.revealCard(id) }
    }

    private func regionSelected(_ rect: NSRect) {
        guard let container, let document = container.pdfView.document else { return }
        let pdfView = container.pdfView
        let inPDFView = container.overlay.convert(rect, to: pdfView)
        guard let page = pdfView.page(for: NSPoint(x: inPDFView.midX, y: inPDFView.midY), nearest: true) else { return }
        let pageRect = pdfView.convert(inPDFView, to: page).intersection(page.bounds(for: .cropBox))
        guard !pageRect.isNull, pageRect.width >= 2, pageRect.height >= 2 else {
            NSSound.beep()
            return
        }
        // The card should show the page, not the reader's own highlights on it.
        let own = drawn.values.flatMap(\.annotations)
        own.forEach { $0.shouldDisplay = false }
        let image = PDFRendering.render(page, rect: pageRect)
        own.forEach { $0.shouldDisplay = true }
        guard let image else {
            NSSound.beep()
            return
        }
        let size = PDFRendering.shownSize(of: pageRect, on: page)
        let index = document.index(for: page)
        Task { await session.addRegionToBoard(page: index, rect: pageRect, image: image, size: size) }
    }

    // PDFViewDelegate (conformance below). PDFKit would hand any link in the PDF to the system as is.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        ExternalLink.open(url)
    }

    // Deferred: setting a document inside a SwiftUI update posts these synchronously.
    @objc private func pageChanged(_ notification: Notification) {
        Task { [weak self] in
            // A new document starts on page 1; that is not where reading stopped, so it is not saved
            // while the reader is still on its way to the real place.
            guard let self, waiting == nil, let pdfView = container?.pdfView, let page = pdfView.currentPage,
                  let document = pdfView.document else { return }
            session.readerDidShow(page: document.index(for: page), label: page.label)
        }
    }

    @objc private func selectionChanged(_ notification: Notification) {
        Task { [weak self] in
            let text = self?.container?.pdfView.currentSelection?.string ?? ""
            self?.session.hasTextSelection = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// PDFKit calls its delegate on the main thread.
extension ReaderCoordinator: @MainActor PDFViewDelegate {}
