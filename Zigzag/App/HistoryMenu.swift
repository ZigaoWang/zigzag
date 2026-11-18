import AppKit

/// Groups history for the History menu (#271), as Safari does: today's latest in the menu, the rest of today and the
/// last week's days in submenus. One entry per page per day.
nonisolated enum HistoryMenuDays {
    struct Day {
        let start: Date
        let entries: [HistoryEntry]
    }

    struct Grouped {
        var today: [HistoryEntry] = []
        var earlierToday: [HistoryEntry] = []
        /// Newest first.
        var earlier: [Day] = []
    }

    /// Drops future entries (clock set back) and ones older than `earlierDays`.
    static func group(_ entries: [HistoryEntry], now: Date, calendar: Calendar = .current, todayLimit: Int = 15,
                      dayLimit: Int = 40, earlierDays: Int = 7) -> Grouped {
        let today = calendar.startOfDay(for: now)
        var byDay: [Int: [HistoryEntry]] = [:]
        var seen: [Int: Set<String>] = [:]
        for entry in entries.sorted(by: { $0.lastVisit > $1.lastVisit }) {
            let start = calendar.startOfDay(for: entry.lastVisit)
            guard let ago = calendar.dateComponents([.day], from: start, to: today).day, (0...earlierDays).contains(ago),
                  seen[ago, default: []].insert(entry.url.absoluteString).inserted else { continue }
            byDay[ago, default: []].append(entry)
        }
        var grouped = Grouped()
        let todays = byDay[0] ?? []
        grouped.today = Array(todays.prefix(todayLimit))
        grouped.earlierToday = Array(todays.dropFirst(todayLimit).prefix(dayLimit))
        grouped.earlier = byDay.keys.filter { $0 > 0 }.sorted().compactMap { ago in
            guard let start = calendar.date(byAdding: .day, value: -ago, to: today), let pages = byDay[ago] else { return nil }
            return Day(start: start, entries: Array(pages.prefix(dayLimit)))
        }
        return grouped
    }

    /// Title on one line, truncated past `limit` characters.
    static func menuTitle(_ entry: HistoryEntry, limit: Int = 60) -> String {
        let shown = HistoryStore.shownTitle(entry.title.trimmingCharacters(in: .whitespacesAndNewlines), url: entry.url)
        return shortened(shown, limit: limit)
    }

    static func shortened(_ text: String, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard line.count > limit else { return line }
        return line.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Yesterday, else weekday and date, localized.
    static func title(of day: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)), calendar.isDate(day, inSameDayAs: yesterday) {
            // Said of the real yesterday, as the formatter only knows it.
            formatter.dateStyle = .full
            formatter.doesRelativeDateFormatting = true
            return formatter.string(from: calendar.date(byAdding: .day, value: -1, to: Date()) ?? day)
        }
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter.string(from: day)
    }
}

/// Builds the History menu on open (#271): Recently Closed, today's pages, and a submenu per earlier day. Private
/// windows' tabs are never listed.
final class HistoryMenu: NSObject, NSMenuDelegate {
    static let shared = HistoryMenu()

    /// Tags filled items so the next open removes them.
    private static let pageID = NSUserInterfaceItemIdentifier("ZigzagHistoryMenuPage")

    private static let recentlyClosedID = NSUserInterfaceItemIdentifier("ZigzagHistoryMenuRecentlyClosed")
    private static var recentlyClosedTitle: String {
        String(localized: "Recently Closed", comment: "History menu item: a submenu of the tabs and windows you closed lately.")
    }

    /// Dimmed when empty.
    static func makeRecentlyClosedItem() -> NSMenuItem {
        let item = NSMenuItem(title: recentlyClosedTitle, action: nil, keyEquivalent: "")
        item.identifier = recentlyClosedID
        return item
    }

    private let noShortcuts = Pages()
    /// Day submenus' delegates, held here since menus hold them weakly.
    private var days: [Pages] = []

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Skip during shortcut lookups (⌘ key down); every shortcut is on a fixed item.
        if let event = NSApp.currentEvent, event.type == .keyDown, event.modifierFlags.contains(.command) { return }
        let controller = WindowManager.shared.keyController
        for item in menu.items where item.identifier == Self.pageID { menu.removeItem(item) }
        days.removeAll()
        guard let index = menu.items.firstIndex(where: { $0.identifier == Self.recentlyClosedID }) else { return }
        fillRecentlyClosed(menu.items[index], from: controller)
        var at = index + 1
        func add(_ item: NSMenuItem) {
            item.identifier = Self.pageID
            menu.insertItem(item, at: at)
            at += 1
        }
        let history = (controller?.tabManager.profile ?? Profiles.shared.default).history
        let now = Date()
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: now))
        let grouped = HistoryMenuDays.group(history.items(matching: "", from: since, to: nil, limit: 3000).map(\.entry), now: now)
        if !grouped.today.isEmpty {
            add(.separator())
            grouped.today.forEach { add(Self.pageItem($0)) }
            if !grouped.earlierToday.isEmpty {
                add(Self.dayItem(String(localized: "Earlier Today", comment: "History menu item: a submenu of the pages visited today before the ones listed above it."), grouped.earlierToday))
            }
        }
        if !grouped.earlier.isEmpty {
            add(.separator())
            for day in grouped.earlier { add(Self.dayItem(HistoryMenuDays.title(of: day.start, now: now), day.entries)) }
        }
    }

    private func fillRecentlyClosed(_ recentlyClosedItem: NSMenuItem, from controller: BrowserWindowController?) {
        let recentlyClosed = NSMenu(title: Self.recentlyClosedTitle)
        recentlyClosed.delegate = noShortcuts
        // Private windows' closed tabs are never listed.
        if let controller, !controller.tabManager.isPrivate {
            for closed in controller.tabManager.recentlyClosedTabs.prefix(10) {
                let item = SidebarMenus.Item(HistoryMenuDays.shortened(HistoryStore.shownTitle(closed.title, url: closed.url))) { [weak controller] in
                    guard let controller else { return }
                    controller.window?.makeKeyAndOrderFront(nil)
                    controller.tabManager.reopenClosedTab(closed.id)
                }
                item.image = Self.icon(for: closed.url)
                recentlyClosed.addItem(item)
            }
        }
        let windows = WindowManager.shared.recentlyClosedWindows.prefix(5)
        if !windows.isEmpty, !recentlyClosed.items.isEmpty { recentlyClosed.addItem(.separator()) }
        for window in windows {
            let item = SidebarMenus.Item(String(localized: "Window with \(window.tabCount) Tabs", comment: "History › Recently Closed: a closed window, with how many tabs it had.")) {
                WindowManager.shared.reopenClosedWindow(window.id)
            }
            item.image = Tokens.Symbol.image("macwindow", size: 13)
            // Tooltip with the page it showed, to tell windows apart.
            if let shown = window.shown, let url = shown.url { item.toolTip = HistoryStore.shownTitle(shown.customTitle ?? shown.title, url: url) }
            recentlyClosed.addItem(item)
        }
        recentlyClosedItem.submenu = recentlyClosed.items.isEmpty ? nil : recentlyClosed
    }

    private static func pageItem(_ entry: HistoryEntry) -> NSMenuItem {
        let url = entry.url
        let item = SidebarMenus.Item(HistoryMenuDays.menuTitle(entry)) { open(url) }
        item.image = icon(for: url)
        item.toolTip = url.absoluteString
        return item
    }

    /// Filled when the submenu opens.
    private static func dayItem(_ title: String, _ entries: [HistoryEntry]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        let pages = Pages { menu in entries.forEach { menu.addItem(pageItem($0)) } }
        menu.delegate = pages
        shared.days.append(pages)
        item.submenu = menu
        return item
    }

    /// Opens in the current tab, as Chrome does; ⌘-click opens a new tab.
    private static func open(_ url: URL) {
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        guard let controller = WindowManager.shared.keyController else { WindowManager.shared.openFromZigzag(url); return }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.open(url, disposition: newTab ? .foregroundTab : .currentTab)
    }

    private static func icon(for url: URL) -> NSImage {
        guard let icon = SiteIcons.shownIcon(for: url)?.copy() as? NSImage else { return Tokens.Symbol.image("globe", size: 13) }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// Fills itself on first open, so shortcut lookups never build it.
    final class Pages: NSObject, NSMenuDelegate {
        var fill: ((NSMenu) -> Void)?

        init(fill: ((NSMenu) -> Void)? = nil) { self.fill = fill }

        func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                                  action: UnsafeMutablePointer<Selector?>) -> Bool { false }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let fill else { return }
            self.fill = nil
            fill(menu)
        }
    }
}
