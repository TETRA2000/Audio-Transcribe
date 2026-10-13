import Foundation
import SwiftData

/// Where `TranscriptionViewModel` saves sessions. A protocol so tests can make saving fail.
protocol HistorySaving: AnyObject {
    /// Saves `snapshot` as the session `id`: inserted the first time, updated after that.
    func upsert(id: UUID, snapshot: SessionSnapshot) throws
}

/// The History store: one SwiftData container on this device (in memory for tests).
final class HistoryStore: HistorySaving {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        // The on-disk store is named "History". An in-memory store gets a unique name, so each one is separate.
        let configuration = ModelConfiguration(
            inMemory ? UUID().uuidString : "History",
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: HistorySession.self, configurations: configuration)
    }

    func upsert(id: UUID, snapshot: SessionSnapshot) throws {
        // Encode first, so a failure leaves nothing half-written in the context.
        let contentData = try JSONEncoder().encode(snapshot.content)
        let session: HistorySession
        if let existing = try self.session(id: id) {
            session = existing
        } else {
            session = HistorySession(id: id)
            context.insert(session)
        }
        session.startedAt = snapshot.startedAt
        session.duration = snapshot.duration
        session.kindRaw = snapshot.kind.rawValue
        session.languageRaw = snapshot.language.rawValue
        session.sourceLabels = snapshot.sourceLabels
        session.fileName = snapshot.fileName
        session.headline = snapshot.headline
        session.contentData = contentData
        session.searchKey = snapshot.searchKey
        session.savedAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func session(id: UUID) throws -> HistorySession? {
        var descriptor = FetchDescriptor<HistorySession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// What the History list shows for `query`.
    func fetch(matching query: String) throws -> [HistorySession] {
        try context.fetch(Self.descriptor(matching: query))
    }

    /// The IDs of the sessions the History list shows for `query`.
    func ids(matching query: String) throws -> Set<UUID> {
        Set(try fetch(matching: query).map(\.id))
    }

    func delete(_ ids: Set<UUID>) throws {
        let ids = Array(ids)
        let sessions = try context.fetch(FetchDescriptor<HistorySession>(predicate: #Predicate { ids.contains($0.id) }))
        for session in sessions {
            context.delete(session)
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Newest first. A query that isn't blank keeps the sessions whose `searchKey` contains it, folded the same way.
    /// SwiftData's `contains` is a literal, case-sensitive match, so both sides must be folded.
    static func descriptor(matching query: String) -> FetchDescriptor<HistorySession> {
        let key = HistorySearch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let predicate: Predicate<HistorySession>? = key.isEmpty ? nil : #Predicate { $0.searchKey.contains(key) }
        return FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
    }
}
