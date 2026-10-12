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
            RecapContent(summary: "A.", keyPoints: ["x"]),
            RecapContent(summary: "B.", keyPoints: []),
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
        #expect(RecapContent(summary: "S.", keyPoints: ["a", "b"]).plainText == "S.\n- a\n- b")
        #expect(RecapContent(summary: "S.", keyPoints: []).plainText == "S.")
    }

    @Test func entryRangeFormatting() {
        #expect(RecapEntry.formattedRange(0, 605) == "00:00 – 10:05")
    }

    @Test func intervalLabels() {
        #expect(RecapInterval.ten.seconds == 600)
        #expect(RecapInterval.five.menuLabel == "5 minutes")
        #expect(RecapInterval.fifteen.shortLabel == "Every 15 min")
    }
}
