import Foundation
import Testing
@testable import Zigzag

/// Every word Zigzag says goes through the string catalog, so it can be translated, and English reads exactly as it
/// did before. These read the built app's own catalog and the app's source; none of them opens the library.
struct LocalizationTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The app's English, as String(localized:) finds it: the catalog's English, else the key itself.
    private static func english(_ key: String, _ value: String? = nil) -> String {
        let bundle = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? .main
        return bundle.localizedString(forKey: key, value: value, table: nil)
    }

    /// A handful of strings from around the app read the same English as before the catalog.
    @Test func englishIsUnchanged() {
        #expect(Self.english("New Tab") == "New Tab")
        #expect(Self.english("Import from Another Browser…") == "Import from Another Browser…")
        #expect(Self.english("Back to Pinned Page") == "Back to Pinned Page")
        #expect(Self.english("key.space-bar", "Space") == "Space")
        #expect(String(format: Self.english("%@ (%@)"), "Reload", "⌘R") == "Reload (⌘R)")
        #expect(SaveFailure.message("Couldn’t save the page", CocoaError(.fileWriteOutOfSpace))
                == "Couldn’t save the page. Not enough space on your Mac.")
    }

    /// Counts read in the singular for one, from the catalog's plural forms, as the code's own ternaries did.
    @Test func pluralsReadAsBefore() {
        func count(_ key: String, _ n: Int) -> String { String.localizedStringWithFormat(Self.english(key), n) }
        #expect(count("%lld tabs", 1) == "1 tab")
        #expect(count("%lld tabs", 3) == "3 tabs")
        #expect(count("Close %lld Tabs", 1) == "Close Tab")
        #expect(count("Close %lld Tabs", 2) == "Close 2 Tabs")
        #expect(count("Closed %lld tabs", 1) == "Closed 1 tab")
        #expect(String.localizedStringWithFormat(Self.english("Updated %lld passwords from %@."), 1, "Chrome")
                == "Updated 1 password from Chrome.")
        #expect(String.localizedStringWithFormat(Self.english("Read and change what you see on %@ and %lld other sites"), "github.com", 1)
                == "Read and change what you see on github.com and 1 other site")
        // Every plural form the catalog keeps reaches the built app.
        let plurals = Self.catalogPlurals()
        #expect(plurals.count > 30)
        for (key, forms) in plurals {
            if let one = forms["one"] { #expect(count(key, 1) == String.localizedStringWithFormat(one, 1), "\(key) for 1") }
            if let other = forms["other"] { #expect(count(key, 3) == String.localizedStringWithFormat(other, 3), "\(key) for 3") }
        }
    }

    /// The catalog holds what the code says: a key the code no longer uses is stale, and one that isn't in the
    /// catalog yet means scripts/sync-strings.sh wasn't run after the change.
    @Test func catalogIsInStep() throws {
        let strings = try Self.catalog()
        #expect(strings.count > 1000)
        let stale = strings.filter { (($0.value as? [String: Any])?["extractionState"] as? String) == "stale" }.map(\.key)
        #expect(stale.isEmpty, "Stale in the catalog, run scripts/sync-strings.sh: \(stale.sorted().prefix(20))")
    }

    /// No control, menu item, tooltip or accessibility label is set from a bare English literal: each goes through
    /// String(localized:). Debug-only code is left out.
    @Test func noBareStringsInControls() {
        let pattern = try! NSRegularExpression(pattern: #"(?:toolTip\s*[:=]|setAccessibilityLabel\(|setAccessibilityValue\(|setAccessibilityHelp\(|NSMenuItem\(title:|NSMenu\(title:|\.stringValue\s*=|placeholderString\s*=|messageText\s*=|informativeText\s*=|PillButton\(title:|TextButton\(title:|confirmTitle:|alternateTitle:|allowTitle:|denyTitle:|SidebarMenus\.Item\(|\bItem\(title:|\bItem\(|\bitem\(|FormRow\(title:|addButton\(withTitle:|setActionName\()\s*"([A-Z][^"\\]*[a-z][^"\\]*)""#)
        let root = Self.repo.appendingPathComponent("Zigzag")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        var found: [String] = []
        for url in files where url.pathExtension == "swift" && !["DebugBridge.swift", "MaterialsShowcase.swift"].contains(url.lastPathComponent) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // How deep inside #if DEBUG this line is.
            var debug = 0
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if") { if debug > 0 || trimmed.contains("DEBUG") { debug += 1 }; continue }
                if trimmed.hasPrefix("#endif") { if debug > 0 { debug -= 1 }; continue }
                guard debug == 0, !trimmed.hasPrefix("//") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line) else { continue }
                    // A brand on its own ("Zigzag") is the same in every language.
                    if ["Zigzag", "Zigzag Dev"].contains(String(line[r])) { continue }
                    found.append("\(url.lastPathComponent):\(i + 1) “\(line[r])”")
                }
            }
        }
        #expect(found.isEmpty, "Not localizable:\n\(found.joined(separator: "\n"))")
    }

    private static func catalog() throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appendingPathComponent("Zigzag/Resources/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    /// The English plural forms the catalog keeps, by key: ["%lld tabs": ["one": "%lld tab", "other": "%lld tabs"]].
    private static func catalogPlurals() -> [String: [String: String]] {
        var plurals: [String: [String: String]] = [:]
        for (key, entry) in (try? catalog()) ?? [:] {
            let en = ((entry as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any]
            guard let forms = (en?["variations"] as? [String: Any])?["plural"] as? [String: Any] else { continue }
            plurals[key] = forms.compactMapValues { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        return plurals
    }
}
