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
    private final class Dot: InteractiveView {
        let color: SpaceColor

        init(_ color: SpaceColor) {
            self.color = color
            super.init(frame: .zero)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(color.name)
            toolTip = color.name
        }

        required init?(coder: NSCoder) { fatalError() }

        override func stateDidChange(animated: Bool) {
            layer?.cornerRadius = bounds.height / 2
            layer?.backgroundColor = cgColor(color.swatch)
            // The chosen one wears the accent as a ring around it; the others a hairline, so a pale one still shows.
            layer?.borderWidth = isSelected ? Tokens.Metric.focusRing : Tokens.Metric.hairline
            layer?.borderColor = cgColor(isSelected ? Brand.Theme.for(self).accent : Tokens.Color.controlEdge)
            setAccessibilityValue(isSelected)
        }

        override func layout() {
            super.layout()
            stateDidChange(animated: false)
        }
    }

    static let colors = SpaceColor.allCases.filter { !$0.isNeutral }
    static let side: CGFloat = Tokens.Metric.favicon + Tokens.Space.x1
    private let dots: [Dot]
    var selected: SpaceColor { didSet { refresh() } }
    var onChange: ((SpaceColor) -> Void)?

    init(selected: SpaceColor) {
        self.selected = selected
        dots = Self.colors.map(Dot.init)
        super.init(frame: .zero)
        for dot in dots {
            addSubview(dot)
            dot.onClick = { [weak self, weak dot] _ in
                guard let self, let dot else { return }
                self.selected = dot.color
                self.onChange?(dot.color)
            }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func refresh() {
        for dot in dots { dot.isSelected = dot.color == selected }
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

/// The sheets that make, change and remove a profile, wherever they're asked for: Settings, or a space's editor.
enum ProfileSheets {
    /// The profile's color with its first letter, the size of the picture on a row.
    static func tile(for profile: ProfileInfo) -> NSImage {
        SpaceSettingsRow.tile(name: profile.displayName, swatch: Library.shared.color(of: profile).swatch, icon: nil)
    }

    /// Asks for a new profile's name and color, and what extensions it starts with. `done` hears the profile made.
    @discardableResult
    static func new(in host: NSView, done: ((ProfileInfo) -> Void)? = nil) -> FormSheet {
        let library = Library.shared
        let name = FilledField(placeholder: String(localized: "Name this profile", comment: "Placeholder of the name field in the sheet that makes or edits a profile."))
        let used = Set(library.profiles.map { library.color(of: $0) })
        let dots = ColorDots(selected: ColorDots.colors.first { !used.contains($0) } ?? ColorDots.colors[library.profiles.count % ColorDots.colors.count])
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
                       message: String(localized: "A profile has its own extensions, sign-ins, passwords, history and favorites. Spaces on the same profile share them.", comment: "Under the title of the sheet that makes a profile."),
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

    /// A new profile gets the extensions another has, each as if just added: on as it is there, with nothing it
    /// stored and nothing it was allowed carried over.
    static func copyExtensions(from source: UUID, to target: UUID) {
        let from = Profiles.shared.profile(source).installs, to = Profiles.shared.profile(target).installs
        for id in from.installedIDs { to.save(ExtensionInstalls.State(enabled: from.isEnabled(id)), for: id) }
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
        let typed = FilledField(placeholder: name)
        var message = String(localized: "Its extensions and everything they hold, including any wallets, are deleted, along with its sign-ins, saved passwords, history and favorites. Make sure you have your recovery phrases. This can’t be undone.",
                             comment: "Message of the sheet that deletes a profile.")
        if !library.spaces(in: id).isEmpty {
            let first = library.profiles[0].displayName
            message += " " + String(localized: "Its spaces move to \(first).", comment: "Added to the message of the sheet that deletes a profile, when the profile has spaces. The placeholder is the first profile's name.")
        }
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
            Task { await Profiles.shared.remove(id) }
        }
    }
}
