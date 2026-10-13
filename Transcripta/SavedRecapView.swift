import SwiftUI

/// The Recap panel for a saved session: its summary and recaps, read-only, with matches of `query` marked.
struct SavedRecapView: View {
    let content: SessionContent
    var query: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recap")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            if content.overview == nil && content.recaps.isEmpty {
                ContentUnavailableView {
                    Label("No summary", systemImage: "doc.text")
                } description: {
                    Text("This session was saved without a summary or recaps.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let overview = content.overview {
                            OverviewSection(state: .done(overview), onSummarizeAgain: nil, query: query)
                            Divider()
                        }
                        ForEach(Array(content.recaps.enumerated()), id: \.offset) { _, recap in
                            RecapEntryRow(entry: recap.entry, canRetry: false, onRetry: nil, query: query)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    SavedRecapView(
        content: SessionContent(
            segments: [],
            recaps: [
                SessionContent.Recap(windowStart: 0, windowEnd: 600, isFinal: false, headline: "Shortlist down to Northwind and Larkspur", keyPoints: ["SSO is a hard requirement"]),
                SessionContent.Recap(windowStart: 600, windowEnd: 840, isFinal: true, headline: "Rollout targets Feb 3", keyPoints: []),
            ],
            overview: RecapContent(headline: "Vendor pick narrows to two; rollout targets Feb 3", keyPoints: ["Larkspur is 18% cheaper"])
        ),
        query: "larkspur"
    )
    .frame(width: 340, height: 600)
}
