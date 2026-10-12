import SwiftUI

/// The transcript: finished lines with their times (and speakers, when several sources are live), then the
/// in-progress text. It follows new text as it arrives.
struct TranscriptList: View {
    let viewModel: TranscriptionViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.segments) { segment in
                    transcriptRow(segment)
                }
                ForEach(viewModel.volatileLines) { line in
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
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }

    private func transcriptRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(segment.formattedStart)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            if let speaker = segment.speaker {
                speakerTag(speaker)
            }
            Text(segment.text.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A small colored label: the first source (the microphone when enabled) uses the accent color, others orange.
    private func speakerTag(_ speaker: String) -> some View {
        let color: Color = speaker == viewModel.channels.first?.label ? .accentColor : .orange
        return Text(speaker)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
    }
}
