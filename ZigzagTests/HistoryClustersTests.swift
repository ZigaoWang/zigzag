import Foundation
import Testing
@testable import Zigzag

/// How History folds visits into sessions and runs of one site, and what it calls each session.
@MainActor
struct HistoryClustersTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A visit at `hour`:`minute` on October `day`, 2026, New York time.
    private func visit(_ url: String, _ day: Int, _ hour: Int, _ minute: Int = 0) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: "", visitCount: 1, lastVisit: date(day, hour, minute))
    }

    private func shape(_ sessions: [HistoryClusters.Session]) -> [[String]] {
        sessions.map { $0.clusters.map { "\($0.host) \($0.entries.count)" } }
    }

    @Test func runsOfOneSiteFold() {
        let sessions = HistoryClusters.group([
            visit("https://github.com/a", 30, 10, 5),
            visit("https://www.github.com/b", 30, 10, 4),
            visit("https://GitHub.com/c", 30, 10, 3),
            visit("https://news.example.com/", 30, 10, 2),
            visit("https://github.com/d", 30, 10, 1),
        ], calendar: calendar)
        // www. and case don't split a site; a visit elsewhere does, so the last GitHub page stands alone.
        #expect(shape(sessions) == [["github.com 3", "news.example.com 1", "github.com 1"]])
        #expect(sessions[0].clusters[0].entries.map(\.url.path) == ["/a", "/b", "/c"])
        #expect(sessions[0].start == date(30, 10, 1))
        #expect(sessions[0].end == date(30, 10, 5))
    }

    /// Lunch ends a session; a short pause doesn't. Neither does a session run past midnight.
    @Test func breaksAndMidnightSplitSessions() {
        #expect(HistoryClusters.sessionGap == 40 * 60)
        let sessions = HistoryClusters.group([
            visit("https://github.com/a", 30, 14, 0),
            visit("https://github.com/b", 30, 13, 25),  // 35 minutes before: same session
            visit("https://github.com/c", 30, 12, 0),   // 85 minutes before: a new one
            visit("https://github.com/d", 30, 0, 10),
            visit("https://github.com/e", 29, 23, 50),  // 20 minutes, but the day before
        ], calendar: calendar)
        #expect(shape(sessions) == [["github.com 2"], ["github.com 1"], ["github.com 1"], ["github.com 1"]])
        #expect(HistoryClusters.continues(visit("https://a.com", 30, 12, 40), with: visit("https://b.com", 30, 12, 0), calendar: calendar))
        #expect(!HistoryClusters.continues(visit("https://a.com", 30, 12, 41), with: visit("https://b.com", 30, 12, 0), calendar: calendar))
    }

    /// Search hands back matches by rank; History still shows them newest first.
    @Test func searchResultsSortByTime() {
        let sessions = HistoryClusters.group([
            visit("https://a.com/1", 30, 9),
            visit("https://b.com/1", 30, 9, 20),
            visit("https://a.com/2", 30, 9, 10),
        ], calendar: calendar)
        #expect(shape(sessions) == [["b.com 1", "a.com 2"]])
        #expect(HistoryClusters.group([], calendar: calendar).isEmpty)
    }

    @Test func titles() {
        let now = date(31, 18)  // Saturday, October 31, 2026, 6 PM
        let title = { (start: Date) in HistoryClusters.title(startingAt: start, now: now, calendar: calendar) }
        #expect(title(date(31, 9)) == "This morning")
        #expect(title(date(31, 14, 10)) == "This afternoon")
        #expect(title(date(31, 17, 30)) == "This evening")
        #expect(title(date(31, 2)) == "Late last night")
        #expect(title(date(30, 19)) == "Yesterday evening")
        #expect(title(date(30, 22)) == "Last night")
        #expect(title(date(27, 8)) == "Tuesday morning")
        #expect(title(date(18, 13)) == "Sunday afternoon, October 18")
        #expect(title(date(12, 1, month: 12, year: 2025)) == "Friday late night, December 12, 2025")
    }

    /// A session's heading names the day and the part of it, never a time: each row under it shows its own.
    @Test func headingsLeaveTimesToTheRows() throws {
        let script = HistoryPage.template
        let start = try #require(script.range(of: "function sessionElement"))
        let body = script[start.lowerBound...].prefix(while: { $0 != "}" })
        #expect(body.contains("session.title"))
        #expect(!body.contains("span("))
        #expect(!body.contains("timeOf("))
    }
}
