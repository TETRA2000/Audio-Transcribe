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
