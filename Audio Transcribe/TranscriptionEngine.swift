import Foundation
import Speech
import AVFoundation

nonisolated enum TranscriptionLanguage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case english
    case japanese

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en-US")
        case .japanese: Locale(identifier: "ja-JP")
        }
    }

    var displayName: String {
        switch self {
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

nonisolated enum TranscriptionError: LocalizedError {
    case unsupportedLocale
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            "This language isn't supported for on-device transcription on this device."
        case .audioFormatUnavailable:
            "No compatible audio format is available for transcription."
        }
    }
}

nonisolated struct TranscriptUpdate: Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let isFinal: Bool
}

/// Wraps the on-device Speech framework analyzer/transcriber pipeline for both
/// live audio (microphone, system audio) and pre-recorded files.
actor TranscriptionEngine {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var converter: AnalyzerInputConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var liveResultsContinuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    /// Whether any audio reached the live analyzer. An analyzer that never received input doesn't end its
    /// results when finalized, so the engine ends them itself.
    private var didAppendLiveAudio = false

    static func resolvedLocale(for language: TranscriptionLanguage) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: language.locale)
    }

    static func isAvailable(for language: TranscriptionLanguage) async -> Bool {
        guard let locale = await resolvedLocale(for: language) else { return false }
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains(locale)
    }

    /// Ensures the on-device model assets for `language` are installed, reporting progress if a download is needed.
    func prepareAssets(for language: TranscriptionLanguage, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws {
        guard let locale = await Self.resolvedLocale(for: language) else {
            throw TranscriptionError.unsupportedLocale
        }
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) else {
            return
        }
        progressHandler?(request.progress)
        try await request.downloadAndInstall()
    }

    private func clearAnalysisState() {
        analyzer = nil
        transcriber = nil
        converter = nil
        inputContinuation = nil
    }

    // MARK: - Live transcription (microphone / system audio)

    func startLiveTranscription(language: TranscriptionLanguage) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        guard let locale = await Self.resolvedLocale(for: language) else {
            throw TranscriptionError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.audioFormatUnavailable
        }

        let converter = AnalyzerInputConverter(analyzerFormat: audioFormat)
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        self.transcriber = transcriber
        self.converter = converter
        self.inputContinuation = inputContinuation
        self.analyzer = analyzer

        try await analyzer.start(inputSequence: inputSequence)

        let (results, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        let task = Task {
            do {
                for try await result in transcriber.results {
                    continuation.yield(TranscriptUpdate(result))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        liveResultsContinuation = continuation
        didAppendLiveAudio = false
        return results
    }

    /// Feeds a captured audio buffer (from the microphone or system audio) into the in-progress live transcription.
    func appendLiveAudio(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let inputContinuation else { return }
        guard let inputs = try? converter.convert(buffer, at: nil) else { return }
        for input in inputs {
            inputContinuation.yield(input)
            didAppendLiveAudio = true
        }
    }

    /// Stops feeding audio and waits for the transcriber to finalize its results.
    func finishLiveTranscription() async throws {
        let analyzer = self.analyzer
        let resultsContinuation = liveResultsContinuation
        let receivedAudio = didAppendLiveAudio
        liveResultsContinuation = nil
        if let converter, let inputContinuation {
            if let inputs = try? converter.flush() {
                for input in inputs {
                    inputContinuation.yield(input)
                }
            }
            inputContinuation.finish()
        }
        clearAnalysisState()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        if !receivedAudio {
            // No input means no results to deliver, but the transcriber's results never end on their own.
            resultsContinuation?.finish()
        }
    }

    // MARK: - File transcription

    func transcribeFile(at url: URL, language: TranscriptionLanguage) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        guard let locale = await Self.resolvedLocale(for: language) else {
            throw TranscriptionError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await result in transcriber.results {
                                continuation.yield(TranscriptUpdate(result))
                            }
                        }
                        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                            try await analyzer.finalizeAndFinish(through: lastSampleTime)
                        } else {
                            await analyzer.cancelAndFinishNow()
                        }
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch {
                    await analyzer.cancelAndFinishNow()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension TranscriptUpdate {
    nonisolated init(_ result: SpeechTranscriber.Result) {
        self.init(
            text: String(result.text.characters),
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            isFinal: result.isFinal
        )
    }
}
