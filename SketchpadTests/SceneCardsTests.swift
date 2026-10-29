import Foundation
import Testing
@testable import Sketchpad

struct SceneCardsTests {
    private static func card(_ pdf: String, kind: String = "quote", version: Int = 1, page: Any = 2) -> String {
        #"{"sketchpad":{"v":\#(version),"kind":"\#(kind)","pdf":{"id":"\#(pdf)","title":"T","path":"/p.pdf"},"page":\#(page),"rects":[[2,10,20,30,8]],"text":"q"}}"#
    }

    private static let scene = """
        {"type":"excalidraw","version":2,"elements":[
          {"id":"quote-a","type":"rectangle","customData":\(card("A"))},
          {"id":"deleted","type":"rectangle","isDeleted":true,"customData":\(card("A"))},
          {"id":"foreign","type":"rectangle","customData":{"other":{"x":1}}},
          {"id":"plain","type":"text"},
          {"id":"newer","type":"image","customData":\(card("A", version: 2))},
          {"id":"broken","type":"image","customData":\(card("A", page: #""two""#))},
          {"id":"unknown-kind","type":"image","customData":\(card("A", kind: "video"))},
          {"id":"region-b","type":"image","customData":\(card("B", kind: "region"))}
        ],"appState":{},"files":{}}
        """

    @Test func findsOnlyReadableLiveCards() {
        let cards = SceneCards.cards(in: Self.scene)
        #expect(cards.map(\.elementId) == ["quote-a", "region-b"])
        #expect(cards.first?.data.kind == .quote)
        #expect(cards.first?.data.pdf.id == "A")
        #expect(cards.first?.data.rects == [PageRect(page: 2, rect: CGRect(x: 10, y: 20, width: 30, height: 8))])
        #expect(cards.last?.data.kind == .region)
    }

    @Test(arguments: ["", "not json", "[]", #"{"elements":"none"}"#])
    func returnsNothingForScenesItCannotRead(_ scene: String) {
        #expect(SceneCards.cards(in: scene).isEmpty)
    }

    @Test func cardDataRoundTripsThroughThePage() throws {
        let reference = PDFReference(id: "A", title: "論文", path: "/p.pdf", bookmark: nil)
        let card = CardData(kind: .quote, pdf: reference, page: 3,
                            rects: [PageRect(page: 3, rect: CGRect(x: 1.23, y: 4.56, width: 7, height: 8))], text: "引文")
        let decoded = try #require(CardData.decode(card.jsonObject()))
        #expect(decoded.rects == [PageRect(page: 3, rect: CGRect(x: 1.2, y: 4.6, width: 7, height: 8))])
        #expect(decoded.text == "引文")
        #expect(decoded.pdf == reference)
    }

    @Test func linkNamesThePDFAndTheOneBasedPage() {
        let reference = PDFReference(id: "A B", title: "T", path: "/p.pdf", bookmark: nil)
        #expect(CardData(kind: .pdf, pdf: reference, page: 0).link == "sketchpad-pdf://open?pdf=A%20B&page=1")
    }
}
