import Foundation
import Testing
@testable import Audio_Transcribe

/// Runs the real on-device transcriber against short synthesized clips in `Fixtures/`.
/// Skipped where the Speech models aren't supported (e.g. the Simulator or older hardware).
/// The first run may download the language model.
@Suite(.timeLimit(.minutes(5)))
struct TranscriptionEngineTests {
    @Test(.enabled("English on-device transcription is supported") {
        await TranscriptionEngine.isAvailable(for: .english)
    })
    func transcribesEnglishFile() async throws {
        let updates = try await transcribe(fixture: "english-sample", language: .english)
        let text = updates.map(\.text).joined().lowercased()
        #expect(text.contains("test of on-device transcription") || text.contains("test of on device transcription"))
        #expect(text.contains("quick brown fox"))
        assertWellFormed(updates)
    }

    @Test(.enabled("Japanese on-device transcription is supported") {
        await TranscriptionEngine.isAvailable(for: .japanese)
    })
    func transcribesJapaneseFile() async throws {
        let updates = try await transcribe(fixture: "japanese-sample", language: .japanese)
        let text = updates.map(\.text).joined()
        #expect(text.contains("こんにちは"))
        #expect(text.contains("テスト"))
        assertWellFormed(updates)
    }

    @Test(.enabled("English on-device transcription is supported") {
        await TranscriptionEngine.isAvailable(for: .english)
    })
    func missingFileThrows() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("does-not-exist.m4a")
        await #expect(throws: (any Error).self) {
            _ = try await TranscriptionEngine().transcribeFile(at: url, language: .english)
        }
    }

    /// A live source that never delivers audio (e.g. a microphone that fails to start) must not leave the
    /// results stream open forever, or stopping the session hangs.
    @Test(.enabled("English on-device transcription is supported") {
        await TranscriptionEngine.isAvailable(for: .english)
    })
    func liveResultsEndWhenFinishedWithoutAnyAudio() async throws {
        let engine = TranscriptionEngine()
        try await engine.prepareAssets(for: .english)
        let results = try await engine.startLiveTranscription(language: .english)
        try await engine.finishLiveTranscription()

        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { for try await _ in results {} } catch {}
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(ended, "The live results stream should end once the transcription is finished")
    }

    private func transcribe(fixture: String, language: TranscriptionLanguage) async throws -> [TranscriptUpdate] {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(
            bundle.url(forResource: fixture, withExtension: "m4a")
                ?? bundle.url(forResource: fixture, withExtension: "m4a", subdirectory: "Fixtures")
        )
        let engine = TranscriptionEngine()
        try await engine.prepareAssets(for: language)
        var updates: [TranscriptUpdate] = []
        for try await update in try await engine.transcribeFile(at: url, language: language) {
            updates.append(update)
        }
        return updates
    }

    /// File transcription uses the non-progressive preset, so every result should be final and in order.
    private func assertWellFormed(_ updates: [TranscriptUpdate]) {
        #expect(!updates.isEmpty)
        #expect(updates.allSatisfy { $0.isFinal })
        #expect(updates.allSatisfy { $0.start <= $0.end })
        #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.end <= $1.start })
    }
}

private final class BundleToken {}
