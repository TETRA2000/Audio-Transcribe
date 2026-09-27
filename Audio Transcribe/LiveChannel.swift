import AVFoundation
import Observation

/// Transcribes a live stream of audio buffers. `TranscriptionEngine` is the real implementation; tests use a fake.
nonisolated protocol LiveTranscribing: Sendable {
    func startLiveTranscription(language: TranscriptionLanguage) async throws -> AsyncThrowingStream<TranscriptUpdate, Error>
    func appendLiveAudio(_ buffer: AVAudioPCMBuffer) async
    func finishLiveTranscription() async throws
}

extension TranscriptionEngine: LiveTranscribing {}

enum ChannelKind: Hashable {
    case microphone
    case systemAudio
}

/// Starts and stops one capture source, such as `MicrophoneSource` or `SystemAudioSource`.
struct LiveAudioSource {
    let start: () throws -> AsyncStream<AVAudioPCMBuffer>
    let stop: () -> Void
}

/// One live capture source paired with its own transcriber. Segments are stored on the session timeline:
/// `timeOffset` (how long after the session started this channel started) is added to the transcriber's times.
/// A channel runs once; start a new one for each session.
@Observable
final class LiveChannel {
    let kind: ChannelKind
    /// "You" for the microphone; the app name or "System audio" for system audio.
    let label: String
    private(set) var timeOffset: TimeInterval = 0
    var segments: [TranscriptSegment] = []
    var volatileText = ""
    private(set) var isRunning = false
    /// Set when the source stopped by itself, for example because the microphone was unplugged.
    private(set) var endedUnexpectedly = false

    @ObservationIgnored var onUnexpectedEnd: (() -> Void)?
    @ObservationIgnored var onFailure: ((Error) -> Void)?

    private let source: LiveAudioSource
    private let transcriber: any LiveTranscribing
    @ObservationIgnored private var labelSegments = false
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?

    init(kind: ChannelKind, label: String, source: LiveAudioSource, transcriber: any LiveTranscribing) {
        self.kind = kind
        self.label = label
        self.source = source
        self.transcriber = transcriber
    }

    /// Starts the transcriber, then the source. If the source fails to start, the transcriber is finished and the
    /// error is rethrown. With `labelSegments`, each segment's `speaker` is set to `label`.
    func start(language: TranscriptionLanguage, sessionStart: Date, labelSegments: Bool) async throws {
        self.labelSegments = labelSegments
        let results = try await transcriber.startLiveTranscription(language: language)

        let buffers: AsyncStream<AVAudioPCMBuffer>
        do {
            buffers = try source.start()
        } catch {
            try? await transcriber.finishLiveTranscription()
            throw error
        }
        timeOffset = Date().timeIntervalSince(sessionStart)
        isRunning = true

        resultsTask = Task { [weak self] in
            await self?.consume(results)
        }
        feedTask = Task { [weak self, transcriber] in
            for await buffer in buffers {
                await transcriber.appendLiveAudio(buffer)
            }
            await self?.sourceDidEnd()
        }
    }

    /// Stops the source and waits until the transcriber has delivered its final results. Does nothing if the
    /// channel isn't running.
    func stop() async throws {
        guard isRunning else { return }
        isStopping = true
        source.stop()
        feedTask?.cancel()
        feedTask = nil
        try await finishTranscriber()
    }

    /// Starts every channel concurrently. If any fails, stops the ones that started and rethrows the first error.
    static func startAll(
        _ channels: [LiveChannel],
        language: TranscriptionLanguage,
        sessionStart: Date,
        labelSegments: Bool
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for channel in channels {
                    group.addTask {
                        try await channel.start(language: language, sessionStart: sessionStart, labelSegments: labelSegments)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            for channel in channels {
                try? await channel.stop()
            }
            throw error
        }
    }

    /// Stops every channel concurrently, then throws the first error, if any.
    static func stopAll(_ channels: [LiveChannel]) async throws {
        var firstError: Error?
        await withTaskGroup(of: Error?.self) { group in
            for channel in channels {
                group.addTask {
                    do {
                        try await channel.stop()
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            for await case let error? in group where firstError == nil {
                firstError = error
            }
        }
        if let firstError { throw firstError }
    }

    private func finishTranscriber() async throws {
        isRunning = false
        let resultsTask = self.resultsTask
        self.resultsTask = nil
        do {
            try await transcriber.finishLiveTranscription()
        } catch {
            resultsTask?.cancel()
            throw error
        }
        await resultsTask?.value
    }

    private func sourceDidEnd() async {
        guard isRunning, !isStopping else { return }
        endedUnexpectedly = true
        source.stop()
        try? await finishTranscriber()
        onUnexpectedEnd?()
    }

    private func consume(_ results: AsyncThrowingStream<TranscriptUpdate, Error>) async {
        do {
            for try await update in results {
                if update.isFinal {
                    segments.append(TranscriptSegment(
                        start: update.start + timeOffset,
                        end: update.end + timeOffset,
                        text: update.text,
                        speaker: labelSegments ? label : nil
                    ))
                    volatileText = ""
                } else {
                    volatileText = update.text
                }
            }
        } catch {
            onFailure?(error)
        }
    }
}
