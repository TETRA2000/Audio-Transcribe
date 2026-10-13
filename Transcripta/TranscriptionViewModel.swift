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

    /// Recaps of the live session, made on device while recording.
    let recap: RecapScheduler
    /// How often the recap scheduler is asked whether a recap is due.
    static let recapTickInterval: Duration = .seconds(30)
    @ObservationIgnored private var recapTicker: Task<Void, Never>?

    /// Where sessions are saved. `nil` when History couldn't be opened, and in tests that don't need it.
    let history: (any HistorySaving)?
    /// The History entry for the session on screen, once it has been saved.
    private(set) var historyID: UUID?
    /// Shown when the session couldn't be saved to History. Transcription carries on.
    var historyWarning: String?
    @ObservationIgnored private var historyStartedAt: Date?
    @ObservationIgnored private var historyFileName: String?
    @ObservationIgnored private var historyLanguage: TranscriptionLanguage = .english

    /// `recapGenerator` defaults to the on-device model. It is built here rather than as a default argument, which
    /// would be evaluated outside the main actor.
    init(recapGenerator: (any RecapGenerating)? = nil, history: (any HistorySaving)? = nil) {
        recap = RecapScheduler(generator: recapGenerator ?? SystemRecapGenerator())
        self.history = history
    }

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
    ///
    /// The view reads this several times per render, and in-progress text re-renders it many times a second,
    /// so the merge is cached. Channels only ever append segments, so a channel's segment count and last
    /// segment identify its contents.
    var segments: [TranscriptSegment] {
        guard !channels.isEmpty else { return fileSegments }
        let key = channels.map { MergeKey(channel: ObjectIdentifier($0), count: $0.segments.count, lastID: $0.segments.last?.id) }
        if let mergeCache, mergeCache.key == key {
            return mergeCache.segments
        }
        let merged = TranscriptSegment.merged(channels.map(\.segments))
        mergeCache = (key, merged)
        return merged
    }

    private struct MergeKey: Equatable {
        let channel: ObjectIdentifier
        let count: Int
        let lastID: UUID?
    }

    @ObservationIgnored private var mergeCache: (key: [MergeKey], segments: [TranscriptSegment])?

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

    /// The transcript as plain text for Copy and Share.
    var fullText: String { TranscriptSegment.plainText(segments) }

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
            let sessionStart = Date()
            beginHistorySession(startedAt: sessionStart, fileName: nil)
            try await LiveChannel.startAll(
                newChannels,
                language: language,
                sessionStart: sessionStart,
                labelSegments: newChannels.count > 1
            )
            status = Self.statusAfterStarting(current: status, anyChannelRunning: newChannels.contains(where: \.isRunning))
            if isRecording {
                startRecaps(sessionStart: sessionStart)
            }
        } catch {
            channels = []
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        let recapSession = recap.session
        do {
            try await LiveChannel.stopAll(channels)
            status = Self.statusAfterStopping(current: status)
        } catch {
            status = .failed(error.localizedDescription)
        }
        // After the channels have drained, so the final recap includes the last segments.
        await endRecaps(session: recapSession)
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
        beginHistorySession(startedAt: Date(), fileName: fileURL.lastPathComponent)

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
            return
        }
        saveToHistory()
        recap.reset(language: language)
        let session = recap.session
        await recap.summarizeTranscript(fileSegments)
        guard session == recap.session else { return }
        saveToHistory()
    }

    /// Makes the summary of the whole conversation again: from the recaps after a live session, or from the whole
    /// transcript of a file.
    func summarizeAgain() async {
        let session = recap.session
        if channels.isEmpty {
            await recap.summarizeTranscript(fileSegments)
        } else {
            await recap.summarizeRecaps()
        }
        guard session == recap.session else { return }
        saveToHistory()
    }

    /// Clears the transcript. Does nothing while recording, so running channels are never dropped.
    func clear() {
        guard !isRecording else { return }
        channels = []
        fileSegments = []
        fileVolatileText = ""
        channelWarning = nil
        recapTicker?.cancel()
        recapTicker = nil
        recap.clear()
        historyID = nil
        historyStartedAt = nil
        historyFileName = nil
        historyWarning = nil
    }

    /// Starts a History entry for the session about to be recorded or transcribed. The entry is created at the
    /// first save that has final text.
    func beginHistorySession(startedAt: Date, fileName: String?) {
        historyID = nil
        historyStartedAt = startedAt
        historyFileName = fileName
        historyLanguage = language
    }

    /// Saves the session on screen to History: a new entry the first time it has final text, then updates to it.
    /// Does nothing before `beginHistorySession` or after `clear`.
    func saveToHistory() {
        guard let history, let startedAt = historyStartedAt else { return }
        guard let snapshot = SessionSnapshot.make(
            kind: historyFileName == nil ? .live : .file,
            language: historyLanguage,
            startedAt: startedAt,
            fileName: historyFileName,
            sourceLabels: channels.map(\.label),
            segments: segments,
            recaps: recap.entries,
            overview: recap.overview
        ) else { return }
        let id = historyID ?? UUID()
        do {
            try history.upsert(id: id, snapshot: snapshot)
            historyID = id
            historyWarning = nil
        } catch {
            historyWarning = "Couldn't save this session to History. \(error.localizedDescription)"
        }
    }

    /// One ticker step while recording: a recap if one is due, and a History checkpoint.
    func tickRecaps(now: TimeInterval) {
        recap.tick(now: now, segments: segments)
        saveToHistory()
    }

    func retryRecap(_ id: UUID) {
        recap.retry(id, segments: segments)
        let session = recap.session
        Task {
            await recap.waitForIdle()
            guard session == recap.session else { return }
            saveToHistory()
        }
    }

    func exportFiles(_ kind: ExportKind, baseName: String) -> [ExportFile] {
        let overview: RecapContent? = if case .done(let content) = recap.overview { content } else { nil }
        return TranscriptExporter.files(
            kind,
            baseName: baseName,
            combined: segments,
            channels: channels.map { (label: $0.label, segments: $0.segments) },
            header: TranscriptExporter.summaryHeader(overview: overview, recaps: recap.entries)
        )
    }

    /// Writes the export files for `kind` into a folder the user picked. Existing files are never overwritten.
    func export(_ kind: ExportKind, toFolder folder: URL, date: Date = Date()) {
        do {
            _ = try TranscriptExporter.write(
                exportFiles(kind, baseName: TranscriptExporter.defaultBaseName(for: date)),
                toPickedFolder: folder
            )
        } catch {
            status = .failed(error.localizedDescription)
        }
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
            let deviceID = AudioInputDevices.resolve(uid: selectedMicUID, in: AudioInputDevices.all())
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
            let recapSession = recap.session
            Task { await endRecaps(session: recapSession) }
        }
    }

    private func liveTranscriptionDidFail(_ error: Error) {
        status = .failed(error.localizedDescription)
        let channels = self.channels
        let recapSession = recap.session
        Task {
            try? await LiveChannel.stopAll(channels)
            await endRecaps(session: recapSession)
        }
    }

    /// Starts a fresh recap session and asks the scheduler every `recapTickInterval` whether a recap is due.
    func startRecaps(sessionStart: Date) {
        recap.reset(language: language)
        recapTicker?.cancel()
        recapTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.recapTickInterval)
                guard let self, !Task.isCancelled, self.isRecording else { return }
                self.tickRecaps(now: Date().timeIntervalSince(sessionStart))
            }
        }
    }

    /// Stops the ticker and makes the final recap for the recap session that was current when the recording
    /// ended. Does nothing if a newer session has started since (Start pressed while the old channels were still
    /// draining) or if this session already finished: `finish` runs once per session.
    func endRecaps(session: Int) async {
        guard session == recap.session else { return }
        recapTicker?.cancel()
        recapTicker = nil
        // The channels have drained: save the whole transcript before the final recap, which can take a while.
        saveToHistory()
        await recap.finish(segments: segments)
        // A Clear or a new session during the final recap belongs to another entry.
        guard session == recap.session else { return }
        saveToHistory()
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
