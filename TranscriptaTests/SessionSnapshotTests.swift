import Foundation
import Testing
@testable import Transcripta

struct SessionSnapshotTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ state: RecapEntry.State, isFinal: Bool = false) -> RecapEntry {
        RecapEntry(id: UUID(), windowStart: 0, windowEnd: 60, segmentIDs: [], isFinal: isFinal, state: state)
    }

    private func make(
        kind: SessionKind = .live,
        fileName: String? = nil,
        sourceLabels: [String] = ["You", "Zoom"],
        segments: [TranscriptSegment],
        recaps: [RecapEntry] = [],
        overview: OverviewState? = nil
    ) -> SessionSnapshot? {
        SessionSnapshot.make(
            kind: kind, language: .english, startedAt: start, fileName: fileName, sourceLabels: sourceLabels,
            segments: segments, recaps: recaps, overview: overview
        )
    }

    @Test func multiSourceLiveSessionKeepsSpeakersAndTimes() throws {
        let snapshot = try #require(make(segments: [
            TranscriptSegment(start: 0, end: 2, text: " Hello.", speaker: "You"),
            TranscriptSegment(start: 3, end: 7.5, text: " Hi.", speaker: "Zoom"),
        ]))
        #expect(snapshot.kind == .live)
        #expect(snapshot.startedAt == start)
        #expect(snapshot.duration == 7.5)
        #expect(snapshot.sourceLabels == ["You", "Zoom"])
        #expect(snapshot.content.segments == [
            SessionContent.Segment(start: 0, end: 2, text: " Hello.", speaker: "You"),
            SessionContent.Segment(start: 3, end: 7.5, text: " Hi.", speaker: "Zoom"),
        ])
    }

    @Test func fileSessionKeepsItsFileName() throws {
        let snapshot = try #require(make(kind: .file, fileName: "Interview.m4a", sourceLabels: [], segments: [
            TranscriptSegment(start: 0, end: 4, text: "Hello"),
        ]))
        #expect(snapshot.kind == .file)
        #expect(snapshot.fileName == "Interview.m4a")
        #expect(snapshot.content.segments.first?.speaker == nil)
    }

    @Test func failedRecapsAreLeftOut() throws {
        let snapshot = try #require(make(
            segments: [TranscriptSegment(start: 0, end: 1, text: "a")],
            recaps: [
                entry(.done(RecapContent(headline: "First", keyPoints: ["p"]))),
                entry(.failed(message: "Boom")),
                entry(.done(RecapContent(headline: "Last", keyPoints: [])), isFinal: true),
            ]
        ))
        #expect(snapshot.content.recaps.map(\.headline) == ["First", "Last"])
        #expect(snapshot.content.recaps.map(\.isFinal) == [false, true])
        #expect(snapshot.content.recaps.first?.keyPoints == ["p"])
    }

    @Test func overviewIsKeptOnlyWhenDone() throws {
        let segments = [TranscriptSegment(start: 0, end: 1, text: "a")]
        let done = try #require(make(segments: segments, overview: .done(RecapContent(headline: "Overall", keyPoints: []))))
        #expect(done.content.overview?.headline == "Overall")
        #expect(done.headline == "Overall")
        #expect(try #require(make(segments: segments, overview: .generating)).content.overview == nil)
        #expect(try #require(make(segments: segments, overview: .failed(message: "x"))).content.overview == nil)
    }

    @Test func headlineFallsBackToTheOnlyRecap() throws {
        let segments = [TranscriptSegment(start: 0, end: 1, text: "a")]
        let one = try #require(make(segments: segments, recaps: [entry(.done(RecapContent(headline: "Only", keyPoints: [])))]))
        #expect(one.headline == "Only")
        let two = try #require(make(segments: segments, recaps: [
            entry(.done(RecapContent(headline: "A", keyPoints: []))),
            entry(.done(RecapContent(headline: "B", keyPoints: []))),
        ]))
        #expect(two.headline == nil)
    }

    @Test func noFinalTextMeansNothingToSave() {
        #expect(make(segments: []) == nil)
        #expect(make(segments: [TranscriptSegment(start: 0, end: 1, text: "  \n")]) == nil)
    }

    @Test func searchKeyHoldsEverythingFolded() throws {
        let snapshot = try #require(make(
            fileName: "Café.m4a",
            segments: [TranscriptSegment(start: 0, end: 1, text: " The BUDGET is final.", speaker: "Zoom")],
            recaps: [entry(.done(RecapContent(headline: "Vendors", keyPoints: ["Larkspur"])))],
            overview: .done(RecapContent(headline: "Quarterly Review", keyPoints: []))
        ))
        for part in ["cafe.m4a", "zoom", "quarterly review", "vendors", "larkspur", "the budget is final."] {
            #expect(snapshot.searchKey.contains(part), "missing \(part)")
        }
    }

    @Test func contentRoundTripsThroughJSON() throws {
        let content = SessionContent(
            segments: [SessionContent.Segment(start: 0, end: 1, text: "こんにちは", speaker: nil)],
            recaps: [SessionContent.Recap(windowStart: 0, windowEnd: 60, isFinal: true, headline: "H", keyPoints: ["k"])],
            overview: RecapContent(headline: "O", keyPoints: [])
        )
        let decoded = try JSONDecoder().decode(SessionContent.self, from: JSONEncoder().encode(content))
        #expect(decoded == content)
    }

    @Test func savedRecapBecomesADoneEntry() {
        let recap = SessionContent.Recap(windowStart: 5, windowEnd: 65, isFinal: true, headline: "H", keyPoints: ["k"])
        let entry = recap.entry
        #expect(entry.windowStart == 5)
        #expect(entry.windowEnd == 65)
        #expect(entry.isFinal)
        #expect(entry.content == RecapContent(headline: "H", keyPoints: ["k"]))
    }

    @Test func plainTextMatchesTheViewModelsFullText() {
        #expect(TranscriptSegment.plainText([
            TranscriptSegment(start: 0, end: 1, text: "Hello,"),
            TranscriptSegment(start: 1, end: 2, text: " world."),
        ]) == "Hello, world.")
        #expect(TranscriptSegment.plainText([
            TranscriptSegment(start: 0, end: 1, text: " Hi.", speaker: "You"),
            TranscriptSegment(start: 1, end: 2, text: " Yo.", speaker: "Zoom"),
        ]) == "You: Hi.\nZoom: Yo.")
    }

    @Test func nonFiniteTimesBecomeZeroSoTheSessionCanBeSaved() throws {
        let window = RecapEntry(
            id: UUID(), windowStart: .nan, windowEnd: .infinity, segmentIDs: [], isFinal: false,
            state: .done(RecapContent(headline: "H", keyPoints: []))
        )
        let snapshot = try #require(make(
            segments: [
                TranscriptSegment(start: 0, end: 4, text: "a"),
                TranscriptSegment(start: .nan, end: .infinity, text: "b"),
            ],
            recaps: [window]
        ))
        #expect(snapshot.content.segments[1].start == 0)
        #expect(snapshot.content.segments[1].end == 0)
        #expect(snapshot.content.recaps[0].windowStart == 0)
        #expect(snapshot.content.recaps[0].windowEnd == 0)
        #expect(snapshot.duration == 4)
        #expect(throws: Never.self) { try JSONEncoder().encode(snapshot.content) }
    }
}
