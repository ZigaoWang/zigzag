import Foundation

/// What's saved about a profile: who it is, and how it's shown.
struct ProfileInfo: Codable, Identifiable, Equatable {
    var id: UUID
    /// Nil for the first profile until it's given a name: it's then shown as "Default", in your language.
    var name: String?
    /// The color of its tile. Nil: the one its place in the list gives it.
    var color: SpaceColor?
    var created: Date?

    var isDefault: Bool { id == Profile.defaultID }
}

/// The profiles there are, and which space is on which. Kept in a file of its own (Profiles.json), not in the
/// library: a Zigzag from before profiles rewrites the library without what it doesn't know, and would drop every
/// space's profile. It never writes this file, so going back to it and forward again loses nothing.
struct ProfileDirectory: Codable, Equatable {
    /// The first profile, which holds what Zigzag kept before there were profiles. Always there, never removed.
    private(set) var first = ProfileInfo(id: Profile.defaultID)
    /// The profiles made since, in the order they're listed.
    private(set) var others: [ProfileInfo] = []
    /// The spaces that aren't on the first profile: a space's ID, and its profile's. A space not here is on the first.
    private(set) var spaces: [String: UUID] = [:]
    /// Profiles being removed: gone from every list, their data still to be erased. A removal that was interrupted
    /// is finished from here the next time Zigzag starts.
    private(set) var deleting: [ProfileInfo] = []

    init() {}

    /// A file that leaves something out (one written by hand, or by a later Zigzag that keeps more) still reads.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let saved = try values.decodeIfPresent(ProfileInfo.self, forKey: .first) {
            first.name = saved.name
            first.color = saved.color
            first.created = saved.created
        }
        // The first profile is listed once, as the first.
        others = (try values.decodeIfPresent([ProfileInfo].self, forKey: .others) ?? []).filter { !$0.isDefault }
        spaces = try values.decodeIfPresent([String: UUID].self, forKey: .spaces) ?? [:]
        deleting = try values.decodeIfPresent([ProfileInfo].self, forKey: .deleting) ?? []
    }

    var all: [ProfileInfo] { [first] + others }

    func profile(_ id: UUID) -> ProfileInfo? { all.first { $0.id == id } }

    /// The profile a space is on. A space whose profile is gone is on the first.
    func profileID(ofSpace space: UUID) -> UUID {
        guard let id = spaces[space.uuidString], others.contains(where: { $0.id == id }) else { return Profile.defaultID }
        return id
    }

    @discardableResult
    mutating func add(name: String, color: SpaceColor? = nil, id: UUID = UUID(), created: Date = Date()) -> ProfileInfo {
        let info = ProfileInfo(id: id, name: name, color: color, created: created)
        others.append(info)
        return info
    }

    mutating func update(_ id: UUID, name: String?, color: SpaceColor?) {
        if id == first.id {
            first.name = name
            first.color = color
        } else if let index = others.firstIndex(where: { $0.id == id }) {
            others[index].name = name
            others[index].color = color
        }
    }

    mutating func assign(space: UUID, to profile: UUID) {
        spaces[space.uuidString] = profile == Profile.defaultID || !others.contains { $0.id == profile } ? nil : profile
    }

    /// Takes a profile out of the list and notes that its data is still to be erased. Its spaces go to the first
    /// profile; they're returned. The first profile can't be removed.
    @discardableResult
    mutating func remove(_ id: UUID) -> [UUID] {
        guard let index = others.firstIndex(where: { $0.id == id }) else { return [] }
        deleting.append(others.remove(at: index))
        let moved = spaces.filter { $0.value == id }.keys
        for key in moved { spaces[key] = nil }
        return moved.compactMap(UUID.init(uuidString:))
    }

    /// A removed profile's data is erased: nothing of it is left to finish.
    mutating func finishedDeleting(_ id: UUID) {
        deleting.removeAll { $0.id == id }
    }

    /// Which space is on which profile, to keep with an undo step.
    var assignments: [String: UUID] { spaces }

    /// Puts back which space was on which profile. A profile removed since isn't brought back: its spaces stay on
    /// the first.
    mutating func restore(assignments: [String: UUID]) {
        spaces = assignments.filter { entry in others.contains { $0.id == entry.value } }
    }

    /// Forgets spaces that are gone. Not done as they go: undoing a space's removal brings it back to its profile.
    mutating func prune(keeping live: Set<UUID>) {
        spaces = spaces.filter { UUID(uuidString: $0.key).map(live.contains) ?? false }
    }

    /// Stores WebKit has on disk that belong to no profile here and aren't being removed. Never erased without
    /// asking: a Profiles.json put back from a backup, or set aside as unreadable, makes a profile in use look like one.
    func orphans(amongStores stores: [UUID]) -> [UUID] {
        let known = Set(others.map(\.id) + deleting.map(\.id))
        return stores.filter { !known.contains($0) }
    }
}
