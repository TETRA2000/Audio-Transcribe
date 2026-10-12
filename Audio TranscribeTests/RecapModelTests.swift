import Foundation
import FoundationModels
import Testing
@testable import Audio_Transcribe

/// Runs the real on-device model. Skipped where Apple Intelligence isn't available, including GitHub's macOS VMs.
@Suite(.timeLimit(.minutes(2)))
struct RecapModelTests {
    static let english = [
        "You: Thanks for joining. We need to pick a ticketing vendor before December 31.",
        "Zoom: The shortlist is Northwind and Larkspur. Larkspur is about 18 percent cheaper.",
        "You: Larkspur only offers business-hours support, which is a problem for the Tokyo team.",
        "Zoom: I'll email Dana at Larkspur today to ask about an overnight support tier.",
        "You: Great. Let's aim for a rollout on February 3 if they say yes.",
    ]

    static let japanese = [
        "You: 本日はありがとうございます。12月31日までにチケット管理ツールを決める必要があります。",
        "Zoom: 候補はノースウィンドとラークスパーの二社です。ラークスパーの方が約18パーセント安いです。",
        "You: ただ、ラークスパーのサポートは平日日中のみで、東京チームには問題です。",
        "Zoom: 今日中にラークスパーの担当者に夜間サポートについて問い合わせます。",
        "You: よろしくお願いします。問題なければ2月3日の導入を目指しましょう。",
    ]

    /// Openers that describe the conversation instead of saying what was said.
    static let metaOpener = try! Regex(#"^(?i)(the|this|in this) (conversation|episode|discussion|transcript|speakers?|podcast|meeting)\b"#)

    /// Harmless, but structured (`@Generable`) generation refused it as "May contain sensitive content" every time.
    static let anxious = [
        "We're headed somewhere, and it's not clear yet whether it's a good place or a bad one.",
        "Honestly, I'm scared.",
        "Not about the usual things people mention, like a cyberattack or a market crash or machines taking over.",
        "What worries me is what my work means if a computer can do it better.",
        "It's a question about purpose, about what it means to be a person who does math.",
        "So let's just talk about it.",
    ]

    @Test(.enabled("Apple Intelligence is available") { SystemLanguageModel.default.availability == .available })
    func recapsEnglish() async throws {
        let content = try await SystemRecapGenerator().recap(lines: Self.english, earlier: nil, language: .english)
        #expect(!content.headline.isEmpty)
        #expect(content.headline.split(separator: " ").count <= 16, "headline: \(content.headline)")
        #expect(content.headline.firstMatch(of: Self.metaOpener) == nil, "headline: \(content.headline)")
        #expect(!content.keyPoints.isEmpty)
        #expect(content.keyPoints.count <= 6)
    }

    @Test(.enabled("Apple Intelligence is available") { SystemLanguageModel.default.availability == .available })
    func recapsAnAnxiousButHarmlessConversation() async throws {
        let content = try await SystemRecapGenerator().recap(lines: Self.anxious, earlier: nil, language: .english)
        #expect(!content.headline.isEmpty)
    }

    @Test(.enabled("Apple Intelligence is available") { SystemLanguageModel.default.availability == .available })
    func recapsJapanese() async throws {
        let content = try await SystemRecapGenerator().recap(lines: Self.japanese, earlier: "They opened the vendor review.", language: .japanese)
        #expect(!content.headline.isEmpty)
        #expect(!content.keyPoints.isEmpty)
        #expect(content.keyPoints.count <= 6)
        #expect(content.headline.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) })
    }

    @Test(.enabled("Apple Intelligence is available") { SystemLanguageModel.default.availability == .available })
    func overviewCombinesManyRecapsInRounds() async throws {
        let topics = [
            ("Kickoff: ticketing vendor must be live before Dec 31", ["Budget cap is $40k a year", "You own the migration checklist"]),
            ("Five vendors reviewed; three lack SSO or Japanese support", ["Shortlist: Northwind and Larkspur"]),
            ("Larkspur is 18% cheaper but only offers business-hours support", ["Tokyo team needs overnight coverage"]),
            ("Dana at Larkspur will be asked about an overnight tier", ["Email goes out today"]),
            ("Northwind demo set for Thursday at 3 pm", ["Bring SSO questions"]),
            ("Data migration needs two weeks of testing", ["Start testing Jan 6"]),
            ("Training sessions planned for both offices", ["Tokyo session in Japanese"]),
            ("Rollout targeted for Feb 3 if Larkspur says yes", ["Fallback: Northwind on Feb 17"]),
            ("Old contract cannot be extended past Dec 31", ["Legal confirmed on Monday"]),
            ("Next check-in is Friday", ["Decision due then"]),
        ].map { RecapContent(headline: $0.0, keyPoints: $0.1) }

        let content = try await SystemRecapGenerator().overview(of: topics, language: .english)

        #expect(!content.headline.isEmpty)
        #expect(content.headline.split(separator: " ").count <= 16, "headline: \(content.headline)")
        #expect(!content.keyPoints.isEmpty)
        #expect(content.keyPoints.count <= 6)
    }
}
