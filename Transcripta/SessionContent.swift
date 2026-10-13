import Foundation

/// How a saved session was made.
nonisolated enum SessionKind: String, Codable, Sendable {
    case live
    case file
}

/// The text of a saved session: what History shows, exports and searches. Stored JSON-encoded in
/// `HistorySession.contentData`.
nonisolated struct SessionContent: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        /// As in `TranscriptSegment.speaker`: set only for multi-source sessions.
        var speaker: String?
    }

    /// A finished recap. Failed recaps are not saved.
    struct Recap: Codable, Equatable, Sendable {
        var windowStart: TimeInterval
        var windowEnd: TimeInterval
        var isFinal: Bool
        var headline: String
        var keyPoints: [String]
    }

    var segments: [Segment]
    var recaps: [Recap]
    /// The summary of the whole conversation, when one was made.
    var overview: RecapContent?
}

extension SessionContent.Segment {
    nonisolated init(_ segment: TranscriptSegment) {
        self.init(start: segment.start, end: segment.end, text: segment.text, speaker: segment.speaker)
    }

    /// A transcript segment with a new ID. Convert once per opened session, so list IDs stay stable.
    var transcriptSegment: TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, speaker: speaker)
    }
}

extension SessionContent.Recap {
    /// `nonisolated` because `HistorySearch` (nonisolated) reads it.
    nonisolated var content: RecapContent { RecapContent(headline: headline, keyPoints: keyPoints) }

    /// The recap as the Recap panel shows it.
    var entry: RecapEntry {
        RecapEntry(id: UUID(), windowStart: windowStart, windowEnd: windowEnd, segmentIDs: [], isFinal: isFinal, state: .done(content))
    }
}
