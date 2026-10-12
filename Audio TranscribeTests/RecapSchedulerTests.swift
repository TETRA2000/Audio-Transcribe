import Foundation
import Testing
@testable import Audio_Transcribe

@Suite(.timeLimit(.minutes(1)))
struct RecapSchedulerTests {
    private func makeScheduler(_ generator: FakeRecapGenerator, language: TranscriptionLanguage = .english) -> RecapScheduler {
        let scheduler = RecapScheduler(generator: generator)
        scheduler.reset(language: language)
        return scheduler
    }

    @Test func noRecapBeforeTheInterval() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        scheduler.tick(now: 599, segments: [speech(40, at: 0)])
        await scheduler.waitForIdle()
        #expect(generator.calls.isEmpty)
        #expect(scheduler.entries.isEmpty)
        #expect(scheduler.nextRecapAt == 600)
    }

    @Test func recapAtTheIntervalCoversEverySegment() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let segments = [speech(20, at: 0, speaker: "You"), speech(20, at: 300, speaker: "Zoom")]

        scheduler.tick(now: 600, segments: segments)
        await scheduler.waitForIdle()

        #expect(generator.calls.count == 1)
        #expect(generator.calls[0].lines == TranscriptSegment.lines(segments))
        #expect(generator.calls[0].earlier == nil)
        #expect(generator.calls[0].language == .english)
        #expect(scheduler.entries.count == 1)
        let entry = scheduler.entries[0]
        #expect(entry.windowStart == 0)
        #expect(entry.windowEnd == 305)
        #expect(entry.segmentIDs == segments.map(\.id))
        #expect(!entry.isFinal)
        #expect(entry.content == RecapContent(summary: "Summary 1", keyPoints: ["Point"]))
        #expect(scheduler.lastRecapAt == 600)
        #expect(scheduler.nextRecapAt == 1200)
        #expect(!scheduler.isGenerating)
    }

    @Test func coveredSegmentsAreNotRecappedAgain() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        scheduler.tick(now: 1200, segments: [a, b])
        await scheduler.waitForIdle()

        #expect(generator.calls.map(\.lines) == [TranscriptSegment.lines([a]), TranscriptSegment.lines([b])])
    }

    @Test func lateSegmentGoesIntoTheNextWindowOnce() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(20, at: 0, speaker: "You")
        let b = speech(20, at: 300, speaker: "You")
        scheduler.tick(now: 600, segments: [a, b])
        await scheduler.waitForIdle()

        // `late` finalized after the first recap but starts before `b` on the merged timeline.
        let late = speech(20, at: 290, speaker: "Zoom")
        let d = speech(20, at: 700, speaker: "You")
        scheduler.tick(now: 1200, segments: [a, late, b, d])
        await scheduler.waitForIdle()

        #expect(generator.calls[1].lines == TranscriptSegment.lines([late, d]))
        #expect(scheduler.entries[1].windowStart == 290)
        #expect(scheduler.entries[1].windowEnd == 705)
    }

    @Test func shortWindowsCarryOverUntilThereIsEnough() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let first = speech(10, at: 0)
        let second = speech(10, at: 700)
        let third = speech(10, at: 1300)

        scheduler.tick(now: 600, segments: [first])
        await scheduler.waitForIdle()
        #expect(generator.calls.isEmpty)
        #expect(scheduler.lastRecapAt == 600)

        scheduler.tick(now: 1200, segments: [first, second])
        await scheduler.waitForIdle()
        #expect(generator.calls.isEmpty)

        scheduler.tick(now: 1800, segments: [first, second, third])
        await scheduler.waitForIdle()
        #expect(generator.calls.count == 1)
        #expect(generator.calls[0].lines == TranscriptSegment.lines([first, second, third]))
    }

    @Test(arguments: [(59, false), (60, true)])
    func japaneseMinimumIsSixtyCharacters(count: Int, recaps: Bool) async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator, language: .japanese)
        let segment = TranscriptSegment(start: 0, end: 5, text: String(repeating: "あ", count: count))

        scheduler.tick(now: 600, segments: [segment])
        await scheduler.waitForIdle()

        #expect(generator.calls.count == (recaps ? 1 : 0))
    }

    @Test func tickWhileGeneratingDoesNotStartAnother() async {
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await generator.waitForCalls(1)
        #expect(scheduler.isGenerating)
        #expect(scheduler.generatingWindow == 0...5)

        scheduler.tick(now: 1300, segments: [a, b])
        #expect(generator.calls.count == 1)

        generator.holdsCalls = false
        generator.releaseHeldCalls()
        await scheduler.waitForIdle()
        #expect(scheduler.entries.count == 1)
        #expect(scheduler.lastRecapAt == 600)

        scheduler.tick(now: 1300, segments: [a, b])
        await scheduler.waitForIdle()
        #expect(generator.calls.count == 2)
        #expect(generator.calls[1].lines == TranscriptSegment.lines([b]))
    }

    @Test func finishWaitsForTheInFlightRecapThenCoversTheRest() async {
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await generator.waitForCalls(1)
        let finishing = Task { await scheduler.finish(segments: [a, b]) }
        for _ in 0..<10 { await Task.yield() }
        #expect(generator.calls.count == 1)

        generator.holdsCalls = false
        generator.releaseHeldCalls()
        await finishing.value

        #expect(scheduler.entries.count == 2)
        #expect(!scheduler.entries[0].isFinal)
        #expect(scheduler.entries[1].isFinal)
        #expect(generator.calls[1].lines == TranscriptSegment.lines([b]))
        #expect(scheduler.hasEnded)
        #expect(scheduler.nextRecapAt == nil)
    }

    @Test func finishWithNothingLeftAddsNoEntry() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()

        await scheduler.finish(segments: [a])

        #expect(scheduler.entries.count == 1)
        #expect(generator.calls.count == 1)
        #expect(scheduler.hasEnded)
    }

    @Test func finishRunsOnlyOnce() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)

        await scheduler.finish(segments: [a])
        await scheduler.finish(segments: [a, speech(40, at: 100)])

        #expect(scheduler.entries.count == 1)
        #expect(generator.calls.count == 1)
    }

    @Test func failureAppendsAFailedEntryAndCoversItsSegments() async {
        let generator = FakeRecapGenerator()
        generator.results = [.failure(FakeRecapError())]
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        #expect(scheduler.entries.map(\.state) == [.failed(message: "Boom")])

        scheduler.tick(now: 1200, segments: [a, b])
        await scheduler.waitForIdle()
        #expect(generator.calls[1].lines == TranscriptSegment.lines([b]))
    }

    @Test func retryReplacesTheFailedEntryInPlace() async {
        let generator = FakeRecapGenerator()
        let second = RecapContent(summary: "Second", keyPoints: [])
        let retried = RecapContent(summary: "Retried", keyPoints: [])
        generator.results = [.failure(FakeRecapError()), .success(second), .success(retried)]
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        scheduler.tick(now: 1200, segments: [a, b])
        await scheduler.waitForIdle()
        let failedID = scheduler.entries[0].id

        scheduler.retry(failedID, segments: [a, b])
        await scheduler.waitForIdle()

        #expect(scheduler.entries.count == 2)
        #expect(scheduler.entries[0].id == failedID)
        #expect(scheduler.entries[0].content == retried)
        #expect(scheduler.entries[1].content == second)
        #expect(generator.calls[2].lines == TranscriptSegment.lines([a]))
        #expect(generator.calls[2].earlier == nil)
    }

    @Test func laterRecapsGetTheEarlierSummary() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        scheduler.tick(now: 1200, segments: [a, b])
        await scheduler.waitForIdle()

        #expect(generator.calls[0].earlier == nil)
        #expect(generator.calls[1].earlier == "Summary 1")
    }

    @Test func changingTheIntervalOnlyMovesTheNextRecap() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)
        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        #expect(scheduler.nextRecapAt == 1200)

        scheduler.interval = .five
        #expect(scheduler.nextRecapAt == 900)
        #expect(scheduler.entries.count == 1)

        scheduler.tick(now: 899, segments: [a, b])
        await scheduler.waitForIdle()
        #expect(generator.calls.count == 1)

        scheduler.tick(now: 900, segments: [a, b])
        await scheduler.waitForIdle()
        #expect(generator.calls.count == 2)
    }

    @Test func clearDropsTheInFlightRecap() async {
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let scheduler = makeScheduler(generator)
        scheduler.tick(now: 600, segments: [speech(40, at: 0)])
        await generator.waitForCalls(1)

        scheduler.clear()
        generator.releaseHeldCalls()
        for _ in 0..<10 { await Task.yield() }

        #expect(scheduler.entries.isEmpty)
        #expect(!scheduler.isGenerating)
        #expect(scheduler.lastRecapAt == 0)
    }

    @Test func resetDuringFinishDropsTheFinalRecap() async {
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await generator.waitForCalls(1)
        let finishing = Task { await scheduler.finish(segments: [a, b]) }
        for _ in 0..<10 { await Task.yield() }

        scheduler.reset(language: .english)
        generator.holdsCalls = false
        generator.releaseHeldCalls()
        await finishing.value

        #expect(scheduler.entries.isEmpty)
        #expect(!scheduler.hasEnded)
        #expect(generator.calls.count == 1)
    }

    @Test func unavailableModelIsNeverCalled() async {
        let generator = FakeRecapGenerator()
        generator.availability = .appleIntelligenceOff
        let scheduler = makeScheduler(generator)

        scheduler.tick(now: 600, segments: [speech(40, at: 0)])
        await scheduler.finish(segments: [speech(40, at: 0)])

        #expect(generator.calls.isEmpty)
        #expect(scheduler.entries.isEmpty)
        #expect(scheduler.availability == .appleIntelligenceOff)
        #expect(scheduler.nextRecapAt == nil)
    }
}
