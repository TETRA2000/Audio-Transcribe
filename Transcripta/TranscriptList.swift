import SwiftUI

/// The live transcript: the view model's lines, following new text as it arrives.
struct TranscriptList: View {
    let viewModel: TranscriptionViewModel

    var body: some View {
        TranscriptLines(
            segments: viewModel.segments,
            volatileLines: viewModel.volatileLines,
            primarySpeaker: viewModel.channels.first?.label
        )
    }
}

/// Search matches to mark in a transcript.
struct TranscriptHighlight: Equatable {
    /// Every match, in order. `TextMatch.text` is the segment's index, and ranges are in `TranscriptLines.displayText`.
    let matches: [HistorySearch.TextMatch]
    /// The index in `matches` of the match to show.
    let current: Int
    /// Changed to scroll to the current match again, as when stepping with only one match.
    var request = 0
}

/// A transcript: finished lines with their times (and speakers, when there are several sources), then the
/// in-progress text. Search matches are marked, and the current one is scrolled into view.
struct TranscriptLines: View {
    let segments: [TranscriptSegment]
    var volatileLines: [VolatileLine] = []
    /// The speaker shown in the accent color (the first source). Other speakers are orange.
    var primarySpeaker: String?
    var highlight: TranscriptHighlight?
    /// A live transcript follows new text at the bottom. A saved one opens at the top.
    var followsEnd = true

    /// The text a line shows, which is also what search matches are found in.
    nonisolated static func displayText(_ segment: TranscriptSegment) -> String {
        segment.text.trimmingCharacters(in: .whitespaces)
    }

    /// Match ranges by segment, and the current match, worked out once per body evaluation.
    private struct Marks {
        var ranges: [TranscriptSegment.ID: [Range<String.Index>]] = [:]
        var currentID: TranscriptSegment.ID?
        var currentRange: Range<String.Index>?
    }

    private func marks() -> Marks {
        var marks = Marks()
        guard let highlight else { return marks }
        for (position, match) in highlight.matches.enumerated() where segments.indices.contains(match.text) {
            let id = segments[match.text].id
            marks.ranges[id, default: []].append(match.range)
            if position == highlight.current {
                marks.currentID = id
                marks.currentRange = match.range
            }
        }
        return marks
    }

    var body: some View {
        let marks = marks()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        transcriptRow(segment, marks: marks)
                            .id(segment.id)
                    }
                    ForEach(volatileLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let label = line.label {
                                speakerTag(label)
                            }
                            Text(line.text.trimmingCharacters(in: .whitespaces))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            // Keep the end of the transcript in view as lines arrive, instead of scrolling to a marker on every update:
            // the marker sat inside the padding, which left the newest text partly hidden, and the onChange action on
            // the in-progress text hit SwiftUI's "tried to update multiple times per frame" limit.
            .defaultScrollAnchor(followsEnd ? .bottom : .top)
            .defaultScrollAnchor(followsEnd ? .bottom : nil, for: .sizeChanges)
            // A task rather than onChange: on first appearance, scrolling has to wait until the lazy stack is laid out.
            .task(id: highlight) {
                await Task.yield()
                guard let id = marks.currentID else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func transcriptRow(_ segment: TranscriptSegment, marks: Marks) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(segment.formattedStart)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            if let speaker = segment.speaker {
                speakerTag(speaker)
            }
            Text(lineText(segment, marks: marks))
                .textSelection(.enabled)
        }
    }

    private func lineText(_ segment: TranscriptSegment, marks: Marks) -> AttributedString {
        let text = Self.displayText(segment)
        guard let ranges = marks.ranges[segment.id] else { return AttributedString(text) }
        return SearchHighlight.marked(text, ranges: ranges, current: marks.currentID == segment.id ? marks.currentRange : nil)
    }

    /// A small colored label: the primary speaker uses the accent color, others orange.
    private func speakerTag(_ speaker: String) -> some View {
        let color: Color = speaker == primarySpeaker ? .accentColor : .orange
        return Text(speaker)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
    }
}
