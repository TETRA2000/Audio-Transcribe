import AVFoundation
import Foundation
@testable import Audio_Transcribe

struct TestError: LocalizedError {
    var errorDescription: String? { "Test error." }
}

/// A transcriber whose results the test drives by hand.
actor FakeTranscriber: LiveTranscribing {
    private let startError: Error?
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private(set) var finishCount = 0
    private(set) var appendedBufferCount = 0
    private var isFinishGated = false
    private var finishGateContinuation: CheckedContinuation<Void, Never>?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func startLiveTranscription(language: TranscriptionLanguage) throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        self.continuation = continuation
        return stream
    }

    /// Mirrors `TranscriptionEngine.appendLiveAudio`, which silently drops buffers once
    /// `finishLiveTranscription()` has cleared its analysis state.
    func appendLiveAudio(_ buffer: AVAudioPCMBuffer) {
        guard finishCount == 0 else { return }
        appendedBufferCount += 1
    }

    /// Makes the *next* `finishLiveTranscription()` call suspend until `releaseFinish()` is called, so a test
    /// can deterministically control exactly when a finish completes (e.g. to prove a second caller waits for
    /// an already-in-flight finish rather than returning early).
    func gateFinish() {
        isFinishGated = true
    }

    func releaseFinish() {
        isFinishGated = false
        finishGateContinuation?.resume()
        finishGateContinuation = nil
    }

    func finishLiveTranscription() async throws {
        if isFinishGated {
            await withCheckedContinuation { finishGateContinuation = $0 }
        }
        finishCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ update: TranscriptUpdate) {
        continuation?.yield(update)
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

/// A capture source whose lifetime the test drives by hand.
final class FakeSource {
    var startError: Error?
    private(set) var stopCount = 0
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    var liveAudioSource: LiveAudioSource {
        LiveAudioSource(
            start: { [self] in
                if let startError { throw startError }
                let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
                self.continuation = continuation
                return stream
            },
            stop: { [self] in
                stopCount += 1
                continuation?.finish()
                continuation = nil
            }
        )
    }

    /// Sends a captured buffer into the stream, as when audio arrives from the source.
    func send(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }

    /// Ends the buffer stream without `stop()`, as when a device is unplugged.
    func endUnexpectedly() {
        continuation?.finish()
        continuation = nil
    }
}

/// A channel that has not been started, with its transcript filled in directly.
func makeIdleChannel(
    _ kind: ChannelKind,
    label: String,
    segments: [TranscriptSegment] = [],
    volatileText: String = ""
) -> LiveChannel {
    let channel = LiveChannel(kind: kind, label: label, source: FakeSource().liveAudioSource, transcriber: FakeTranscriber())
    channel.segments = segments
    channel.volatileText = volatileText
    return channel
}
