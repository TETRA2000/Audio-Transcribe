import Foundation
import Testing
@testable import Audio_Transcribe

struct TranscriptExporterTests {
    private let mic = [TranscriptSegment(start: 0, end: 1, text: " Hello.", speaker: "You")]
    private let app = [TranscriptSegment(start: 2, end: 3, text: " Hi.", speaker: "Zoom")]

    @Test func combinedPrefixesTimestampsAndSpeakers() {
        let segments = [
            TranscriptSegment(start: 12, end: 14, text: " Hi, can you hear me?", speaker: "You"),
            TranscriptSegment(start: 15, end: 17, text: " Yes, loud and clear.", speaker: "Zoom"),
        ]
        #expect(TranscriptExporter.combined(segments) == """
            [00:12] You: Hi, can you hear me?
            [00:15] Zoom: Yes, loud and clear.
            """)
    }

    @Test func combinedOmitsTheLabelWhenSegmentsHaveNoSpeaker() {
        let segments = [
            TranscriptSegment(start: 65, end: 66, text: "こんにちは。"),
            TranscriptSegment(start: 66, end: 67, text: "これはテストです。"),
        ]
        #expect(TranscriptExporter.combined(segments) == "[01:05] こんにちは。\n[01:06] これはテストです。")
    }

    @Test func combinedOfNoSegmentsIsEmpty() {
        #expect(TranscriptExporter.combined([]) == "")
    }

    @Test func separateDropsSpeakerLabels() {
        let texts = TranscriptExporter.separate([(label: "You", segments: mic), (label: "Zoom", segments: app)])
        #expect(texts.map(\.label) == ["You", "Zoom"])
        #expect(texts.map(\.text) == ["[00:00] Hello.", "[00:02] Hi."])
    }

    @Test(arguments: [
        (ExportKind.combined, ["T.txt"]),
        (.separate, ["T-You.txt", "T-Zoom.txt"]),
        (.combinedAndSeparate, ["T.txt", "T-You.txt", "T-Zoom.txt"]),
    ])
    func filesForEachKind(kind: ExportKind, names: [String]) {
        let files = TranscriptExporter.files(
            kind,
            baseName: "T",
            combined: TranscriptSegment.merged([mic, app]),
            channels: [(label: "You", segments: mic), (label: "Zoom", segments: app)]
        )
        #expect(files.map(\.name) == names)
    }

    @Test func combinedFileHoldsTheLabeledTimeline() throws {
        let files = TranscriptExporter.files(
            .combined,
            baseName: "T",
            combined: TranscriptSegment.merged([mic, app]),
            channels: [(label: "You", segments: mic), (label: "Zoom", segments: app)]
        )
        let file = try #require(files.first)
        #expect(file.text == "[00:00] You: Hello.\n[00:02] Zoom: Hi.")
    }

    @Test(arguments: [
        (nil as String?, "Transcript.txt"),
        ("You", "Transcript-You.txt"),
        ("zoom.us", "Transcript-zoom.us.txt"),
        ("A/B: Call", "Transcript-A-B- Call.txt"),
    ])
    func fileName(label: String?, expected: String) {
        #expect(TranscriptExporter.fileName(base: "Transcript", label: label) == expected)
    }

    @Test func defaultBaseNameUsesLocalDateAndTime() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 5)))
        #expect(TranscriptExporter.defaultBaseName(for: date) == "Transcript 2026-09-27 14.05")
    }

    @Test func writeCreatesUTF8Files() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try TranscriptExporter.write([ExportFile(name: "T.txt", text: "こんにちは")], to: folder)

        #expect(urls.map(\.lastPathComponent) == ["T.txt"])
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "こんにちは")
    }

    @Test func writeDoesNotOverwriteExistingFiles() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "old".write(to: folder.appending(path: "T.txt"), atomically: true, encoding: .utf8)

        let urls = try TranscriptExporter.write([ExportFile(name: "T.txt", text: "new")], to: folder)

        #expect(urls.map(\.lastPathComponent) == ["T 2.txt"])
        #expect(try String(contentsOf: folder.appending(path: "T.txt"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "new")
    }

    @Test func writeKeepsFilesWithTheSameNameApart() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try TranscriptExporter.write(
            [ExportFile(name: "T-You.txt", text: "mic"), ExportFile(name: "T-You.txt", text: "app")],
            to: folder
        )

        #expect(urls.map(\.lastPathComponent) == ["T-You.txt", "T-You 2.txt"])
        #expect(try String(contentsOf: urls[1], encoding: .utf8) == "app")
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
