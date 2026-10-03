import Foundation
import Testing
@testable import Audio_Transcribe

struct TranscriptionLanguageTests {
    @Test func englishUsesUSEnglishLocale() {
        let locale = TranscriptionLanguage.english.locale
        #expect(locale.language.languageCode == .english)
        #expect(locale.region == .unitedStates)
    }

    @Test func japaneseUsesJapanLocale() {
        let locale = TranscriptionLanguage.japanese.locale
        #expect(locale.language.languageCode == .japanese)
        #expect(locale.region == .japan)
    }

    @Test func displayNamesAreInTheirOwnLanguage() {
        #expect(TranscriptionLanguage.english.displayName == "English")
        #expect(TranscriptionLanguage.japanese.displayName == "日本語")
    }
}

struct TranscriptSegmentTests {
    @Test(arguments: [
        (0.0, "00:00"),
        (59.9, "00:59"),
        (65.0, "01:05"),
        (3725.0, "62:05"),
        (-1.0, "--:--"),
        (Double.infinity, "--:--"),
        (Double.nan, "--:--"),
    ])
    func formattedStart(seconds: TimeInterval, expected: String) {
        let segment = TranscriptSegment(start: seconds, end: seconds, text: "")
        #expect(segment.formattedStart == expected)
    }
}

struct TranscriptMergeTests {
    @Test func segmentsHaveNoSpeakerByDefault() {
        #expect(TranscriptSegment(start: 0, end: 1, text: "Hi").speaker == nil)
    }

    @Test func mergeInterleavesChannelsByStartTime() {
        let mic = [
            TranscriptSegment(start: 0, end: 2, text: "a", speaker: "You"),
            TranscriptSegment(start: 10, end: 12, text: "c", speaker: "You"),
        ]
        let app = [TranscriptSegment(start: 5, end: 6, text: "b", speaker: "Zoom")]

        let merged = TranscriptSegment.merged([mic, app])

        #expect(merged.map(\.text) == ["a", "b", "c"])
        #expect(merged.map(\.speaker) == ["You", "Zoom", "You"])
    }

    @Test func mergeKeepsChannelOrderForTies() {
        let mic = [TranscriptSegment(start: 3, end: 4, text: "mic")]
        let app = [
            TranscriptSegment(start: 3, end: 4, text: "app 1"),
            TranscriptSegment(start: 3, end: 4, text: "app 2"),
        ]
        #expect(TranscriptSegment.merged([mic, app]).map(\.text) == ["mic", "app 1", "app 2"])
    }

    @Test func mergeOfNothingIsEmpty() {
        #expect(TranscriptSegment.merged([]).isEmpty)
        #expect(TranscriptSegment.merged([[], []]).isEmpty)
    }
}
