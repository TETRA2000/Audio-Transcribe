import Foundation
import FoundationModels
import Testing
@testable import Audio_Transcribe

struct RecapGeneratorTests {
    @Test func chunksKeepLinesThatFitTogether() {
        // "aaaa\nbbbb" is exactly 9 characters.
        #expect(SystemRecapGenerator.chunks(["aaaa", "bbbb"], budget: 9) == [["aaaa", "bbbb"]])
    }

    @Test func chunksSplitOnLineBoundaries() {
        #expect(SystemRecapGenerator.chunks(["aaaa", "bbbb", "cc"], budget: 8) == [["aaaa"], ["bbbb", "cc"]])
    }

    @Test func chunksTruncateAnOversizedLine() {
        let line = String(repeating: "x", count: 10_000)
        #expect(SystemRecapGenerator.chunks([line], budget: 2_500) == [[String(repeating: "x", count: 2_500)]])
    }

    @Test func chunksIsolateAnOversizedLineBetweenShortOnes() {
        let long = String(repeating: "x", count: 20)
        #expect(SystemRecapGenerator.chunks(["a", long, "b"], budget: 10) == [["a"], [String(repeating: "x", count: 10)], ["b"]])
    }

    @Test func chunksOfNothingIsEmpty() {
        #expect(SystemRecapGenerator.chunks([], budget: 10).isEmpty)
    }

    @Test func budgetsPerLanguage() {
        #expect(SystemRecapGenerator.budget(for: .english) == 6_000)
        #expect(SystemRecapGenerator.budget(for: .japanese) == 2_500)
    }

    @Test func promptWithoutEarlierSummary() {
        #expect(SystemRecapGenerator.prompt(lines: ["You: Hi.", "Zoom: Hello."], earlier: nil)
            == "Transcript:\nYou: Hi.\nZoom: Hello.")
    }

    @Test func promptWithEarlierSummary() {
        #expect(SystemRecapGenerator.prompt(lines: ["You: Hi."], earlier: "They met.")
            == "Earlier: They met.\n\nTranscript:\nYou: Hi.")
    }

    @Test func instructionsNameTheResponseLanguage() {
        #expect(SystemRecapGenerator.instructions(for: .english).hasSuffix("Respond in English."))
        #expect(SystemRecapGenerator.instructions(for: .japanese).hasSuffix("Respond in Japanese."))
        #expect(SystemRecapGenerator.mergeInstructions(for: .japanese).hasSuffix("Respond in Japanese."))
    }

    @Test func mergePromptListsEachPart() {
        let parts = [
            RecapContent(headline: "A.", keyPoints: ["x"]),
            RecapContent(headline: "B.", keyPoints: []),
        ]
        #expect(SystemRecapGenerator.mergePrompt(parts) == "Part 1:\nA.\n- x\n\nPart 2:\nB.")
    }

    @Test(arguments: [
        (SystemLanguageModel.Availability.available, RecapAvailability.available),
        (.unavailable(.appleIntelligenceNotEnabled), .appleIntelligenceOff),
        (.unavailable(.deviceNotEligible), .deviceNotEligible),
        (.unavailable(.modelNotReady), .modelNotReady),
    ])
    func availabilityMapping(system: SystemLanguageModel.Availability, expected: RecapAvailability) {
        #expect(RecapAvailability(system) == expected)
    }

    @Test func onlyUnavailableStatesHaveMessages() {
        #expect(RecapAvailability.available.title == nil)
        #expect(RecapAvailability.appleIntelligenceOff.title == "Recaps need Apple Intelligence")
        #expect(RecapAvailability.modelNotReady.message == "The model is still downloading. Recaps will start when it's ready.")
    }

    @Test func otherErrorsUseTheirDescription() {
        #expect(!RecapErrors.isContextOverflow(FakeRecapError()))
        #expect(RecapErrors.message(for: FakeRecapError()) == "Boom")
    }

    @Test func plainTextListsKeyPoints() {
        #expect(RecapContent(headline: "S.", keyPoints: ["a", "b"]).plainText == "S.\n- a\n- b")
        #expect(RecapContent(headline: "S.", keyPoints: []).plainText == "S.")
    }

    @Test func entryRangeFormatting() {
        #expect(RecapEntry.formattedRange(0, 605) == "00:00 – 10:05")
    }

    @Test func intervalLabels() {
        #expect(RecapInterval.ten.seconds == 600)
        #expect(RecapInterval.five.menuLabel == "5 minutes")
        #expect(RecapInterval.fifteen.shortLabel == "Every 15 min")
    }

    @Test func parsesAFormattedReply() {
        let reply = "Summary: They compared two vendors. Larkspur is cheaper.\nKey points:\n- Shortlist: Northwind, Larkspur\n- Rollout Feb 3"
        #expect(SystemRecapGenerator.parse(reply)
            == RecapContent(headline: "They compared two vendors. Larkspur is cheaper.", keyPoints: ["Shortlist: Northwind, Larkspur", "Rollout Feb 3"]))
    }

    @Test func parseToleratesBlankLinesSpacesAndOtherBullets() {
        let reply = "  summary:   A.  \n\nKey Points:\n\n  • x  \n* y\n- z\n"
        #expect(SystemRecapGenerator.parse(reply) == RecapContent(headline: "A.", keyPoints: ["x", "y", "z"]))
    }

    @Test func parseJoinsASummaryOverSeveralLines() {
        #expect(SystemRecapGenerator.parse("Summary: A.\nB.\nKey points:\n- x")
            == RecapContent(headline: "A. B.", keyPoints: ["x"]))
    }

    @Test func parseWithoutKeyPoints() {
        #expect(SystemRecapGenerator.parse("Summary: A.") == RecapContent(headline: "A.", keyPoints: []))
    }

    @Test func parseKeepsAnUnformattedReplyAsTheSummary() {
        #expect(SystemRecapGenerator.parse("\nThey talked about grids.\n")
            == RecapContent(headline: "They talked about grids.", keyPoints: []))
    }

    @Test(arguments: [("概要", "キーポイント", ":"), ("要約", "重要なポイント", "："), ("まとめ", "要点", ":")])
    func parsesJapaneseLabels(summary: String, keyPoints: String, colon: String) {
        let reply = "\(summary)\(colon) 導入は2月3日を目指します。\n\n\(keyPoints)\(colon)\n- 期限: 12月31日\n- 候補: ノースウィンド、ラークスパー"
        #expect(SystemRecapGenerator.parse(reply)
            == RecapContent(headline: "導入は2月3日を目指します。", keyPoints: ["期限: 12月31日", "候補: ノースウィンド、ラークスパー"]))
    }

    @Test func parseKeepsAtMostSixKeyPoints() {
        let reply = "Summary: A.\nKey points:\n" + (1...8).map { "- p\($0)" }.joined(separator: "\n")
        #expect(SystemRecapGenerator.parse(reply).keyPoints == ["p1", "p2", "p3", "p4", "p5", "p6"])
    }

    @Test func instructionsAskForTheReplyFormat() {
        for instructions in [SystemRecapGenerator.instructions(for: .japanese), SystemRecapGenerator.mergeInstructions(for: .english)] {
            #expect(instructions.contains("Summary: <1 to 3 sentences>\nKey points:\n- <point>"))
        }
    }

    @Test func refusalsAreReportedAsDeclined() {
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
            let refusal = LanguageModelError.refusal(.init(explanation: "", debugDescription: "May contain sensitive content"))
            #expect(RecapErrors.message(for: refusal) == "The on-device model declined the request.")
        }
    }
}
