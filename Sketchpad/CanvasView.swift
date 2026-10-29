import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "com.mopshi.Sketchpad", category: "canvas")

/// Hosts the Excalidraw page (web/) for one document window and keeps it in step with the document.
/// The message protocol is described at the top of web/src/bridge.ts.
struct CanvasView: NSViewRepresentable {
    @Binding var document: SketchpadDocument
    let session: BoardSession

    func makeCoordinator() -> CanvasCoordinator {
        CanvasCoordinator(document: $document, session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.document = $document
        context.coordinator.show(document.scene)
        session.sceneDidChange(document.scene)
    }
}

@MainActor
final class CanvasCoordinator: NSObject {
    var document: Binding<SketchpadDocument>
    let session: BoardSession
    private weak var webView: WKWebView?
    private var isPageReady = false
    /// The scene the page currently shows. Lets `show` skip the page's own edits (already on screen)
    /// and push only changes made on this side, such as File ▸ Revert or Edit ▸ Undo.
    private var sceneInPage: String?
    /// Pushes the page has not finished loading. A "change" arriving meanwhile was posted before the
    /// page received the push, so it describes the board being replaced.
    private var pushesInFlight = 0

    init(document: Binding<SketchpadDocument>, session: BoardSession) {
        self.document = document
        self.session = session
        super.init()
        session.canvas = self
    }

    var window: NSWindow? { webView?.window }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(WebAssetSchemeHandler(root: WebAssetSchemeHandler.bundledRoot),
                                          forURLScheme: WebAssetSchemeHandler.scheme)
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: "sketchpad")

        let webView = BoardWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onDropPDFs = { [weak self] urls, point in
            guard let session = self?.session else { return }
            Task { await session.insertPDFs(urls, at: point) }
        }
        // Personal app: keep Safari's Web Inspector available (Develop ▸ this Mac ▸ Sketchpad).
        webView.isInspectable = true
        webView.load(URLRequest(url: WebAssetSchemeHandler.startURL))
        self.webView = webView
        return webView
    }

    func show(_ scene: String) {
        guard isPageReady, scene != sceneInPage, let webView else { return }
        sceneInPage = scene
        pushesInFlight += 1
        Task {
            defer { pushesInFlight -= 1 }
            do {
                // Return a value: the async bridge mishandles a JavaScript `undefined` result.
                _ = try await webView.callAsyncJavaScript("await window.sketchpad.load(scene); return true",
                                                          arguments: ["scene": scene], contentWorld: .page)
            } catch {
                logger.error("Loading the scene into the page failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Adds a card to the board (web/src/cards.ts) and returns its element id. Nil while the page is
    /// not ready or is loading a scene; the edit then reaches the document as an ordinary "change".
    func insertCard(_ spec: CardSpec) async -> String? {
        guard isPageReady, let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript("return await window.sketchpad.insertCard(spec)",
                                                               arguments: ["spec": spec.jsObject()], contentWorld: .page)
            return result as? String
        } catch {
            logger.error("Adding a card failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Scrolls the board to an element and selects it.
    func reveal(_ elementId: String) async {
        guard isPageReady, let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript("return window.sketchpad.reveal(id)",
                                                      arguments: ["id": elementId], contentWorld: .page)
        } catch {
            logger.error("Revealing a card failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Points every card of one PDF at a new location, as one undo step.
    func relinkPDF(id: String, to reference: PDFReference) async {
        guard isPageReady, let webView else { return }
        do {
            let pdf = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))
            let changed = try await webView.callAsyncJavaScript("return window.sketchpad.relinkPDF(pdfId, pdf)",
                                                                arguments: ["pdfId": id, "pdf": pdf], contentWorld: .page)
            logger.notice("Relinked \(changed as? Int ?? 0) cards to \(reference.path, privacy: .public)")
        } catch {
            logger.error("Relinking a PDF failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension CanvasCoordinator: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            let secure = body["isSecureContext"] as? Bool ?? false
            let subtle = body["hasSubtleCrypto"] as? Bool ?? false
            let origin = body["origin"] as? String ?? "?"
            // Notice level so it lands in `log show`; image insertion needs subtle crypto.
            logger.notice("Page ready: origin \(origin, privacy: .public), secure context \(secure), subtle crypto \(subtle)")
            isPageReady = true
            sceneInPage = nil
            show(document.wrappedValue.scene)
        case "change":
            guard let scene = body["scene"] as? String else { return }
            guard pushesInFlight == 0 else {
                logger.info("Dropped a change posted before the page received a newer scene")
                return
            }
            sceneInPage = scene
            // Assigning through the binding registers an undo step and marks the document edited.
            guard scene != document.wrappedValue.scene else { return }
            document.wrappedValue.scene = scene
            logger.info("Scene changed (\(scene.utf8.count) bytes)")
        case "openPDF":
            guard let card = body["card"].flatMap(CardData.decode) else {
                logger.error("A card link carried data this version cannot read")
                NSSound.beep()
                return
            }
            session.open(card, elementId: body["elementId"] as? String)
        case "openLink":
            guard let text = body["url"] as? String, let url = URL(string: text) else { return }
            ExternalLink.open(url)
        case "log":
            let text = body["message"] as? String ?? ""
            if body["level"] as? String == "error" {
                logger.error("Page: \(text, privacy: .public)")
            } else {
                logger.info("Page: \(text, privacy: .public)")
            }
        default:
            logger.error("Unknown message from the page: \(type, privacy: .public)")
        }
    }
}

extension CanvasCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Excalidraw's "export image" saves through <a download>.
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url else { return .cancel }
        // Embedded elements (YouTube and the like) load in iframes; leave those alone.
        guard action.targetFrame?.isMainFrame ?? true else { return .allow }
        if [WebAssetSchemeHandler.scheme, "blob", "about"].contains(url.scheme) { return .allow }
        // Any other page would replace the canvas; open it in the default browser instead.
        ExternalLink.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.error("Web content process ended; reloading the page")
        isPageReady = false
        sceneInPage = nil
        webView.reload()
    }
}

extension CanvasCoordinator: WKUIDelegate {
    /// window.open and target="_blank" links (the help dialog) open in the default browser. Element
    /// links come through `onLinkOpen` instead (the "openLink" message).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Embedded pages can call window.open too, so this goes through the same check as board links.
        if let url = action.request.url { ExternalLink.open(url) }
        return nil
    }

    /// <input type="file">, used by Excalidraw's image tool.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        let response = if let window = webView.window {
            await panel.beginSheetModal(for: window)
        } else {
            await panel.begin()
        }
        return response == .OK ? panel.urls : nil
    }
}

extension CanvasCoordinator: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        let result = if let window = webView?.window {
            await panel.beginSheetModal(for: window)
        } else {
            await panel.begin()
        }
        guard result == .OK, let url = panel.url else { return nil }
        // The save panel already asked about replacing; WKDownload fails if the file is still there.
        try? FileManager.default.removeItem(at: url)
        return url
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// Links in boards and PDFs, which come from anywhere (excalidraw.com, shared files, papers). Only web
/// and mail links are opened, never file: URLs or URL schemes that start other apps.
enum ExternalLink {
    @MainActor static func open(_ url: URL) {
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        } else {
            logger.notice("Ignored a link: \(url.absoluteString, privacy: .public)")
        }
    }
}

/// WKUserContentController keeps its handlers alive for as long as the web view lives; going through
/// this weak hop keeps the coordinator (and the document binding it holds) out of that cycle.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
