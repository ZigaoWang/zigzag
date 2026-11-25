#if DEBUG
import Foundation

/// Debug builds only: every string Zigzag looks up in its catalog comes back accented, bracketed and about 40% longer
/// ("Settings" → "[Šéţţîñĝš ~~~~]"), so text cut off by a longer language, and text that never went through the
/// catalog, both show. On for a run with `-ZigzagPseudoLocalize YES`; tests turn it on with `PseudoLocale.$on`.
nonisolated enum PseudoLocale {
    /// On for one task and what it calls synchronously, as tests use it.
    @TaskLocal static var on = false
    /// On for the whole run, from the launch argument.
    nonisolated(unsafe) private(set) static var forTheRun = false

    static var isOn: Bool { forTheRun || on }

    /// A real language every string is looked up in for the run, from ZIGZAG_TEST_LANGUAGE, so the layout tests can lay
    /// out German or Russian without touching the Mac's languages or any settings.
    nonisolated(unsafe) private(set) static var language: String?

    /// At launch: on for the run when asked, before any string is looked up. ZIGZAG_PSEUDO_LOCALIZE=1 asks for a test run.
    static func startIfAsked() {
        if let code = ProcessInfo.processInfo.environment["ZIGZAG_TEST_LANGUAGE"], !code.isEmpty {
            language = code
            install()
            return
        }
        guard UserDefaults.standard.bool(forKey: "ZigzagPseudoLocalize")
                || ProcessInfo.processInfo.environment["ZIGZAG_PSEUDO_LOCALIZE"] == "1" else { return }
        forTheRun = true
        install()
    }

    /// `String(localized:)` has no hook of its own: it reads the catalog through Bundle's
    /// `_localizedStringForKey:value:table:localizations:`, so that method is wrapped, only once pseudo strings are
    /// asked for. The wrapper hands back a new string and lets ARC own both.
    static func install() {
        guard !installed else { return }
        installed = true
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSString
        let selector = NSSelectorFromString("_localizedStringForKey:value:table:localizations:")
        guard let method = class_getInstanceMethod(Bundle.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
        let wrapped: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> NSString = { bundle, key, value, table, languages in
            if let language, isApp(bundle) { return original(bundle, selector, key, value, table, [language] as NSArray) }
            let found = original(bundle, selector, key, value, table, languages)
            guard isOn, isApp(bundle) else { return found }
            return pseudo(found, key: key, table: table)
        }
        method_setImplementation(method, imp_implementationWithBlock(wrapped))
    }

    nonisolated(unsafe) private static var installed = false

    /// The app's bundle, which `String(localized:)` may reach through an object of its own for the same folder.
    private static func isApp(_ bundle: AnyObject) -> Bool {
        bundle === Bundle.main || (bundle as? Bundle)?.bundleURL == Bundle.main.bundleURL
    }

    /// A looked-up string made pseudo. A plural carries its forms, so it comes from a copy of the English plurals with
    /// every form made pseudo, which the system reads as it reads the app's own.
    private static func pseudo(_ found: NSString, key: NSString, table: NSString?) -> NSString {
        // Every string answers formatConfiguration; only a plural's answer is something.
        guard found.responds(to: NSSelectorFromString("formatConfiguration")), found.value(forKey: "formatConfiguration") != nil else {
            return NSString(string: transform(found as String))
        }
        guard let plurals else { return found }
        return plurals.localizedString(forKey: key as String, value: found as String, table: table as String?) as NSString
    }

    /// The app's English plurals (.stringsdict) with every form pseudo, in a bundle of their own.
    private static let plurals: Bundle? = {
        guard let english = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZigzagPseudoLocale-\(getpid())", isDirectory: true)
        let folder = root.appendingPathComponent("en.lproj", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in (try? FileManager.default.contentsOfDirectory(atPath: english)) ?? [] where file.hasSuffix(".stringsdict") {
            guard let entries = NSDictionary(contentsOfFile: english + "/" + file) as? [String: Any] else { continue }
            let pseudo = entries.mapValues { entry -> Any in
                guard let entry = entry as? [String: Any] else { return entry }
                return entry.mapValues { part -> Any in
                    if let format = part as? String { return transform(format) }
                    guard var rule = part as? [String: Any] else { return part }
                    for category in ["zero", "one", "two", "few", "many", "other"] {
                        if let form = rule[category] as? String { rule[category] = transform(form, brackets: false) }
                    }
                    return rule
                }
            }
            (pseudo as NSDictionary).write(to: folder.appendingPathComponent(file), atomically: true)
        }
        atexit { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("ZigzagPseudoLocale-\(getpid())")) }
        return Bundle(path: root.path)
    }()

    /// "Settings" → "[Šéţţîñĝš ~~~~]": letters accented, format arguments kept, about 40% more length as tildes.
    /// Plain code with no shared state, since strings are looked up on any thread.
    static func transform(_ text: String, brackets: Bool = true) -> String {
        guard !text.isEmpty else { return text }
        let characters = Array(text)
        var out = "", letters = 0, i = 0
        while i < characters.count {
            if characters[i] == "%", let end = argumentEnd(characters, from: i) {
                out += String(characters[i..<end])
                i = end
                continue
            }
            let character = characters[i]
            if character.isLetter { letters += 1 }
            out.append(accents[character] ?? character)
            i += 1
        }
        let padding = String(repeating: "~", count: Int((Double(letters) * 0.4).rounded(.up)))
        let padded = padding.isEmpty ? out : out + " " + padding
        return brackets ? "[" + padded + "]" : padded
    }

    /// Where a format argument starting at `start` ("%@", "%lld", "%1$@", "%.1f", "%#@name@", "%%") ends, or nil.
    private static func argumentEnd(_ c: [Character], from start: Int) -> Int? {
        var i = start + 1
        guard i < c.count else { return nil }
        if c[i] == "%" { return i + 1 }
        // A position: digits then $.
        var j = i
        while j < c.count, c[j].isASCII, c[j].isNumber { j += 1 }
        if j > i, j < c.count, c[j] == "$" { i = j + 1 }
        // A substitution: #@name@.
        if i + 1 < c.count, c[i] == "#", c[i + 1] == "@" {
            var k = i + 2
            while k < c.count, c[k] != "@" { k += 1 }
            return k < c.count ? k + 1 : nil
        }
        while i < c.count, "-+ 0#".contains(c[i]) { i += 1 }
        while i < c.count, c[i].isASCII, c[i].isNumber { i += 1 }
        if i < c.count, c[i] == "." {
            i += 1
            while i < c.count, c[i].isASCII, c[i].isNumber { i += 1 }
        }
        for length in ["ll", "hh", "l", "h", "q", "z", "t", "j"] where String(c[i..<min(i + length.count, c.count)]) == length {
            i += length.count
            break
        }
        guard i < c.count, "@dDuUxXoOfeEgGcCsSpaFi".contains(c[i]) else { return nil }
        return i + 1
    }

    /// Whether some of the text came from `transform`: an accented letter or its padding.
    static func isPseudo(_ text: String) -> Bool { text.contains("~]") || text.contains { marked.contains($0) } }

    private static let plain = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let marked = Set("áƀçðéƒĝĥîĵķļɱñöþǫŕšţûṽŵẋýžÅƁÇÐÉƑĜĤÎĴĶĻṀÑÖÞǪŔŠŢÛṼŴẊÝŽ")
    private static let accents = Dictionary(uniqueKeysWithValues: zip(plain, "áƀçðéƒĝĥîĵķļɱñöþǫŕšţûṽŵẋýžÅƁÇÐÉƑĜĤÎĴĶĻṀÑÖÞǪŔŠŢÛṼŴẊÝŽ"))
}
#endif
