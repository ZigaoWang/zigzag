import Foundation
import Testing

/// Zigzag names its controls in title case, as a Mac app does, and never sets type in small caps or forced lowercase.
/// These read the app's own source, so a new button or menu item that slips gets caught here rather than by a friend.
struct CapitalizationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Zigzag")

    private static var sources: [(path: String, lines: [String])] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "swift" }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0.components(separatedBy: "\n")) }
        }
    }

    /// Words that stay lowercase inside a title ("Open in New Tab", "Close Tabs to the Right").
    private static let small: Set<String> = ["a", "an", "the", "and", "or", "but", "nor", "of", "in", "on", "to", "for", "with",
                                             "at", "by", "from", "as", "via", "vs", "into", "per"]

    /// The first lowercase word that should be capitalized, if any. Inserted values count as capitalized.
    static func lowercaseWord(in title: String) -> String? {
        let plain = title.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "X", options: .regularExpression)
        for (i, word) in plain.split(separator: " ").enumerated() {
            let core = word.trimmingCharacters(in: CharacterSet.letters.inverted)
            guard let first = core.first, first.isLetter, first.isLowercase else { continue }
            // A domain or a file name ("zigzagbrowser.com") is written as it is.
            if word.contains(".") && !word.hasSuffix(".") || word.contains("@") { continue }
            if i > 0 && small.contains(core) { continue }
            return String(core)
        }
        return nil
    }

    @Test func ruleReadsTitles() {
        #expect(Self.lowercaseWord(in: "Open in New Tab") == nil)
        #expect(Self.lowercaseWord(in: "Close \\(count) Tabs") == nil)
        #expect(Self.lowercaseWord(in: "Remove from Zigzag…") == nil)
        #expect(Self.lowercaseWord(in: "Open zigzagbrowser.com") == nil)
        #expect(Self.lowercaseWord(in: "Copy link") == "link")
        #expect(Self.lowercaseWord(in: "in Folder") == "in")
    }

    /// Buttons, menu items, a sheet's answers and an icon button's name: each in title case.
    @Test func controlsAreTitleCase() {
        let pattern = try! NSRegularExpression(pattern: #"(?:PillButton\(title:|TextButton\(title:|confirmTitle:|alternateTitle:|allowTitle:|denyTitle:|toolTip:|SidebarMenus\.Item\(|\bitem\(|Item\(title:)\s*"((?:[^"\\]|\\.)*)""#)
        var found: [String] = []
        for (path, lines) in Self.sources {
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line) else { continue }
                    let title = String(line[r])
                    if let word = Self.lowercaseWord(in: title) { found.append("\(path):\(i + 1) “\(title)” (\(word))") }
                }
            }
        }
        #expect(found.isEmpty, "Not in title case:\n\(found.joined(separator: "\n"))")
    }

    /// No small caps and no forced case, in the app's own drawing or in its pages' styles.
    @Test func noForcedCase() {
        let banned = ["text-transform: lowercase", "text-transform: uppercase", "small-caps", "font-variant-caps", "lowercaseSmallCaps",
                      "upperCaseSmallCaps", "lowerCaseSmallCaps"]
        var found: [String] = []
        for (path, lines) in Self.sources {
            for (i, line) in lines.enumerated() where banned.contains(where: line.contains) { found.append("\(path):\(i + 1)") }
        }
        #expect(found.isEmpty, "Forced case or small caps:\n\(found.joined(separator: "\n"))")
    }
}
