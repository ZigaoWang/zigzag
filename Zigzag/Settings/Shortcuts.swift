import AppKit

/// Keyboard shortcuts you've changed in Settings. The menu bar is the one source of truth: changes are written onto
/// its items, so the menus, the Shortcuts pane and the keys themselves always agree.
enum Shortcuts {
    struct Combo: Codable, Equatable {
        /// The key, as a menu item's key equivalent; empty means no shortcut.
        var key: String
        var modifiers: UInt

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
        static let none = Combo(key: "", modifiers: 0)
    }

    private static let storeKey = "ShortcutOverrides"
    /// Each item's shortcut as Zigzag ships it, read before any change is applied.
    private static var defaults: [String: Combo] = [:]
    static let changed = Signal<Void>()

    /// An item is known by what it does (its action and tag), since some titles change with state.
    static func id(_ item: NSMenuItem) -> String? {
        // Hidden aliases (⌘= beside ⌘+, ⌘← beside ⌘[) share their item's action and tag; they keep their own keys and
        // aren't listed, so changing or resetting the visible one never rewrites them.
        guard let action = item.action, !item.isAlternate, !(item.isHidden && item.allowsKeyEquivalentWhenHidden) else { return nil }
        return NSStringFromSelector(action) + "#\(item.tag)"
    }

    private static var overrides: [String: Combo] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Combo].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storeKey) }
    }

    static var allItems: [NSMenuItem] {
        var result: [NSMenuItem] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub) } else if id(item) != nil { result.append(item) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
        return result
    }

    private static func combo(of item: NSMenuItem) -> Combo {
        Combo(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    private static func write(_ combo: Combo, to item: NSMenuItem) {
        item.keyEquivalent = combo.key
        item.keyEquivalentModifierMask = combo.flags
    }

    /// Call once the menu bar is built: remembers the shipped shortcuts, then applies yours.
    static func apply() {
        let saved = overrides
        for item in allItems {
            guard let id = id(item) else { continue }
            if defaults[id] == nil { defaults[id] = combo(of: item) }
            if let combo = saved[id] { write(combo, to: item) }
        }
    }

    /// Changed by you, going by what's saved rather than the item's keys: macOS adjusts some of its own items
    /// (Enter Full Screen) after launch, which isn't a change of yours.
    static func isCustom(_ item: NSMenuItem) -> Bool {
        guard let id = id(item), let saved = overrides[id] else { return false }
        return saved != defaults[id]
    }

    /// A fixed shortcut Zigzag keeps for itself (⌘1–9 for tabs, ⌃1–9 for spaces, ⌘= beside ⌘+): its title, if
    /// these keys are one. They can't be given to anything else, or one of the two would silently stop working.
    static func reserved(_ combo: Combo) -> String? {
        guard !combo.key.isEmpty else { return nil }
        func walk(_ menu: NSMenu) -> String? {
            for item in menu.items {
                if let sub = item.submenu, let found = walk(sub) { return found }
                if item.isHidden, item.allowsKeyEquivalentWhenHidden, Self.combo(of: item) == combo { return item.title }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(walk)
    }

    /// The item that already answers to these keys, other than `item`.
    static func owner(of combo: Combo, besides item: NSMenuItem) -> NSMenuItem? {
        guard !combo.key.isEmpty else { return nil }
        return allItems.first { $0 !== item && Self.combo(of: $0) == combo }
    }

    /// Gives `item` these keys. If another item had them, it loses them, and is returned so the change can be said.
    @discardableResult
    static func set(_ combo: Combo, for item: NSMenuItem) -> NSMenuItem? {
        guard let id = id(item) else { return nil }
        var saved = overrides
        let previous = owner(of: combo, besides: item)
        if let previous, let otherID = self.id(previous) {
            write(Combo.none, to: previous)
            saved[otherID] = Combo.none
        }
        write(combo, to: item)
        saved[id] = combo == defaults[id] ? nil : combo
        overrides = saved
        changed.send(())
        return previous
    }

    static func reset(_ item: NSMenuItem) {
        guard let id = id(item), let shipped = defaults[id] else { return }
        // Its shipped keys may have gone to something else since; they come back here.
        if let other = owner(of: shipped, besides: item), let otherID = self.id(other) {
            var saved = overrides
            write(Combo.none, to: other)
            saved[otherID] = Combo.none
            overrides = saved
        }
        write(shipped, to: item)
        var saved = overrides
        saved[id] = nil
        overrides = saved
        changed.send(())
    }

    static var hasChanges: Bool { allItems.contains(where: isCustom) }

    static func resetAll() {
        for item in allItems { if let id = id(item), let shipped = defaults[id] { write(shipped, to: item) } }
        overrides = [:]
        changed.send(())
    }

    /// The keys to draw for a combo, modifiers first in the order macOS shows them.
    static func caps(_ combo: Combo) -> [String] {
        guard !combo.key.isEmpty else { return [] }
        var keys: [String] = []
        let m = combo.flags
        let shiftedLetter = combo.key.uppercased() == combo.key && combo.key.lowercased() != combo.key
        if m.contains(.control) { keys.append("⌃") }
        if m.contains(.option) { keys.append("⌥") }
        if m.contains(.shift) || shiftedLetter { keys.append("⇧") }
        if m.contains(.command) { keys.append("⌘") }
        keys.append(name(of: combo.key))
        return keys
    }

    static func caps(_ item: NSMenuItem) -> [String] { caps(combo(of: item)) }

    /// " (⌘S)" for a tooltip: the shortcut as it is now (set in Settings), or nothing if there isn't one.
    static func hint(for action: Selector) -> String {
        guard let item = allItems.first(where: { $0.action == action }) else { return "" }
        let keys = caps(item)
        return keys.isEmpty ? "" : " (" + keys.joined() + ")"
    }

    private static func name(of key: String) -> String {
        let special: [Int: String] = [
            NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓", NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→",
            NSDeleteCharacter: "⌫", NSDeleteFunctionKey: "⌦", NSCarriageReturnCharacter: "↩", NSTabCharacter: "⇥",
            NSHomeFunctionKey: "↖", NSEndFunctionKey: "↘", NSPageUpFunctionKey: "⇞", NSPageDownFunctionKey: "⇟",
        ]
        guard let scalar = key.unicodeScalars.first else { return key }
        if let name = special[Int(scalar.value)] { return name }
        if (NSF1FunctionKey...NSF20FunctionKey).contains(Int(scalar.value)) { return "F\(Int(scalar.value) - NSF1FunctionKey + 1)" }
        if key == " " { return "Space" }
        return key.uppercased()
    }

    /// Reads a pressed key as a shortcut. Plain keys need a modifier (other than ⇧ alone), so typing can't
    /// accidentally take over a letter; function keys and arrows may stand on their own.
    static func combo(from event: NSEvent) -> Combo? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), let scalar = chars.unicodeScalars.first else { return nil }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunction = (0xF700...0xF8FF).contains(Int(scalar.value))
        guard isFunction || !flags.subtracting(.shift).isEmpty else { return nil }
        return Combo(key: chars, modifiers: flags.rawValue)
    }
}
