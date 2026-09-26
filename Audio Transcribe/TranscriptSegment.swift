import Foundation

struct TranscriptSegment: Identifiable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    /// The segment's start time as `MM:SS`, with minutes continuing past 59 (e.g. `62:05`).
    var formattedStart: String {
        guard start.isFinite, start >= 0 else { return "--:--" }
        let totalSeconds = Int(start)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
