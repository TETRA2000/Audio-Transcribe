import Foundation

/// Search for History: text is folded so case, accents and character width don't matter. Matches are found in
/// the original text, and snippets are cut around them.
///
/// Matching folds one original `Character` at a time, so every match maps back to whole characters of the original
/// text. `fold` works the same way, and `searchKey` (what the History list's predicate searches) is built with it,
/// so the list and the opened session agree on what matches.
nonisolated enum HistorySearch {
    /// Case-, diacritic- and width-insensitive. Compatibility normalization (NFKC) comes first, so half-width
    /// katakana with a separate voiced mark (ｶﾞ) becomes the full-width character (ガ). Japanese voiced marks are
    /// kept: か and が stay different. The result is NFC (precomposed), so SwiftData's code-point `contains` matches it.
    static func fold(_ text: String) -> String {
        // NFC at the end: folding can leave a voiced mark separate (カ + ゙), and SwiftData's `contains` compares
        // code points, so the stored key and the query must both be composed.
        String(text.flatMap(foldCharacter)).precomposedStringWithCanonicalMapping
    }

    /// Everything a session is searched by, in the order snippets prefer: the file name, the speakers, the
    /// summary, the recaps, then the transcript one line per segment.
    static func searchableTexts(fileName: String?, content: SessionContent) -> [String] {
        var texts: [String] = []
        if let fileName { texts.append(fileName) }
        var speakers: [String] = []
        for speaker in content.segments.compactMap(\.speaker) where !speakers.contains(speaker) {
            speakers.append(speaker)
        }
        texts += speakers
        if let overview = content.overview { texts.append(overview.plainText) }
        texts += content.recaps.map(\.content.plainText)
        texts += content.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        return texts
    }

    /// The folded text the History list searches. Texts are joined with newlines, so a query never matches across
    /// two of them.
    static func searchKey(fileName: String?, content: SessionContent) -> String {
        fold(searchableTexts(fileName: fileName, content: content).joined(separator: "\n"))
    }

    private static func foldCharacter(_ character: Character) -> [Character] {
        Array(String(character).precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
    }

    /// The ranges of `query` in `text`, in order and not overlapping. Empty when the query folds to nothing.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = Array(fold(query))
        guard !needle.isEmpty else { return [] }
        // Each folded character, with the range of the original character it came from.
        var folded: [Character] = []
        var origins: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            for character in foldCharacter(text[index]) {
                folded.append(character)
                origins.append(index..<next)
            }
            index = next
        }
        var result: [Range<String.Index>] = []
        var start = 0
        while start + needle.count <= folded.count {
            guard folded[start..<(start + needle.count)].elementsEqual(needle) else {
                start += 1
                continue
            }
            let range = origins[start].lowerBound..<origins[start + needle.count - 1].upperBound
            // A character that folds to several (ß → ss) can produce two matches inside it: keep the first.
            if let last = result.last, range.lowerBound < last.upperBound {
                start += 1
                continue
            }
            result.append(range)
            start += needle.count
        }
        return result
    }

    /// A match in one of several texts: which text, and where in it.
    struct TextMatch: Equatable {
        let text: Int
        let range: Range<String.Index>
    }

    /// Every match of `query` in `texts`, text by text.
    static func matches(in texts: [String], query: String) -> [TextMatch] {
        texts.enumerated().flatMap { index, text in
            ranges(of: query, in: text).map { TextMatch(text: index, range: $0) }
        }
    }

    /// An excerpt around a match, for a History row.
    struct Snippet: Equatable {
        /// The excerpt on one line, with "…" where it was cut.
        let text: String
        /// Where the match is in `text`.
        let match: Range<String.Index>
    }

    /// About `radius` characters either side of the first match in the first text that has one.
    static func snippet(in texts: [String], query: String, radius: Int = 40) -> Snippet? {
        for text in texts {
            guard let match = ranges(of: query, in: text).first else { continue }
            let start = text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
            let before = (start == text.startIndex ? "" : "…") + oneLine(text[start..<match.lowerBound])
            let matched = oneLine(text[match])
            let after = oneLine(text[match.upperBound..<end]) + (end == text.endIndex ? "" : "…")
            let snippet = before + matched + after
            let lower = snippet.index(snippet.startIndex, offsetBy: before.count)
            let upper = snippet.index(lower, offsetBy: matched.count)
            return Snippet(text: snippet, match: lower..<upper)
        }
        return nil
    }

    private static func oneLine(_ text: Substring) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
