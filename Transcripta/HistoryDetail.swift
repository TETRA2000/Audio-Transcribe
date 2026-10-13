import SwiftUI

/// A saved session's content, decoded once, with the transcript in the form the transcript view shows.
struct LoadedSession {
    let content: SessionContent
    /// Converted once, so line IDs stay stable while the session is open.
    let segments: [TranscriptSegment]
    /// Computed once: the share and copy actions read it on every body evaluation.
    let plainText: String

    init(_ content: SessionContent) {
        self.content = content
        let segments = content.segments.map(\.transcriptSegment)
        self.segments = segments
        plainText = TranscriptSegment.plainText(segments)
    }

    func transcriptMatches(_ query: String) -> [HistorySearch.TextMatch] {
        HistorySearch.matches(in: segments.map(TranscriptLines.displayText), query: query)
    }
}

/// A saved session, read-only: its transcript, with its summary and recaps in the Recap panel. Opened from a
/// search, it marks the matches and steps through those in the transcript.
struct HistoryDetail: View {
    let session: HistorySession
    /// The search the session was opened from. Blank for none.
    var query: String = ""
    /// Asks to delete this session. The container confirms first.
    let onDelete: () -> Void

    @State private var loaded: LoadedSession?
    @State private var loadFailed = false
    @State private var matches: [HistorySearch.TextMatch] = []
    @State private var currentMatch = 0
    #if os(macOS)
    @State private var showsRecap = true
    #else
    @State private var showsRecap = false
    #endif
    @State private var exportRequest: ExportRequest?
    @State private var errorMessage: String?

    private var activeQuery: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        Group {
            if let loaded {
                transcript(loaded)
            } else if loadFailed {
                ContentUnavailableView {
                    Label("This session couldn't be read", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("You can still delete it.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(HistoryFormat.title(session.startedAt))
        .toolbar { toolbar }
        .inspector(isPresented: $showsRecap) {
            Group {
                if let loaded {
                    SavedRecapView(content: loaded.content, query: activeQuery)
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
            .presentationDragIndicator(.visible)
        }
        .task(id: "\(session.id)|\(query)") { load() }
        .transcriptExporter(
            request: $exportRequest,
            makeFiles: { kind, baseName in
                guard let loaded else { return [] }
                return TranscriptExporter.files(kind, baseName: baseName, content: loaded.content, sourceLabels: session.sourceLabels)
            },
            onFailure: { errorMessage = $0.localizedDescription }
        )
        .alert("Couldn't export", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() {
        do {
            let loaded = LoadedSession(try session.content())
            self.loaded = loaded
            loadFailed = false
            matches = activeQuery.map(loaded.transcriptMatches) ?? []
            currentMatch = 0
        } catch {
            loaded = nil
            loadFailed = true
            matches = []
            currentMatch = 0
        }
    }

    private func transcript(_ loaded: LoadedSession) -> some View {
        TranscriptLines(
            segments: loaded.segments,
            primarySpeaker: session.sourceLabels.first,
            highlight: matches.isEmpty ? nil : TranscriptHighlight(matches: matches, current: min(currentMatch, matches.count - 1)),
            followsEnd: false
        )
        .safeAreaInset(edge: .top) {
            if activeQuery != nil {
                matchBar
            }
        }
    }

    private var matchBar: some View {
        HStack {
            Text(matches.isEmpty ? "No matches in the transcript" : "\(currentMatch + 1) of \(matches.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                guard !matches.isEmpty else { return }
                currentMatch = (currentMatch - 1 + matches.count) % matches.count
            } label: {
                Image(systemName: "chevron.up")
            }
            .accessibilityLabel("Previous match")
            .disabled(matches.count < 2)
            Button {
                guard !matches.isEmpty else { return }
                currentMatch = (currentMatch + 1) % matches.count
            } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel("Next match")
            .disabled(matches.count < 2)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                showsRecap.toggle()
            } label: {
                Label("Recap", systemImage: "apple.intelligence")
            }
        }
        ToolbarItem {
            Menu {
                if let loaded {
                    Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(loaded.plainText) }
                    ShareLink(item: loaded.plainText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    ExportMenuItems(hasSeparateSources: session.sourceLabels.count > 1, request: $exportRequest)
                    Divider()
                }
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Label("Session", systemImage: "ellipsis")
            }
        }
    }
}
