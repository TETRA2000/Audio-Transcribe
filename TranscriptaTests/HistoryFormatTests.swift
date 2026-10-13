import Foundation
import Testing
@testable import Transcripta

struct HistoryFormatTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, month: Int = 10, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func groupsByDay() {
        let now = date(13, 9)
        #expect(HistoryFormat.group(for: date(13, 1), now: now, calendar: calendar) == .today)
        #expect(HistoryFormat.group(for: date(12, 23), now: now, calendar: calendar) == .yesterday)
        #expect(HistoryFormat.group(for: date(7, 0), now: now, calendar: calendar) == .thisWeek)
        #expect(HistoryFormat.group(for: date(6, 23), now: now, calendar: calendar) == .earlier)
    }

    @Test func groupTitles() {
        #expect(HistoryFormat.DayGroup.allCases.map(\.rawValue) == ["Today", "Yesterday", "This Week", "Earlier"])
    }

    @Test func titleShowsTheYearOnlyForOtherYears() {
        let now = date(13, 9)
        #expect(!HistoryFormat.title(date(12, 14), now: now, calendar: calendar).contains("2026"))
        #expect(HistoryFormat.title(date(12, 14, year: 2025), now: now, calendar: calendar).contains("2025"))
    }

    @Test(arguments: [
        (0.0, "< 1 min"),
        (59.0, "< 1 min"),
        (60.0, "1 min"),
        (754.0, "12 min"),
        (3600.0, "1 h"),
        (3900.0, "1 h 5 min"),
    ])
    func durations(seconds: TimeInterval, expected: String) {
        #expect(HistoryFormat.duration(seconds) == expected)
    }

    @Test func detailsNameTheSourcesOrFile() throws {
        let store = try HistoryStore(inMemory: true)
        let live = UUID(), file = UUID()
        try store.upsert(id: live, snapshot: SessionSnapshot.make(
            kind: .live, language: .english, startedAt: Date(), fileName: nil, sourceLabels: ["You", "Zoom"],
            segments: [TranscriptSegment(start: 0, end: 754, text: "x")], recaps: [], overview: nil
        )!)
        try store.upsert(id: file, snapshot: SessionSnapshot.make(
            kind: .file, language: .english, startedAt: Date(), fileName: "a.m4a", sourceLabels: [],
            segments: [TranscriptSegment(start: 0, end: 60, text: "x")], recaps: [], overview: nil
        )!)
        #expect(HistoryFormat.details(for: try #require(try store.session(id: live))) == "12 min · You + Zoom")
        #expect(HistoryFormat.details(for: try #require(try store.session(id: file))) == "1 min · File")
    }
}
