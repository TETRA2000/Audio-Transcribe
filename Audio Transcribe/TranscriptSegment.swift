import Foundation

struct TranscriptSegment: Identifiable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Who spoke: "You", an app name, or "System audio". `nil` for file transcripts and single-source sessions.
    var speaker: String? = nil

    /// The segment's start time as `MM:SS`, with minutes continuing past 59 (e.g. `62:05`).
    var formattedStart: String { Self.formatted(start) }

    /// A session-timeline time as `MM:SS`, with minutes continuing past 59. `--:--` for invalid times.
    static func formatted(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "--:--" }
        let totalSeconds = Int(time)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// One line per segment: the trimmed text, prefixed with `Speaker: ` when the segment has a speaker.
    static func lines(_ segments: [TranscriptSegment]) -> [String] {
        segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return segment.speaker.map { "\($0): \(text)" } ?? text
        }
    }

    /// Merges several channels' segments into one timeline ordered by start time. Segments that start at the same
    /// time keep the order of `channels` (the microphone is listed first), then their order within the channel.
    static func merged(_ channels: [[TranscriptSegment]]) -> [TranscriptSegment] {
        channels.enumerated()
            .flatMap { channelIndex, segments in
                segments.enumerated().map { index, segment in (segment: segment, channel: channelIndex, index: index) }
            }
            .sorted { lhs, rhs in
                if lhs.segment.start != rhs.segment.start { return lhs.segment.start < rhs.segment.start }
                if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
                return lhs.index < rhs.index
            }
            .map(\.segment)
    }
}
