import Foundation
import Testing
@testable import Zigzag

/// Emoji found by name in the icon picker's field (#163): "rocket" finds 🚀, letters stay in the field as a search,
/// and an emoji typed or pasted is still the icon.
struct EmojiSearchTests {
    private static let index = EmojiSearch.makeIndex()

    // MARK: The index

    @Test func theIndexHasEveryEverydayEmojiByName() throws {
        let byEmoji = Dictionary(Self.index.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(Self.index.count > 1000)
        #expect(byEmoji["🚀"]?.name == "rocket")
        #expect(byEmoji["🐈"]?.name == "cat")
        #expect(byEmoji["😀"]?.name == "grinning face")
        // A symbol that shows as an emoji when asked is kept in that form.
        #expect(byEmoji["❤️"] != nil)
        #expect(byEmoji["☀️"] != nil)
        #expect(byEmoji["❤"] == nil)
        // One of each.
        #expect(byEmoji.count == Self.index.count)
    }

    @Test func theIndexHasOnlyWholeEmojiThatShowAsEmoji() {
        for entry in Self.index {
            #expect(IconGrid.lastEmoji(in: entry.emoji) == entry.emoji, "\(entry.name)")
            #expect(!entry.name.isEmpty && entry.name == entry.name.lowercased())
            #expect(!entry.name.contains("\\N{"))
        }
        // No skin tones, hair, flags' letters, digits or "#".
        let parts: [UInt32] = [0x1F3FB, 0x1F3FF, 0x1F9B0, 0x1F1E6, 0x1F1EF, 0x31, 0x23, 0x2A]
        for value in parts {
            #expect(EmojiSearch.emoji(for: Unicode.Scalar(value)!) == nil)
        }
        #expect(!Self.index.contains { $0.emoji.unicodeScalars.contains { $0.properties.isEmojiModifier } })
    }

    @Test func aNameIsUnicodesLowercased() {
        #expect(EmojiSearch.name(of: "🚀") == "rocket")
        // Without "heavy" and a last "sign", which say nothing about the picture.
        #expect(EmojiSearch.name(of: "👍") == "thumbs up")
        #expect(EmojiSearch.name(of: "\u{2795}") == "plus")
        #expect(EmojiSearch.name(of: "\u{2764}") == "black heart")
        #expect(EmojiSearch.emoji(for: "\u{2764}") == "❤️")
        #expect(EmojiSearch.emoji(for: "🚀") == "🚀")
    }

    // MARK: Matching

    @Test func theBestMatchesComeFirst() {
        let entries = [
            EmojiSearch.Entry(emoji: "🐯", name: "tiger face"),
            EmojiSearch.Entry(emoji: "😺", name: "smiling cat face with open mouth"),
            EmojiSearch.Entry(emoji: "🐱", name: "cat face"),
            EmojiSearch.Entry(emoji: "🐈", name: "cat"),
            EmojiSearch.Entry(emoji: "🛒", name: "shopping trolley", keywords: ["cart"]),
            EmojiSearch.Entry(emoji: "🦆", name: "duck"),
        ]
        func found(_ query: String) -> [String] { EmojiSearch.search(query, in: entries).map(\.emoji) }
        // The name itself, then a name that starts with it, then a word in it, then the everyday words.
        #expect(found("cat") == ["🐈", "🐱", "😺"])
        #expect(found("ca") == ["🐈", "🐱", "😺", "🛒"])
        // Any case, extra spaces, words in any order.
        #expect(found("  Face   CAT ") == ["🐱", "😺"])
        #expect(found("smil") == ["😺"])
        // Inside a word, once it's long enough to mean something.
        #expect(found("olley") == ["🛒"])
        #expect(found("uck").isEmpty)
        #expect(found("zebra").isEmpty)
        #expect(found("   ").isEmpty)
    }

    @Test func typingANameFindsItsEmoji() {
        func first(_ query: String) -> String? { EmojiSearch.search(query, in: Self.index).first?.emoji }
        #expect(first("rocket") == "🚀")
        #expect(first("cat") == "🐈")
        #expect(!EmojiSearch.search("cat", in: Self.index).contains { $0.emoji == "🪪" })
        #expect(first("thumbs up") == "👍")
        #expect(first("pizza") == "🍕")
        #expect(EmojiSearch.search("love", in: Self.index).contains { $0.emoji == "❤️" })
        #expect(!EmojiSearch.search("a", in: Self.index).isEmpty)
        #expect(EmojiSearch.search("qqzzx", in: Self.index).isEmpty)
    }

    // MARK: The field

    @Test func lettersAreASearchAndAnEmojiIsTheIcon() {
        #expect(IconGrid.fieldState("", shown: nil) == .empty)
        #expect(IconGrid.fieldState("", shown: "🍕") == .empty)
        // Letters stay, as a search.
        #expect(IconGrid.fieldState("a", shown: nil) == .search("a"))
        #expect(IconGrid.fieldState("red heart", shown: nil) == .search("red heart"))
        #expect(IconGrid.fieldState("1", shown: nil) == .search("1"))
        // An emoji typed or pasted is the icon, as before, even among words.
        #expect(IconGrid.fieldState("🚀", shown: nil) == .emoji("🚀"))
        #expect(IconGrid.fieldState("I love 🍕", shown: nil) == .emoji("🍕"))
        #expect(IconGrid.fieldState("🍕🚀", shown: "🍕") == .emoji("🚀"))
        #expect(IconGrid.fieldState("❤️", shown: nil) == .emoji("❤️"))
        // Letters typed beside the emoji the field shows start a search in its place.
        #expect(IconGrid.fieldState("🍕d", shown: "🍕") == .search("d"))
        #expect(IconGrid.fieldState("c🍕", shown: "🍕") == .search("c"))
        #expect(IconGrid.fieldState("🍕", shown: "🍕") == .emoji("🍕"))
    }

    @Test @MainActor func aSearchShowsMatchesAndEscGoesBack() async throws {
        let grid = IconGrid(noneSymbol: "circle.dashed", selected: "🍕")
        var picked: [String?] = []
        grid.onPick = { picked.append($0) }
        _ = await withCheckedContinuation { done in EmojiSearch.index { done.resume(returning: $0) } }
        grid.type("🍕rocket")
        #expect(grid.query == "rocket")
        #expect(grid.results.first?.emoji == "🚀")
        // Searching changes nothing yet.
        #expect(grid.selected == "🍕")
        #expect(picked.isEmpty)
        // Esc: back to the icon.
        #expect(grid.endSearch())
        #expect(grid.query == nil && grid.results.isEmpty)
        #expect(!grid.endSearch())
        // Return picks the best match.
        grid.type("🍕rocket")
        #expect(grid.pickFirstResult())
        #expect(grid.selected == "🚀" && picked == ["🚀"])
        #expect(grid.query == nil)
        // A search emptied isn't the emoji deleted; the emoji deleted is.
        grid.type("🚀x")
        grid.type("")
        #expect(grid.selected == "🚀")
        grid.type("🚀")
        grid.type("")
        #expect(grid.selected == nil && picked == ["🚀", "🚀", nil])
    }
}
