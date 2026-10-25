import AppKit

/// "Bring your stuff from another browser": finds the browsers on this Mac, imports what the person picks,
/// merges with what's already here, and says plainly what came over and what couldn't.
@MainActor
enum ImportCoordinator {
    enum Kind: Hashable, Sendable {
        case chromium(ChromiumImporter.Browser)
        case firefox(FirefoxImporter.Browser)
        case safari
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
            case .chromium(let browser): browser.name == "Arc" ? [.passwords, .bookmarks, .history, .tabs] : [.passwords, .bookmarks, .history]
            case .firefox: [.passwords, .bookmarks, .history]
            case .safari: [.passwords, .bookmarks, .history]
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
            return choice
        }
    }

    /// Browsers on this Mac with something to bring, Arc first, then by how commonly they're switched from.
    static func detectedSources() -> [Source] {
        var sources: [Source] = []
        for browser in ChromiumImporter.browsers where ChromiumImporter.isInstalled(browser) {
            // Several profiles: each is its own choice ("Chrome (Work)"), as other browsers' importers do.
            let profiles = browser.name == "Arc" ? [] : ChromiumImporter.profileNames(of: browser)
            if profiles.count > 1 {
                for (folder, display) in profiles {
                    sources.append(Source(kind: .chromium(browser.only(folder, named: display)), name: "\(browser.name) (\(display))", bundleID: browser.bundleID))
                }
            } else {
                sources.append(Source(kind: .chromium(browser), name: browser.name, bundleID: browser.bundleID))
            }
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariImporter.bundleID) != nil {
            sources.append(Source(kind: .safari, name: "Safari", bundleID: SafariImporter.bundleID))
        }
        for browser in FirefoxImporter.browsers where FirefoxImporter.isInstalled(browser) {
            sources.append(Source(kind: .firefox(browser), name: browser.name, bundleID: browser.bundleID))
        }
        return sources
    }

    static func fileSource(_ url: URL) -> Source {
        Source(kind: .file(url), name: url.lastPathComponent, bundleID: nil)
    }

    /// What a source holds, counted without decrypting anything: "6 passwords, 57 bookmarks and history".
    static func preview(_ source: Source) async -> String {
        let kind = source.kind
        return await Task.detached(priority: .utility) { () -> String in
            func phrase(_ n: Int, _ one: String, _ many: String) -> String? { n > 0 ? "\(n) \(n == 1 ? one : many)" : nil }
            switch kind {
            case .chromium(let browser):
                let profiles = ChromiumImporter.profiles(of: browser)
                let files = profiles.flatMap { p in ["Login Data", "Bookmarks", "History"].map { p.appendingPathComponent($0) } }
                if files.contains(where: { FileManager.default.fileExists(atPath: $0.path) && !FileManager.default.isReadableFile(atPath: $0.path) }) {
                    return "macOS will need your permission to read it"
                }
                let counts = ChromiumImporter.counts(browser)
                let parts = [phrase(counts.passwords, "password", "passwords"), phrase(counts.bookmarks, "bookmark", "bookmarks"),
                             counts.history > 0 ? "history" : nil, browser.name == "Arc" ? "spaces and pinned tabs" : nil].compactMap { $0 }
                return parts.isEmpty ? "Nothing to bring over" : ListFormatter.localizedString(byJoining: parts)
            case .firefox(let browser):
                let counts = FirefoxImporter.counts(browser)
                let parts = [phrase(counts.passwords, "password", "passwords"), phrase(counts.bookmarks, "bookmark", "bookmarks"), counts.history > 0 ? "history" : nil].compactMap { $0 }
                return parts.isEmpty ? "Nothing to bring over" : ListFormatter.localizedString(byJoining: parts)
            case .safari:
                return SafariImporter.hasAccess ? "Bookmarks and history. Passwords come from the Passwords app." : "Bookmarks and history need your permission. Passwords come from the Passwords app."
            case .file(let url):
                return url.lastPathComponent
            }
        }.value
    }

    struct Summary {
        let source: String
        var passwords = 0
        var updatedPasswords = 0
        var bookmarks = 0
        var history = 0
        var spaces = 0
        var problems: [ImportProblem] = []

        /// "Imported 214 passwords and 86 bookmarks from Arc."
        var sentence: String {
            var parts: [String] = []
            func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
            if passwords > 0 { parts.append(count(passwords, "password", "passwords")) }
            if bookmarks > 0 { parts.append(count(bookmarks, "bookmark", "bookmarks")) }
            if spaces > 0 { parts.append(count(spaces, "space", "spaces")) }
            if history > 0 { parts.append(count(history, "page of history", "pages of history")) }
            guard !parts.isEmpty else { return updatedPasswords > 0 ? "Updated \(count(updatedPasswords, "password", "passwords")) from \(source)." : "Nothing new to bring over from \(source)." }
            let list = ListFormatter.localizedString(byJoining: parts)
            return "Imported \(list) from \(source)."
        }
    }

    /// Imports from one source. Reading happens off the main thread; macOS may show its own prompts on the way
    /// (allowing access to a browser's passwords).
    static func run(_ source: Source, _ choice: Choice, primaryPassword: String = "") async -> Summary {
        var summary = Summary(source: source.name)
        let reading = choice.reading
        let isArc: Bool = { if case .chromium(let b) = source.kind { return b.name == "Arc" } else { return false } }()

        // Arc's spaces, pinned tabs, favorites and history come through its own importer, which knows its sidebar.
        var arcReading = reading
        // Only the parts you chose: the sidebar for spaces and bookmarks, history for history.
        if isArc {
            if choice.contains(.tabs) || choice.contains(.bookmarks) {
                let result = ArcImporter.importSidebar().result
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
                    HistoryStore.shared.importVisits(entries)
                    summary.history = entries.count
                case .failure(let error):
                    summary.problems.append(ArcImporter.historyProblem(error))
                }
            }
            arcReading = reading.intersection(.passwords)
        }

        let kind = source.kind
        let batch: ImportBatch = await Task.detached(priority: .userInitiated) {
            switch kind {
            case .chromium(let browser): return ChromiumImporter.read(browser, isArc ? arcReading : reading)
            case .firefox(let browser): return FirefoxImporter.read(browser, reading, primaryPassword: primaryPassword)
            case .safari: return SafariImporter.read(reading)
            case .file(let url):
                if url.pathExtension.lowercased() == "zip" { return SafariImporter.readExport(url) }
                switch CSVImporter.read(url) {
                case .success(let (_, batch)): return batch
                case .failure: return ImportBatch(problems: [ImportProblem(message: "\(url.lastPathComponent) isn't a password export Zigzag recognizes. Export a CSV from your password manager or browser and choose it.", fix: .none)])
                }
            }
        }.value

        summary.problems += batch.problems
        if choice.contains(.passwords) { await savePasswords(batch.logins, into: &summary) }
        if choice.contains(.bookmarks), !batch.bookmarks.isEmpty { summary.bookmarks += addBookmarks(batch.bookmarks, from: source.name) }
        if choice.contains(.history), !batch.history.isEmpty {
            HistoryStore.shared.importVisits(batch.history)
            summary.history += batch.history.count
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
            summary.problems.append(ImportProblem(message: "Zigzag couldn’t read the passwords it already has, so it didn’t add any. Try again.",
                                                  fix: .retry, retries: Choice.passwords.rawValue))
            return
        }
        for credential in existing { here[Key(origin: credential.origin, username: credential.username)] = credential }
        var changed = false
        var failed = 0
        for key in order {
            guard let login = newest[key] else { continue }
            if var current = here[key] {
                guard let date = when(login), date > current.modified else { continue }
                if let saved = try? await store.password(for: current.id), saved.matches(login.password) { continue }
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
        if changed { await store.announceChanges() }
        if failed > 0 {
            summary.problems.append(ImportProblem(message: "\(failed) \(failed == 1 ? "password" : "passwords") couldn’t be saved. Try again.",
                                                  fix: .retry, retries: Choice.passwords.rawValue))
        }
    }

    /// Bookmarks go into a space of their own ("From Chrome"), so nothing already here gets crowded.
    private static func addBookmarks(_ bookmarks: [ImportBatch.Bookmark], from name: String) -> Int {
        let spaceName = "From \(name)"
        let space = Library.shared.spaces.first { $0.name == spaceName } ?? Library.shared.addSpace(name: spaceName)
        var known = Set((Library.shared.spaces.first { $0.id == space.id }?.bookmarks ?? []).map { TabManager.normalize($0.url) })
        var added = 0
        for bookmark in bookmarks where !known.contains(TabManager.normalize(bookmark.url)) {
            if Library.shared.addBookmark(url: bookmark.url, title: bookmark.title, to: space.id) != nil {
                known.insert(TabManager.normalize(bookmark.url))
                added += 1
                FaviconStore.shared.prefetch(for: bookmark.url)
            }
        }
        return added
    }
}
