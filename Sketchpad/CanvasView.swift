import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "com.mopshi.Sketchpad", category: "canvas")

/// Hosts the Excalidraw page (web/) for one document window and keeps it in step with the document.
/// The message protocol is described at the top of web/src/bridge.ts.
struct CanvasView: NSViewRepresentable {
    @Binding var document: SketchpadDocument

    func makeCoordinator() -> CanvasCoordinator {
        CanvasCoordinator(document: $document)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.document = $document
        context.coordinator.show(document.scene)
    }
}

@MainActor
final class CanvasCoordinator: NSObject {
    var document: Binding<SketchpadDocument>
    private weak var webView: WKWebView?
    private var isPageReady = false
    /// The scene the page currently shows. Lets `show` skip the page's own edits (already on screen)
    /// and push only changes made on this side, such as File ▸ Revert or Edit ▸ Undo.
    private var sceneInPage: String?
    /// Pushes the page has not finished loading. A "change" arriving meanwhile was posted before the
    /// page received the push, so it describes the board being replaced.
    private var pushesInFlight = 0

    init(document: Binding<SketchpadDocument>) {
        self.document = document
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(WebAssetSchemeHandler(root: WebAssetSchemeHandler.bundledRoot),
                                          forURLScheme: WebAssetSchemeHandler.scheme)
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: "sketchpad")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
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
        NSWorkspace.shared.open(url)
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
    /// window.open and target="_blank" links (element links, the help dialog) open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
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
