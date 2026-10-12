import Foundation
@testable import Transcripta

struct FakeRecapError: LocalizedError {
    var errorDescription: String? { "Boom" }
}

/// Records each call. Returns `results` in order, then `Summary N` / `["Point"]`.
/// With `holdsCalls`, each call waits until `releaseHeldCalls()`.
final class FakeRecapGenerator: RecapGenerating {
    struct Call {
        let lines: [String]
        let earlier: String?
        let language: TranscriptionLanguage
    }

    var availability: RecapAvailability = .available
    var results: [Result<RecapContent, Error>] = []
    var holdsCalls = false
    private(set) var calls: [Call] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent {
        calls.append(Call(lines: lines, earlier: earlier, language: language))
        let number = calls.count
        if holdsCalls {
            await withCheckedContinuation { held.append($0) }
        }
        let result = results.isEmpty
            ? .success(RecapContent(headline: "Summary \(number)", keyPoints: ["Point"]))
            : results.removeFirst()
        return try result.get()
    }

    /// The parts passed to each `overview(of:language:)` call.
    private(set) var overviewCalls: [[RecapContent]] = []
    var overviewResults: [Result<RecapContent, Error>] = []

    func overview(of parts: [RecapContent], language: TranscriptionLanguage) async throws -> RecapContent {
        overviewCalls.append(parts)
        let result = overviewResults.isEmpty
            ? .success(RecapContent(headline: "Overview \(overviewCalls.count)", keyPoints: ["Overall point"]))
            : overviewResults.removeFirst()
        return try result.get()
    }

    func releaseHeldCalls() {
        let continuations = held
        held = []
        continuations.forEach { $0.resume() }
    }

    /// Waits until `count` calls have started, including ones still held.
    func waitForCalls(_ count: Int) async {
        while calls.count < count { await Task.yield() }
    }
}

/// A segment of `words` words starting at `start` and lasting 5 seconds.
func speech(_ words: Int, at start: TimeInterval, speaker: String? = nil) -> TranscriptSegment {
    TranscriptSegment(
        start: start,
        end: start + 5,
        text: Array(repeating: "word", count: words).joined(separator: " "),
        speaker: speaker
    )
}
