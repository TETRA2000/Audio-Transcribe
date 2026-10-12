import Foundation
import FoundationModels

/// Makes one recap from transcript lines. The scheduler talks to this, so tests can swap in a fake.
protocol RecapGenerating: AnyObject {
    var availability: RecapAvailability { get }
    func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent
}

/// Recaps with Apple Intelligence's on-device model. Each call uses fresh sessions, so context never builds up.
/// Windows over the language's character budget are recapped in chunks, then merged with one more call.
///
/// The model replies in plain text in a fixed format that `parse` reads, rather than through guided generation
/// (`@Generable`): guided generation refuses ordinary conversation as "May contain sensitive content", and the
/// permissive guardrails meant for summarizing user content only apply to plain-text replies.
final class SystemRecapGenerator: RecapGenerating {
    static let minimumChunkCharacters = 500
    static let maximumKeyPoints = 6

    var availability: RecapAvailability {
        RecapAvailability(SystemLanguageModel.default.availability)
    }

    func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent {
        try await recap(lines, budget: Self.budget(for: language), earlier: earlier, language: language)
    }

    private func recap(_ lines: [String], budget: Int, earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent {
        var partials: [RecapContent] = []
        for chunk in Self.chunks(lines, budget: budget) {
            do {
                partials.append(try await respond(
                    instructions: Self.instructions(for: language),
                    prompt: Self.prompt(lines: chunk, earlier: earlier)
                ))
            } catch let error where RecapErrors.isContextOverflow(error) && budget / 2 >= Self.minimumChunkCharacters {
                partials.append(try await recap(chunk, budget: budget / 2, earlier: earlier, language: language))
            }
        }
        guard let first = partials.first else { throw EmptyTranscriptError() }
        if partials.count == 1 { return first }
        return try await respond(instructions: Self.mergeInstructions(for: language), prompt: Self.mergePrompt(partials))
    }

    private func respond(instructions: String, prompt: String) async throws -> RecapContent {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        return Self.parse(try await session.respond(to: prompt).content)
    }

    // MARK: Pure helpers

    /// Labels the model uses for the two parts of its reply. It is asked for the English ones, but translates them
    /// when it answers in Japanese.
    static let summaryLabels = ["summary", "概要", "要約", "まとめ"]
    static let keyPointsLabels = ["key points", "キーポイント", "重要なポイント", "要点"]

    /// Reads a reply in the `replyFormat`. Labels are matched without regard to case, with `:` or `：`, blank lines are
    /// skipped, and `-`, `•` and `*` all count as bullets. A reply without a summary label becomes the summary as a whole.
    static func parse(_ reply: String) -> RecapContent {
        let lines = reply.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let summaryIndex = lines.firstIndex(where: { text(after: summaryLabels, in: $0) != nil }) else {
            return RecapContent(summary: reply.trimmingCharacters(in: .whitespacesAndNewlines), keyPoints: [])
        }
        let keyPointsIndex = lines[(summaryIndex + 1)...].firstIndex { text(after: keyPointsLabels, in: $0) != nil }
        let firstLine = text(after: summaryLabels, in: lines[summaryIndex]) ?? ""
        let summary = ([firstLine] + lines[(summaryIndex + 1)..<(keyPointsIndex ?? lines.endIndex)])
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var keyPoints: [String] = []
        if let keyPointsIndex {
            for line in lines[(keyPointsIndex + 1)...] {
                guard let bullet = line.first, "-•*".contains(bullet) else { continue }
                let point = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !point.isEmpty { keyPoints.append(point) }
            }
        }
        return RecapContent(summary: summary, keyPoints: Array(keyPoints.prefix(maximumKeyPoints)))
    }

    /// The rest of `line` after one of `labels` and a colon, or `nil` when the line doesn't start with a label.
    private static func text(after labels: [String], in line: String) -> String? {
        for label in labels where line.lowercased().hasPrefix(label) {
            let rest = line.dropFirst(label.count).drop { $0 == " " }
            guard let colon = rest.first, colon == ":" || colon == "：" else { continue }
            return rest.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static let replyFormat = "Reply in exactly this format, with no other text, and keep the labels \"Summary:\" and \"Key points:\" in English:\n"
        + "Summary: <1 to 3 sentences>\nKey points:\n- <point>\n- <point>\n"

    static func budget(for language: TranscriptionLanguage) -> Int {
        switch language {
        case .english: 6_000
        case .japanese: 2_500
        }
    }

    /// Packs whole lines into chunks whose newline-joined length is at most `budget`.
    /// A line longer than `budget` is truncated to it and gets a chunk of its own.
    static func chunks(_ lines: [String], budget: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var size = 0
        for original in lines {
            let line = original.count > budget ? String(original.prefix(budget)) : original
            if !current.isEmpty, size + 1 + line.count > budget {
                result.append(current)
                current = []
                size = 0
            }
            size += current.isEmpty ? line.count : 1 + line.count
            current.append(line)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func instructions(for language: TranscriptionLanguage) -> String {
        "You summarize a live conversation transcript. Each line is \"Speaker: text\"; lines without a speaker come from a single source. "
            + "Write a summary of 1 to 3 sentences and up to 6 key points: important names, numbers, dates, decisions and requests. "
            + "Use only what is in the transcript. "
            + replyFormat
            + "Respond in \(language.responseLanguageName)."
    }

    static func mergeInstructions(for language: TranscriptionLanguage) -> String {
        "You combine partial recaps of consecutive parts of one conversation into a single recap. "
            + "Write a summary of 1 to 3 sentences and up to 6 key points, keeping the most important names, numbers, dates, decisions and requests. "
            + replyFormat
            + "Respond in \(language.responseLanguageName)."
    }

    static func prompt(lines: [String], earlier: String?) -> String {
        var parts: [String] = []
        if let earlier {
            parts.append("Earlier: \(earlier)")
            parts.append("")
        }
        parts.append("Transcript:")
        parts.append(contentsOf: lines)
        return parts.joined(separator: "\n")
    }

    static func mergePrompt(_ partials: [RecapContent]) -> String {
        partials.enumerated()
            .map { index, partial in "Part \(index + 1):\n\(partial.plainText)" }
            .joined(separator: "\n\n")
    }
}

struct EmptyTranscriptError: LocalizedError {
    var errorDescription: String? { "There was nothing to summarize." }
}

enum RecapErrors {
    /// Whether the model ran out of context. macOS 26 reports `GenerationError`; 27 reports `LanguageModelError`.
    static func isContextOverflow(_ error: Error) -> Bool {
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *),
           let error = error as? LanguageModelError, case .contextSizeExceeded = error {
            return true
        }
        if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error {
            return true
        }
        return false
    }

    /// Whether the model declined: a guardrail violation or a refusal.
    static func isDeclined(_ error: Error) -> Bool {
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return true
            default: break
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return true
            default: break
            }
        }
        return false
    }

    /// The reason shown after "Couldn't summarize this part."
    static func message(for error: Error) -> String {
        if isContextOverflow(error) { return "This part was too long to summarize." }
        if isDeclined(error) { return "The on-device model declined the request." }
        return error.localizedDescription
    }
}

extension TranscriptionLanguage {
    /// The language named in the model's instructions.
    nonisolated var responseLanguageName: String {
        switch self {
        case .english: "English"
        case .japanese: "Japanese"
        }
    }
}
