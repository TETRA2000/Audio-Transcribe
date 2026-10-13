import Foundation

/// How History rows and sections describe sessions.
enum HistoryFormat {
    /// The list's sections, newest first.
    enum DayGroup: String, CaseIterable {
        case today = "Today"
        case yesterday = "Yesterday"
        /// The last 7 days, today included, apart from today and yesterday.
        case thisWeek = "This Week"
        case earlier = "Earlier"
    }

    static func group(for date: Date, now: Date, calendar: Calendar = .current) -> DayGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekStart {
            return .thisWeek
        }
        return .earlier
    }

    /// The row's first line: the month, day and time, with the year when it isn't this year.
    static func title(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day().hour().minute()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return date.formatted(style)
    }

    /// "< 1 min", "12 min", "1 h", "1 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        guard minutes > 0 else { return "< 1 min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The row's last line when not searching: the duration, then the sources or "File".
    static func details(for session: HistorySession) -> String {
        let source = session.kind == .file ? "File" : session.sourceLabels.joined(separator: " + ")
        return "\(duration(session.duration)) · \(source)"
    }
}
