import Foundation
import CryptoKit

/// `chrome.userScripts`, as Tampermonkey, Violentmonkey and ScriptCat use it in Chrome: the extension hands over
/// scripts (code of its own making, or files from its package) with the sites they're for, and they run there.
///
/// WebKit has no user-script API, but it has content scripts an extension registers itself
/// (`scripting.registerContentScripts`). Those already match sites, pick frames, run at the right moment and can
/// message the extension, with the same tab IDs `chrome.tabs` uses, which is the hard part. So each user script
/// becomes one: Zigzag writes its code to a file in the extension's loaded copy (WebKit takes files, not code), and
/// bridge.js registers that file. Chrome keeps user scripts across restarts; so does Zigzag, in UserScripts.json
/// beside the extension. Each time the background starts, missing files are written again and bridge.js registers
/// whatever WebKit no longer has.
///
/// One difference from Chrome: a user script runs in the extension's content-script world, not a world of its own,
/// so it could also reach what content scripts can (`chrome.storage`). Chrome's user-script world can already
/// message the extension's background when the extension asks (Tampermonkey does), and the background can do
/// anything, so the scripts are trusted no more than in Chrome. A world's own CSP (`configureWorld`) is kept and
/// answered, not applied: WebKit runs content scripts outside the page's CSP anyway.
@available(macOS 15.4, *)
@MainActor
final class BridgeUserScripts: BridgeNamespace {
    static let name = "userScripts"
    static let permission = "userScripts"
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    /// The folder in the extension's loaded copy that the files go in.
    static let folderName = "zigzag-user-scripts"

    /// What each extension registered, as it gave it, and its world settings. Read from disk on first use.
    private struct Registry {
        var scripts: [[String: Any]] = []
        var worlds: [[String: Any]] = []
    }
    private var registries: [String: Registry] = [:]

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "register":
            var registry = registry(for: extensionID)
            let scripts = args.objects(0)
            try Self.checkNew(scripts, existing: Set(registry.scripts.compactMap { $0.string("id") }))
            let made = try scripts.map { try contentScript(for: $0, extensionID: extensionID) }
            registry.scripts += scripts
            save(registry, for: extensionID)
            return made
        case "update":
            // Chrome's update replaces the fields given and keeps the rest.
            var registry = registry(for: extensionID)
            var made: [[String: Any]] = []
            for changes in args.objects(0) {
                let id = changes.string("id") ?? ""
                guard let index = registry.scripts.firstIndex(where: { $0.string("id") == id }) else {
                    throw BridgeError("Script with ID '\(id)' does not exist or is not fully registered")
                }
                let script = registry.scripts[index].merging(changes) { $1 }
                try Self.check(script)
                made.append(try contentScript(for: script, extensionID: extensionID))
                registry.scripts[index] = script
            }
            save(registry, for: extensionID)
            tidy(extensionID)
            return made
        case "unregister":
            var registry = registry(for: extensionID)
            let all = registry.scripts.compactMap { $0.string("id") }
            let ids = args.object(0)["ids"] as? [String] ?? all
            if let missing = ids.first(where: { !all.contains($0) }) { throw BridgeError("Nonexistent script ID '\(missing)'") }
            registry.scripts.removeAll { ids.contains($0.string("id") ?? "") }
            save(registry, for: extensionID)
            tidy(extensionID)
            return ids
        case "getScripts":
            let scripts = registry(for: extensionID).scripts
            guard let ids = args.object(0)["ids"] as? [String] else { return scripts }
            return scripts.filter { ids.contains($0.string("id") ?? "") }
        case "restore":
            // The background has started: bridge.js registers again whatever WebKit no longer has.
            return tidy(extensionID)
        case "execute":
            // A one-off run (Chrome 135): the files for scripting.executeScript, which bridge.js calls.
            let injection = args.object(0)
            let script: [String: Any] = ["id": "execute", "js": injection["js"] ?? [], "matches": ["<all_urls>"], "world": injection["world"] ?? "USER_SCRIPT"]
            try Self.check(script)
            return try contentScript(for: script, extensionID: extensionID)
        case "configureWorld":
            var registry = registry(for: extensionID)
            let properties = args.object(0)
            registry.worlds.removeAll { $0.string("worldId") == properties.string("worldId") }
            registry.worlds.append(properties)
            save(registry, for: extensionID)
            return nil
        case "getWorldConfigurations":
            return registry(for: extensionID).worlds
        case "resetWorldConfiguration":
            var registry = registry(for: extensionID)
            registry.worlds.removeAll { $0.string("worldId") == args.string(0) }
            save(registry, for: extensionID)
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    /// Turned off or removed: WebKit has already forgotten its content scripts; their files go too. What it
    /// registered stays (the removal deletes it with the extension's folder), for when it's turned back on.
    func release(_ extensionID: String) {
        if let folder = filesFolder(for: extensionID) { try? FileManager.default.removeItem(at: folder) }
        registries[extensionID] = nil
    }

    // MARK: Checks

    /// Chrome's checks for scripts being registered, with Chrome's words, so an extension that reads them can tell.
    static func checkNew(_ scripts: [[String: Any]], existing: Set<String>) throws {
        var seen = existing
        for script in scripts {
            let id = script.string("id") ?? ""
            guard !id.isEmpty else { throw BridgeError("Script's ID must not be empty") }
            guard !id.hasPrefix("_") else { throw BridgeError("Script's ID '\(id)' must not start with '_'") }
            guard seen.insert(id).inserted else { throw BridgeError("Duplicate script ID '\(id)'") }
            try check(script)
        }
    }

    static func check(_ script: [String: Any]) throws {
        let id = script.string("id") ?? ""
        guard !(script["matches"] as? [String] ?? []).isEmpty else { throw BridgeError("Script with ID '\(id)' must specify at least one match.") }
        let sources = script["js"] as? [[String: Any]] ?? []
        guard !sources.isEmpty else { throw BridgeError("User script with ID '\(id)' must specify at least one js source.") }
        for source in sources where (source["code"] is String) == (source["file"] is String) {
            throw BridgeError("User script with ID '\(id)' must specify exactly one of 'code' or 'file' as a js source.")
        }
    }

    // MARK: Files

    /// The content script WebKit gets for a user script: its files, written now if they aren't there yet.
    private func contentScript(for script: [String: Any], extensionID: String) throws -> [String: Any] {
        guard let folder = filesFolder(for: extensionID), let root = ExtensionStore.overlayDirectory(for: extensionID) else {
            throw BridgeError("User scripts can't be kept for this extension")
        }
        let includeGlobs = script["includeGlobs"] as? [String] ?? [], excludeGlobs = script["excludeGlobs"] as? [String] ?? []
        var paths: [String] = []
        for source in script["js"] as? [[String: Any]] ?? [] {
            // A file of the extension's own, with no globs to check, is used as it is.
            if let file = source.string("file"), includeGlobs.isEmpty, excludeGlobs.isEmpty {
                paths.append(file.hasPrefix("/") ? String(file.dropFirst()) : file)
                continue
            }
            let code: String
            if let file = source.string("file") {
                let url = root.appendingPathComponent(file.hasPrefix("/") ? String(file.dropFirst()) : file).standardizedFileURL
                guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), let text = try? String(contentsOf: url, encoding: .utf8) else {
                    throw BridgeError("Could not load file: '\(file)'.")
                }
                code = text
            } else {
                code = source.string("code") ?? ""
            }
            let text = Self.fileText(code: code, includeGlobs: includeGlobs, excludeGlobs: excludeGlobs)
            // WebKit reads a file once and keeps what it read (the first test showed a file changed in place still ran
            // as before), so each file is named for what's in it: new code is always a new file.
            let name = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".js"
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { throw BridgeError("Could not store the user script '\(script.string("id") ?? "")'") }
            }
            paths.append(Self.folderName + "/" + name)
        }
        var made: [String: Any] = [
            "id": script.string("id") ?? "", "js": paths, "matches": script["matches"] ?? [],
            "allFrames": script["allFrames"] as? Bool ?? false, "runAt": script.string("runAt") ?? "document_idle",
            // Chrome's user-script world is a world apart from the page; the content-script world is WebKit's nearest.
            "world": script.string("world") == "MAIN" ? "MAIN" : "ISOLATED",
        ]
        if let excludeMatches = script["excludeMatches"] as? [String], !excludeMatches.isEmpty { made["excludeMatches"] = excludeMatches }
        return made
    }

    /// The code, run only where its globs allow (WebKit's content scripts have no globs of their own).
    static func fileText(code: String, includeGlobs: [String], excludeGlobs: [String]) -> String {
        guard !includeGlobs.isEmpty || !excludeGlobs.isEmpty else { return code }
        func list(_ globs: [String]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: globs.map(globPattern), options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return """
        if ((() => { const url = location.href, test = (p) => new RegExp(p).test(url), include = \(list(includeGlobs)), exclude = \(list(excludeGlobs));
          return (!include.length || include.some(test)) && !exclude.some(test); })()) {
        \(code)
        }

        """
    }

    /// A Chrome glob as a regular expression for the whole address: `*` is anything, `?` one character.
    static func globPattern(_ glob: String) -> String {
        var pattern = "^"
        for character in glob {
            switch character {
            case "*": pattern += ".*"
            case "?": pattern += "."
            case "\\", "^", "$", ".", "|", "+", "(", ")", "[", "]", "{", "}", "/": pattern += "\\" + String(character)
            default: pattern.append(character)
            }
        }
        return pattern + "$"
    }

    private func filesFolder(for extensionID: String) -> URL? {
        ExtensionStore.overlayDirectory(for: extensionID)?.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Every registered script's files are there (written again if the loaded copy was made anew), and files no
    /// script uses any more go. Answers the content scripts.
    @discardableResult
    private func tidy(_ extensionID: String) -> [[String: Any]] {
        let made = registry(for: extensionID).scripts.compactMap { try? contentScript(for: $0, extensionID: extensionID) }
        guard let folder = filesFolder(for: extensionID),
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return made }
        let used = Set(made.flatMap { $0["js"] as? [String] ?? [] }.map { ($0 as NSString).lastPathComponent })
        for file in files where !used.contains(file) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        return made
    }

    // MARK: Registry

    private static func registryFile(for extensionID: String) -> URL {
        ExtensionStore.folder(for: extensionID).appendingPathComponent("UserScripts.json")
    }

    private func registry(for extensionID: String) -> Registry {
        if let known = registries[extensionID] { return known }
        var registry = Registry()
        if let data = try? Data(contentsOf: Self.registryFile(for: extensionID)),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            registry.scripts = saved["scripts"] as? [[String: Any]] ?? []
            registry.worlds = saved["worlds"] as? [[String: Any]] ?? []
        }
        registries[extensionID] = registry
        return registry
    }

    private func save(_ registry: Registry, for extensionID: String) {
        registries[extensionID] = registry
        let saved: [String: Any] = ["scripts": registry.scripts, "worlds": registry.worlds]
        guard let data = try? JSONSerialization.data(withJSONObject: saved) else { return }
        try? data.write(to: Self.registryFile(for: extensionID), options: .atomic)
    }
}

private extension Array where Element == Any {
    /// A list of objects, as `register([…])` passes its scripts.
    func objects(_ index: Int) -> [[String: Any]] { indices.contains(index) ? self[index] as? [[String: Any]] ?? [] : [] }
}
