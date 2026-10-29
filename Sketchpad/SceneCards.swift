import CoreGraphics
import Foundation

/// The `customData.sketchpad` object of a card element. The board's cards are the PDF highlights:
/// the reader draws them back from here, and nothing is ever written into the PDF itself.
///
/// - `pdf`: an image of the first page, the way into the reader.
/// - `quote`: a rectangle holding text selected in the reader; `rects` are its lines.
/// - `region`: an image of part of a page; `rects` holds that one area.
///
/// web/src/cards.ts puts this object on the element as is. Bump `currentVersion` when the shape changes;
/// cards from a newer version are ignored rather than misread.
struct CardData: Codable, Equatable, Sendable {
    static let currentVersion = 1

    enum Kind: String, Codable, Sendable {
        case pdf, quote, region
    }

    var v = CardData.currentVersion
    var kind: Kind
    var pdf: PDFReference
    /// The page the card points at, 0-based.
    var page: Int
    var rects: [PageRect] = []
    /// The full quoted text; the card itself may show it shortened.
    var text: String?

    init(kind: Kind, pdf: PDFReference, page: Int, rects: [PageRect] = [], text: String? = nil) {
        self.kind = kind
        self.pdf = pdf
        self.page = page
        self.rects = rects
        self.text = text
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        kind = try container.decode(Kind.self, forKey: .kind)
        pdf = try container.decode(PDFReference.self, forKey: .pdf)
        page = try container.decode(Int.self, forKey: .page)
        rects = try container.decodeIfPresent([PageRect].self, forKey: .rects) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    /// Only shows Excalidraw's link icon and makes the card clickable; what the click does is decided
    /// from this data, so a hand-edited link changes nothing.
    var link: String {
        var components = URLComponents()
        components.scheme = "sketchpad-pdf"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "pdf", value: pdf.id),
                                 URLQueryItem(name: "page", value: String(page + 1))]
        return components.string ?? "sketchpad-pdf://open"
    }

    /// Reads card data the page handed over (a parsed JSON object). Nil for anything else, including
    /// cards written by a newer version.
    static func decode(_ object: Any) -> CardData? {
        guard let object = object as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let card = try? JSONDecoder().decode(CardData.self, from: data),
              card.v == currentVersion else { return nil }
        return card
    }

    /// The JSON object handed to the page.
    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
    }
}

/// A rectangle on one page, in PDFKit page space (origin at the page's bottom left). Stored as
/// `[page, x, y, width, height]`, rounded to 0.1 pt, to keep board files small.
struct PageRect: Codable, Equatable, Sendable {
    var page: Int
    var rect: CGRect

    init(page: Int, rect: CGRect) {
        self.page = page
        self.rect = rect
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        page = try container.decode(Int.self)
        rect = CGRect(x: try container.decode(Double.self), y: try container.decode(Double.self),
                      width: try container.decode(Double.self), height: try container.decode(Double.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(page)
        for value in [rect.minX, rect.minY, rect.width, rect.height] {
            try container.encode((Double(value) * 10).rounded() / 10)
        }
    }
}

/// A card found in a board, with the id of the element that carries it.
struct SceneCard: Equatable, Sendable {
    var elementId: String
    var data: CardData
}

enum SceneCards {
    /// Every card in a serialized scene. Elements without card data, or with data this version cannot
    /// read, are skipped, so a foreign or damaged element never hides the other cards.
    static func cards(in scene: String) -> [SceneCard] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(scene.utf8)) as? [String: Any],
              let elements = object["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { element in
            guard element["isDeleted"] as? Bool != true,
                  let id = element["id"] as? String,
                  let customData = element["customData"] as? [String: Any],
                  let raw = customData["sketchpad"],
                  let card = CardData.decode(raw) else { return nil }
            return SceneCard(elementId: id, data: card)
        }
    }
}
