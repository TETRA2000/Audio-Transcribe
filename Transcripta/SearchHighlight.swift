import SwiftUI

/// Marks search matches in text.
enum SearchHighlight {
    /// `text` with a light background on each range, and a stronger one on `current`.
    static func marked(_ text: String, ranges: [Range<String.Index>], current: Range<String.Index>? = nil) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges {
            guard let marked = Range(range, in: attributed) else { continue }
            attributed[marked].backgroundColor = range == current ? Color.yellow : Color.yellow.opacity(0.35)
        }
        return attributed
    }
}
