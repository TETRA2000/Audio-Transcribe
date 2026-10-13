import Foundation
import Testing
@testable import Transcripta

private struct SaveFailed: LocalizedError {
    var errorDescription: String? { "Disk full." }
}

private final class FailingHistory: HistorySaving {
    func upsert(id: UUID, snapshot: SessionSnapshot) throws { throw SaveFailed() }
}

@Suite(.timeLimit(.minutes(1)))
struct TranscriptionViewModelHistoryTests {
    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// A "recording" live session with one idle microphone channel holding `words` words.
    private func makeRecording(_ store: HistoryStore, generator: FakeRecapGenerator = FakeRecapGenerator(), words: Int = 40) -> TranscriptionViewModel {
        let viewModel = TranscriptionViewModel(recapGenerator: generator, history: store)
        viewModel.channels = [makeIdleChannel(.microphone, label: "You", segments: [speech(words, at: 0)])]
        viewModel.recap.reset(language: .english)
        viewModel.beginHistorySession(startedAt: startedAt, fileName: nil)
        viewModel.status = .recording
        return viewModel
    }

    @Test func stopSavesTheSessionWithItsFinalRecap() async throws {
        let store = try HistoryStore(inMemory: true)
        let viewModel = makeRecording(store)

        await viewModel.stop()

        let session = try #require(try store.fetch(matching: "").first)
        #expect(session.id == viewModel.historyID)
        #expect(session.kind == .live)
        #expect(session.startedAt == startedAt)
        #expect(session.sourceLabels == ["You"])
        #expect(try session.content().recaps.map(\.headline) == ["Summary 1"])
        #expect(session.headline == "Summary 1")
    }

    @Test func tickWritesACheckpointAndUpdatesTheSameEntry() throws {
        let store = try HistoryStore(inMemory: true)
        let viewModel = makeRecording(store, words: 3)

        viewModel.tickRecaps(now: 30)
        let id = try #require(viewModel.historyID)
        viewModel.channels[0].segments.append(speech(3, at: 10))
        viewModel.tickRecaps(now: 60)

        let sessions = try store.fetch(matching: "")
        #expect(sessions.map(\.id) == [id])
        #expect(try sessions[0].content().segments.count == 2)
    }

    @Test func summarizeAgainUpdatesTheSavedFile() async throws {
        let store = try HistoryStore(inMemory: true)
        let viewModel = TranscriptionViewModel(recapGenerator: FakeRecapGenerator(), history: store)
        viewModel.recap.reset(language: .english)
        viewModel.beginHistorySession(startedAt: startedAt, fileName: "Interview.m4a")
        viewModel.fileSegments = [speech(40, at: 0)]
        viewModel.saveToHistory()
        let id = try #require(viewModel.historyID)

        await viewModel.summarizeAgain()

        let session = try #require(try store.session(id: id))
        #expect(session.kind == .file)
        #expect(session.fileName == "Interview.m4a")
        #expect(session.headline == "Summary 1")
        #expect(try store.fetch(matching: "").count == 1)
    }

    @Test func retryUpdatesTheSavedRecaps() async throws {
        let store = try HistoryStore(inMemory: true)
        let generator = FakeRecapGenerator()
        generator.results = [.failure(FakeRecapError())]
        let viewModel = makeRecording(store, generator: generator)
        viewModel.recap.interval = .five
        viewModel.tickRecaps(now: 300)
        await viewModel.recap.waitForIdle()
        let failed = try #require(viewModel.recap.entries.first)

        viewModel.retryRecap(failed.id)

        let id = try #require(viewModel.historyID)
        while try store.session(id: id)?.content().recaps.isEmpty ?? true {
            await Task.yield()
        }
        #expect(try store.session(id: id)?.content().recaps.map(\.headline) == ["Summary 2"])
    }

    @Test func clearMakesTheNextSessionANewEntry() throws {
        let store = try HistoryStore(inMemory: true)
        let viewModel = TranscriptionViewModel(recapGenerator: FakeRecapGenerator(), history: store)
        viewModel.beginHistorySession(startedAt: startedAt, fileName: "a.m4a")
        viewModel.fileSegments = [speech(3, at: 0)]
        viewModel.saveToHistory()
        let first = try #require(viewModel.historyID)

        viewModel.clear()
        #expect(viewModel.historyID == nil)
        viewModel.beginHistorySession(startedAt: startedAt, fileName: "b.m4a")
        viewModel.fileSegments = [speech(3, at: 0)]
        viewModel.saveToHistory()

        #expect(viewModel.historyID != first)
        #expect(Set(try store.fetch(matching: "").compactMap(\.fileName)) == ["a.m4a", "b.m4a"])
    }

    @Test func emptySessionIsNotSaved() throws {
        let store = try HistoryStore(inMemory: true)
        let viewModel = TranscriptionViewModel(recapGenerator: FakeRecapGenerator(), history: store)
        viewModel.beginHistorySession(startedAt: startedAt, fileName: nil)
        viewModel.channels = [makeIdleChannel(.microphone, label: "You")]
        viewModel.saveToHistory()
        #expect(viewModel.historyID == nil)
        #expect(try store.fetch(matching: "").isEmpty)
    }

    @Test func nothingIsSavedBeforeASessionBegins() throws {
        let store = try HistoryStore(inMemory: true)
        let viewModel = TranscriptionViewModel(recapGenerator: FakeRecapGenerator(), history: store)
        viewModel.fileSegments = [speech(3, at: 0)]
        viewModel.saveToHistory()
        #expect(try store.fetch(matching: "").isEmpty)
    }

    @Test func failedSaveWarnsWithoutChangingStatus() {
        let viewModel = TranscriptionViewModel(recapGenerator: FakeRecapGenerator(), history: FailingHistory())
        viewModel.beginHistorySession(startedAt: startedAt, fileName: nil)
        viewModel.fileSegments = [speech(3, at: 0)]
        viewModel.status = .recording

        viewModel.saveToHistory()

        #expect(viewModel.historyWarning == "Couldn't save this session to History. Disk full.")
        #expect(viewModel.status == .recording)
        #expect(viewModel.historyID == nil)
    }

    @Test func staleFinishDoesNotWriteIntoTheNextSession() async throws {
        let store = try HistoryStore(inMemory: true)
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let viewModel = makeRecording(store, generator: generator)

        let stopping = Task { await viewModel.stop() }
        await generator.waitForCalls(1)
        let liveID = try #require(viewModel.historyID)
        viewModel.clear()
        viewModel.beginHistorySession(startedAt: startedAt, fileName: "next.m4a")
        viewModel.fileSegments = [speech(3, at: 0)]
        viewModel.saveToHistory()
        let nextID = try #require(viewModel.historyID)
        generator.releaseHeldCalls()
        await stopping.value

        #expect(try store.fetch(matching: "").count == 2)
        #expect(try store.session(id: liveID)?.content().recaps.isEmpty == true)
        #expect(try store.session(id: nextID)?.content().recaps.isEmpty == true)
        #expect(try store.session(id: nextID)?.fileName == "next.m4a")
    }
}
