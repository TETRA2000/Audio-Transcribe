import Foundation
import FoundationModels

/// One recap's text: what `SystemRecapGenerator.parse` reads from the model's reply.
nonisolated struct RecapContent: Equatable, Sendable {
    var summary: String
    var keyPoints: [String]

    init(summary: String, keyPoints: [String]) {
        self.summary = summary
        self.keyPoints = keyPoints
    }

    /// The summary followed by one `- ` line per key point, for Copy.
    var plainText: String {
        ([summary] + keyPoints.map { "- \($0)" }).joined(separator: "\n")
    }
}

/// One recap in the panel. Entries are only appended, except that Retry replaces a failed entry's state.
struct RecapEntry: Identifiable, Equatable {
    enum State: Equatable {
        case done(RecapContent)
        case failed(message: String)
    }

    let id: UUID
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    /// The segments this entry covers, so Retry can rebuild the same window.
    let segmentIDs: [UUID]
    /// Made when the session ended (Stop, or the last source stopped).
    let isFinal: Bool
    var state: State

    var content: RecapContent? {
        if case .done(let content) = state { content } else { nil }
    }

    var formattedRange: String { Self.formattedRange(windowStart, windowEnd) }

    static func formattedRange(_ start: TimeInterval, _ end: TimeInterval) -> String {
        "\(TranscriptSegment.formatted(start)) – \(TranscriptSegment.formatted(end))"
    }
}

enum RecapInterval: Int, CaseIterable, Identifiable {
    case five = 5
    case ten = 10
    case fifteen = 15

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    var menuLabel: String { "\(rawValue) minutes" }
    var shortLabel: String { "Every \(rawValue) min" }
}

enum RecapAvailability: Equatable {
    case available
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady

    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: self = .appleIntelligenceOff
            case .deviceNotEligible: self = .deviceNotEligible
            case .modelNotReady: self = .modelNotReady
            @unknown default: self = .deviceNotEligible
            }
        }
    }

    var title: String? {
        switch self {
        case .available: nil
        case .appleIntelligenceOff: "Recaps need Apple Intelligence"
        case .deviceNotEligible: "Recaps aren't available on this device"
        case .modelNotReady: "Preparing Apple Intelligence"
        }
    }

    var message: String? {
        switch self {
        case .available: nil
        case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings to get on-device recaps. Transcription keeps working without it."
        case .deviceNotEligible: "This device doesn't support Apple Intelligence. Transcription keeps working without it."
        case .modelNotReady: "The model is still downloading. Recaps will start when it's ready."
        }
    }
}
