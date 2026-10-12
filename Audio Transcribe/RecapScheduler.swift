import Foundation
import Observation

/// Decides when a live session is recapped and what each recap covers, and keeps the list of recaps.
///
/// Coverage is tracked by segment ID rather than by time: a segment from another channel can finalize after a
/// recap but start earlier on the merged timeline, and it must land in the next recap exactly once.
@MainActor
@Observable
final class RecapScheduler {
    private(set) var entries: [RecapEntry] = []
    var interval: RecapInterval = .ten
    /// The window being summarized right now, for the "Summarizing…" row.
    private(set) var generatingWindow: ClosedRange<TimeInterval>?
    private(set) var availability: RecapAvailability
    /// Set once the final recap has been made (or attempted) for this session.
    private(set) var hasEnded = false
    /// Session time of the last tick that made, or skipped, a recap.
    private(set) var lastRecapAt: TimeInterval = 0

    /// The summary of the whole conversation: made at the end of a live session from its recaps, or from the whole
    /// transcript of a file. `nil` until one is made, and when there is nothing to summarize.
    private(set) var overview: OverviewState?

    var isGenerating: Bool { generatingWindow != nil }

    /// Identifies the current session: it changes on every `reset` and `clear`.
    var session: Int { generation }

    var nextRecapAt: TimeInterval? {
        guard availability == .available, !hasEnded else { return nil }
        return lastRecapAt + interval.seconds
    }

    @ObservationIgnored private let generator: any RecapGenerating
    @ObservationIgnored private var language: TranscriptionLanguage = .english
    @ObservationIgnored private var coveredIDs: Set<UUID> = []
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Bumped by `clear`, so results and `finish` calls from before it are dropped.
    @ObservationIgnored private var generation = 0

    init(generator: any RecapGenerating) {
        self.generator = generator
        availability = generator.availability
    }

    /// Starts a new session.
    func reset(language: TranscriptionLanguage) {
        clear()
        self.language = language
        availability = generator.availability
    }

    /// Removes every recap and drops any recap still being generated.
    func clear() {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        entries = []
        coveredIDs = []
        lastRecapAt = 0
        generatingWindow = nil
        hasEnded = false
        overview = nil
    }

    /// Called periodically while recording. Recaps the uncovered segments once `interval` has passed.
    func tick(now: TimeInterval, segments: [TranscriptSegment]) {
        refreshAvailability()
        guard availability == .available, !hasEnded, inFlight == nil,
              now - lastRecapAt >= interval.seconds else { return }
        lastRecapAt = now
        let window = uncovered(in: segments)
        guard Self.hasEnoughContent(window, language: language) else { return }
        startRecap(of: window, isFinal: false, replacing: nil)
    }

    /// Ends the session: waits for any recap in progress, then recaps what's left as the final recap.
    func finish(segments: [TranscriptSegment]) async {
        let generation = self.generation
        await waitForIdle()
        guard generation == self.generation, !hasEnded else { return }
        hasEnded = true
        refreshAvailability()
        guard availability == .available else { return }
        let window = uncovered(in: segments)
        if Self.hasEnoughContent(window, language: language) {
            startRecap(of: window, isFinal: true, replacing: nil)
            await waitForIdle()
        }
        guard generation == self.generation else { return }
        await summarizeRecaps()
    }

    /// Summarizes the whole session from its successful recaps. With fewer than two there is nothing to combine:
    /// a single recap already is the summary.
    func summarizeRecaps() async {
        let parts = entries.compactMap(\.content)
        guard parts.count >= 2 else { return }
        let language = self.language
        await makeOverview { generator in try await generator.overview(of: parts, language: language) }
    }

    /// Summarizes a whole transcript, such as a transcribed file, in one recap.
    func summarizeTranscript(_ segments: [TranscriptSegment]) async {
        guard Self.hasEnoughContent(segments, language: language) else { return }
        let lines = TranscriptSegment.lines(segments)
        let language = self.language
        await makeOverview { generator in try await generator.recap(lines: lines, earlier: nil, language: language) }
    }

    private func makeOverview(_ make: (any RecapGenerating) async throws -> RecapContent) async {
        refreshAvailability()
        guard availability == .available, overview != .generating else { return }
        let generation = self.generation
        overview = .generating
        let state: OverviewState
        do {
            state = .done(try await make(generator))
        } catch {
            state = .failed(message: RecapErrors.message(for: error))
        }
        guard generation == self.generation else { return }
        overview = state
    }

    /// Runs a failed entry's window again and replaces that entry with the result.
    func retry(_ id: UUID, segments: [TranscriptSegment]) {
        guard inFlight == nil,
              let entry = entries.first(where: { $0.id == id }),
              case .failed = entry.state else { return }
        let ids = Set(entry.segmentIDs)
        let window = segments.filter { ids.contains($0.id) }
        guard !window.isEmpty else { return }
        startRecap(of: window, isFinal: entry.isFinal, replacing: id)
    }

    /// Waits until no recap is being generated.
    func waitForIdle() async {
        while let task = inFlight {
            await task.value
            if inFlight == task { inFlight = nil }
        }
    }

    static func hasEnoughContent(_ window: [TranscriptSegment], language: TranscriptionLanguage) -> Bool {
        let text = window.map(\.text).joined(separator: " ")
        switch language {
        case .english: return text.split(whereSeparator: \.isWhitespace).count >= 30
        case .japanese: return text.filter { !$0.isWhitespace }.count >= 60
        }
    }

    /// Picks up the model becoming available mid-session, such as a finished download or Apple Intelligence
    /// turned on in System Settings.
    private func refreshAvailability() {
        if availability != .available {
            availability = generator.availability
        }
    }

    private func uncovered(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { !coveredIDs.contains($0.id) }
    }

    private func startRecap(of window: [TranscriptSegment], isFinal: Bool, replacing id: UUID?) {
        let ids = window.map(\.id)
        coveredIDs.formUnion(ids)
        let start = window.map(\.start).min() ?? 0
        let end = max(window.map(\.end).max() ?? start, start)
        let lines = TranscriptSegment.lines(window)
        let earlier = headline(before: id)
        let language = self.language
        let generation = self.generation
        let generator = self.generator
        generatingWindow = start...end

        inFlight = Task {
            let state: RecapEntry.State
            do {
                state = .done(try await generator.recap(lines: lines, earlier: earlier, language: language))
            } catch {
                state = .failed(message: RecapErrors.message(for: error))
            }
            guard generation == self.generation else { return }
            self.generatingWindow = nil
            self.inFlight = nil
            if let id, let index = self.entries.firstIndex(where: { $0.id == id }) {
                self.entries[index].state = state
            } else {
                self.entries.append(RecapEntry(
                    id: UUID(), windowStart: start, windowEnd: end,
                    segmentIDs: ids, isFinal: isFinal, state: state
                ))
            }
        }
    }

    /// The headline of the latest successful recap before `id`, or before the end of the list when `id` is nil.
    private func headline(before id: UUID?) -> String? {
        let end = id.flatMap { id in entries.firstIndex { $0.id == id } } ?? entries.endIndex
        return entries[..<end].reversed().lazy.compactMap(\.content).first?.headline
    }
}
