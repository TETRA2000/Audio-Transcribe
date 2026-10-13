import SwiftData
import SwiftUI

/// What the macOS sidebar or the iOS History list has selected.
enum HistorySelection: Hashable {
    case currentSession
    case session(UUID)
}

/// The saved sessions as list sections, newest first and grouped by day. When `query` isn't blank, only matching
/// sessions are shown, each with a snippet. Must be inside a `List` with the History container in the environment.
struct HistorySections: View {
    let query: String
    /// Asks to delete these sessions. The container confirms first.
    let onDelete: (Set<UUID>) -> Void
    @Query private var sessions: [HistorySession]

    init(query: String, onDelete: @escaping (Set<UUID>) -> Void) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onDelete = onDelete
        _sessions = Query(HistoryStore.descriptor(matching: query))
    }

    var body: some View {
        if sessions.isEmpty {
            Section("History") {
                Text(query.isEmpty ? "Transcripts you record or transcribe appear here." : "No sessions match “\(query)”.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let now = Date()
            let groups = Dictionary(grouping: sessions) { HistoryFormat.group(for: $0.startedAt, now: now) }
            ForEach(HistoryFormat.DayGroup.allCases, id: \.self) { group in
                if let sessions = groups[group] {
                    Section(group.rawValue) {
                        ForEach(sessions) { session in
                            row(session)
                        }
                    }
                }
            }
        }
    }

    private func row(_ session: HistorySession) -> some View {
        let item = HistorySelection.session(session.id)
        return Group {
            #if os(macOS)
            HistoryRow(session: session, query: query)
            #else
            NavigationLink(value: item) {
                HistoryRow(session: session, query: query)
            }
            #endif
        }
        .tag(item)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete([session.id]) }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash") { onDelete([session.id]) }
                .tint(.red)
        }
    }
}

/// One saved session: date and time, then the headline (or file name, or sources), then the duration and sources,
/// or a snippet around the match while searching.
struct HistoryRow: View {
    let session: HistorySession
    let query: String
    @State private var snippet: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(HistoryFormat.title(session.startedAt))
                .font(.headline)
            Text(session.subtitle)
                .lineLimit(2)
            Group {
                if let snippet {
                    Text(snippet)
                        .lineLimit(2)
                } else {
                    Text(HistoryFormat.details(for: session))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .task(id: "\(session.id)|\(query)") { snippet = makeSnippet() }
    }

    /// Built once per session and query, and only for rows on screen: it decodes the session's content.
    private func makeSnippet() -> AttributedString? {
        guard !query.isEmpty, let content = try? session.content(),
              let snippet = HistorySearch.snippet(in: HistorySearch.searchableTexts(fileName: session.fileName, content: content), query: query)
        else { return nil }
        var attributed = AttributedString(snippet.text)
        if let match = Range(snippet.match, in: attributed) {
            attributed[match].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}

/// Shown in place of History when its store couldn't be opened.
struct HistoryUnavailableView: View {
    let message: String?

    var body: some View {
        ContentUnavailableView {
            Label("History couldn't be opened", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message ?? "")
        }
    }
}

extension View {
    /// Asks before deleting the `pending` sessions, then deletes them and reports the IDs. A failure shows an alert.
    func historyDeleteConfirmation(
        pending: Binding<Set<UUID>>,
        store: HistoryStore?,
        onDeleted: @escaping (Set<UUID>) -> Void
    ) -> some View {
        modifier(HistoryDeleteConfirmation(pending: pending, store: store, onDeleted: onDeleted))
    }
}

private struct HistoryDeleteConfirmation: ViewModifier {
    @Binding var pending: Set<UUID>
    let store: HistoryStore?
    let onDeleted: (Set<UUID>) -> Void
    @State private var errorMessage: String?
    /// `pending` is emptied as the dialog starts to close, so the title keeps the last count it showed.
    @State private var lastCount = 0

    func body(content: Content) -> some View {
        let count = pending.isEmpty ? lastCount : pending.count
        content
            .onChange(of: pending) { if !pending.isEmpty { lastCount = pending.count } }
            .confirmationDialog(
                count == 1 ? "Delete this session?" : "Delete \(count) sessions?",
                isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }),
                titleVisibility: .visible,
                presenting: pending
            ) { ids in
                Button("Delete", role: .destructive) {
                    do {
                        try store?.delete(ids)
                        onDeleted(ids)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } message: { _ in
                Text("Deleted sessions can't be recovered.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

#if !os(macOS)
/// iOS: History in a sheet with its own navigation stack: the searchable list, then a session's detail.
struct HistoryScreen: View {
    let store: HistoryStore?
    let storeError: String?
    /// Reports deleted sessions, so the session on screen isn't saved back.
    let onDeleted: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Set<HistorySelection> = []
    @State private var path: [HistorySelection] = []
    @State private var pendingDelete: Set<UUID> = []
    @State private var editMode = EditMode.inactive

    private var selectedIDs: Set<UUID> {
        Set(selection.compactMap { item -> UUID? in
            if case .session(let id) = item { return id }
            return nil
        })
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    if store != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            EditButton()
                        }
                    }
                    if editMode.isEditing, !selectedIDs.isEmpty {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Delete (\(selectedIDs.count))", role: .destructive) { pendingDelete = selectedIDs }
                        }
                    }
                }
                .environment(\.editMode, $editMode)
                .navigationDestination(for: HistorySelection.self) { item in
                    if case .session(let id) = item, let session = try? store?.session(id: id) {
                        HistoryDetail(session: session, query: query, onDelete: { pendingDelete = [id] })
                    }
                }
        }
        .historyDeleteConfirmation(pending: $pendingDelete, store: store) { ids in
            onDeleted(ids)
            selection.subtract(ids.map(HistorySelection.session))
            path.removeAll { item in
                if case .session(let id) = item { return ids.contains(id) }
                return false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            List(selection: $selection) {
                HistorySections(query: query, onDelete: { pendingDelete = $0 })
            }
            .searchable(text: $query, prompt: "Search transcripts and summaries")
            .modelContainer(store.container)
        } else {
            HistoryUnavailableView(message: storeError)
        }
    }
}
#endif
