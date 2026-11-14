import AppKit
import WebKit

/// A key press_key presses: which key, with which modifiers, and the key event macOS would make for it on a US
/// keyboard. Plain data, read and checked on the network's queue.
nonisolated struct MCPKeyPress: Equatable, Sendable {
    enum Modifier: String, CaseIterable, Sendable {
        case shift, alt, ctrl, meta
    }

    /// The key as the page names it (`KeyboardEvent.key`): "Enter", "Tab", "a".
    let key: String
    /// In the order of `Modifier.allCases`.
    let modifiers: [Modifier]
    /// What the key event carries, as macOS gives it.
    let characters: String
    let charactersIgnoringModifiers: String
    let keyCode: UInt16
    /// One of the keys that move or select rather than type (arrows, Home, Page Down, forward Delete).
    let isFunctionKey: Bool

    /// How it reads back: "Shift+Tab", "Meta+a".
    var name: String {
        let names: [Modifier: String] = [.shift: "Shift", .alt: "Alt", .ctrl: "Ctrl", .meta: "Meta"]
        return (modifiers.compactMap { names[$0] } + [key == " " ? "Space" : key]).joined(separator: "+")
    }

    /// Changes what's in a field: a character, Space, Backspace or Delete. Never pressed in a password field.
    var editsText: Bool { key.count == 1 || ["Backspace", "Delete"].contains(key) }

    /// May submit a form or follow a link, so a page load is waited for after it.
    var mayNavigate: Bool { ["Enter", " "].contains(key) }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.alt) { flags.insert(.option) }
        if modifiers.contains(.ctrl) { flags.insert(.control) }
        if modifiers.contains(.meta) { flags.insert(.command) }
        if isFunctionKey { flags.insert(.function) }
        if key.hasPrefix("Arrow") { flags.insert(.numericPad) }
        return flags
    }

    private struct Named {
        let key: String, code: UInt16, characters: String, function: Bool
    }

    private static func function(_ scalar: Int) -> String { String(UnicodeScalar(UInt32(scalar)).map(Character.init) ?? " ") }

    private static let named: [String: Named] = {
        let keys = [
            Named(key: "Enter", code: 36, characters: "\r", function: false),
            Named(key: "Escape", code: 53, characters: "\u{1b}", function: false),
            Named(key: "Tab", code: 48, characters: "\t", function: false),
            Named(key: "Backspace", code: 51, characters: "\u{7f}", function: false),
            Named(key: "Delete", code: 117, characters: function(NSDeleteFunctionKey), function: true),
            Named(key: "ArrowUp", code: 126, characters: function(NSUpArrowFunctionKey), function: true),
            Named(key: "ArrowDown", code: 125, characters: function(NSDownArrowFunctionKey), function: true),
            Named(key: "ArrowLeft", code: 123, characters: function(NSLeftArrowFunctionKey), function: true),
            Named(key: "ArrowRight", code: 124, characters: function(NSRightArrowFunctionKey), function: true),
            Named(key: "Home", code: 115, characters: function(NSHomeFunctionKey), function: true),
            Named(key: "End", code: 119, characters: function(NSEndFunctionKey), function: true),
            Named(key: "PageUp", code: 116, characters: function(NSPageUpFunctionKey), function: true),
            Named(key: "PageDown", code: 121, characters: function(NSPageDownFunctionKey), function: true),
            Named(key: " ", code: 49, characters: " ", function: false),
        ]
        var table = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.lowercased(), $0) })
        for (alias, key) in ["return": "enter", "esc": "escape", "up": "arrowup", "down": "arrowdown", "left": "arrowleft",
                             "right": "arrowright", "space": " ", "spacebar": " ", "del": "delete", "pgup": "pageup", "pgdn": "pagedown"] {
            table[alias] = table[key]
        }
        return table
    }()

    /// The US keyboard's key codes, for the characters it has a key for.
    private static let keyCodes: [Character: UInt16] = {
        let rows: [(String, [UInt16])] = [
            ("asdfhgzxcv", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), ("bqweryt", [11, 12, 13, 14, 15, 16, 17]),
            ("123465=97-80]ou[ip", [18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35]),
            ("lj'k;\\,/nm.`", [37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50]),
        ]
        var table: [Character: UInt16] = [:]
        for (characters, codes) in rows { for (character, code) in zip(characters, codes) { table[character] = code } }
        // The same keys with Shift.
        for (shifted, plain) in zip("!@#$%^&*()_+{}|:\"<>?~", "1234567890-=[]\\;',./`") { table[shifted] = table[plain] }
        return table
    }()

    static func parse(_ text: String, modifiers given: [String]) -> Result<MCPKeyPress, MCPArgumentError> {
        let aliases: [String: Modifier] = ["shift": .shift, "alt": .alt, "option": .alt, "opt": .alt, "ctrl": .ctrl, "control": .ctrl,
                                           "meta": .meta, "cmd": .meta, "command": .meta]
        var modifiers = Set<Modifier>()
        for name in given {
            guard let modifier = aliases[name.trimmingCharacters(in: .whitespaces).lowercased()] else {
                return .failure(.init("\(name) isn't a modifier. Use shift, alt, ctrl or meta."))
            }
            modifiers.insert(modifier)
        }
        // "Shift+Tab", "Meta+a", and "+" or "Shift++" for the plus key itself.
        var keyPart = text
        if text.count > 1, text.contains("+") {
            var parts = text.components(separatedBy: "+")
            if text.hasSuffix("++") {
                parts.removeLast(2)
                keyPart = "+"
            } else {
                keyPart = parts.removeLast()
            }
            for part in parts {
                guard let modifier = aliases[part.trimmingCharacters(in: .whitespaces).lowercased()] else {
                    return .failure(.init("\(part) in \(text) isn't a modifier. Use Shift, Alt, Ctrl or Meta, like Shift+Tab."))
                }
                modifiers.insert(modifier)
            }
        }
        let ordered = Modifier.allCases.filter(modifiers.contains)
        if let named = named[keyPart == " " ? " " : keyPart.trimmingCharacters(in: .whitespaces).lowercased()] {
            var characters = named.characters
            // Shift-Tab is a back tab, as macOS has it.
            if named.key == "Tab", modifiers.contains(.shift) { characters = "\u{19}" }
            return .success(MCPKeyPress(key: named.key, modifiers: ordered, characters: characters, charactersIgnoringModifiers: named.characters,
                                        keyCode: named.code, isFunctionKey: named.function))
        }
        guard keyPart.count == 1, let character = keyPart.first else {
            return .failure(.init("\(text) isn't a key press_key knows. Use Enter, Escape, Tab, Backspace, Delete, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown, Space, or one character."))
        }
        guard !character.isNewline, character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.init("Give Enter, Tab or Escape by name, not as a character."))
        }
        var mods = modifiers
        var shown = String(character)
        // A capital letter is typed with Shift; with Shift, a letter comes out capital.
        if character.isLetter, character.isUppercase { mods.insert(.shift) }
        if mods.contains(.shift), character.isLetter { shown = shown.uppercased() }
        var characters = shown
        // Control and a letter make the letter's control character, as macOS has it.
        if mods.contains(.ctrl), let ascii = shown.lowercased().unicodeScalars.first, ascii.isASCII, ("a"..."z").contains(Character(ascii)) {
            characters = String(UnicodeScalar(UInt8(ascii.value - 96)))
        }
        let code = keyCodes[Character(shown.lowercased())] ?? 0x7F
        return .success(MCPKeyPress(key: shown, modifiers: Modifier.allCases.filter(mods.contains), characters: characters,
                                    charactersIgnoringModifiers: shown, keyCode: code, isFunctionKey: false))
    }
}

/// Presses keys in a page as the keyboard would: real key events handed to the tab's web view, so the page gets
/// trusted events and WebKit does what the key does (Enter submits, Tab moves the focus, the caret moves). It
/// works the same in a window behind others or a tab that isn't showing. A key the page doesn't take comes back
/// from WebKit to the app, as keys do, on its way to the menus: `ZigzagApplication` stops it there, so it never
/// runs a Zigzag shortcut, closes a tab or reaches another view.
@MainActor
enum MCPKeyDelivery {
    private struct Sent {
        let event: NSEvent
        let at: Date
    }

    private static var sent: [Sent] = []
    /// Keys stopped on their way back to the app, for tests.
    private(set) static var stopped = 0

    /// One of the events press_key made: never to be handled outside the page.
    static func isAgentEvent(_ event: NSEvent) -> Bool {
        guard !sent.isEmpty, event.type == .keyDown || event.type == .keyUp else { return false }
        return sent.contains { $0.event === event || ($0.event.type == event.type && $0.event.timestamp == event.timestamp && $0.event.keyCode == event.keyCode) }
    }

    /// Called from `ZigzagApplication.sendEvent`: true when the event is press_key's and must go no further.
    static func stopsOnTheWayBack(_ event: NSEvent) -> Bool {
        guard isAgentEvent(event) else { return false }
        stopped += 1
        return true
    }

    static func events(for press: MCPKeyPress, window: NSWindow?) -> [NSEvent] {
        // A time of its own, a little after now, so each event can be told apart even if WebKit copies it.
        let time = ProcessInfo.processInfo.systemUptime + Double.random(in: 0.000_001...0.000_999)
        return [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: press.modifierFlags, timestamp: time, windowNumber: window?.windowNumber ?? 0,
                             context: nil, characters: press.characters, charactersIgnoringModifiers: press.charactersIgnoringModifiers,
                             isARepeat: false, keyCode: press.keyCode)
        }
    }

    /// Presses the key in the web view. Its answer, the element with the focus after it (or null), comes once the
    /// page has had the key up, or after a moment if the page kept that from Zigzag's own listener.
    static func press(_ press: MCPKeyPress, in webView: WKWebView) async -> JSON {
        let now = Date()
        sent.removeAll { now.timeIntervalSince($0.at) > 30 }
        let events = events(for: press, window: webView.window)
        sent += events.map { Sent(event: $0, at: now) }
        return await withCheckedContinuation { continuation in
            var answered = false
            func answer(_ value: JSON) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: value)
            }
            // Asked for before the keys go, so the page is listening when they come.
            MCPPageScript.start("awaitKey", ["key": press.key], in: webView) { result in
                answer((try? result.get())?["focused"].flatMap { JSON(foundation: $0) } ?? .null)
            }
            for event in events {
                if event.type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { answer(.null) }
        }
    }
}
