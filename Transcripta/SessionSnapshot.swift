import Foundation

/// What History stores for the session on screen, built from the view model's state at a save point.
struct SessionSnapshot: Equatable {
    var kind: SessionKind
    var language: TranscriptionLanguage
    var startedAt: Date
    /// The end of the last segment on the session's timeline.
    var duration: TimeInterval
    /// The live channels' labels in order (the microphone first). Empty for files.
    var sourceLabels: [String]
    var fileName: String?
    var content: SessionContent

    /// For the History row: the summary's headline, or the only recap's headline (a single recap is not combined
    /// into a summary).
    var headline: String? {
        content.overview?.headline ?? (content.recaps.count == 1 ? content.recaps[0].headline : nil)
    }

    var searchKey: String { HistorySearch.searchKey(fileName: fileName, content: content) }

    /// `nil` when there is no final text: nothing to read or search, so nothing is saved.
    static func make(
        kind: SessionKind,
        language: TranscriptionLanguage,
        startedAt: Date,
        fileName: String?,
        sourceLabels: [String],
        segments: [TranscriptSegment],
        recaps: [RecapEntry],
        overview: OverviewState?
    ) -> SessionSnapshot? {
        guard segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let savedRecaps = recaps.compactMap { entry in
            entry.content.map { content in
                SessionContent.Recap(
                    windowStart: entry.windowStart, windowEnd: entry.windowEnd, isFinal: entry.isFinal,
                    headline: content.headline, keyPoints: content.keyPoints
                )
            }
        }
        let summary: RecapContent? = if case .done(let content) = overview { content } else { nil }
        return SessionSnapshot(
            kind: kind,
            language: language,
            startedAt: startedAt,
            duration: segments.map(\.end).max() ?? 0,
            sourceLabels: sourceLabels,
            fileName: fileName,
            content: SessionContent(segments: segments.map(SessionContent.Segment.init), recaps: savedRecaps, overview: summary)
        )
    }
}
