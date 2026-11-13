import AppKit

extension ProfileInfo {
    /// Its name as shown. The first profile is "Default" until it's given a name of its own.
    var displayName: String {
        name ?? String(localized: "Default", comment: "The name of the first profile, which holds what Zigzag kept before there were profiles, until it's renamed.")
    }
}

extension Library {
    /// A profile's color: the one chosen for it, else the one its place in the list gives it.
    func color(of profile: ProfileInfo) -> SpaceColor {
        if let color = profile.color { return color }
        let colors = SpaceColor.allCases.filter { !$0.isNeutral }
        return colors[(profiles.firstIndex { $0.id == profile.id } ?? 0) % colors.count]
    }
}

/// The curated colors as a row of dots, one chosen: a profile's color in its form.
final class ColorDots: NSView {
    static let colors = SpaceColor.allCases.filter { !$0.isNeutral }
    /// As big as the space editor's swatches, which these are.
    static let side: CGFloat = 24
    private let dots: [LookSwatch]
    var selected: SpaceColor { didSet { refresh() } }
    var onChange: ((SpaceColor) -> Void)?

    init(selected: SpaceColor) {
        self.selected = selected
        // The space editor's own swatch, so a color chosen looks chosen the same way everywhere.
        dots = Self.colors.map { LookSwatch(look: .curated($0)) }
        super.init(frame: .zero)
        for dot in dots {
            addSubview(dot)
            dot.onClick = { [weak self, weak dot] _ in
                guard let self, let dot, let index = self.dots.firstIndex(where: { $0 === dot }) else { return }
                self.selected = Self.colors[index]
                self.onChange?(self.selected)
            }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func refresh() {
        for (dot, color) in zip(dots, Self.colors) { dot.isSelected = color == selected }
    }

    override func layout() {
        super.layout()
        let side = Self.side
        // Spread across the row, the first at its start and the last at its end.
        let step = dots.count > 1 ? (bounds.width - side) / CGFloat(dots.count - 1) : 0
        for (index, dot) in dots.enumerated() {
            dot.frame = NSRect(x: round(CGFloat(index) * min(step, side + Tokens.Space.x3)), y: round((bounds.height - side) / 2), width: side, height: side)
        }
    }
}

/// The profiles as a dropdown's choices, wherever one is chosen: Settings, a space's editor, Import,
/// adding an extension.
enum ProfileChoice {
    /// Fills a dropdown with the profiles, each with its tile, and selects one. Returns their IDs in the order
    /// shown: the choice is read back from these, not from the list as it is later, which may have changed while
    /// the menu was open.
    @discardableResult
    static func fill(_ button: DropdownButton, selected: UUID) -> [UUID] {
        let profiles = Library.shared.profiles
        button.options = options(profiles)
        button.selectedIndex = profiles.firstIndex { $0.id == selected } ?? 0
        return profiles.map(\.id)
    }

    static func options(_ profiles: [ProfileInfo] = Library.shared.profiles) -> [DropdownButton.Option] {
        profiles.map { DropdownButton.Option(title: $0.displayName, image: ProfileSheets.tile(for: $0)) }
    }

    /// What a profile's dropdown is called, for VoiceOver, where no label stands beside it.
    static var label: String { String(localized: "Profile", comment: "What VoiceOver calls a menu that chooses a profile, and the label before that choice in a space's editor.") }

    /// What being on a profile means, in a line under a space's choice of one: enough to choose without a trip to
    /// Settings. Spaces aren't Chrome's profiles: a sign-in in one space is there in the others on its profile (#201).
    static var spaceNote: String {
        String(localized: "Spaces on the same profile share sign-ins, history and extensions. Use another profile to keep them apart.",
               comment: "Note under the Profile row in a space's editor, which also opens for a new space: what being on the same profile means.")
    }

    /// The item at the end of a space's Profile menu: a profile of its own for the space, named after it, in one step.
    static var newForSpace: String {
        String(localized: "New Profile", comment: "Item at the end of the Profile menu in a space's editor: makes a profile named after the space and puts the space on it, in one step.")
    }
}

extension ProfileDirectory {
    /// The profile's name beside a space where spaces are listed (the sidebar's header, the space switcher, a
    /// space's menu): only once there's more than one profile. With one, nothing speaks of profiles. Nor when it's
    /// called what the space is (`spaceName`), as one New Profile made for it is: "Work … Work" says nothing more.
    func shownName(ofSpace id: UUID, spaceName: String) -> String? {
        guard all.count > 1, let name = profile(profileID(ofSpace: id))?.displayName else { return nil }
        let trimmed = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmed(name).caseInsensitiveCompare(trimmed(spaceName)) == .orderedSame ? nil : name
    }
}

/// The sheets that make, change and remove a profile, wherever they're asked for: Settings, or a space's editor.
enum ProfileSheets {
    /// The profile's color with its first letter, the size of the picture on a row.
    static func tile(for profile: ProfileInfo) -> NSImage {
        SpaceSettingsRow.tile(name: profile.displayName, swatch: Library.shared.color(of: profile).swatch, icon: nil)
    }

    /// With more than one profile, added to what a sheet says before clearing one profile's cache or cookies: whose
    /// they are.
    static func onlyNote(_ profile: UUID?) -> String? {
        guard let profile, Library.shared.hasManyProfiles, let info = Library.shared.directory.profile(profile) else { return nil }
        return String(localized: "Only in \(info.displayName); other profiles aren’t changed.", comment: "Added to the message of a sheet that asks before clearing the cache or cookies, when there's more than one profile. The placeholder is the profile's name.")
    }

    /// Whether a page that moves to a space on `target` is rebuilt there, losing what it held that wasn't saved:
    /// one that's loaded, in another profile. A private page keeps its window's own store wherever it goes, and
    /// one that isn't loaded has nothing to lose.
    static func isRebuilt(isPrivate: Bool, isLoaded: Bool, in profile: UUID, movingTo target: UUID) -> Bool {
        !isPrivate && isLoaded && profile != target
    }

    /// Asks, over `host`, before pages that are loaded move to a space on another profile, where they're rebuilt
    /// with that profile's sign-ins and extensions. `move` runs at once when none of them would change profile.
    static func confirmCrossing(_ tabs: [Tab], to spaceID: UUID, in host: NSView, cancelled: @escaping () -> Void = {}, then move: @escaping () -> Void) {
        let target = Library.shared.profileID(ofSpace: spaceID)
        let crossing = tabs.filter { isRebuilt(isPrivate: $0.isPrivate, isLoaded: $0.webView != nil, in: $0.profile.id, movingTo: target) }
        guard !crossing.isEmpty, let space = Library.shared.space(spaceID), let profile = Library.shared.directory.profile(target) else { move(); return }
        let one = crossing.count == 1
        ConfirmSheet.show(in: host,
                          title: one ? String(localized: "Move this tab to \(space.name)?", comment: "Title of the sheet that asks before a tab moves to a space on another profile. The placeholder is the space's name.")
                                     : String(localized: "Move these tabs to \(space.name)?", comment: "Title of the sheet that asks before several tabs move to a space on another profile. The placeholder is the space's name."),
                          message: one ? String(localized: "\(space.name) is on \(profile.displayName), a profile with its own sign-ins and extensions. The page reloads there and keeps its back and forward history.", comment: "Message of the sheet that asks before a tab moves to a space on another profile. First the space's name, then the profile's.")
                                       : String(localized: "\(space.name) is on \(profile.displayName), a profile with its own sign-ins and extensions. The pages reload there and keep their back and forward history.", comment: "Message of the sheet that asks before several tabs move to a space on another profile. First the space's name, then the profile's."),
                          confirmTitle: String(localized: "Move and Reload", comment: "Button of the sheet that asks before tabs move to a space on another profile.")) { confirmed in
            if confirmed { move() } else { cancelled() }
        }
    }

    /// Asks for a new profile's name and color, and what extensions it starts with. `done` hears the profile made.
    @discardableResult
    static func new(in host: NSView, done: ((ProfileInfo) -> Void)? = nil) -> FormSheet {
        let library = Library.shared
        let name = FilledField(placeholder: String(localized: "Name this profile", comment: "Placeholder of the name field in the sheet that makes or edits a profile."))
        let dots = ColorDots(selected: SpaceColor.next(unused: library.profiles.map { library.color(of: $0) }, fallback: ColorDots.colors))
        let seeds = library.profiles
        let start = DropdownButton()
        start.options = [DropdownButton.Option(title: String(localized: "Start Empty", comment: "Choice in the sheet that makes a profile: it starts with no extensions."), image: nil)]
            + seeds.map { DropdownButton.Option(title: String(localized: "Same as \($0.displayName)", comment: "Choice in the sheet that makes a profile: it starts with the extensions another profile has. The placeholder is that profile's name."), image: nil) }
        start.selectedIndex = 0
        let rows = [
            FormSheet.Row(label: nil, view: name),
            FormSheet.Row(label: String(localized: "Color", comment: "Label of the row of colors in the sheet that makes or edits a profile."), view: dots, height: ColorDots.side + Tokens.Space.x1),
            FormSheet.Row(label: String(localized: "Extensions", comment: "Label in the sheet that makes a profile: which extensions it starts with."), view: start),
            .note(String(localized: "Extensions are added fresh. Nothing they’ve stored in another profile comes along.", comment: "Note in the sheet that makes a profile, under the choice of which extensions it starts with.")),
        ]
        return FormSheet.show(in: host, title: String(localized: "New Profile", comment: "Title of the sheet that makes a profile."), symbol: "person",
                       message: String(localized: "A profile has its own extensions, sign-ins, history and favorites. Spaces on the same profile share them.", comment: "Under the title of the sheet that makes a profile."),
                       rows: rows, confirmTitle: String(localized: "Create", comment: "Button that makes the profile, in the sheet that asks for its name."),
                       canConfirm: { [weak name] in !(name?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) { confirmed in
            guard confirmed else { return }
            let made = library.addProfile(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), color: dots.selected)
            if start.selectedIndex > 0, seeds.indices.contains(start.selectedIndex - 1) {
                copyExtensions(from: seeds[start.selectedIndex - 1].id, to: made.id)
            }
            done?(made)
        }
    }

    /// A new profile gets the extensions another has: on or off as there, allowed what they are there and on the same
    /// sites, with nothing they stored.
    private static func copyExtensions(from source: UUID, to target: UUID) {
        let from = Profiles.shared.profile(source).installs, to = Profiles.shared.profile(target).installs
        for id in from.installedIDs {
            guard let state = from.state(id) else { continue }
            to.save(state.carried(enabled: state.enabled), for: id)
        }
    }

    static func edit(_ id: UUID, in host: NSView) {
        let library = Library.shared
        guard let profile = library.directory.profile(id) else { return }
        let name = FilledField(placeholder: String(localized: "Name this profile", comment: "Placeholder of the name field in the sheet that makes or edits a profile."))
        name.stringValue = profile.displayName
        let dots = ColorDots(selected: library.color(of: profile))
        let rows = [
            FormSheet.Row(label: nil, view: name),
            FormSheet.Row(label: String(localized: "Color", comment: "Label of the row of colors in the sheet that makes or edits a profile."), view: dots, height: ColorDots.side + Tokens.Space.x1),
        ]
        FormSheet.show(in: host, title: String(localized: "Edit Profile", comment: "Title of the sheet that renames a profile and changes its color."), symbol: "person",
                       rows: rows, confirmTitle: String(localized: "Save", comment: "Button that saves a profile's new name and color."),
                       canConfirm: { [weak name] in !(name?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) { confirmed in
            guard confirmed else { return }
            let typed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // The first profile left with the name it's shown by keeps following your language.
            library.updateProfile(id, name: profile.name == nil && typed == profile.displayName ? nil : typed, color: dots.selected)
        }
    }

    /// Removing a profile deletes wallets and sign-ins for good, so it asks you to type its name: a click alone
    /// can't do it.
    static func confirmDelete(_ id: UUID, in host: NSView) {
        let library = Library.shared
        guard let profile = library.directory.profile(id), !profile.isDefault else { return }
        let name = profile.displayName
        // Not while something is still being brought into it (an import, an extension): that would be erased half
        // written.
        let tellInUse = { [weak host] in
            guard let host else { return }
            ConfirmSheet.notice(in: host, title: String(localized: "\(name) can’t be deleted yet", comment: "Title of the sheet shown instead of the one that deletes a profile, while an import or an extension is still going into that profile. The placeholder is the profile's name."),
                                message: String(localized: "Something is still being added to it, such as an import or an extension. Try again when that’s done.", comment: "Message of the sheet shown instead of the one that deletes a profile, while an import or an extension is still going into that profile."))
        }
        if Profiles.shared.removalBlock(id) == .inUse { tellInUse(); return }
        let typed = FilledField(placeholder: name)
        // What goes, what moves, what stays, and last that it's for good.
        var message = String(localized: "Its sign-ins, history, favorites and extensions are deleted, with everything the extensions hold, wallets included.",
                             comment: "Message of the sheet that deletes a profile. More sentences may follow.")
        if !library.spaces(in: id).isEmpty {
            let first = library.profiles[0].displayName
            message = Words.sentences(message, String(localized: "Its spaces move to \(first).", comment: "Added to the message of the sheet that deletes a profile, when the profile has spaces. The placeholder is the first profile's name."))
        }
        message = Words.sentences(message, String(localized: "Saved passwords stay.", comment: "Added to the message of the sheet that deletes a profile: the passwords Zigzag saved, which every profile shares, aren't deleted with it."))
        message = Words.sentences(message, String(localized: "Write down any recovery phrases first. This can’t be undone.", comment: "Ends the message of the sheet that deletes a profile: a wallet extension's recovery phrase is the only way back to it."))
        let rows = [
            FormSheet.Row.note(String(localized: "Type \(name) to confirm", comment: "Over the field in the sheet that deletes a profile. The placeholder is the profile's name.")),
            FormSheet.Row(label: nil, view: typed),
        ]
        FormSheet.show(in: host, title: String(localized: "Delete \(name)?", comment: "Title of the sheet that deletes a profile. The placeholder is the profile's name."),
                       symbol: "exclamationmark.triangle", message: message, rows: rows,
                       confirmTitle: String(localized: "Delete Profile", comment: "Button of the sheet that deletes a profile, and tooltip of the trash button on a profile's row in Settings › Profiles."),
                       destructive: true,
                       canConfirm: { [weak typed] in typed?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }) { confirmed in
            guard confirmed else { return }
            Task {
                // An import begun while the question was open: nothing is removed, and it says so.
                if await !Profiles.shared.remove(id), Profiles.shared.removalBlock(id) == .inUse { tellInUse() }
            }
        }
    }
}
