import Foundation
import WebKit

/// Serves the bundled web build (Contents/Resources/dist) at sketchpad://app/, so the page has a
/// proper origin. Loading it through file:// instead risks WebKit blocking its ES modules and fonts.
final class WebAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "sketchpad"
    static let startURL = URL(string: "sketchpad://app/index.html")!
    static var bundledRoot: URL {
        Bundle.main.resourceURL!.appending(path: "dist", directoryHint: .isDirectory)
    }

    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        guard let file = fileURL(for: url), let data = try? Data(contentsOf: file) else {
            respond(to: task, url: url, status: 404, mimeType: "text/plain; charset=utf-8", data: Data("Not found".utf8))
            return
        }
        respond(to: task, url: url, status: 200, mimeType: Self.mimeType(forExtension: file.pathExtension), data: data)
    }

    // Every response is sent synchronously in `start`, so there is never anything left to cancel.
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// The file inside `root` that a request URL points at; nil for paths that would escape `root`.
    func fileURL(for url: URL) -> URL? {
        var path = url.path(percentEncoded: false)
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appending(path: String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return file
    }

    /// WebKit refuses to run module scripts unless they arrive with a JavaScript MIME type.
    static func mimeType(forExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "wasm": "application/wasm"
        default: "application/octet-stream"
        }
    }

    private func respond(to task: any WKURLSchemeTask, url: URL, status: Int, mimeType: String, data: Data) {
        let headers = ["Content-Type": mimeType, "Content-Length": String(data.count)]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
