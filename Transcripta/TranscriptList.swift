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
    static func displayText(_ segment: TranscriptSegment) -> String {
        segment.text.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        transcriptRow(segment, index: index)
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
            .onChange(of: highlight, initial: true) {
                guard let highlight, highlight.matches.indices.contains(highlight.current) else { return }
                let segment = segments[highlight.matches[highlight.current].text]
                withAnimation { proxy.scrollTo(segment.id, anchor: .center) }
            }
        }
    }

    private func transcriptRow(_ segment: TranscriptSegment, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(segment.formattedStart)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            if let speaker = segment.speaker {
                speakerTag(speaker)
            }
            Text(lineText(segment, index: index))
                .textSelection(.enabled)
        }
    }

    private func lineText(_ segment: TranscriptSegment, index: Int) -> AttributedString {
        let text = Self.displayText(segment)
        guard let highlight else { return AttributedString(text) }
        let current = highlight.matches.indices.contains(highlight.current) ? highlight.matches[highlight.current] : nil
        let ranges = highlight.matches.filter { $0.text == index }.map(\.range)
        return SearchHighlight.marked(text, ranges: ranges, current: current?.text == index ? current?.range : nil)
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
