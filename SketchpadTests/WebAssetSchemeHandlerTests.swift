import Foundation
import Testing
@testable import Sketchpad

@MainActor
struct WebAssetSchemeHandlerTests {
    let handler = WebAssetSchemeHandler(root: URL(filePath: "/tmp/web", directoryHint: .isDirectory))

    private func resolve(_ string: String) -> String? {
        handler.fileURL(for: URL(string: string)!)?.path
    }

    @Test func mapsRequestsToFilesUnderTheRoot() {
        #expect(resolve("sketchpad://app/assets/index.js") == "/tmp/web/assets/index.js")
        #expect(resolve("sketchpad://app/fonts/Xiaolai/Xiaolai-Regular.woff2") == "/tmp/web/fonts/Xiaolai/Xiaolai-Regular.woff2")
    }

    @Test func servesIndexForTheBareOrigin() {
        #expect(resolve("sketchpad://app/") == "/tmp/web/index.html")
        #expect(resolve("sketchpad://app") == "/tmp/web/index.html")
    }

    @Test func decodesPercentEncodedNames() {
        #expect(resolve("sketchpad://app/fonts/Comic%20Shanns.woff2") == "/tmp/web/fonts/Comic Shanns.woff2")
    }

    @Test func refusesPathsThatEscapeTheRoot() {
        #expect(resolve("sketchpad://app/../secret") == nil)
        #expect(resolve("sketchpad://app/assets/../../secret") == nil)
        #expect(resolve("sketchpad://app/%2E%2E/secret") == nil)
        #expect(resolve("sketchpad://app/../web-other/file") == nil, "a sibling sharing the root's name prefix is still outside")
    }

    @Test func givesModuleScriptsAJavaScriptType() {
        #expect(WebAssetSchemeHandler.mimeType(forExtension: "js").hasPrefix("text/javascript"))
        #expect(WebAssetSchemeHandler.mimeType(forExtension: "WOFF2") == "font/woff2")
        #expect(WebAssetSchemeHandler.mimeType(forExtension: "unknown") == "application/octet-stream")
    }
}
