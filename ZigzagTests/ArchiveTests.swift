import AppKit
import Testing
@testable import Zigzag

@MainActor struct ArchiveTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func entry(_ url: String, _ when: String?, space: UUID = UUID(), title: String = "Page") -> ArchivedTab {
        ArchivedTab(url: URL(string: url)!, title: title, spaceID: space, archivedAt: when.map(date) ?? Date())
    }

    @Test func groupsByDayNewestFirst() {
        let entries = [
            entry("https://a.com", "2026-11-18T09:00:00Z"),
            entry("https://b.com", "2026-11-16T22:00:00Z"),
            entry("https://c.com", "2026-11-18T15:30:00Z"),
            entry("https://d.com", "2026-11-17T00:10:00Z"),
            entry("https://e.com", "2026-11-16T01:00:00Z"),
        ]
        let days = ArchiveDays.group(entries, calendar: calendar)
        #expect(days.map(\.start) == [date("2026-11-18T00:00:00Z"), date("2026-11-17T00:00:00Z"), date("2026-11-16T00:00:00Z")])
        #expect(days[0].entries.map(\.url.host) == ["c.com", "a.com"])
        #expect(days[1].entries.map(\.url.host) == ["d.com"])
        #expect(days[2].entries.map(\.url.host) == ["b.com", "e.com"])
        #expect(ArchiveDays.group([], calendar: calendar).isEmpty)
    }

    @Test func daysAreTodayYesterdayThenDated() {
        let now = date("2026-11-18T12:00:00Z")
        func title(_ day: String) -> String { ArchiveDays.title(of: date(day), now: now, calendar: calendar, locale: locale) }
        #expect(title("2026-11-18T00:00:00Z") == String(localized: "Today"))
        #expect(title("2026-11-17T00:00:00Z") == String(localized: "Yesterday"))
        #expect(title("2026-11-14T00:00:00Z") == "Saturday, November 14")
        // Across New Year the year is shown.
        #expect(title("2025-12-30T00:00:00Z").contains("2025"))
        // Future dates (clock set back) count as today.
        #expect(title("2026-11-19T00:00:00Z") == String(localized: "Today"))
    }

    @Test func searchFindsTitleAddressAndSpace() {
        let tab = entry("https://github.com/zigzag", "2026-11-18T09:00:00Z", title: "Pull Requests")
        #expect(ArchiveDays.matches(tab, words: ArchiveDays.words("pull"), space: "Work"))
        #expect(ArchiveDays.matches(tab, words: ArchiveDays.words("GitHub requests"), space: "Work"))
        #expect(ArchiveDays.matches(tab, words: ArchiveDays.words("work"), space: "Work"))
        #expect(!ArchiveDays.matches(tab, words: ArchiveDays.words("home"), space: "Work"))
        #expect(ArchiveDays.matches(tab, words: ArchiveDays.words("  "), space: nil))
    }

    @Test func restoreOpensInItsSpaceAndLeavesTheArchive() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.allTabs.forEach { $0.close() }; manager.invalidate() }
        let tab = entry("https://example.com/restored", nil, space: space, title: "Restored")
        let other = entry("https://example.com/kept", nil, space: space)
        let archive = TabArchive(file: nil, entries: [tab, other])
        let before = manager.tabs(in: space).count

        let restored = manager.restore(tab, from: archive)
        #expect(restored.url == tab.url)
        #expect(restored.spaceID == space)
        #expect(manager.selectedTab === restored)
        #expect(manager.tabs(in: space).count == before + 1)
        #expect(archive.entries.map(\.url) == [other.url])
    }

    @Test func restoreWithItsSpaceGoneOpensInTheCurrentOne() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.allTabs.forEach { $0.close() }; manager.invalidate() }
        let tab = entry("https://example.com/orphan", nil, space: UUID())
        let archive = TabArchive(file: nil, entries: [tab])
        let restored = manager.restore(tab, from: archive)
        #expect(restored.spaceID == manager.currentSpaceID)
        #expect(archive.entries.isEmpty)
    }

    @Test func restoreGoesToTheTabAlreadyOpen() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.allTabs.forEach { $0.close() }; manager.invalidate() }
        let open = manager.newTab(url: URL(string: "https://example.com/open")!, spaceID: space, select: false)
        let count = manager.tabs(in: space).count
        let archive = TabArchive(file: nil, entries: [entry("https://example.com/open", nil, space: space)])
        let restored = manager.restore(archive.entries[0], from: archive)
        #expect(restored === open)
        #expect(manager.selectedTab === open)
        #expect(manager.tabs(in: space).count == count)
        #expect(archive.entries.isEmpty)
    }
}
