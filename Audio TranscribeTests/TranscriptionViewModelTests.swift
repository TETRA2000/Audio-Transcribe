import Foundation
import Testing
@testable import Audio_Transcribe

struct TranscriptionViewModelTests {
    @Test func availableSourceKinds() {
        let viewModel = TranscriptionViewModel()
        #if os(macOS)
        #expect(viewModel.availableSourceKinds == [.microphone, .systemAudio, .file])
        #else
        #expect(viewModel.availableSourceKinds == [.microphone, .file])
        #endif
    }

    @Test(arguments: [
        (TranscriptionStatus.idle, false, false),
        (.preparingModel, false, true),
        (.recording, true, false),
        (.transcribingFile, false, true),
        (.failed("error"), false, false),
    ])
    func recordingAndBusyFlags(status: TranscriptionStatus, isRecording: Bool, isBusy: Bool) {
        let viewModel = TranscriptionViewModel()
        viewModel.status = status
        #expect(viewModel.isRecording == isRecording)
        #expect(viewModel.isBusy == isBusy)
    }

    @Test func fullTextKeepsEnglishSpacingFromTheTranscriber() {
        let viewModel = TranscriptionViewModel()
        viewModel.segments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello, this is a test."),
            TranscriptSegment(start: 2, end: 4, text: " The quick brown fox."),
        ]
        #expect(viewModel.fullText == "Hello, this is a test. The quick brown fox.")
    }

    @Test func fullTextDoesNotInsertSpacesIntoJapanese() {
        let viewModel = TranscriptionViewModel()
        viewModel.segments = [
            TranscriptSegment(start: 0, end: 2, text: "こんにちは。"),
            TranscriptSegment(start: 2, end: 4, text: "これはテストです。"),
        ]
        #expect(viewModel.fullText == "こんにちは。これはテストです。")
    }

    @Test func clearRemovesTranscript() {
        let viewModel = TranscriptionViewModel()
        viewModel.segments = [TranscriptSegment(start: 0, end: 1, text: "Hello")]
        viewModel.volatileText = "wor"
        viewModel.clear()
        #expect(viewModel.segments.isEmpty)
        #expect(viewModel.volatileText.isEmpty)
    }

    @Test func consumeReplacesVolatileTextAndAppendsFinalResults() async {
        let viewModel = TranscriptionViewModel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        continuation.yield(TranscriptUpdate(text: "Hel", start: 0, end: 0.5, isFinal: false))
        continuation.yield(TranscriptUpdate(text: "Hello wor", start: 0, end: 1, isFinal: false))
        continuation.yield(TranscriptUpdate(text: "Hello world.", start: 0, end: 1.2, isFinal: true))
        continuation.yield(TranscriptUpdate(text: " Next", start: 1.2, end: 1.6, isFinal: false))
        continuation.finish()

        await viewModel.consume(stream)

        #expect(viewModel.segments.map(\.text) == ["Hello world."])
        #expect(viewModel.segments.first?.start == 0)
        #expect(viewModel.segments.first?.end == 1.2)
        #expect(viewModel.volatileText == " Next")
    }

    @Test func consumeClearsVolatileTextWhenItBecomesFinal() async {
        let viewModel = TranscriptionViewModel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        continuation.yield(TranscriptUpdate(text: "こんにち", start: 0, end: 0.5, isFinal: false))
        continuation.yield(TranscriptUpdate(text: "こんにちは。", start: 0, end: 1, isFinal: true))
        continuation.finish()

        await viewModel.consume(stream)

        #expect(viewModel.segments.map(\.text) == ["こんにちは。"])
        #expect(viewModel.volatileText.isEmpty)
    }

    @Test func consumeReportsStreamErrors() async {
        let viewModel = TranscriptionViewModel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        continuation.yield(TranscriptUpdate(text: "Partial.", start: 0, end: 1, isFinal: true))
        continuation.finish(throwing: TranscriptionError.unsupportedLocale)

        await viewModel.consume(stream)

        #expect(viewModel.segments.map(\.text) == ["Partial."])
        #expect(viewModel.status == .failed(TranscriptionError.unsupportedLocale.localizedDescription))
    }
}
