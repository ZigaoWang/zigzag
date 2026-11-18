import Foundation
import Testing
@testable import Zigzag

/// History menu (#271): today's pages in the menu, earlier days in submenus.
struct HistoryMenuTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func visit(_ url: String, _ day: Int, _ hour: Int, _ minute: Int = 0, title: String = "") -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: title, visitCount: 1, lastVisit: date(day, hour, minute))
    }

    /// Monday, November 16, 2026, 3 p.m.
    private var now: Date { date(16, 15) }

    @Test func todayAndEarlierDays() {
        let grouped = HistoryMenuDays.group([
            visit("https://a.example/", 16, 9),
            visit("https://b.example/", 16, 14),
            visit("https://c.example/", 15, 23, 59),
            visit("https://d.example/", 14, 0, 1),
            visit("https://e.example/", 15, 8),
        ], now: now, calendar: calendar)
        #expect(grouped.today.map(\.url.host) == ["b.example", "a.example"])
        #expect(grouped.earlierToday.isEmpty)
        #expect(grouped.earlier.map(\.start) == [date(15, 0), date(14, 0)])
        #expect(grouped.earlier.map { $0.entries.map(\.url.host) } == [["c.example", "e.example"], ["d.example"]])
    }

    @Test func aPageIsListedOnceADayAtItsLatestVisit() {
        let grouped = HistoryMenuDays.group([
            visit("https://a.example/", 16, 9, title: "Old"),
            visit("https://b.example/", 16, 10),
            visit("https://a.example/", 16, 11, title: "New"),
            visit("https://a.example/", 15, 11),
        ], now: now, calendar: calendar)
        #expect(grouped.today.map(\.url.host) == ["a.example", "b.example"])
        #expect(grouped.today.first?.title == "New")
        // Another day lists it again.
        #expect(grouped.earlier.first?.entries.count == 1)
    }

    @Test func listsAreCapped() {
        let pages = (0..<60).map { visit("https://site\($0).example/", 16, 14, 59 - $0) }
            + (0..<60).map { visit("https://old\($0).example/", 15, 12, 59 - $0) }
        let grouped = HistoryMenuDays.group(pages, now: now, calendar: calendar, todayLimit: 15, dayLimit: 40)
        #expect(grouped.today.count == 15)
        #expect(grouped.today.first?.url.host == "site0.example")
        // The rest of today, up to the cap, newest first after the menu's.
        #expect(grouped.earlierToday.count == 40)
        #expect(grouped.earlierToday.first?.url.host == "site15.example")
        #expect(grouped.earlier.first?.entries.count == 40)
    }

    @Test func onlyTheLastWeek() {
        let grouped = HistoryMenuDays.group([
            visit("https://week.example/", 9, 12),
            visit("https://older.example/", 8, 23),
            // Clock set back: a "tomorrow" visit isn't listed.
            visit("https://later.example/", 17, 9),
        ], now: now, calendar: calendar, earlierDays: 7)
        #expect(grouped.today.isEmpty)
        #expect(grouped.earlier.map(\.start) == [date(9, 0)])
    }

    @Test func titlesAreOneShortLine() {
        let long = String(repeating: "word ", count: 30)
        let title = HistoryMenuDays.menuTitle(HistoryEntry(url: URL(string: "https://a.example/")!, title: long, visitCount: 1, lastVisit: now))
        #expect(title.count == 60)
        #expect(title.hasSuffix("…"))
        #expect(HistoryMenuDays.shortened("Two\nlines") == "Two lines")
        // No title: the site.
        #expect(HistoryMenuDays.menuTitle(HistoryEntry(url: URL(string: "https://a.example/x")!, title: "  ", visitCount: 1, lastVisit: now)) == "a.example")
    }

    @Test func dayTitles() {
        let english = Locale(identifier: "en_US")
        #expect(HistoryMenuDays.title(of: date(14, 0), now: now, calendar: calendar, locale: english) == "Saturday, November 14")
        #expect(HistoryMenuDays.title(of: date(15, 0), now: now, calendar: calendar, locale: english) == "Yesterday")
        #expect(HistoryMenuDays.title(of: date(14, 0), now: now, calendar: calendar, locale: Locale(identifier: "zh_Hans")).contains("11月14日"))
    }
}
