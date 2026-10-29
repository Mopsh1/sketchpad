import Testing
@testable import Sketchpad

struct QuoteTextTests {
    @Test(arguments: [
        ("virtual\nreality", "virtual reality"),
        ("inter-\naction design", "interaction design"),
        ("Head-\nMounted", "Head-Mounted"), // a capital after the break: a real hyphen
        ("沉浸式虛擬\n實境", "沉浸式虛擬實境"),
        ("使用 \nVR 頭戴\n顯示器", "使用 VR 頭戴顯示器"),
        ("高臨場感，\nPresence", "高臨場感，Presence"),
        ("  extra   spaces \n\n here ", "extra spaces here"),
        ("ﬁeld of view", "field of view"),
    ])
    func joinsLinesIntoOneParagraph(_ input: String, _ expected: String) {
        #expect(QuoteText.normalize(input) == expected)
    }

    @Test func clipsLongTextWithAnEllipsis() {
        #expect(QuoteText.clipped("abcdef", to: 4) == "abc…")
        #expect(QuoteText.clipped("abc", to: 4) == "abc")
    }
}
