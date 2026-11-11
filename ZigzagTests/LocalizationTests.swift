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
        #expect(plurals.count > 25)
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

    // MARK: Simplified Chinese

    /// The built app's Chinese, as String(localized:) finds it when Zigzag runs in Simplified Chinese.
    private static func chinese(_ key: String) -> String {
        let bundle = Bundle(path: Bundle.main.path(forResource: "zh-Hans", ofType: "lproj") ?? "") ?? .main
        return bundle.localizedString(forKey: key, value: "⟨missing⟩", table: nil)
    }

    /// Every string, and every plural form, has its Chinese, and none is empty.
    @Test func everyStringHasChinese() throws {
        var missing: [String] = []
        for (key, entry) in try Self.catalog() {
            let forms = Self.forms(entry, "zh-Hans")
            let state = ((((entry as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any])?["state"] as? String
            if forms.isEmpty || forms.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) || (state != nil && state != "translated") {
                missing.append(key)
            }
        }
        #expect(missing.isEmpty, "No Chinese for: \(missing.sorted().prefix(20))")
        #expect(Bundle.main.localizations.contains("zh-Hans"))
    }

    /// Each Chinese string takes the same arguments as its English, of the same types, so a translation that
    /// reorders them can't read the wrong one or crash.
    @Test func chineseKeepsTheFormatSpecifiers() throws {
        var wrong: [String] = []
        for (key, entry) in try Self.catalog() {
            let english = Self.forms(entry, "en")
            let chinese = Self.forms(entry, "zh-Hans")
            guard let zh = chinese.first else { continue }
            let en = english.first ?? key
            if Self.arguments(en, entry, "en") != Self.arguments(zh, entry, "zh-Hans") { wrong.append("\(key) → \(zh)") }
        }
        #expect(wrong.isEmpty, "Arguments differ:\n\(wrong.joined(separator: "\n"))")
    }

    /// The glossary's words, everywhere: one English term is one Chinese term, and the words Zigzag decided
    /// against never come back.
    @Test func chineseFollowsTheGlossary() throws {
        let terms: [(english: String, chinese: String)] = [
            (#"\bSpaces?\b"#, "空间"), ("Favorite", "收藏"), (#"\bPeek\b"#, "速览"), ("[Cc]ommand bar", "命令栏"),
            ("[Ss]idebar", "边栏"), (#"\bShare"#, "共享"), (#"\bReload"#, "重新载入"), ("Private [Ww]indow", "无痕浏览窗口"),
            (#"\bReader\b"#, "阅读器"), ("Split View", "分屏浏览"), ("[Ss]ign-ins", "登录状态"), (#"\bArchive"#, "归档"),
            (#"\b[Pp]rofiles?\b"#, "个人资料"),
        ]
        let avoided = ["您", "侧边栏", "分享", "刷新", "工作区", "隐私浏览", "扩展程序", "描述文件"]
        var off: [String] = []
        for (key, entry) in try Self.catalog() where key != "key.space-bar" {
            guard let zh = Self.forms(entry, "zh-Hans").first else { continue }
            let en = Self.forms(entry, "en").first ?? key
            for term in terms where en.range(of: term.english, options: .regularExpression) != nil && !zh.contains(term.chinese) {
                off.append("\(en) → \(zh), wants \(term.chinese)")
            }
            for word in avoided where zh.contains(word) { off.append("\(zh) says \(word)") }
            // Full-width punctuation in Chinese sentences: no half-width comma or full stop beside a Chinese word.
            if zh.range(of: #"\p{Han}[,.;:?!]\s|\p{Han}[,;?!]"#, options: .regularExpression) != nil { off.append("\(zh): half-width punctuation") }
        }
        #expect(off.isEmpty, "\(off.joined(separator: "\n"))")
    }

    /// The built app speaks Chinese, counts included: Chinese has one plural form, used for one as for many.
    @Test func chineseReachesTheApp() {
        #expect(Self.chinese("New Tab") == "新建标签页")
        #expect(Self.chinese("Reopen Closed Tab") == "重新打开已关闭的标签页")
        #expect(Self.chinese("key.space-bar") == "空格键")
        func count(_ key: String, _ n: Int) -> String { String.localizedStringWithFormat(Self.chinese(key), n) }
        #expect(count("%lld tabs", 3) == "3 个标签页")
        #expect(count("Close %lld Tabs", 2) == "关闭 2 个标签页")
        #expect(String.localizedStringWithFormat(Self.chinese("Updated %lld passwords from %@."), 5, "Chrome") == "已从 Chrome 更新 5 个密码。")
        #expect(String(format: Self.chinese("%@ (%@)"), "重新载入", "⌘R") == "重新载入（⌘R）")
    }

    /// A catalog entry's strings in one language: its single string, or each plural form and substitution.
    private static func forms(_ entry: Any, _ language: String) -> [String] {
        guard let unit = ((entry as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any] else { return [] }
        func value(_ any: Any?) -> String? { ((any as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        var forms: [String] = []
        if let main = value(unit) { forms.append(main) }
        if let plural = (unit["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            forms += ["other", "one", "zero", "few", "many", "two"].compactMap { plural[$0] }.compactMap(value)
        }
        for case let sub as [String: Any] in (unit["substitutions"] as? [String: Any])?.values.map({ $0 }) ?? [] {
            let plural = (sub["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
            forms += plural.values.compactMap(value)
        }
        return forms
    }

    /// The arguments a format reads, as argument number and type: "%2$@ has %lld" reads [1: lld, 2: @].
    private static func arguments(_ format: String, _ entry: Any, _ language: String) -> [Int: String] {
        let unit = ((entry as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any]
        let subs = unit?["substitutions"] as? [String: Any] ?? [:]
        let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(#@\w+@|[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaFi]|%)"#)
        var arguments: [Int: String] = [:]
        var next = 0
        for match in pattern.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            let type = String(format[Range(match.range(at: 2), in: format)!])
            guard type != "%" else { continue }
            next += 1
            let position = Range(match.range(at: 1), in: format).flatMap { Int(format[$0]) } ?? next
            if type.hasPrefix("#@") {
                let sub = subs[String(type.dropFirst(2).dropLast())] as? [String: Any]
                arguments[sub?["argNum"] as? Int ?? position] = sub?["formatSpecifier"] as? String
            } else {
                arguments[position] = type.hasSuffix("lld") ? "lld" : String(type.suffix(1))
            }
        }
        return arguments
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
