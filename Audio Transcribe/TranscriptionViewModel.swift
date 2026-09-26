import Foundation
import AVFoundation
import Observation

enum TranscriptionSource: String, CaseIterable, Identifiable, Hashable {
    case microphone
    case systemAudio
    case file

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio"
        case .file: "File"
        }
    }
}

enum TranscriptionStatus: Equatable {
    case idle
    case preparingModel
    case recording
    case transcribingFile
    case failed(String)
}

@MainActor
@Observable
final class TranscriptionViewModel {
    var sourceKind: TranscriptionSource = .microphone
    var language: TranscriptionLanguage = .english
    var status: TranscriptionStatus = .idle
    var segments: [TranscriptSegment] = []
    var volatileText: String = ""
    /// Download progress for the on-device language model, when a download is needed.
    var modelDownloadProgress: Progress?

    var availableSourceKinds: [TranscriptionSource] {
        #if os(macOS)
        TranscriptionSource.allCases
        #else
        [.microphone, .file]
        #endif
    }

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    var isBusy: Bool {
        switch status {
        case .preparingModel, .transcribingFile: true
        case .idle, .recording, .failed: false
        }
    }

    private let engine = TranscriptionEngine()
    private let microphoneSource = MicrophoneSource()
    #if os(macOS)
    private let systemAudioSource = SystemAudioSource()
    #endif
    private var feedTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    func start() async {
        guard sourceKind != .file else { return }
        segments = []
        volatileText = ""

        if sourceKind == .microphone {
            guard await AVAudioApplication.requestRecordPermission() else {
                status = .failed("Microphone access was denied.")
                return
            }
        }

        do {
            try await prepareAssets()

            let resultsStream = try await engine.startLiveTranscription(language: language)
            resultsTask = Task { [weak self] in
                await self?.consume(resultsStream)
            }

            let bufferStream: AsyncStream<AVAudioPCMBuffer>
            switch sourceKind {
            case .microphone:
                bufferStream = try microphoneSource.start()
            case .systemAudio:
                #if os(macOS)
                bufferStream = try systemAudioSource.start()
                #else
                status = .failed("System audio isn't available on this platform.")
                return
                #endif
            case .file:
                return
            }

            status = .recording
            feedTask = Task { [weak self] in
                guard let self else { return }
                for await buffer in bufferStream {
                    await self.engine.appendLiveAudio(buffer)
                }
            }
        } catch {
            microphoneSource.stop()
            #if os(macOS)
            systemAudioSource.stop()
            #endif
            try? await engine.finishLiveTranscription()
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        feedTask?.cancel()
        feedTask = nil

        switch sourceKind {
        case .microphone:
            microphoneSource.stop()
        case .systemAudio:
            #if os(macOS)
            systemAudioSource.stop()
            #endif
        case .file:
            break
        }

        do {
            try await engine.finishLiveTranscription()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        status = .idle
    }

    func transcribe(fileURL: URL) async {
        segments = []
        volatileText = ""

        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            try await prepareAssets()

            status = .transcribingFile
            let resultsStream = try await engine.transcribeFile(at: fileURL, language: language)
            await consume(resultsStream)
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func clear() {
        segments = []
        volatileText = ""
    }

    private func prepareAssets() async throws {
        status = .preparingModel
        defer { modelDownloadProgress = nil }
        try await engine.prepareAssets(for: language) { progress in
            Task { @MainActor in
                self.modelDownloadProgress = progress
            }
        }
    }

    private func consume(_ stream: AsyncThrowingStream<TranscriptUpdate, Error>) async {
        do {
            for try await update in stream {
                if update.isFinal {
                    segments.append(TranscriptSegment(start: update.start, end: update.end, text: update.text))
                    volatileText = ""
                } else {
                    volatileText = update.text
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
