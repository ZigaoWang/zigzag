import AppKit
import WebKit

/// "Bring your stuff from another browser": finds the browsers on this Mac, imports what the person picks,
/// merges with what's already here, and says plainly what came over and what couldn't.
@MainActor
enum ImportCoordinator {
    enum Kind: Hashable, Sendable {
        case chromium(ChromiumImporter.Browser)
        case firefox(FirefoxImporter.Browser)
        case safari
        case orion(OrionImporter.Browser)
        /// A CSV or Safari export zip the person chose.
        case file(URL)
    }

    struct Source: Identifiable, Hashable {
        let kind: Kind
        let name: String
        let bundleID: String?
        var id: String { name }

        /// The browser's real icon, from the app on this Mac.
        var icon: NSImage {
            if let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: app.path)
            }
            return NSWorkspace.shared.icon(for: .commaSeparatedText)
        }

        /// What can come over from it.
        var offers: Choice {
            switch kind {
            // Only Chrome and its kin share a store with Zigzag: Firefox's and Safari's extensions come from their own.
            case .chromium(let browser) where browser.name == "Arc": [.passwords, .bookmarks, .history, .tabs, .signIns, .extensions]
            // Passwords and most sign-ins need the browser's Keychain item; without one known, they stay behind.
            case .chromium(let browser) where browser.safeStorage == nil: [.bookmarks, .history, .extensions]
            case .chromium: [.passwords, .bookmarks, .history, .signIns, .extensions]
            case .firefox: [.passwords, .bookmarks, .history, .signIns]
            // Safari's cookies sit behind Full Disk Access, and a file holds none: nothing to offer.
            case .safari: [.passwords, .bookmarks, .history]
            // Orion's passwords are in its own Keychain (a note says how to export them); its sign-ins, like
            // Safari's, aren't in a file Zigzag reads. Its Chrome Web Store extensions come from the same store.
            case .orion: [.passwords, .bookmarks, .history, .extensions]
            case .file: [.passwords, .bookmarks, .history]
            }
        }
    }

    struct Choice: OptionSet, Hashable {
        let rawValue: Int
        static let passwords = Choice(rawValue: 1)
        static let bookmarks = Choice(rawValue: 2)
        static let history = Choice(rawValue: 4)
        /// Arc's spaces, pinned tabs and favorites.
        static let tabs = Choice(rawValue: 8)
        /// The sites you're signed in to there, so you stay signed in here.
        static let signIns = Choice(rawValue: 16)
        /// Its extensions from the Chrome Web Store, added here from the store after one question.
        static let extensions = Choice(rawValue: 32)

        /// What trying again after these problems should run: just the parts that failed, or everything.
        static func retrying(_ problems: [ImportProblem], else all: Choice) -> Choice {
            let scopes: [Choice] = problems.filter { $0.fix == .retry || $0.fix == .primaryPassword }
                .map { $0.fix == .primaryPassword ? Choice.passwords : Choice(rawValue: $0.retries) }
            guard !scopes.isEmpty, !scopes.contains(where: { $0.isEmpty }) else { return all }
            var union: Choice = []
            for scope in scopes { union.formUnion(scope) }
            return union.intersection(all)
        }

        var reading: ChromiumImporter.Choice {
            var choice: ChromiumImporter.Choice = []
            if contains(.passwords) { choice.insert(.passwords) }
            if contains(.bookmarks) { choice.insert(.bookmarks) }
            if contains(.history) { choice.insert(.history) }
            if contains(.signIns) { choice.insert(.cookies) }
            return choice
        }
    }

    /// Browsers on this Mac with something to bring, Arc first, then by how commonly they're switched from.
    static func detectedSources() -> [Source] {
        var sources: [Source] = []
        #if DEBUG
        // A debug copy checked by script (its own data folder or debug channel) lists each browser once, by name:
        // its profiles' names, often email addresses, never show in a capture, even if the run forgot to ask.
        let env = ProcessInfo.processInfo.environment
        let plainNames = ["ZIGZAG_FAKE_BROWSERS", "ZIGZAG_DATA_DIR", "ZIGZAG_DEBUG_CHANNEL"].contains { !(env[$0] ?? "").isEmpty }
        #else
        let plainNames = false
        #endif
        for browser in ChromiumImporter.browsers where ChromiumImporter.isInstalled(browser) {
            // Several profiles: each is its own choice ("Chrome (Work)"), as other browsers' importers do.
            let profiles = browser.name == "Arc" || plainNames ? [] : ChromiumImporter.profileNames(of: browser)
            if profiles.count > 1 {
                // "Wang (a@zigao.xyz)" reads as just "Wang"; the email only when two profiles share a name.
                let short = profiles.map { Self.shortProfileName($0.1) }
                for ((folder, display), name) in zip(profiles, short) {
                    let label = short.filter { $0 == name }.count > 1 ? Self.profileEmail(display) ?? display : name
                    sources.append(Source(kind: .chromium(browser.only(folder, named: display)), name: "\(browser.name) (\(label))", bundleID: browser.bundleID))
                }
            } else {
                sources.append(Source(kind: .chromium(browser), name: browser.name, bundleID: browser.bundleID))
            }
        }
        #if DEBUG
        let realSafari = BrowserFolders.fake == nil
        #else
        let realSafari = true
        #endif
        if realSafari, NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariImporter.bundleID) != nil {
            sources.append(Source(kind: .safari, name: "Safari", bundleID: SafariImporter.bundleID))
        }
        for browser in FirefoxImporter.browsers where FirefoxImporter.isInstalled(browser) {
            sources.append(Source(kind: .firefox(browser), name: browser.name, bundleID: browser.bundleID))
        }
        if OrionImporter.isInstalled() {
            // Several profiles: each is its own choice ("Orion (Work)"), as Chrome's are.
            let profiles = plainNames ? [] : OrionImporter.profileNames()
            if profiles.count > 1 {
                for (folder, name) in profiles {
                    sources.append(Source(kind: .orion(OrionImporter.Browser().only(folder, named: name)),
                                          name: "\(OrionImporter.name) (\(name))", bundleID: OrionImporter.bundleID))
                }
            } else {
                sources.append(Source(kind: .orion(OrionImporter.Browser()), name: OrionImporter.name, bundleID: OrionImporter.bundleID))
            }
        }
        return sources
    }

    /// The sources to start with checked: the browser this person really uses (their default browser, or else
    /// the one used most recently), and every profile of it used in the last three months. Never just whichever
    /// happens to be listed first, which brought over an empty "Default" profile while the real one stayed behind.
    static func suggested(_ sources: [Source]) -> Set<String> {
        let browsers = sources.filter { if case .file = $0.kind { false } else { true } }
        guard !browsers.isEmpty else { return [] }
        let used = Dictionary(browsers.map { ($0.id, lastUsed($0)) }, uniquingKeysWith: { a, _ in a })
        let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        let main: String? = {
            if let defaultBrowser, browsers.contains(where: { $0.bundleID == defaultBrowser }) { return defaultBrowser }
            // Zigzag (or something else) is the default: the browser touched most recently.
            return browsers.max { ((used[$0.id] ?? nil) ?? .distantPast) < ((used[$1.id] ?? nil) ?? .distantPast) }?.bundleID
        }()
        let candidates = browsers.filter { $0.bundleID == main }
        guard !candidates.isEmpty else { return [browsers[0].id] }
        let newest = candidates.compactMap { used[$0.id] ?? nil }.max()
        let picked = candidates.filter { source in
            guard let newest, let date = used[source.id] ?? nil else { return newest == nil }
            return newest.timeIntervalSince(date) < 90 * 24 * 3600
        }
        return Set((picked.isEmpty ? candidates : picked).map(\.id))
    }

    /// When a browser (or one of its profiles) was last used, as far as can be told without reading its data.
    static func lastUsed(_ source: Source) -> Date? {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        switch source.kind {
        case .chromium(let browser):
            let root = ChromiumImporter.rootURL(of: browser)
            // Chromium notes each profile's last use in Local State.
            if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let profile = json["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: Any] {
                let folders = browser.profile.map { [$0] } ?? Array(cache.keys)
                let times = folders.compactMap { ((cache[$0] as? [String: Any])?["active_time"] as? Double).map { Date(timeIntervalSince1970: $0) } }
                if let latest = times.max() { return latest }
                if let last = profile["last_used"] as? String, folders.contains(last) { return modified(root.appendingPathComponent("Local State")) }
            }
            return ChromiumImporter.profiles(of: browser).compactMap { modified($0.appendingPathComponent("History")) }.max()
                ?? modified(root.appendingPathComponent("Local State"))
        case .firefox(let browser):
            return FirefoxImporter.profiles(of: browser).compactMap { modified($0.appendingPathComponent("places.sqlite")) }.max()
        case .safari:
            return modified(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db"))
        case .orion(let browser):
            return OrionImporter.profiles(of: browser).compactMap { modified($0.appendingPathComponent("history")) }.max()
        case .file:
            return nil
        }
    }

    nonisolated static func shortProfileName(_ display: String) -> String {
        guard let open = display.firstIndex(of: "("), display.hasSuffix(")") else { return display }
        let name = display[..<open].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? display : name
    }

    nonisolated static func profileEmail(_ display: String) -> String? {
        guard let open = display.firstIndex(of: "("), display.hasSuffix(")") else { return nil }
        return String(display[display.index(after: open)..<display.index(before: display.endIndex)])
    }

    static func fileSource(_ url: URL) -> Source {
        Source(kind: .file(url), name: url.lastPathComponent, bundleID: nil)
    }

    /// What a source holds, counted without decrypting anything: "6 passwords, 57 bookmarks and history".
    /// "Spaces, 6 passwords, history": what a browser holds, in one short line.
    nonisolated private static func sentence(_ parts: [String]) -> String {
        let line = parts.dropFirst().reduce(parts[0]) {
            // Its own key: Chinese joins a list's items with 、, where a comma joins other things.
            String(localized: "import.short-list", defaultValue: "\($0), \($1)",
                   comment: "Joins the items of a short list in the Import window, like “6 passwords, history”.")
        }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// The previews of a browser macOS keeps private until you allow Zigzag to read it.
    nonisolated static let needsPermission = String(localized: "macOS will need your permission to read it", comment: "Under a browser's name in the Import window's list.")
    nonisolated static let safariNeedsPermission = String(localized: "Bookmarks and history, with your permission",
                                                          comment: "Under Safari's name in the Import window's list: what can come over from it.")

    /// Whether a preview says macOS has to allow reading the browser first.
    static func asksPermission(_ preview: String) -> Bool { preview == needsPermission || preview == safariNeedsPermission }

    /// `extensions`: count the extensions it has that `profile` (left out, the first) doesn't, where they're offered.
    static func preview(_ source: Source, extensions: Bool = false, in profile: Profile? = nil) async -> String {
        let kind = source.kind
        let installed: Set<String>? = extensions ? Set((profile ?? Profiles.shared.default).installs.installedIDs) : nil
        return await Task.detached(priority: .utility) { () -> String in
            let spaces = String(localized: "spaces", comment: "Item in the short list of what a browser holds, in the Import window: Arc's spaces.")
            let history = String(localized: "history", comment: "Item in the short list of what a browser holds, in the Import window: its browsing history.")
            let signIns = String(localized: "sign-ins", comment: "Item in the short list of what a browser holds, in the Import window: the sites it keeps you signed in to.")
            func passwords(_ n: Int) -> String? { n > 0 ? String(localized: "\(n) passwords", comment: "Item in a list of what a browser holds or what came over, in the Import window.") : nil }
            func bookmarks(_ n: Int) -> String? { n > 0 ? String(localized: "\(n) bookmarks", comment: "Item in a list of what a browser holds or what came over, in the Import window.") : nil }
            switch kind {
            case .chromium(let browser):
                let profiles = ChromiumImporter.profiles(of: browser)
                let files = profiles.flatMap { p in ["Login Data", "Bookmarks", "History"].map { p.appendingPathComponent($0) } }
                if files.contains(where: { FileManager.default.fileExists(atPath: $0.path) && !FileManager.default.isReadableFile(atPath: $0.path) }) {
                    return Self.needsPermission
                }
                let counts = ChromiumImporter.counts(browser)
                let newExtensions = installed.map { ChromiumExtensions.toAdd(ChromiumExtensions.found(in: browser, source: ""), installed: $0).count } ?? 0
                // Short enough for one line in the list: Arc's spaces first, then what's counted.
                let opens = browser.safeStorage != nil
                let parts = [browser.name == "Arc" ? spaces : nil, opens ? passwords(counts.passwords) : nil,
                             bookmarks(counts.bookmarks), counts.history > 0 ? history : nil,
                             opens && SignInImporter.hasAny(chromium: profiles) ? signIns : nil,
                             newExtensions > 0 ? String(localized: "\(newExtensions) extensions", comment: "Item in a list of what a browser holds or what came over, in the Import window.") : nil].compactMap { $0 }
                return parts.isEmpty ? String(localized: "Nothing to bring over", comment: "Under a browser's name in the Import window's list.") : Self.sentence(parts)
            case .firefox(let browser):
                let counts = FirefoxImporter.counts(browser)
                let parts = [passwords(counts.passwords), bookmarks(counts.bookmarks), counts.history > 0 ? history : nil,
                             SignInImporter.hasAny(firefox: FirefoxImporter.profiles(of: browser)) ? signIns : nil].compactMap { $0 }
                return parts.isEmpty ? String(localized: "Nothing to bring over", comment: "Under a browser's name in the Import window's list.") : Self.sentence(parts)
            case .safari:
                return SafariImporter.hasAccess
                    ? String(localized: "Bookmarks and history, no passwords", comment: "Under Safari's name in the Import window's list: what can come over from it.")
                    : Self.safariNeedsPermission
            case .orion(let browser):
                if OrionImporter.isPrivate(browser) { return Self.needsPermission }
                let counts = OrionImporter.counts(browser)
                let newExtensions = installed.map { ChromiumExtensions.toAdd(OrionImporter.extensions(of: browser, source: ""), installed: $0).count } ?? 0
                let parts = [bookmarks(counts.bookmarks), counts.history > 0 ? history : nil,
                             newExtensions > 0 ? String(localized: "\(newExtensions) extensions", comment: "Item in a list of what a browser holds or what came over, in the Import window.") : nil].compactMap { $0 }
                return parts.isEmpty ? String(localized: "Nothing to bring over", comment: "Under a browser's name in the Import window's list.") : Self.sentence(parts)
            case .file(let url):
                return url.lastPathComponent
            }
        }.value
    }

    struct Summary {
        let source: String
        var passwords = 0
        var updatedPasswords = 0
        /// Logins already here whose imported password differed but wasn't known to be newer, so stayed as they were.
        var keptPasswords = 0
        var bookmarks = 0
        var history = 0
        var spaces = 0
        /// Sites whose sign-ins came over.
        var signedInSites = 0
        /// Extensions added from the Chrome Web Store.
        var extensions = 0
        /// Its extensions Zigzag doesn't have yet, waiting for the one question before any is added.
        var foundExtensions: [ChromiumExtensions.Found] = []
        var problems: [ImportProblem] = []
        /// Worth saying, with nothing to fix: the import still went fine.
        var notes: [String] = []

        /// Something came over: anything counted above.
        var broughtAny: Bool { passwords + updatedPasswords + bookmarks + history + spaces + signedInSites + extensions > 0 }

        /// "Imported 214 passwords and 86 bookmarks from Arc."
        var sentence: String {
            var parts: [String] = []
            if passwords > 0 { parts.append(String(localized: "\(passwords) passwords", comment: "Item in a list of what a browser holds or what came over, in the Import window.")) }
            if bookmarks > 0 { parts.append(String(localized: "\(bookmarks) bookmarks", comment: "Item in a list of what a browser holds or what came over, in the Import window.")) }
            if spaces > 0 { parts.append(String(localized: "\(spaces) spaces", comment: "Item in the list of what came over, in the Import window.")) }
            if history > 0 { parts.append(String(localized: "\(history) pages of history", comment: "Item in the list of what came over, in the Import window.")) }
            if extensions > 0 { parts.append(String(localized: "\(extensions) extensions", comment: "Item in a list of what a browser holds or what came over, in the Import window.")) }
            var sentences: [String] = []
            if parts.isEmpty {
                sentences.append(!foundExtensions.isEmpty
                    ? String(localized: "Found \(foundExtensions.count) extensions to add from \(source).",
                             comment: "Import window, before the extensions found are added: how many, then a browser's name, like Chrome.")
                    : signedInSites > 0
                    ? String(localized: "Brought over sign-ins for \(signedInSites) sites from \(source).",
                             comment: "Import window, when only sign-ins came over: how many sites, then a browser's name, like Chrome.")
                    : updatedPasswords > 0
                    ? String(localized: "Updated \(updatedPasswords) passwords from \(source).", comment: "Import window: how many passwords were updated, then a browser's name, like Chrome.")
                    : String(localized: "Nothing new to bring over from \(source).", comment: "Import window. The placeholder is a browser's name, like Chrome."))
            } else {
                let list = Words.list(parts)
                sentences.append(String(localized: "Imported \(list) from \(source).",
                                        comment: "Import window: a list like “214 passwords and 86 bookmarks”, then a browser's name, like Chrome."))
                if signedInSites > 0 {
                    sentences.append(String(localized: "Brought over sign-ins for \(signedInSites) sites.", comment: "Import window, after what was imported: how many sites' sign-ins came over."))
                }
            }
            if keptPasswords > 0 {
                sentences.append(String(localized: "Kept \(keptPasswords) passwords already in Zigzag instead of the imported ones.",
                                        comment: "Import window: passwords that stayed as they were because the imported ones weren't known to be newer."))
            }
            return sentences.dropFirst().reduce(sentences[0]) {
                String(localized: "\($0) \($1)", comment: "Joins two sentences, one after the other. Leave out the space if your language doesn't put one between sentences.")
            }
        }
    }

    /// Imports from one source. Reading happens off the main thread; macOS may show its own prompts on the way
    /// (allowing access to a browser's passwords).
    ///
    /// `into`: the profile that gets it all (left out, the first): its history and sign-ins, and the spaces
    /// and favorites made for what came over. Passwords go into the one vault every profile shares.
    static func run(_ source: Source, _ choice: Choice, primaryPassword: String = "", into target: Profile? = nil) async -> Summary {
        let choice = choice.intersection(source.offers)
        let profile = target ?? Profiles.shared.default
        var summary = Summary(source: source.name)
        let reading = choice.reading
        let isArc: Bool = { if case .chromium(let b) = source.kind { return b.name == "Arc" } else { return false } }()

        // Arc's spaces, pinned tabs, favorites and history come through its own importer, which knows its sidebar.
        var arcReading = reading
        // Only the parts you chose: the sidebar for spaces and bookmarks, history for history.
        if isArc {
            if choice.contains(.tabs) || choice.contains(.bookmarks) {
                let result = ArcImporter.importSidebar(into: profile.id).result
                summary.spaces = result.spaces
                summary.bookmarks = result.bookmarks
                summary.problems += result.problems
            }
            if choice.contains(.history) {
                let read = await Task.detached(priority: .userInitiated) { () -> Swift.Result<[(URL, String, Int, Date)], Error> in
                    Swift.Result { try ArcImporter.readHistory() }
                }.value
                switch read {
                case .success(let entries):
                    summary.history = profile.history.importVisits(entries)
                case .failure(let error):
                    summary.problems.append(ArcImporter.historyProblem(error))
                }
            }
            arcReading = reading.intersection([.passwords, .cookies])
        }

        if choice.contains(.extensions), case .chromium(let browser) = source.kind {
            let installed = Set(profile.installs.installedIDs), name = source.name
            summary.foundExtensions = await Task.detached(priority: .userInitiated) {
                ChromiumExtensions.toAdd(ChromiumExtensions.found(in: browser, source: name), installed: installed)
            }.value
        }
        if choice.contains(.extensions), case .orion(let browser) = source.kind {
            let installed = Set(profile.installs.installedIDs), name = source.name
            summary.foundExtensions = await Task.detached(priority: .userInitiated) {
                ChromiumExtensions.toAdd(OrionImporter.extensions(of: browser, source: name), installed: installed)
            }.value
        }

        let kind = source.kind
        let batch: ImportBatch = await Task.detached(priority: .userInitiated) {
            switch kind {
            case .chromium(let browser): return ChromiumImporter.read(browser, isArc ? arcReading : reading)
            case .firefox(let browser): return FirefoxImporter.read(browser, reading, primaryPassword: primaryPassword)
            case .safari: return SafariImporter.read(reading)
            case .orion(let browser): return OrionImporter.read(browser, reading)
            case .file(let url):
                if url.pathExtension.lowercased() == "zip" { return SafariImporter.readExport(url) }
                switch CSVImporter.read(url) {
                case .success(let (_, batch)): return batch
                case .failure: return ImportBatch(problems: [ImportProblem(message: String(localized: "\(url.lastPathComponent) isn’t a password export Zigzag recognizes. Export a CSV from your password manager or browser and choose it.",
                                                                                    comment: "Problem in the Import window. The placeholder is the chosen file's name."),
                                                                  fix: .none)])
                }
            }
        }.value

        summary.problems += batch.problems
        if choice.contains(.passwords) { await savePasswords(batch.logins, into: &summary) }
        if choice.contains(.bookmarks), !batch.bookmarks.isEmpty { summary.bookmarks += addBookmarks(batch.bookmarks, from: source.name, into: profile.id) }
        if choice.contains(.history), !batch.history.isEmpty {
            // Only pages new here count: the same browser again brings nothing new, and says so.
            summary.history += profile.history.importVisits(batch.history)
        }
        // Only ever a profile's own store: private windows each have their own, which nothing imported reaches.
        if choice.contains(.signIns) {
            var applied = SignInImporter.Applied()
            if !batch.cookies.isEmpty { applied = await SignInImporter.apply(batch.cookies, to: profile.store.httpCookieStore) }
            summary.signedInSites = applied.sites
            if let note = SignInImporter.note(unreadable: batch.unreadableCookies + applied.failed,
                                              broughtAny: applied.cookies + applied.kept > 0, from: source.name) {
                summary.notes.append(note)
            }
        }
        return summary
    }

    /// New logins are saved. A login already here is replaced only when the imported password is known to be
    /// newer: a source without dates (a CSV file) never overwrites one. The same login twice in one import (Chrome
    /// keeps it in two files) counts once, the newer copy.
    private static func savePasswords(_ logins: [ImportBatch.Login], into summary: inout Summary) async {
        struct Key: Hashable { let origin: Origin; let username: String }
        func when(_ login: ImportBatch.Login) -> Date? { login.changed ?? login.created }
        var newest: [Key: ImportBatch.Login] = [:]
        var order: [Key] = []
        for login in logins {
            guard let origin = Origin(login.url) else { continue }
            let key = Key(origin: origin, username: login.username)
            if let seen = newest[key] {
                if (when(login) ?? .distantPast) > (when(seen) ?? .distantPast) { newest[key] = login }
            } else {
                newest[key] = login
                order.append(key)
            }
        }
        let store = PasswordStore.shared
        // What's here already, looked up once.
        var here: [Key: Credential] = [:]
        // Unreadable (the Keychain locked, or refusing): adding now would put a second copy of every login here.
        guard let existing = try? await store.all() else {
            summary.problems.append(ImportProblem(message: String(localized: "Zigzag couldn’t read the passwords it already has, so it didn’t add any. Try again.", comment: "Problem in the Import window."),
                                                  fix: .retry, retries: Choice.passwords.rawValue))
            return
        }
        for credential in existing { here[Key(origin: credential.origin, username: credential.username)] = credential }
        var changed = false
        var failed = 0
        for key in order {
            guard let login = newest[key] else { continue }
            if var current = here[key] {
                let saved = try? await store.password(for: current.id)
                if saved?.matches(login.password) == true { continue }
                guard let date = when(login), date > current.modified else {
                    // Not known to be newer (a CSV file has no dates): the one here stays, and the summary says so.
                    if saved != nil { summary.keptPasswords += 1 }
                    continue
                }
                current.modified = date
                if (try? await store.replaceImported(current, password: login.password)) != nil {
                    here[key] = current
                    summary.updatedPasswords += 1
                    changed = true
                } else {
                    failed += 1
                }
            } else if let added = try? await store.addImported(origin: key.origin, username: key.username, password: login.password,
                                                                notes: login.notes, otpAuth: login.otpAuth,
                                                                created: login.created ?? Date(), modified: when(login) ?? Date()) {
                here[key] = added
                summary.passwords += 1
                changed = true
            } else {
                failed += 1
            }
        }
        if changed {
            await store.announceChanges()
            // Passwords brought over are meant to be used: Zigzag keeps offering them even with a password-manager
            // extension added (until you turn that off yourself).
            UserDefaults.standard.set(true, forKey: Autofill.importedKey)
            UserDefaults.standard.set(Date(), forKey: Autofill.importedAtKey)
        }
        if failed > 0 {
            summary.problems.append(ImportProblem(message: String(localized: "\(failed) passwords couldn’t be saved. Try again.", comment: "Problem in the Import window: how many passwords couldn't be saved."),
                                                  fix: .retry, retries: Choice.passwords.rawValue))
        }
    }

    /// Bookmarks go into a space of their own ("From Chrome"), so nothing already here gets crowded. A space made
    /// for them is on the profile the import goes into; one already there stays where it is.
    private static func addBookmarks(_ bookmarks: [ImportBatch.Bookmark], from name: String, into profile: UUID) -> Int {
        let spaceName = String(localized: "From \(name)", comment: "Name of the space imported bookmarks go into. The placeholder is a browser's name: From Chrome.")
        let merge = merged(bookmarks, into: Library.shared.spaces, named: spaceName)
        guard !merge.new.isEmpty else { return 0 }
        let space: SpaceInfo
        if let existing = merge.space {
            space = existing
        } else {
            space = Library.shared.addSpace(name: spaceName)
            Library.shared.setProfile(profile, forSpace: space.id)
        }
        // All in one change: thousands of bookmarks one at a time would redraw every window thousands of times. Their
        // folders come over as folders.
        let added = Library.shared.appendBookmarks(merge.new.map { ($0.url, $0.title) }, to: space.id, folders: merge.new.map(\.folders))
        // Icons for the first ones now; the sidebar fetches the rest for the rows it shows.
        for bookmark in added.prefix(40) { FaviconStore.shared.prefetch(for: bookmark.url) }
        return added.count
    }

    /// What importing bookmarks again adds: only the pages its space doesn't have yet, once each. With that space
    /// deleted, `space` is nil and everything is new, so the space comes back whole.
    static func merged(_ bookmarks: [ImportBatch.Bookmark], into spaces: [SpaceInfo], named spaceName: String) -> (space: SpaceInfo?, new: [ImportBatch.Bookmark]) {
        let space = spaces.first { $0.name == spaceName }
        var known = Set((space?.bookmarks ?? []).map { TabManager.normalize($0.url) })
        return (space, bookmarks.filter { known.insert(TabManager.normalize($0.url)).inserted })
    }
}
