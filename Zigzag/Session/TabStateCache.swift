import Foundation

/// The back/forward data last saved for each tab, so a session save asks WebKit to encode only the tabs that could
/// have changed since: ones that went somewhere or were scrolled. The rest keep the data they had, which is what an
/// encode would give again. The page on screen used to be encoded at every save in case it had been scrolled, a few
/// hundred kilobytes each time for a long history, while a page rewriting its address kept the saves coming (#89).
struct TabStateCache {
    private(set) var saved: [UUID: Data] = [:]

    /// Whether this save has to encode the tab again.
    func needsEncoding(_ id: UUID, changed: Bool) -> Bool {
        changed || saved[id] == nil
    }

    /// Takes a freshly encoded state; true when it differs from what's on disk, so it has to be written.
    /// Compared in full: a hash of Data looks only at its length and first bytes, so going Back (same length, a
    /// different place) would go unsaved.
    mutating func update(_ id: UUID, with data: Data) -> Bool {
        guard saved[id] != data else { return false }
        saved[id] = data
        return true
    }

    /// After a save: forgets closed tabs.
    mutating func finish(keeping ids: Set<UUID>) {
        for id in saved.keys where !ids.contains(id) { saved[id] = nil }
    }
}
