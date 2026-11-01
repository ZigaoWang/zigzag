import Foundation

/// The back/forward data last saved for each tab, so a session save asks WebKit to encode only the tabs that could
/// have changed since: ones that navigated, ones on screen (you may have scrolled), and ones that were on screen at
/// the last save (scrolled, then left). The rest keep the data they had, which is what an encode would give again.
struct TabStateCache {
    private(set) var saved: [UUID: Data] = [:]
    private var shownLastTime: Set<UUID> = []

    /// Whether this save has to encode the tab again.
    func needsEncoding(_ id: UUID, navigated: Bool, shown: Bool) -> Bool {
        navigated || shown || shownLastTime.contains(id) || saved[id] == nil
    }

    /// Takes a freshly encoded state; true when it differs from what's on disk, so it has to be written.
    /// Compared in full: a hash of Data looks only at its length and first bytes, so going Back (same length, a
    /// different place) would go unsaved.
    mutating func update(_ id: UUID, with data: Data) -> Bool {
        guard saved[id] != data else { return false }
        saved[id] = data
        return true
    }

    /// After a save: forgets closed tabs, and remembers which tabs were on screen.
    mutating func finish(keeping ids: Set<UUID>, shown: Set<UUID>) {
        for id in saved.keys where !ids.contains(id) { saved[id] = nil }
        shownLastTime = shown
    }
}
