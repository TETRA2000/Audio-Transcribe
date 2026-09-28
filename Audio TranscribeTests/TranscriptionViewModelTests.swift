import Foundation
import Testing
@testable import Audio_Transcribe

struct TranscriptionViewModelTests {
    @Test func startsInLiveModeWithOnlyTheMicrophoneOn() {
        let viewModel = TranscriptionViewModel()
        #expect(viewModel.mode == .live)
        #expect(viewModel.micEnabled)
        #expect(!viewModel.systemAudioEnabled)
        #expect(viewModel.systemAudioTarget == .allAudio)
        #expect(viewModel.selectedMicUID == nil)
    }

    @Test func systemAudioIsOfferedOnlyOnMacOS() {
        #if os(macOS)
        #expect(TranscriptionViewModel().supportsSystemAudio)
        #else
        #expect(!TranscriptionViewModel().supportsSystemAudio)
        #endif
    }

    @Test(arguments: [
        (true, false, true),
        (false, true, true),
        (true, true, true),
        (false, false, false),
    ])
    func canStartNeedsAnEnabledSource(mic: Bool, systemAudio: Bool, expected: Bool) {
        let viewModel = TranscriptionViewModel()
        viewModel.micEnabled = mic
        viewModel.systemAudioEnabled = systemAudio
        #if os(macOS)
        #expect(viewModel.canStart == expected)
        #else
        #expect(viewModel.canStart == mic)
        #endif
    }

    @Test(arguments: [TranscriptionStatus.recording, .preparingModel, .transcribingFile])
    func cannotStartWhileRecordingOrBusy(status: TranscriptionStatus) {
        let viewModel = TranscriptionViewModel()
        viewModel.status = status
        #expect(!viewModel.canStart)
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
        viewModel.fileSegments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello, this is a test."),
            TranscriptSegment(start: 2, end: 4, text: " The quick brown fox."),
        ]
        #expect(viewModel.fullText == "Hello, this is a test. The quick brown fox.")
    }

    @Test func fullTextDoesNotInsertSpacesIntoJapanese() {
        let viewModel = TranscriptionViewModel()
        viewModel.fileSegments = [
            TranscriptSegment(start: 0, end: 2, text: "こんにちは。"),
            TranscriptSegment(start: 2, end: 4, text: "これはテストです。"),
        ]
        #expect(viewModel.fullText == "こんにちは。これはテストです。")
    }

    @Test func multiSourceTranscriptIsMergedAndLabeled() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [
            makeIdleChannel(.microphone, label: "You", segments: [
                TranscriptSegment(start: 0, end: 1, text: " Hello.", speaker: "You"),
                TranscriptSegment(start: 4, end: 5, text: " Bye.", speaker: "You"),
            ]),
            makeIdleChannel(.systemAudio, label: "Zoom", segments: [
                TranscriptSegment(start: 2, end: 3, text: " Hi.", speaker: "Zoom"),
            ]),
        ]
        #expect(viewModel.segments.map(\.text) == [" Hello.", " Hi.", " Bye."])
        #expect(viewModel.fullText == "You: Hello.\nZoom: Hi.\nYou: Bye.")
        #expect(viewModel.hasSeparateSources)
    }

    @Test func liveChannelsReplaceTheFileTranscript() {
        let viewModel = TranscriptionViewModel()
        viewModel.fileSegments = [TranscriptSegment(start: 0, end: 1, text: "file")]
        viewModel.channels = [makeIdleChannel(.microphone, label: "You", segments: [TranscriptSegment(start: 0, end: 1, text: "live")])]
        #expect(viewModel.segments.map(\.text) == ["live"])
        #expect(!viewModel.hasSeparateSources)
    }

    @Test func volatileLinesAreLabeledOnlyWithSeveralSources() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [
            makeIdleChannel(.microphone, label: "You", volatileText: "Hel"),
            makeIdleChannel(.systemAudio, label: "Zoom"),
        ]
        #expect(viewModel.volatileLines == [VolatileLine(label: "You", text: "Hel")])

        viewModel.channels = [makeIdleChannel(.microphone, label: "You", volatileText: "Hel")]
        #expect(viewModel.volatileLines == [VolatileLine(label: nil, text: "Hel")])

        viewModel.channels = []
        viewModel.fileVolatileText = "fi"
        #expect(viewModel.volatileLines == [VolatileLine(label: nil, text: "fi")])
    }

    @Test func exportFilesUseTheMergedAndPerSourceTranscripts() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [
            makeIdleChannel(.microphone, label: "You", segments: [TranscriptSegment(start: 0, end: 1, text: " Hello.", speaker: "You")]),
            makeIdleChannel(.systemAudio, label: "Zoom", segments: [TranscriptSegment(start: 2, end: 3, text: " Hi.", speaker: "Zoom")]),
        ]
        let files = viewModel.exportFiles(.combinedAndSeparate, baseName: "T")
        #expect(files == [
            ExportFile(name: "T.txt", text: "[00:00] You: Hello.\n[00:02] Zoom: Hi."),
            ExportFile(name: "T-You.txt", text: "[00:00] Hello."),
            ExportFile(name: "T-Zoom.txt", text: "[00:02] Hi."),
        ])
    }

    @Test func clearRemovesTranscript() {
        let viewModel = TranscriptionViewModel()
        viewModel.fileSegments = [TranscriptSegment(start: 0, end: 1, text: "Hello")]
        viewModel.fileVolatileText = "wor"
        viewModel.channels = [makeIdleChannel(.microphone, label: "You")]
        viewModel.channelWarning = "warning"
        viewModel.clear()
        #expect(viewModel.fileSegments.isEmpty)
        #expect(viewModel.fileVolatileText.isEmpty)
        #expect(viewModel.channels.isEmpty)
        #expect(viewModel.channelWarning == nil)
    }

    @Test func clearDoesNothingWhileRecording() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [makeIdleChannel(.microphone, label: "You")]
        viewModel.status = .recording
        viewModel.clear()
        #expect(viewModel.channels.count == 1)
    }

    @Test(arguments: [
        (ChannelKind.microphone, true, "The microphone was disconnected. Other sources are still being transcribed."),
        (.microphone, false, "The microphone was disconnected."),
        (.systemAudio, true, "System audio capture stopped. Other sources are still being transcribed."),
        (.systemAudio, false, "System audio capture stopped."),
    ])
    func channelWarning(kind: ChannelKind, othersStillRunning: Bool, expected: String) {
        #expect(TranscriptionViewModel.warning(for: kind, othersStillRunning: othersStillRunning) == expected)
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

        #expect(viewModel.fileSegments.map(\.text) == ["Hello world."])
        #expect(viewModel.fileSegments.first?.start == 0)
        #expect(viewModel.fileSegments.first?.end == 1.2)
        #expect(viewModel.fileVolatileText == " Next")
    }

    @Test func consumeClearsVolatileTextWhenItBecomesFinal() async {
        let viewModel = TranscriptionViewModel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        continuation.yield(TranscriptUpdate(text: "こんにち", start: 0, end: 0.5, isFinal: false))
        continuation.yield(TranscriptUpdate(text: "こんにちは。", start: 0, end: 1, isFinal: true))
        continuation.finish()

        await viewModel.consume(stream)

        #expect(viewModel.fileSegments.map(\.text) == ["こんにちは。"])
        #expect(viewModel.fileVolatileText.isEmpty)
    }

    @Test(arguments: [
        (TranscriptionStatus.failed("boom"), true, TranscriptionStatus.failed("boom")),
        (.failed("boom"), false, .failed("boom")),
        (.preparingModel, true, .recording),
        (.preparingModel, false, .idle),
        (.idle, true, .recording),
        (.idle, false, .idle),
    ])
    func statusAfterStartingNeverOverwritesAFailure(current: TranscriptionStatus, anyChannelRunning: Bool, expected: TranscriptionStatus) {
        #expect(TranscriptionViewModel.statusAfterStarting(current: current, anyChannelRunning: anyChannelRunning) == expected)
    }

    @Test(arguments: [
        (TranscriptionStatus.failed("boom"), TranscriptionStatus.failed("boom")),
        (.recording, .idle),
        (.idle, .idle),
    ])
    func statusAfterStoppingNeverOverwritesAFailure(current: TranscriptionStatus, expected: TranscriptionStatus) {
        #expect(TranscriptionViewModel.statusAfterStopping(current: current) == expected)
    }

    @Test func consumeReportsStreamErrors() async {
        let viewModel = TranscriptionViewModel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        continuation.yield(TranscriptUpdate(text: "Partial.", start: 0, end: 1, isFinal: true))
        continuation.finish(throwing: TranscriptionError.unsupportedLocale)

        await viewModel.consume(stream)

        #expect(viewModel.fileSegments.map(\.text) == ["Partial."])
        #expect(viewModel.status == .failed(TranscriptionError.unsupportedLocale.localizedDescription))
    }

    @Test func exportToFolderWritesSeparateFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 5)))

        let viewModel = TranscriptionViewModel()
        viewModel.channels = [
            makeIdleChannel(.microphone, label: "You", segments: [TranscriptSegment(start: 0, end: 1, text: " Hello.", speaker: "You")]),
            makeIdleChannel(.systemAudio, label: "Zoom", segments: [TranscriptSegment(start: 2, end: 3, text: " Hi.", speaker: "Zoom")]),
        ]
        viewModel.export(.separate, toFolder: folder, date: date)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(names == ["Transcript 2026-09-27 14.05-You.txt", "Transcript 2026-09-27 14.05-Zoom.txt"])
        #expect(viewModel.status == .idle)
    }

    @Test func exportFailureIsReported() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [makeIdleChannel(.microphone, label: "You", segments: [TranscriptSegment(start: 0, end: 1, text: "Hi")])]
        viewModel.export(.combined, toFolder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        guard case .failed = viewModel.status else {
            Issue.record("Expected a failed status, got \(viewModel.status)")
            return
        }
    }
}
