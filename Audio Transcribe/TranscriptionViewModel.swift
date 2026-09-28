import Foundation
import AVFoundation
import Observation

enum CaptureMode: String, CaseIterable, Identifiable, Hashable {
    case live
    case file

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: "Live"
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

/// In-progress text for one source. `label` is set only when several sources are live.
struct VolatileLine: Identifiable, Equatable {
    let label: String?
    let text: String

    var id: String { label ?? "" }
}

@MainActor
@Observable
final class TranscriptionViewModel {
    var mode: CaptureMode = .live
    var language: TranscriptionLanguage = .english
    var status: TranscriptionStatus = .idle

    var micEnabled = true
    /// The chosen input device's UID (macOS). `nil` means the system default.
    var selectedMicUID: String?
    var systemAudioEnabled = false
    var systemAudioTarget: SystemAudioTarget = .allAudio

    /// The live session's channels. They are kept after stopping so the transcript can still be read and exported.
    var channels: [LiveChannel] = []
    /// The last file transcription.
    var fileSegments: [TranscriptSegment] = []
    var fileVolatileText = ""
    /// Shown when one source of a live session stops by itself, such as an unplugged microphone.
    var channelWarning: String?
    /// Download progress for the on-device language model, when a download is needed.
    var modelDownloadProgress: Progress?

    var supportsSystemAudio: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var canStart: Bool {
        let hasSource = micEnabled || (supportsSystemAudio && systemAudioEnabled)
        return hasSource && !isRecording && !isBusy
    }

    /// The transcript on one timeline: the live channels merged by time, or else the file transcript.
    var segments: [TranscriptSegment] {
        channels.isEmpty ? fileSegments : TranscriptSegment.merged(channels.map(\.segments))
    }

    var volatileLines: [VolatileLine] {
        if channels.isEmpty {
            return fileVolatileText.isEmpty ? [] : [VolatileLine(label: nil, text: fileVolatileText)]
        }
        let labeled = channels.count > 1
        return channels
            .filter { !$0.volatileText.isEmpty }
            .map { VolatileLine(label: labeled ? $0.label : nil, text: $0.volatileText) }
    }

    /// Whether the transcript came from several sources, so it can be exported as separate files.
    var hasSeparateSources: Bool { channels.count > 1 }

    /// The transcript as plain text for Copy and Share. A single-source transcript is concatenated as-is: the
    /// transcriber already includes leading spaces where the language needs them (English) and none where it doesn't
    /// (Japanese). A multi-source transcript puts each segment on its own `Speaker: text` line.
    var fullText: String {
        let segments = self.segments
        if segments.contains(where: { $0.speaker != nil }) {
            return segments
                .map { segment in
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return segment.speaker.map { "\($0): \(text)" } ?? text
                }
                .joined(separator: "\n")
        }
        return segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Prepares language assets and transcribes files. Each live channel has its own engine.
    private let engine = TranscriptionEngine()
    private let microphoneSource = MicrophoneSource()
    #if os(macOS)
    private let systemAudioSource = SystemAudioSource()
    #endif

    func start() async {
        guard mode == .live, canStart else { return }
        clear()
        // Marks the view model busy before the first `await` below, so a second Start tap during the permission
        // prompt or asset preparation sees `canStart == false` instead of racing this call to build its own
        // channels around the same shared `MicrophoneSource`/`SystemAudioSource`.
        status = .preparingModel

        if micEnabled {
            guard await AVAudioApplication.requestRecordPermission() else {
                status = .failed("Microphone access was denied.")
                return
            }
        }

        let newChannels = makeChannels()
        do {
            try await prepareAssets()
            channels = newChannels
            try await LiveChannel.startAll(
                newChannels,
                language: language,
                sessionStart: Date(),
                labelSegments: newChannels.count > 1
            )
            status = Self.statusAfterStarting(current: status, anyChannelRunning: newChannels.contains(where: \.isRunning))
        } catch {
            channels = []
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        do {
            try await LiveChannel.stopAll(channels)
            status = Self.statusAfterStopping(current: status)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// The status to report once `startAll` finishes: unless a channel already failed while `startAll` was
    /// still awaiting (`onFailure` sets `.failed` from underneath this call), reflect whether anything is running.
    static func statusAfterStarting(current: TranscriptionStatus, anyChannelRunning: Bool) -> TranscriptionStatus {
        if case .failed = current { return current }
        return anyChannelRunning ? .recording : .idle
    }

    /// The status to report once `stopAll` finishes: unless a channel already failed while `stopAll` was still
    /// awaiting, stopping always ends in `.idle`.
    static func statusAfterStopping(current: TranscriptionStatus) -> TranscriptionStatus {
        if case .failed = current { return current }
        return .idle
    }

    func transcribe(fileURL: URL) async {
        clear()

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

    /// Clears the transcript. Does nothing while recording, so running channels are never dropped.
    func clear() {
        guard !isRecording else { return }
        channels = []
        fileSegments = []
        fileVolatileText = ""
        channelWarning = nil
    }

    func exportFiles(_ kind: ExportKind, baseName: String) -> [ExportFile] {
        TranscriptExporter.files(
            kind,
            baseName: baseName,
            combined: segments,
            channels: channels.map { (label: $0.label, segments: $0.segments) }
        )
    }

    static func warning(for kind: ChannelKind, othersStillRunning: Bool) -> String {
        let message = switch kind {
        case .microphone: "The microphone was disconnected."
        case .systemAudio: "System audio capture stopped."
        }
        return othersStillRunning ? "\(message) Other sources are still being transcribed." : message
    }

    private func makeChannels() -> [LiveChannel] {
        var channels: [LiveChannel] = []
        if micEnabled {
            #if os(macOS)
            let deviceID = AudioInputDevices.resolve(
                uid: selectedMicUID,
                in: AudioInputDevices.all(),
                defaultID: AudioInputDevices.defaultDeviceID()
            )
            #else
            let deviceID: UInt32? = nil
            #endif
            let microphone = microphoneSource
            channels.append(LiveChannel(
                kind: .microphone,
                label: "You",
                source: LiveAudioSource(
                    start: { try microphone.start(deviceID: deviceID) },
                    stop: { microphone.stop() }
                ),
                transcriber: TranscriptionEngine()
            ))
        }
        #if os(macOS)
        if systemAudioEnabled {
            let systemAudio = systemAudioSource
            let target = systemAudioTarget
            channels.append(LiveChannel(
                kind: .systemAudio,
                label: target.label,
                source: LiveAudioSource(
                    start: { try systemAudio.start(target: target) },
                    stop: { systemAudio.stop() }
                ),
                transcriber: TranscriptionEngine()
            ))
        }
        #endif
        for channel in channels {
            channel.onUnexpectedEnd = { [weak self, weak channel] in
                guard let self, let channel else { return }
                self.channelDidEndUnexpectedly(channel)
            }
            channel.onFailure = { [weak self] error in
                self?.liveTranscriptionDidFail(error)
            }
        }
        return channels
    }

    private func channelDidEndUnexpectedly(_ channel: LiveChannel) {
        let othersStillRunning = channels.contains(where: \.isRunning)
        channelWarning = Self.warning(for: channel.kind, othersStillRunning: othersStillRunning)
        if !othersStillRunning, isRecording {
            status = .idle
        }
    }

    private func liveTranscriptionDidFail(_ error: Error) {
        status = .failed(error.localizedDescription)
        let channels = self.channels
        Task {
            try? await LiveChannel.stopAll(channels)
        }
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

    /// Collects a file transcription's results.
    func consume(_ stream: AsyncThrowingStream<TranscriptUpdate, Error>) async {
        do {
            for try await update in stream {
                if update.isFinal {
                    fileSegments.append(TranscriptSegment(start: update.start, end: update.end, text: update.text))
                    fileVolatileText = ""
                } else {
                    fileVolatileText = update.text
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
