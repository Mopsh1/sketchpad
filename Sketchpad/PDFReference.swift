import Foundation

/// Where a card's PDF lives. The PDF stays where it is (a Zotero folder, say): the card keeps a
/// bookmark, which follows the file through moves and renames on this Mac, and its path as a fallback.
struct PDFReference: Codable, Equatable, Sendable {
    /// Ties together one board's cards for the same PDF. A UUID made when the PDF is first inserted.
    var id: String
    var title: String
    var path: String
    /// Base64 bookmark data; nil when the bookmark could not be made.
    var bookmark: String?

    static func make(for url: URL, id: String = UUID().uuidString, title: String) -> PDFReference {
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return PDFReference(id: id, title: title, path: url.path, bookmark: bookmark?.base64EncodedString())
    }

    /// The file's current location, or nil when neither the bookmark nor the path finds it.
    /// A stale bookmark is not rewritten: that would mark the board edited just for opening a PDF.
    func resolve() -> URL? {
        if let bookmark, let data = Data(base64Encoded: bookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &isStale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
