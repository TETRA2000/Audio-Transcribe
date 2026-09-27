import Foundation
import Testing
@testable import Audio_Transcribe

struct LiveChannelTests {
    private func makeChannel(_ source: FakeSource, _ transcriber: FakeTranscriber, label: String = "Zoom") -> LiveChannel {
        LiveChannel(kind: .systemAudio, label: label, source: source.liveAudioSource, transcriber: transcriber)
    }

    @Test func finalResultsMoveOntoTheSessionTimelineWithTheSpeakerLabel() async throws {
        let source = FakeSource()
        let transcriber = FakeTranscriber()
        let channel = makeChannel(source, transcriber)

        try await channel.start(language: .english, sessionStart: Date(timeIntervalSinceNow: -5), labelSegments: true)
        await transcriber.emit(TranscriptUpdate(text: " Hi there.", start: 1, end: 2, isFinal: true))
        try await channel.stop()

        let segment = try #require(channel.segments.first)
        #expect(segment.text == " Hi there.")
        #expect(abs(segment.start - 6) < 0.5)
        #expect(abs(segment.end - 7) < 0.5)
        #expect(segment.speaker == "Zoom")
    }

    @Test func segmentsHaveNoSpeakerWhenLabelsAreOff() async throws {
        let transcriber = FakeTranscriber()
        let channel = makeChannel(FakeSource(), transcriber)

        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        await transcriber.emit(TranscriptUpdate(text: "Hi.", start: 0, end: 1, isFinal: true))
        await transcriber.emit(TranscriptUpdate(text: " Nex", start: 1, end: 1.5, isFinal: false))
        try await channel.stop()

        #expect(channel.segments.map(\.speaker) == [nil])
        #expect(channel.volatileText == " Nex")
    }

    @Test func stopWaitsForPendingResults() async throws {
        let source = FakeSource()
        let transcriber = FakeTranscriber()
        let channel = makeChannel(source, transcriber)

        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        for index in 0..<3 {
            await transcriber.emit(TranscriptUpdate(text: "\(index)", start: Double(index), end: Double(index) + 1, isFinal: true))
        }
        try await channel.stop()

        #expect(channel.segments.map(\.text) == ["0", "1", "2"])
        #expect(!channel.isRunning)
        #expect(source.stopCount == 1)
        #expect(await transcriber.finishCount == 1)
    }

    @Test func stoppingDoesNotReportAnUnexpectedEnd() async throws {
        let channel = makeChannel(FakeSource(), FakeTranscriber())
        var reported = false
        channel.onUnexpectedEnd = { reported = true }

        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        try await channel.stop()
        for _ in 0..<10 { await Task.yield() }

        #expect(!reported)
        #expect(!channel.endedUnexpectedly)
    }

    @Test func sourceEndingByItselfEndsTheChannel() async throws {
        let source = FakeSource()
        let transcriber = FakeTranscriber()
        let channel = makeChannel(source, transcriber)
        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)

        await withCheckedContinuation { continuation in
            channel.onUnexpectedEnd = { continuation.resume() }
            source.endUnexpectedly()
        }

        #expect(channel.endedUnexpectedly)
        #expect(!channel.isRunning)
        #expect(source.stopCount == 1)
        #expect(await transcriber.finishCount == 1)

        try await channel.stop()
        #expect(source.stopCount == 1)
        #expect(await transcriber.finishCount == 1)
    }

    @Test func sourceFailureFinishesTheTranscriberAndRethrows() async {
        let source = FakeSource()
        source.startError = TestError()
        let transcriber = FakeTranscriber()
        let channel = makeChannel(source, transcriber)

        await #expect(throws: TestError.self) {
            try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        }
        #expect(!channel.isRunning)
        #expect(await transcriber.finishCount == 1)
    }

    @Test func transcriberErrorsAreReported() async throws {
        let transcriber = FakeTranscriber()
        let channel = makeChannel(FakeSource(), transcriber)
        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)

        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error, Never>) in
            channel.onFailure = { continuation.resume(returning: $0) }
            Task { await transcriber.fail(TestError()) }
        }

        #expect(error is TestError)
        try await channel.stop()
    }

    @Test func startAllStopsStartedChannelsWhenOneFails() async {
        let micSource = FakeSource()
        let micTranscriber = FakeTranscriber()
        let appSource = FakeSource()
        appSource.startError = TestError()
        let mic = LiveChannel(kind: .microphone, label: "You", source: micSource.liveAudioSource, transcriber: micTranscriber)
        let app = makeChannel(appSource, FakeTranscriber())

        await #expect(throws: TestError.self) {
            try await LiveChannel.startAll([mic, app], language: .english, sessionStart: Date(), labelSegments: true)
        }

        #expect(!mic.isRunning)
        #expect(!app.isRunning)
        #expect(micSource.stopCount == 1)
        #expect(await micTranscriber.finishCount == 1)
    }

    @Test func stopAllStopsEveryChannel() async throws {
        let sources = [FakeSource(), FakeSource()]
        let channels = sources.map { makeChannel($0, FakeTranscriber()) }

        try await LiveChannel.startAll(channels, language: .english, sessionStart: Date(), labelSegments: true)
        #expect(channels.allSatisfy { $0.isRunning })
        try await LiveChannel.stopAll(channels)

        #expect(channels.allSatisfy { !$0.isRunning })
        #expect(sources.map(\.stopCount) == [1, 1])
    }
}
