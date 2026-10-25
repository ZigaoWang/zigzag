import Foundation

/// Tabs that tidy themselves: an ordinary tab you haven't looked at in a while leaves the sidebar for the archive,
/// where the command bar still finds it. Pinned pages, favorites, what's on screen, anything playing or in a call,
/// and private windows are never archived. The archive keeps a month, newest first, and survives quitting.
nonisolated struct ArchivedTab: Codable, Equatable, Identifiable {
    var id = UUID()
    let url: URL
    let title: String
    let spaceID: UUID
    let archivedAt: Date
}

final class TabArchive {
    static let shared = TabArchive()

    /// How long a tab can sit unseen before it's archived. Nil: never.
    enum After: String, CaseIterable {
        case twelveHours, day, week, never

        var interval: TimeInterval? {
            switch self {
            case .twelveHours: 12 * 3600
            case .day: 24 * 3600
            case .week: 7 * 24 * 3600
            case .never: nil
            }
        }

        var title: String {
            switch self {
            case .twelveHours: "After 12 hours"
            case .day: "After a day"
            case .week: "After a week"
            case .never: "Never"
            }
        }
    }

    static var after: After {
        // Off until you ask for it: tabs disappearing on their own is something you choose.
        get { After(rawValue: UserDefaults.standard.string(forKey: "ArchiveTabsAfter") ?? "") ?? .never }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ArchiveTabsAfter") }
    }

    /// Once, when a space's list has grown long: a quiet offer to turn archiving on. Never asked again.
    static func offerIfCrowded(tabCount: Int) {
        let d = UserDefaults.standard
        guard after == .never, d.string(forKey: "ArchiveTabsAfter") == nil, !d.bool(forKey: "ArchiveOffered"), tabCount >= 20,
              let controller = WindowManager.shared.keyController, !controller.tabManager.isPrivate else { return }
        d.set(true, forKey: "ArchiveOffered")
        Toast.show("Tidy tabs you haven’t used in a day?", symbol: "archivebox", action: ("Turn On", { after = .day }),
                   duration: 10, in: controller)
    }

    private(set) var entries: [ArchivedTab]
    private static let keep: TimeInterval = 30 * 24 * 3600
    private static let limit = 500

    private init() {
        entries = JSONStore.load([ArchivedTab].self, from: Paths.file("Archive.json")) ?? []
        prune()
    }

    func add(_ entry: ArchivedTab) {
        entries.removeAll { $0.url == entry.url }
        entries.insert(entry, at: 0)
        prune()
        save()
    }

    /// Taken out when it's opened again, so it never shows twice.
    func remove(url: URL) {
        let before = entries.count
        entries.removeAll { TabManager.normalize($0.url) == TabManager.normalize(url) }
        if entries.count != before { save() }
    }

    func clear() {
        entries = []
        save()
    }

    func search(_ words: [String], limit: Int) -> [ArchivedTab] {
        var found: [ArchivedTab] = []
        for entry in entries where found.count < limit {
            let haystack = (entry.title + " " + entry.url.absoluteString).lowercased()
            if words.allSatisfy({ haystack.contains($0) }) { found.append(entry) }
        }
        return found
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        entries.removeAll { $0.archivedAt < cutoff }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    private func save() {
        JSONStore.save(entries, to: Paths.file("Archive.json"))
    }
}
