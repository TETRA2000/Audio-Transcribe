import Foundation
import Testing
@testable import Transcripta

struct HistoryStoreTests {
    private func snapshot(
        _ text: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        headline: String? = nil,
        fileName: String? = nil
    ) -> SessionSnapshot {
        SessionSnapshot.make(
            kind: fileName == nil ? .live : .file,
            language: .japanese,
            startedAt: startedAt,
            fileName: fileName,
            sourceLabels: fileName == nil ? ["You"] : [],
            segments: [TranscriptSegment(start: 0, end: 12, text: text)],
            recaps: [],
            overview: headline.map { .done(RecapContent(headline: $0, keyPoints: [])) }
        )!
    }

    @Test func upsertStampsEachSave() throws {
        let store = try HistoryStore(inMemory: true)
        let id = UUID()
        try store.upsert(id: id, snapshot: snapshot("first"))
        let first = try #require(try store.session(id: id)?.savedAt)
        try store.upsert(id: id, snapshot: snapshot("second"))
        #expect(try #require(try store.session(id: id)?.savedAt) > first)
    }

    @Test func upsertInsertsOnceThenUpdates() throws {
        let store = try HistoryStore(inMemory: true)
        let id = UUID()
        try store.upsert(id: id, snapshot: snapshot("first"))
        try store.upsert(id: id, snapshot: snapshot("second", headline: "Summary"))

        let sessions = try store.fetch(matching: "")
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.id == id)
        #expect(session.headline == "Summary")
        #expect(session.language == .japanese)
        #expect(session.kind == .live)
        #expect(session.duration == 12)
        #expect(session.sourceLabels == ["You"])
        #expect(try session.content().segments.map(\.text) == ["second"])
        #expect(session.searchKey.contains("second"))
        #expect(!session.searchKey.contains("first"))
    }

    @Test func fetchIsNewestFirst() throws {
        let store = try HistoryStore(inMemory: true)
        try store.upsert(id: UUID(), snapshot: snapshot("old", startedAt: Date(timeIntervalSince1970: 1)))
        try store.upsert(id: UUID(), snapshot: snapshot("new", startedAt: Date(timeIntervalSince1970: 2)))
        #expect(try store.fetch(matching: "").map { try $0.content().segments[0].text } == ["new", "old"])
    }

    @Test func predicateFindsFoldedText() throws {
        let store = try HistoryStore(inMemory: true)
        try store.upsert(id: UUID(), snapshot: snapshot("The Budget is final"))
        try store.upsert(id: UUID(), snapshot: snapshot("Lunch plans"))
        #expect(try store.fetch(matching: "BUDGET").count == 1)
        #expect(try store.fetch(matching: "dinner").isEmpty)
    }

    @Test func predicateFindsWidthVariants() throws {
        let store = try HistoryStore(inMemory: true)
        try store.upsert(id: UUID(), snapshot: snapshot("ｶﾞｯｺｳへ行く ＡＢＣ"))
        #expect(try store.fetch(matching: "ガッコウ").count == 1)
        #expect(try store.fetch(matching: "abc").count == 1)
        #expect(try store.fetch(matching: "カッコウ").isEmpty)
    }

    @Test func predicateMatchesWildcardCharactersLiterally() throws {
        let store = try HistoryStore(inMemory: true)
        try store.upsert(id: UUID(), snapshot: snapshot("100% sure"))
        try store.upsert(id: UUID(), snapshot: snapshot("abc"))
        #expect(try store.fetch(matching: "%").count == 1)
        #expect(try store.fetch(matching: "_").isEmpty)
    }

    @Test func blankQueryMatchesEverySession() throws {
        let store = try HistoryStore(inMemory: true)
        try store.upsert(id: UUID(), snapshot: snapshot("a"))
        try store.upsert(id: UUID(), snapshot: snapshot("b"))
        #expect(try store.fetch(matching: "  \n").count == 2)
    }

    @Test func deleteRemovesOnlyTheGivenSessions() throws {
        let store = try HistoryStore(inMemory: true)
        let keep = UUID()
        let drop = UUID()
        try store.upsert(id: keep, snapshot: snapshot("keep"))
        try store.upsert(id: drop, snapshot: snapshot("drop"))
        try store.delete([drop])
        #expect(try store.fetch(matching: "").map(\.id) == [keep])
        #expect(try store.session(id: drop) == nil)
    }

    @Test func subtitleFallsBackFromHeadlineToFileNameToSources() throws {
        let store = try HistoryStore(inMemory: true)
        let a = UUID(), b = UUID(), c = UUID()
        try store.upsert(id: a, snapshot: snapshot("x", headline: "Budget review"))
        try store.upsert(id: b, snapshot: snapshot("x", fileName: "Interview.m4a"))
        try store.upsert(id: c, snapshot: snapshot("x"))
        #expect(try store.session(id: a)?.subtitle == "Budget review")
        #expect(try store.session(id: b)?.subtitle == "Interview.m4a")
        #expect(try store.session(id: c)?.subtitle == "You")
    }

    @Test func damagedContentThrows() throws {
        let store = try HistoryStore(inMemory: true)
        let id = UUID()
        try store.upsert(id: id, snapshot: snapshot("x"))
        let session = try #require(try store.session(id: id))
        session.contentData = Data("not json".utf8)
        #expect(throws: (any Error).self) { try session.content() }
    }
}
