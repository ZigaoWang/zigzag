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

    /// Both Chinese localizations separate Chinese from Latin letters and digits. Placeholders are skipped.
    @Test(arguments: ["zh-Hans", "zh-Hant"]) func chineseSpacesLatinAndDigits(_ language: String) throws {
        let strings = try Self.catalog()
        let gap = try NSRegularExpression(pattern: #"[\u4E00-\u9FFF][A-Za-z0-9]|[A-Za-z0-9][\u4E00-\u9FFF]"#)
        let placeholder = try NSRegularExpression(pattern: #"%(\d+\$)?(lld|ld|d|@|f|\.\d+f|#@[A-Za-z]+@)"#)
        func values(_ any: Any?) -> [String] {
            guard let dict = any as? [String: Any] else { return [] }
            var out: [String] = []
            if let unit = dict["stringUnit"] as? [String: Any], let value = unit["value"] as? String { out.append(value) }
            for (_, nested) in dict where nested is [String: Any] { out += values(nested) }
            return out
        }
        var missing: [String] = []
        for (_, entry) in strings {
            let zh = ((entry as? [String: Any])?["localizations"] as? [String: Any])?[language]
            for value in values(zh) {
                let plain = placeholder.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "§")
                if gap.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil { missing.append(value) }
            }
        }
        #expect(missing.isEmpty, "Chinese without a space beside Latin letters or digits: \(missing.prefix(10))")
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

    /// Sentences join per language: no space after a full-width stop, one after an English one.
    @MainActor @Test func sentencesJoinWithoutASpaceAfterAFullWidthStop() {
        #expect(Words.sentences("图片和视频保持原样。", "使用 Dark Reader。") == "图片和视频保持原样。使用 Dark Reader。")
        #expect(Words.sentences("绝不替你同意！", "使用 Autoconsent。") == "绝不替你同意！使用 Autoconsent。")
        #expect(Words.sentences("Never says yes.", "Uses Autoconsent.") == "Never says yes. Uses Autoconsent.")
        #expect(Words.sentences("", "Uses Autoconsent.") == "Uses Autoconsent.")
        #expect(Words.sentences("Never says yes.", nil) == "Never says yes.")
        // After an English closing quote the space stays, unless a full-width stop is inside it.
        #expect(Words.sentences("It says “Allow.”", "Then reload.") == "It says “Allow.” Then reload.")
        #expect(Words.sentences("它说“允许。”", "然后重新载入。") == "它说“允许。”然后重新载入。")
        #expect(Words.sentences("它顯示「已允許。」", "接著重新載入。") == "它顯示「已允許。」接著重新載入。")
    }

    /// Localized sentences are never joined with a literal space; use `Words.sentences`.
    @Test func noSentencesGluedWithASpace() {
        let pattern = try! NSRegularExpression(pattern: #"\+\s*" "\s*\+\s*String\(localized:"#)
        let root = Self.repo.appendingPathComponent("Zigzag")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        var found: [String] = []
        for url in files where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                found.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(found.isEmpty, "Use Words.sentences:\n\(found.joined(separator: "\n"))")
    }

    @Test func onlyEnglishLimitNamesLowercaseForASubsequentListItem() {
        #expect(Words.lowercasedForList("Cookie partition details") == "cookie partition details")
        #expect(Words.lowercasedForList("Cookie 分区详情") == "Cookie 分区详情")
        #expect(Words.lowercasedForList("Détails des cookies") == "Détails des cookies")
        #expect(Words.lowercasedForList("") == "")
    }

    // MARK: Chinese localizations

    private static func chinese(_ key: String, language: String = "zh-Hans") -> String {
        let bundle = Bundle(path: Bundle.main.path(forResource: language, ofType: "lproj") ?? "") ?? .main
        return bundle.localizedString(forKey: key, value: "⟨missing⟩", table: nil)
    }

    /// Simplified Chinese is required; missing Traditional Chinese strings use the English source.
    @Test func everyStringHasChinese() throws {
        let language = "zh-Hans"
        func translated(_ node: [String: Any]) -> Bool {
            if let unit = node["stringUnit"] as? [String: Any] {
                guard unit["state"] as? String == "translated", let value = unit["value"] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            }
            return node.values.compactMap { $0 as? [String: Any] }.allSatisfy(translated)
        }
        for name in ["Localizable", "InfoPlist"] {
            let strings = try Self.catalog(name)
            #expect(!strings.isEmpty)
            let missing = strings.compactMap { key, entry -> String? in
                guard let units = (entry as? [String: Any])?["localizations"] as? [String: Any],
                      let unit = units[language] as? [String: Any],
                      !Self.forms(entry, language).isEmpty, translated(unit) else { return key }
                return nil
            }
            #expect(missing.isEmpty, "\(name) has no \(language) for: \(missing.sorted().prefix(20))")
        }
        #expect(Bundle.main.localizations.contains(language))
    }

    /// Each Chinese string takes the same arguments as its English, of the same types, so a translation that
    /// reorders them can't read the wrong one or crash.
    @Test(arguments: ["zh-Hans", "zh-Hant", "ja"]) func chineseKeepsTheFormatSpecifiers(_ language: String) throws {
        var wrong: [String] = []
        for (key, entry) in try Self.catalog() {
            let en = Self.forms(entry, "en").first ?? key
            let expected = Self.arguments(en, entry, "en")
            let forms = Self.forms(entry, language, includeSubstitutions: false)
            // An untranslated entry is left to the English source, including any substitutions.
            let locales = (entry as? [String: Any])?["localizations"] as? [String: [String: Any]]
            guard let localization = locales?[language] else { continue }
            for zh in forms where Self.arguments(zh, entry, language) != expected {
                wrong.append("\(key) → \(zh)")
            }
            // Each substitution has its own argument specifier and plural forms, independent of the outer format.
            let source = locales?["en"]?["substitutions"] as? [String: [String: Any]] ?? [:]
            let translated = localization["substitutions"] as? [String: [String: Any]] ?? [:]
            for (name, sub) in source {
                let format = sub["formatSpecifier"] as? String
                let plural = (translated[name]?["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
                if format == nil || translated[name]?["formatSpecifier"] as? String != format
                    || translated[name]?["argNum"] as? Int != sub["argNum"] as? Int
                    || plural?["other"] == nil {
                    wrong.append("\(key) → \(name)")
                }
            }
        }
        #expect(wrong.isEmpty, "Arguments differ:\n\(wrong.joined(separator: "\n"))")
    }

    /// The Simplified Chinese glossary's words, everywhere: one English term is one Chinese term, and the words Zigzag decided
    /// against never come back.
    @Test func chineseFollowsTheGlossary() throws {
        let terms: [(english: String, chinese: String)] = [
            (#"\bSpaces?\b"#, "空间"), ("Favorite", "收藏"), (#"\bPeek\b"#, "速览"), ("[Cc]ommand bar", "命令栏"),
            ("[Ss]idebar", "边栏"), (#"\bShare"#, "共享"), (#"\bReload"#, "重新载入"), ("Private [Ww]indow", "无痕浏览窗口"),
            // Zigzag's Reader, not Dark Reader, whose name stays as it is.
            (#"(?<!Dark )\bReader\b"#, "阅读器"), ("Split View", "分屏浏览"), ("[Ss]ign-ins", "登录状态"), (#"\bArchive"#, "归档"),
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

    @MainActor @Test func traditionalChineseReachesTheApp() throws {
        let language = "zh-Hant"
        let folder = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: folder))
        #expect(AppLanguage.choices.contains { $0.code == language && $0.title == "繁體中文" })
        #expect(Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["zh-Hant"]).first == language)
        #expect(Self.chinese("New Tab", language: language) == "新增分頁")
        #expect(Self.chinese("New Private Window", language: language) == "新增私密瀏覽視窗")
        #expect(Self.chinese("key.space-bar", language: language) == "空白鍵")
        #expect(String.localizedStringWithFormat(Self.chinese("%lld tabs", language: language), 3) == "3 個分頁")
        let updated = Self.chinese("Updated %lld passwords from %@.", language: language)
        #expect(String.localizedStringWithFormat(updated, 5, "Chrome") == "已從 Chrome 更新 5 個密碼。")
        #expect(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
                == "你造訪的網站可以要求使用你的相機。")
        for mac in ["zh-TW", "zh-HK", "zh-Hant-MO"] {
            #expect(Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: [mac]).first == language, "\(mac)")
        }
        #expect(Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["zh-CN"]).first == "zh-Hans")
    }

    /// A string with no Traditional Chinese or Japanese yet reads in English, never as a raw key: a key that isn't
    /// English text carries its English in the code, and an entry that is there is complete.
    @Test(arguments: ["zh-Hant", "ja"]) func optionalLanguagesFallBackToEnglish(_ language: String) throws {
        let identifier = try NSRegularExpression(pattern: #"^[a-z0-9]+([.-][A-Za-z0-9]+)+$"#)
        var off: [String] = []
        for name in ["Localizable", "InfoPlist"] {
            for (key, entry) in try Self.catalog(name) {
                let entry = entry as? [String: Any] ?? [:]
                guard let unit = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else {
                    let keyed = identifier.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
                    if name == "Localizable" && keyed && entry["extractionState"] as? String != "extracted_with_value" { off.append("\(key): no English to fall back to") }
                    continue
                }
                let forms = Self.forms(["localizations": [language: unit]], language)
                if forms.isEmpty || forms.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { off.append("\(name) \(key): empty") }
                if let state = (unit["stringUnit"] as? [String: Any])?["state"] as? String, state != "translated" { off.append("\(name) \(key): \(state)") }
            }
        }
        #expect(off.isEmpty, "\(off.sorted().prefix(20))")
        let bundle = try #require(Bundle(path: Bundle.main.path(forResource: language, ofType: "lproj") ?? ""))
        #expect(bundle.localizedString(forKey: "A sentence not in the catalog.", value: nil, table: nil) == "A sentence not in the catalog.")
        #expect(bundle.localizedString(forKey: "not.in.catalog", value: "Space", table: nil) == "Space")
    }

    /// Traditional Chinese reads as Taiwan's macOS does, not as Simplified Chinese in Traditional characters.
    @Test func traditionalChineseAvoidsMainlandWords() throws {
        let avoided = ["您", "賬", "標籤頁", "設置", "默認", "菜單", "窗口", "屏幕", "軟件", "信息", "用戶", "打開", "保存", "刷新", "視頻",
                       "鼠標", "擴展程序", "地址欄", "構建", "分屏", "收藏夾", "支持", "文件夾", "網絡", "服務器"]
        var off: [String] = []
        for name in ["Localizable", "InfoPlist"] {
            for (_, entry) in try Self.catalog(name) {
                for zh in Self.forms(entry, "zh-Hant") {
                    for word in avoided where zh.contains(word) { off.append("\(zh) says \(word)") }
                    if zh.range(of: #"\p{Han}[,.;:?!]\s|\p{Han}[,;?!]|[“”]"#, options: .regularExpression) != nil { off.append("\(zh): half-width punctuation or “” quotes") }
                }
            }
        }
        #expect(off.isEmpty, "\(off.joined(separator: "\n"))")
    }

    // MARK: Japanese

    @MainActor @Test func japaneseReachesTheApp() throws {
        let language = "ja"
        let bundle = try #require(Bundle(path: Bundle.main.path(forResource: language, ofType: "lproj") ?? ""))
        #expect(AppLanguage.choices.contains { $0.code == language && $0.title == "日本語" })
        for mac in ["ja", "ja-JP"] {
            #expect(Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: [mac]).first == language, "\(mac)")
        }
        #expect(Self.chinese("New Tab", language: language) == "新規タブ")
        #expect(Self.chinese("New Private Window", language: language) == "新規プライベートウインドウ")
        #expect(Self.chinese("key.space-bar", language: language) == "スペース")
        #expect(String.localizedStringWithFormat(Self.chinese("%lld tabs", language: language), 1) == "1個のタブ")
        #expect(String.localizedStringWithFormat(Self.chinese("%lld tabs", language: language), 3) == "3個のタブ")
        #expect(String(format: Self.chinese("%@ (%@)", language: language), "再読み込み", "⌘R") == "再読み込み（⌘R）")
        #expect(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
                == "アクセスしたWebサイトが、カメラの使用を求めることがあります。")
    }

    /// Japanese reads as Apple's Japanese does: no space between Japanese and Latin letters, digits or a placeholder,
    /// full-width punctuation and 「」, Apple's spellings, and one word for each of Zigzag's own things.
    @Test func japaneseFollowsTheGlossary() throws {
        let japanese = #"[\p{Hiragana}\p{Katakana}\p{Han}ー、。「」（）：！？]"#
        let space = try NSRegularExpression(pattern: "\(japanese) [!-~]|[!-~] \(japanese)")
        let terms: [(english: String, japanese: String)] = [
            (#"\bSpaces?\b"#, "スペース"), ("[Ss]idebar", "サイドバー"), ("[Cc]ommand bar", "コマンドバー"), (#"\bFavorite"#, "お気に入り"),
            ("Site Controls", "サイトコントロール"), (#"\b[Pp]rofiles?\b"#, "プロファイル"), (#"\bReload"#, "再読み込み"),
            ("Private [Ww]indow", "プライベートウインドウ"), (#"\bArchive"#, "アーカイブ"), ("Live Folder", "ライブフォルダ"),
        ]
        let avoided = ["あなた", "ウィンドウ", "フォルダー", "ブラウザー", "ユーザー", "サーバー", "デベロッパー", "拡張機能", "新しいタブ",
                       "インポート", "エクスポート", "ウェブサイト", "印刷", "貼り付け", "ネストされた", "聴", "もう一度試して", "アプリの"]
        var off: [String] = []
        for name in ["Localizable", "InfoPlist"] {
            for (key, entry) in try Self.catalog(name) {
                let forms = Self.forms(entry, "ja")
                // Search words are a list split by spaces, and never shown.
                let searchWords = ((entry as? [String: Any])?["comment"] as? String)?.contains("Not shown") == true
                for ja in forms {
                    // A numbered step keeps the space after its number, and a file name the one before its date.
                    let plain = ja.replacingOccurrences(of: "%arg", with: "X")
                        .replacingOccurrences(of: #"(?m)^\d+\. "#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #" (%(\d\$)?@\.)"#, with: "$1", options: .regularExpression)
                    if !searchWords, space.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil { off.append("\(ja): space beside Latin") }
                    if ja.range(of: #"[\p{Hiragana}\p{Katakana}\p{Han}][,.;:?!()]|[()][\p{Hiragana}\p{Katakana}\p{Han}]|[“”]"#, options: .regularExpression) != nil {
                        off.append("\(ja): half-width punctuation or “” quotes")
                    }
                    for word in avoided where ja.contains(word) { off.append("\(ja) says \(word)") }
                }
                guard name == "Localizable", key != "key.space-bar", let ja = forms.first else { continue }
                let en = Self.forms(entry, "en").first ?? key
                for term in terms where en.range(of: term.english, options: .regularExpression) != nil && !forms.contains(where: { $0.contains(term.japanese) }) {
                    off.append("\(en) → \(ja), wants \(term.japanese)")
                }
            }
        }
        #expect(off.isEmpty, "\(off.joined(separator: "\n"))")
    }

    /// A catalog entry's strings in one language: its single string, or each plural form and substitution.
    private static func forms(_ entry: Any, _ language: String, includeSubstitutions: Bool = true) -> [String] {
        guard let unit = ((entry as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any] else { return [] }
        func value(_ any: Any?) -> String? { ((any as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        var forms: [String] = []
        if let main = value(unit) { forms.append(main) }
        if let plural = (unit["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            forms += ["other", "one", "zero", "few", "many", "two"].compactMap { plural[$0] }.compactMap(value)
        }
        guard includeSubstitutions else { return forms }
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

    private static func catalog(_ name: String = "Localizable") throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appendingPathComponent("Zigzag/Resources/\(name).xcstrings"))
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
