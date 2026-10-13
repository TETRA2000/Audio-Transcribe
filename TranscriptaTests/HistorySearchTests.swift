import Foundation
import Testing
@testable import Transcripta

struct HistorySearchTests {
    private func found(_ query: String, in text: String) -> [String] {
        HistorySearch.ranges(of: query, in: text).map { String(text[$0]) }
    }

    @Test func foldIgnoresCaseAccentsAndWidth() {
        #expect(HistorySearch.fold("Café ＡＢＣ ｶﾞｯｺｳ") == "cafe abc ガッコウ")
    }

    @Test func foldKeepsJapaneseVoicedMarks() {
        #expect(HistorySearch.fold("がっこう") == "がっこう")
        #expect(HistorySearch.fold("がっこう") != HistorySearch.fold("かっこう"))
    }

    @Test func foldIsPrecomposed() {
        #expect(HistorySearch.fold("ｶﾞｯｺｳ").unicodeScalars.elementsEqual("ガッコウ".unicodeScalars))
    }

    @Test func rangesAreInTheOriginalText() {
        #expect(found("cafe", in: "Café au lait, CAFE noir") == ["Café", "CAFE"])
    }

    @Test func widthVariantsMatch() {
        #expect(found("ガッコウ", in: "ｶﾞｯｺｳへ行く") == ["ｶﾞｯｺｳ"])
        #expect(found("ＡＢＣ", in: "xabcx") == ["abc"])
    }

    @Test func japaneseSubstringMatches() {
        #expect(found("がっ", in: "今日はがっこうです") == ["がっ"])
        #expect(found("かっ", in: "今日はがっこうです").isEmpty)
    }

    @Test func rangesDoNotOverlap() {
        #expect(HistorySearch.ranges(of: "aa", in: "aaaa").count == 2)
        // ß folds to "ss": both halves map back to the same character, which is reported once.
        #expect(found("s", in: "ßa") == ["ß"])
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(HistorySearch.ranges(of: "", in: "abc").isEmpty)
    }

    @Test func matchesListEveryTextInOrder() {
        let matches = HistorySearch.matches(in: ["no", "a fox and a fox", "fox"], query: "FOX")
        #expect(matches.map(\.text) == [1, 1, 2])
    }

    @Test func snippetCutsAroundTheFirstMatch() throws {
        let snippet = try #require(HistorySearch.snippet(in: ["The quick brown fox jumps over the lazy dog"], query: "FOX", radius: 6))
        #expect(snippet.text == "…brown fox jumps…")
        #expect(snippet.text[snippet.match] == "fox")
    }

    @Test func snippetHasNoEllipsisAtTheEndsOfTheText() throws {
        let snippet = try #require(HistorySearch.snippet(in: ["fox jumps"], query: "fox", radius: 6))
        #expect(snippet.text == "fox jumps")
        #expect(snippet.text[snippet.match] == "fox")
    }

    @Test func snippetUsesTheFirstTextWithAMatchAndFlattensLines() throws {
        let snippet = try #require(HistorySearch.snippet(in: ["nothing", "Budget\n- Q3 total"], query: "q3"))
        #expect(snippet.text == "Budget - Q3 total")
        #expect(snippet.text[snippet.match] == "Q3")
        #expect(HistorySearch.snippet(in: ["nothing"], query: "q3") == nil)
    }
}
