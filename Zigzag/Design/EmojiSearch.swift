import CoreText
import Foundation

/// Emoji found by name, for the icon picker's field (#163): "cat" finds 🐈 and 🐱, "rocket" finds 🚀.
///
/// The names are Unicode's own (U+1F680 is ROCKET), in English whatever language Zigzag is in: the localized names
/// macOS's own picker searches aren't something an app can read. A few everyday words the names don't have ("love",
/// "happy", "lol") are added by hand. Every emoji that shows as one on the Mac is here, each in its plain form: no
/// skin tones, flags or emoji joined from several (👩‍💻), which have no name of their own to find them by.
nonisolated enum EmojiSearch {
    struct Entry: Equatable, Sendable {
        let emoji: String
        /// Lowercased, as Unicode names it: "grinning face with smiling eyes".
        let name: String
        /// The name's words, split at spaces and hyphens.
        let words: [String]
        let keywords: [String]

        init(emoji: String, name: String, keywords: [String] = []) {
            self.emoji = emoji
            self.name = name
            words = name.split { $0 == " " || $0 == "-" }.map(String.init)
            self.keywords = keywords
        }
    }

    // MARK: The index

    /// Every emoji, in Unicode's order. Slow enough (a few thousand names looked up) to make once, off the main thread.
    static func makeIndex() -> [Entry] {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        var entries: [Entry] = []
        for range in [0x00A9...0x3299, 0x1F000...0x1FAFF] {
            for value in range {
                guard let scalar = Unicode.Scalar(value), let emoji = emoji(for: scalar), draws(scalar, in: font),
                      let name = name(of: scalar) else { continue }
                entries.append(Entry(emoji: emoji, name: name, keywords: keywords[emoji] ?? []))
            }
        }
        return entries
    }

    /// The emoji a character makes on its own: itself when it shows as one (😀), with U+FE0F when it's a symbol
    /// that shows as one when asked (❤️). Never the parts others are built from: skin tones, hair, flags' letters.
    static func emoji(for scalar: Unicode.Scalar) -> String? {
        let p = scalar.properties
        guard p.isEmoji, scalar.value >= 0xA9, !p.isEmojiModifier,
              !(0x1F1E6...0x1F1FF).contains(scalar.value), !(0x1F9B0...0x1F9B3).contains(scalar.value) else { return nil }
        return p.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
    }

    /// Whether the Mac's emoji font has it: an emoji newer than this macOS would show as an empty box.
    private static func draws(_ scalar: Unicode.Scalar, in font: CTFont) -> Bool {
        let utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        // A character past U+FFFF is two UTF-16 units and gets its glyph in the first slot, 0 in the second.
        return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) && glyphs[0] != 0
    }

    /// Unicode's name, lowercased: U+1F680 → "rocket". Without the old typographers' words that say nothing about
    /// the picture ("heavy plus sign" is "plus", "thumbs up sign" is "thumbs up"), so "hea" finds hearts, not
    /// every heavy symbol.
    static func name(of scalar: Unicode.Scalar) -> String? {
        let text = NSMutableString(string: String(scalar))
        guard CFStringTransform(text, nil, kCFStringTransformToUnicodeName, false) else { return nil }
        // "\N{ROCKET}"
        let raw = text as String
        guard raw.hasPrefix("\\N{"), raw.hasSuffix("}") else { return nil }
        var words = raw.dropFirst(3).dropLast().lowercased().split(separator: " ").map(String.init)
        let plain = words.filter { $0 != "heavy" }
        if !plain.isEmpty { words = plain }
        if words.count > 1, words.last == "sign" { words.removeLast() }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Everyday words for emoji whose names don't say them.
    static let keywords: [String: [String]] = [
        "😀": ["happy", "smile"], "😃": ["happy", "smile"], "😄": ["happy", "smile"], "😊": ["happy", "smile", "blush"],
        "🙂": ["smile"], "😂": ["lol", "laugh", "funny"], "🤣": ["lol", "laugh", "rofl"], "😍": ["love", "crush"],
        "🥰": ["love"], "😘": ["kiss", "love"], "😢": ["sad", "tear"], "😭": ["sad", "sob"], "😡": ["angry", "mad"],
        "😠": ["angry", "mad"], "🤔": ["think", "hmm"], "😎": ["cool"], "😴": ["sleep", "tired"], "🤯": ["mind blown"],
        "❤️": ["love", "red heart"], "💕": ["love"], "💖": ["love"], "👍": ["yes", "like", "ok", "good"],
        "👎": ["no", "dislike", "bad"], "👌": ["ok", "okay", "perfect"], "👋": ["hi", "hello", "bye", "wave"],
        "🙏": ["please", "thanks", "pray"], "👏": ["applause", "bravo"], "💪": ["strong", "gym", "muscle"],
        "🔥": ["hot", "lit", "fire"], "✨": ["magic", "shiny"], "🎉": ["party", "celebrate"], "🎊": ["party", "celebrate"],
        "💯": ["hundred", "perfect"], "✅": ["done", "check", "yes"], "❌": ["no", "wrong"], "⭐": ["favorite"],
        "💰": ["money", "cash"], "💵": ["money", "cash", "dollar"], "💸": ["money", "spend"], "📈": ["growth", "stocks"],
        "💼": ["work", "job", "office"], "🏠": ["home"], "🏡": ["home"], "📚": ["study", "read", "school"],
        "🎓": ["school", "study", "university"], "💻": ["computer", "code", "work"], "⌨️": ["code", "type"],
        "🐛": ["bug"], "🚀": ["launch", "ship", "fast"], "🎮": ["game", "gaming"], "🎵": ["music", "song"],
        "🎶": ["music", "song"], "🍕": ["food"], "🍔": ["food", "burger"], "☕": ["coffee", "cafe"],
        "✈️": ["travel", "flight", "plane"], "🌍": ["world", "globe", "earth", "travel"], "🛒": ["shopping", "cart"],
        "📝": ["note", "write", "todo"], "📅": ["calendar", "date", "schedule"], "🔒": ["lock", "private", "secure"],
        "💡": ["idea"], "⚽": ["football", "sport"], "🏃": ["run", "sport"], "🐶": ["dog", "puppy"], "🐱": ["cat", "kitty"],
        "🌸": ["flower", "spring"], "🌙": ["night", "moon"], "☀️": ["sun", "weather"], "🎂": ["birthday", "cake"],
    ]

    // MARK: Matching

    /// The emoji that match what's typed, best first: the name itself, then a name that starts with it ("cat" →
    /// "cat face"), then one with every word in it ("face cat" → "cat face", "smil" → "smiling face"), then, for a
    /// longer word, one with it anywhere in a word ("ocket"), then the everyday words. Shorter names first among
    /// equals, then Unicode's order.
    static func search(_ query: String, in entries: [Entry]) -> [Entry] {
        let q = normalized(query)
        guard !q.isEmpty else { return [] }
        let words = q.split(separator: " ").map(String.init)
        return entries.enumerated()
            .compactMap { offset, entry in rank(entry, query: q, words: words).map { (rank: $0, offset: offset, entry: entry) } }
            .sorted { ($0.rank, $0.entry.name.count, $0.offset) < ($1.rank, $1.entry.name.count, $1.offset) }
            .map(\.entry)
    }

    /// Lowercased, trimmed, one space between words; hyphens count as spaces, as they do in names.
    static func normalized(_ text: String) -> String {
        text.lowercased().split { $0 == " " || $0 == "-" || $0.isNewline }.joined(separator: " ")
    }

    /// Lower is better; nil is no match.
    static func rank(_ entry: Entry, query q: String, words: [String]) -> Int? {
        if entry.name == q { return 0 }
        if entry.name.hasPrefix(q) { return 1 }
        if words.allSatisfy({ word in entry.words.contains { $0.hasPrefix(word) } }) { return 2 }
        // Not for "cat", which is in "identification" and "multiplication".
        if q.count >= 4, entry.name.contains(q) { return 3 }
        if entry.keywords.contains(where: { $0 == q || $0.hasPrefix(q) }) { return 4 }
        return nil
    }

    // MARK: Made once

    @MainActor private static var made: [Entry]?
    @MainActor private static var waiting: [@MainActor ([Entry]) -> Void] = []

    /// The index, made the first time it's asked for, off the main thread, and kept; `done` runs on the main thread,
    /// right away once it's made.
    @MainActor static func index(_ done: @escaping @MainActor ([Entry]) -> Void) {
        if let made { done(made); return }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        Task.detached(priority: .userInitiated) {
            let entries = makeIndex()
            await MainActor.run {
                made = entries
                let callers = waiting
                waiting = []
                callers.forEach { $0(entries) }
            }
        }
    }

    /// The index if it's been made.
    @MainActor static var madeIndex: [Entry]? { made }
}
