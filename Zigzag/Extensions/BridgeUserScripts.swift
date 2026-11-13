import Foundation
import CryptoKit
import WebKit

/// `chrome.userScripts`, as Tampermonkey, Violentmonkey and ScriptCat use it in Chrome: the extension hands over
/// scripts (code of its own making, or files from its package) with the sites they're for, and they run there.
///
/// As in Chrome, a user script runs in a world of its own, apart from the page and apart from the extension's content
/// scripts: a WKContentWorld per extension (and per `worldId` it names), never the one WebKit gives its content
/// scripts. A script from a site like Greasy Fork is code nobody at the extension wrote, so it gets nothing of the
/// extension's: no `chrome.storage`, no way to change the other scripts, no messages that pass for the extension's
/// own. What Chrome gives that world, Zigzag gives, and nothing more: the extension's ID, `runtime.sendMessage` and
/// `runtime.connect`, which reach the extension's `runtime.onUserScriptMessage` and `onUserScriptConnect` (never
/// `onMessage` or `onConnect`), and `runtime.onMessage` for what the extension sends its tab, all only once the
/// extension asks for them (`configureWorld({ messaging: true })`). Managers treat what arrives there as coming from
/// a script, not from themselves.
///
/// How the pieces go:
/// - Scripts are page scripts Zigzag adds to every web view of the profile (`attach`), each in its world, run where
///   its match patterns, globs and the extension's site access allow, at the time it asks for, in every frame or the
///   top one. Chrome keeps them across restarts; so does Zigzag, in UserScripts.json beside the extension.
/// - A message from the world goes to Zigzag (a script message handler only that world has), and on to the
///   extension from its content-script world in the same frame, which WebKit names "WebExtension-<id>": so WebKit
///   says which tab and frame it came from, as for any content script, and the extension hears it with that sender.
///   bridge.js, in the extension, hands such a message to onUserScriptMessage only, and a port to onUserScriptConnect.
/// - What the extension sends a tab (`tabs.sendMessage`) reaches the worlds in that tab the same way back.
/// - `userScripts.execute` runs its code in the world of each frame scripting.executeScript reaches.
///
/// A world's CSP (`configureWorld`) is applied as far as a world can have one here: without 'unsafe-eval' in its
/// script-src, eval and Function refuse, as in Chrome. WebKit runs these worlds outside the page's CSP, so what Chrome
/// lets the world's CSP open up (an inline script into the page) isn't the world's to decide; where the world's CSP
/// allows inline scripts and the page doesn't, a manager can run that script in its world instead
/// (`__zigzagInlineScript`, which Tampermonkey's fix in ExtensionShims uses).
@available(macOS 15.4, *)
@MainActor
final class BridgeUserScripts: BridgeNamespace {
    static let name = "userScripts"
    static let permission = "userScripts"
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    /// The folder in the extension's loaded copy that earlier versions wrote scripts to, removed when found.
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
            for script in scripts { _ = try sources(of: script, extensionID: extensionID) }
            registry.scripts += scripts
            save(registry, for: extensionID)
            return nil
        case "update":
            // Chrome's update replaces the fields given and keeps the rest.
            var registry = registry(for: extensionID)
            for changes in args.objects(0) {
                let id = changes.string("id") ?? ""
                guard let index = registry.scripts.firstIndex(where: { $0.string("id") == id }) else {
                    throw BridgeError("Script with ID '\(id)' does not exist or is not fully registered")
                }
                let script = registry.scripts[index].merging(changes) { $1 }
                try Self.check(script)
                _ = try sources(of: script, extensionID: extensionID)
                registry.scripts[index] = script
            }
            save(registry, for: extensionID)
            return nil
        case "unregister":
            var registry = registry(for: extensionID)
            let all = registry.scripts.compactMap { $0.string("id") }
            let ids = args.object(0)["ids"] as? [String] ?? all
            if let missing = ids.first(where: { !all.contains($0) }) { throw BridgeError("Nonexistent script ID '\(missing)'") }
            registry.scripts.removeAll { ids.contains($0.string("id") ?? "") }
            save(registry, for: extensionID)
            return ids
        case "getScripts":
            let scripts = registry(for: extensionID).scripts
            guard let ids = args.object(0)["ids"] as? [String] else { return scripts }
            return scripts.filter { ids.contains($0.string("id") ?? "") }
        case "restore":
            // The background has started. Scripts no longer go through WebKit, so this only tidies up after versions
            // that wrote them to files.
            removeOldFiles(extensionID)
            return nil
        case "execute":
            return try prepareExecution(args.object(0), extensionID: extensionID)
        case "executeResults":
            return await executionResults(args.string(0) ?? "", nonces: args.indices.contains(1) ? args[1] as? [String] ?? [] : [])
        case "configureWorld":
            var registry = registry(for: extensionID)
            let properties = args.object(0)
            if let world = properties.string("worldId") { try Self.checkWorldID(world) }
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
        case "frame":
            // The background heard a frame's world say it listens (bridge.js): which tab and frame it's in, by WebKit.
            let details = args.object(0)
            guard let key = details.string("key"), var frame = frames[key], frame.extensionID == extensionID,
                  let tab = details["tabId"] as? Int else { return nil }
            frame.tabID = tab
            frame.frameID = details["frameId"] as? Int
            frame.documentID = details.string("documentId")
            frames[key] = frame
            return nil
        case "tabMessage":
            return await tabMessage(args.object(0), message: args.indices.contains(1) ? args[1] : NSNull(), sender: args.object(2), extensionID: extensionID)
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    /// Turned off or removed: its scripts leave every page from the next load. What it registered stays (the removal
    /// deletes it with the extension's folder), for when it's turned back on.
    func release(_ extensionID: String) {
        removeOldFiles(extensionID)
        registries[extensionID] = nil
        frames = frames.filter { $0.value.extensionID != extensionID }
        executions = executions.filter { $0.value.extensionID != extensionID }
        refresh()
    }

    private func removeOldFiles(_ extensionID: String) {
        if let folder = host.profile.installs.overlayDirectory(for: extensionID)?.appendingPathComponent(Self.folderName, isDirectory: true) {
            try? FileManager.default.removeItem(at: folder)
        }
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
        if let world = script.string("worldId") {
            guard script.string("world") != "MAIN" else { throw BridgeError("User script with ID '\(id)' can't specify a world ID for the main world.") }
            try checkWorldID(world)
        }
    }

    static func checkWorldID(_ world: String) throws {
        guard !world.hasPrefix("_") else { throw BridgeError("World IDs beginning with '_' are reserved.") }
        guard world.count <= 256 else { throw BridgeError("World IDs must be at most 256 characters.") }
    }

    // MARK: Worlds

    /// The worlds' names start with this, never with WebKit's "WebExtension-", which would give them the extension's API.
    static let worldPrefix = "ZigzagUserScripts-"
    /// The message handler each user-script world has, and the one the extension's content-script world has.
    static let worldHandler = "zigzagUserScript"
    static let relayHandler = "zigzagUserScriptRelay"
    /// What starts each of Zigzag's page scripts here, so they can be told from everything else in a web view.
    static let mark = "/* zigzag user scripts */"

    static func worldName(extensionID: String, worldID: String?) -> String {
        worldPrefix + extensionID + (worldID.map { "/" + $0 } ?? "")
    }

    /// The extension and world ID a world's name stands for; nil for any other world.
    static func parseWorld(_ name: String?) -> (extensionID: String, worldID: String?)? {
        guard let name, name.hasPrefix(worldPrefix) else { return nil }
        let rest = name.dropFirst(worldPrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return rest.isEmpty ? nil : (String(rest), nil) }
        return (String(rest[..<slash]), String(rest[rest.index(after: slash)...]))
    }

    /// The world WebKit runs an extension's content scripts in (WebExtensionContext's own name for it).
    static func contentScriptWorld(_ extensionID: String) -> WKContentWorld { WKContentWorld.world(name: "WebExtension-" + extensionID) }

    /// What a world was configured with: its own configuration, or the default one (no worldId), or Chrome's default.
    struct WorldSettings: Equatable {
        var messaging = false
        /// What its CSP allows: eval and Function, and an inline script (which Zigzag runs in the world).
        var allowsEval = false
        var allowsInline = false
    }

    static func settings(for worldID: String?, in worlds: [[String: Any]]) -> WorldSettings {
        let own = worlds.first { $0.string("worldId") == worldID } ?? worlds.first { $0.string("worldId") == nil }
        let csp = own?.string("csp")
        return WorldSettings(messaging: own?["messaging"] as? Bool ?? false,
                             allowsEval: csp.map { allows("'unsafe-eval'", in: $0) } ?? false,
                             allowsInline: csp.map { allows("'unsafe-inline'", in: $0) } ?? false)
    }

    /// Whether a CSP's script-src (or, without one, its default-src) has a source. Chrome's default CSP for the world,
    /// when none was set, allows neither eval nor inline scripts.
    static func allows(_ source: String, in csp: String) -> Bool {
        let directives = csp.split(separator: ";").map { $0.split(whereSeparator: \.isWhitespace).map { $0.lowercased() } }
        let directive = directives.first { $0.first == "script-src" } ?? directives.first { $0.first == "default-src" }
        return directive?.dropFirst().contains(source) ?? false
    }

    // MARK: Pages

    /// Every web view of the profile whose pages run user scripts (Tab adds its own as it makes them).
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private final class Installed { var generation = -1; var handlers: Set<String> = [] }
    private let installed = NSMapTable<WKUserContentController, Installed>.weakToStrongObjects()
    /// Counts up whenever the scripts change: a script registered or removed, a world configured, an extension on or
    /// off, its site access changed.
    private var generation = 0
    private var built: (generation: Int, scripts: [WKUserScript], handlers: [(world: WKContentWorld, name: String)])?
    private lazy var messages = UserScriptMessages(owner: self)

    /// A web view's pages run the profile's user scripts from now on.
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        sync(controller)
    }

    /// The scripts changed: every web view has the new set for its next page, as Chrome's registrations apply.
    func refresh() {
        generation += 1
        for controller in controllers.allObjects { sync(controller) }
    }

    private func sync(_ controller: WKUserContentController) {
        let record = installed.object(forKey: controller) ?? {
            let record = Installed()
            installed.setObject(record, forKey: controller)
            return record
        }()
        guard record.generation != generation else { return }
        let current = currentScripts()
        OwnScripts.remove(from: controller, where: Self.isOurs)
        for handler in current.handlers {
            let key = handler.name + "\u{0}" + (handler.world.name ?? "")
            guard record.handlers.insert(key).inserted else { continue }
            controller.addScriptMessageHandler(messages, contentWorld: handler.world, name: handler.name)
        }
        current.scripts.forEach(controller.addUserScript)
        record.generation = generation
    }

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(mark) }

    /// The page scripts and message handlers for every extension that's on and allowed user scripts.
    private func currentScripts() -> (scripts: [WKUserScript], handlers: [(world: WKContentWorld, name: String)]) {
        if let built, built.generation == generation { return (built.scripts, built.handlers) }
        var scripts: [WKUserScript] = [], handlers: [(world: WKContentWorld, name: String)] = []
        for id in host.profile.installs.installedIDs {
            guard let context = host.context(for: id), ExtensionBridge.allows(Self.permission, for: context) else { continue }
            let registry = registry(for: id)
            handlers.append((Self.contentScriptWorld(id), Self.relayHandler))
            let access = Self.siteAccess(of: context)
            var worldsUsed: [String?] = []
            var made: [(runAt: Int, id: String, script: WKUserScript)] = []
            for script in registry.scripts {
                let main = script.string("world") == "MAIN"
                let worldID = main ? nil : script.string("worldId")
                if !main, !worldsUsed.contains(worldID) { worldsUsed.append(worldID) }
                let world = main ? WKContentWorld.page : WKContentWorld.world(name: Self.worldName(extensionID: id, worldID: worldID))
                guard let codes = try? sources(of: script, extensionID: id) else { continue }
                let runAt = ["document_start": 0, "document_end": 1][script.string("runAt") ?? "document_idle"] ?? 2
                for code in codes {
                    let user = Self.userScript(code: code, matches: script["matches"] as? [String] ?? [], excludeMatches: script["excludeMatches"] as? [String] ?? [],
                                               includeGlobs: script["includeGlobs"] as? [String] ?? [], excludeGlobs: script["excludeGlobs"] as? [String] ?? [],
                                               access: access, injectionTime: runAt == 0 ? .atDocumentStart : .atDocumentEnd,
                                               mainFrameOnly: !(script["allFrames"] as? Bool ?? false), world: world)
                    made.append((runAt, script.string("id") ?? "", user))
                }
            }
            // Each world is readied first, in every frame: what it gives its scripts (messaging, its CSP).
            for worldID in worldsUsed {
                let world = WKContentWorld.world(name: Self.worldName(extensionID: id, worldID: worldID))
                handlers.append((world, Self.worldHandler))
                scripts.append(WKUserScript(source: Self.mark + "\n" + Self.prelude(Self.settings(for: worldID, in: registry.worlds), extensionID: id),
                                            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
            }
            // Chrome runs document_start scripts, then document_end, then document_idle, each by its ID, as Chrome keeps
            // them: Tampermonkey names its own "1|page", "2|…" and "3|content" to run in that order. A script's sources
            // run in their own order.
            scripts += made.enumerated().sorted { ($0.element.runAt, $0.element.id, $0.offset) < ($1.element.runAt, $1.element.id, $1.offset) }
                .map(\.element.script)
        }
        built = (generation, scripts, handlers)
        return (scripts, handlers)
    }

    /// Where the extension may run, as patterns; nil when everywhere. Its scripts run only there, as in Chrome, where
    /// user scripts need the extension's host access.
    static func siteAccess(of context: WKWebExtensionContext) -> (allowed: [String], denied: [String])? {
        let now = Date()
        let denied = context.deniedPermissionMatchPatterns.filter { $0.value > now }.keys.map(\.string).sorted()
        if (context.hasAccessToAllURLs || context.hasAccessToAllHosts) && denied.isEmpty { return nil }
        return (context.grantedPermissionMatchPatterns.filter { $0.value > now }.keys.map(\.string).sorted(), denied)
    }

    /// One source of a user script as a page script: WebKit matches the patterns itself where it can read them, and
    /// anything else (globs, site access, patterns it can't read) is checked by the code before it runs.
    static func userScript(code: String, matches: [String], excludeMatches: [String], includeGlobs: [String], excludeGlobs: [String],
                           access: (allowed: [String], denied: [String])?, injectionTime: WKUserScriptInjectionTime,
                           mainFrameOnly: Bool, world: WKContentWorld) -> WKUserScript {
        let include = webKitPatterns(matches), exclude = webKitPatterns(excludeMatches)
        let native = include != nil && exclude != nil && canMatchNatively
        var checks: [String] = []
        if !native { checks.append(matchCheck(allowed: matches, denied: excludeMatches)) }
        if !includeGlobs.isEmpty || !excludeGlobs.isEmpty { checks.append(globCheck(include: includeGlobs, exclude: excludeGlobs)) }
        if let access { checks.append(matchCheck(allowed: access.allowed, denied: access.denied)) }
        let body = checks.isEmpty ? code : "if (\(checks.joined(separator: " && "))) {\n\(code)\n}\n"
        let source = mark + "\n" + body
        if native, let include, let exclude,
           let script = matchingScript(source: source, injectionTime: injectionTime, mainFrameOnly: mainFrameOnly, include: include, exclude: exclude, world: world) {
            return script
        }
        let fallback = native ? mark + "\n" + "if (\(([matchCheck(allowed: matches, denied: excludeMatches)] + checks).joined(separator: " && "))) {\n\(code)\n}\n" : source
        return WKUserScript(source: fallback, injectionTime: injectionTime, forMainFrameOnly: mainFrameOnly, in: world)
    }

    /// WebKit's own way to give a page script match patterns, as it does for content scripts. Not public; without
    /// it, the code checks its patterns itself.
    private static let matchingInit = NSSelectorFromString("_initWithSource:injectionTime:forMainFrameOnly:includeMatchPatternStrings:excludeMatchPatternStrings:associatedURL:contentWorld:")
    static var canMatchNatively: Bool { class_getInstanceMethod(WKUserScript.self, matchingInit) != nil }

    private static func matchingScript(source: String, injectionTime: WKUserScriptInjectionTime, mainFrameOnly: Bool,
                                       include: [String], exclude: [String], world: WKContentWorld) -> WKUserScript? {
        guard let method = class_getInstanceMethod(WKUserScript.self, matchingInit),
              let allocated = (WKUserScript.self as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, NSString, Int, Bool, NSArray, NSArray, NSURL?, WKContentWorld) -> Unmanaged<WKUserScript>?
        let initialize = unsafeBitCast(method_getImplementation(method), to: Init.self)
        return initialize(allocated, matchingInit, source as NSString, injectionTime.rawValue, mainFrameOnly, include as NSArray, exclude as NSArray, nil, world)?
            .takeRetainedValue()
    }

    /// Chrome's patterns as WebKit reads them, or nil if one isn't something it reads the same way: a port, a query, a
    /// scheme it doesn't take. `<all_urls>` is every web address and file.
    static func webKitPatterns(_ patterns: [String]) -> [String]? {
        var out: [String] = []
        for pattern in patterns {
            if pattern == "<all_urls>" { out += ["*://*/*", "file:///*"]; continue }
            guard let parts = patternParts(pattern), ["*", "http", "https", "file"].contains(parts.scheme),
                  !parts.host.contains(":"), !parts.path.contains("?"), !parts.path.contains("#") else { return nil }
            out.append(pattern)
        }
        return out
    }

    private static func patternParts(_ pattern: String) -> (scheme: String, host: String, path: String)? {
        guard let separator = pattern.range(of: "://") else { return nil }
        let scheme = String(pattern[..<separator.lowerBound]).lowercased(), rest = pattern[separator.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash]), path = String(rest[slash...])
        guard scheme == "file" || !host.isEmpty else { return nil }
        let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        if name != "*", name.dropFirst(name.hasPrefix("*.") ? 2 : 0).contains("*") { return nil }
        return (scheme, host, path)
    }

    /// A Chrome match pattern as a regular expression for an address without its fragment; nil if it isn't one.
    static func patternRegex(_ pattern: String) -> String? {
        if pattern == "<all_urls>" { return "^(?:https?|wss?|ftp|file)://" }
        guard let parts = patternParts(pattern) else { return nil }
        let schemes = ["*": "(?:https?|wss?)", "http": "http", "https": "https", "file": "file", "ftp": "ftp", "ws": "ws", "wss": "wss"]
        guard let scheme = schemes[parts.scheme] else { return nil }
        var host: String
        let hostPart = parts.host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let port = parts.host.contains(":") ? parts.host.split(separator: ":", maxSplits: 1).last.map(String.init) : nil
        if hostPart == "*" { host = "[^/:]*" } else if hostPart.hasPrefix("*.") { host = "(?:[^/:]*\\.)?" + escaped(String(hostPart.dropFirst(2))) } else { host = escaped(hostPart) }
        // No port in the pattern matches any port, as in Chrome; `*` matches any.
        host += port.map { $0 == "*" ? "(?::\\d+)?" : ":" + escaped($0) } ?? "(?::\\d+)?"
        let path = parts.path.map { $0 == "*" ? ".*" : escaped(String($0)) }.joined()
        return "^" + scheme + "://" + (parts.scheme == "file" ? "" : host) + path + "$"
    }

    private static func escaped(_ text: String) -> String { NSRegularExpression.escapedPattern(for: text) }

    /// A test of the address against Chrome's patterns, for the code to make before it runs.
    private static func matchCheck(allowed: [String], denied: [String]) -> String {
        "(() => { const url = location.href.split('#')[0], test = (p) => new RegExp(p).test(url); return \(json(allowed.compactMap(patternRegex))).some(test) && !\(json(denied.compactMap(patternRegex))).some(test); })()"
    }

    private static func globCheck(include: [String], exclude: [String]) -> String {
        "(() => { const url = location.href, test = (p) => new RegExp(p).test(url), include = \(json(include.map(globPattern))), exclude = \(json(exclude.map(globPattern))); return (!include.length || include.some(test)) && !exclude.some(test); })()"
    }

    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// The code, run only where its globs allow (WebKit's page scripts have no globs of their own).
    static func fileText(code: String, includeGlobs: [String], excludeGlobs: [String]) -> String {
        guard !includeGlobs.isEmpty || !excludeGlobs.isEmpty else { return code }
        return "if (\(globCheck(include: includeGlobs, exclude: excludeGlobs))) {\n\(code)\n}\n"
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

    /// A script's code, each source in turn: its own, or a file of the extension's package, never one outside it.
    private func sources(of script: [String: Any], extensionID: String) throws -> [String] {
        let root = (host.profile.installs.overlayDirectory(for: extensionID) ?? ExtensionStore.packageDirectory(for: extensionID))?.standardizedFileURL
        return try (script["js"] as? [[String: Any]] ?? []).map { source in
            if let code = source.string("code") { return code }
            let file = source.string("file") ?? ""
            guard let root else { throw BridgeError("Could not load file: '\(file)'.") }
            let url = root.appendingPathComponent(file.hasPrefix("/") ? String(file.dropFirst()) : file).standardizedFileURL
            guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { throw BridgeError("Could not load file: '\(file)'.") }
            return text
        }
    }

    // MARK: Messages

    /// A frame's world that listens for what the extension sends its tab: where it is, by Zigzag and by WebKit.
    private struct Frame {
        weak var webView: WKWebView?
        let info: WKFrameInfo
        let extensionID: String
        let world: String
        var tabID: Int?
        var frameID: Int?
        var documentID: String?
    }
    private var frames: [String: Frame] = [:]

    /// A message from a user-script world (`world`) or from the extension's content-script world in that frame.
    fileprivate func receive(_ message: WKScriptMessage) async -> (Any?, String?) {
        guard let webView = message.webView, let body = message.body as? [String: Any], let kind = body.string("kind") else { return (nil, "Unknown message") }
        let frame = message.frameInfo
        if message.name == Self.relayHandler {
            // From the extension's content-script world: something for a user-script world in the same frame.
            guard let worldName = message.world.name, worldName.hasPrefix("WebExtension-") else { return (nil, nil) }
            let extensionID = String(worldName.dropFirst("WebExtension-".count))
            guard host.context(for: extensionID) != nil else { return (nil, nil) }
            switch kind {
            case "execute":
                return (await execute(token: body.string("token") ?? "", nonce: body.string("nonce") ?? "", extensionID: extensionID, in: webView, frame: frame), nil)
            case "port-message", "port-disconnect":
                guard let worldID = body["worldName"] as? String, Self.parseWorld(worldID)?.extensionID == extensionID else { return (nil, nil) }
                _ = try? await webView.callAsyncJavaScript(Self.receiveCall, arguments: ["packet": body], in: frame, contentWorld: WKContentWorld.world(name: worldID))
                return (nil, nil)
            default:
                return (nil, nil)
            }
        }
        // From a user-script world: only what Chrome lets it say, only once the extension turned messaging on.
        guard let world = Self.parseWorld(message.world.name), let context = host.context(for: world.extensionID),
              ExtensionBridge.allows(Self.permission, for: context),
              Self.settings(for: world.worldID, in: registry(for: world.extensionID).worlds).messaging else {
            return (nil, "Could not establish connection. Receiving end does not exist.")
        }
        if let target = body.string("target"), target != world.extensionID { return (nil, "Could not establish connection. Receiving end does not exist.") }
        guard let key = body.string("key"), !key.isEmpty else { return (nil, "Unknown message") }
        let worldName = message.world.name ?? ""
        var op: [String: Any] = ["kind": kind, "key": key, "worldName": worldName]
        switch kind {
        case "send": op["message"] = body["message"] ?? NSNull()
        case "connect": op["port"] = body["port"] ?? 0; op["name"] = body.string("name") ?? ""
        case "post": op["port"] = body["port"] ?? 0; op["message"] = body["message"] ?? NSNull()
        case "disconnect": op["port"] = body["port"] ?? 0
        case "listen":
            if frames.count > 2_000 { frames = frames.filter { $0.value.webView != nil } }
            frames[key] = Frame(webView: webView, info: frame, extensionID: world.extensionID, world: worldName)
            op["kind"] = "hello"
        default: return (nil, "Unknown message")
        }
        do {
            let answer = try await webView.callAsyncJavaScript(Self.relayCall, arguments: ["op": op], in: frame, contentWorld: Self.contentScriptWorld(world.extensionID))
            return (["value": ExtensionBridge.plain(answer) ?? NSNull()], nil)
        } catch {
            return (nil, (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? "Could not establish connection. Receiving end does not exist.")
        }
    }

    /// `tabs.sendMessage` from the extension: to the worlds in that tab that listen (and the frame, or document, it
    /// names). The first answer is the one; with none, whether any heard it.
    private func tabMessage(_ target: [String: Any], message: Any, sender: [String: Any], extensionID: String) async -> [String: Any] {
        guard let tab = target["tabId"] as? Int else { return ["reached": 0] }
        let frameID = target["frameId"] as? Int, documentID = target.string("documentId")
        frames = frames.filter { $0.value.webView != nil }
        let reached = frames.filter { _, frame in
            frame.extensionID == extensionID && frame.tabID == tab && (frameID == nil || frame.frameID == frameID) && (documentID == nil || frame.documentID == documentID)
        }
        guard !reached.isEmpty else { return ["reached": 0] }
        final class First { var done = false; var left: Int; var heard = 0; init(_ left: Int) { self.left = left } }
        let first = First(reached.count)
        return await withCheckedContinuation { continuation in
            for (key, frame) in reached {
                Task { @MainActor in
                    var answer: [String: Any]?
                    if let webView = frame.webView {
                        let packet: [String: Any] = ["kind": "tab-message", "key": key, "message": message, "sender": sender]
                        answer = (try? await webView.callAsyncJavaScript(Self.receiveCall, arguments: ["packet": packet], in: frame.info,
                                                                         contentWorld: WKContentWorld.world(name: frame.world))) as? [String: Any]
                    }
                    if answer == nil || answer?["none"] != nil { self.frames[key] = answer == nil ? nil : self.frames[key] } else { first.heard += 1 }
                    guard !first.done else { return }
                    if let answer, answer.keys.contains("value") {
                        first.done = true
                        continuation.resume(returning: ["reached": first.heard, "answered": true, "value": answer["value"] ?? NSNull()])
                        return
                    }
                    first.left -= 1
                    if first.left == 0 {
                        first.done = true
                        continuation.resume(returning: ["reached": first.heard])
                    }
                }
            }
        }
    }

    // MARK: Running once

    /// What `userScripts.execute` runs, until each frame scripting.executeScript reached has asked for it.
    private struct Execution {
        let extensionID: String
        let codes: [String]
        /// A user-script world's name, or nil for the page's own world (MAIN).
        let world: String?
        var results: [String: [String: Any]] = [:]
    }
    private var executions: [String: Execution] = [:]

    private func prepareExecution(_ injection: [String: Any], extensionID: String) throws -> [String: Any] {
        let main = injection.string("world") == "MAIN"
        let script: [String: Any] = ["id": "execute", "js": injection["js"] ?? [], "matches": ["<all_urls>"],
                                     "world": main ? "MAIN" : "USER_SCRIPT", "worldId": injection["worldId"] ?? NSNull()]
        var checked = script
        if checked["worldId"] is NSNull { checked["worldId"] = nil }
        try Self.check(checked)
        let codes = try sources(of: checked, extensionID: extensionID)
        let token = UUID().uuidString
        let world = main ? nil : Self.worldName(extensionID: extensionID, worldID: checked.string("worldId"))
        if executions.count > 50 { executions.removeAll() }
        executions[token] = Execution(extensionID: extensionID, codes: codes, world: world)
        return ["token": token]
    }

    /// Runs the code in one frame, in its world, readied first as its registered scripts would find it.
    private func execute(token: String, nonce: String, extensionID: String, in webView: WKWebView, frame: WKFrameInfo) async -> Any? {
        guard let execution = executions[token], execution.extensionID == extensionID, !nonce.isEmpty else { return nil }
        let world = execution.world.map(WKContentWorld.world(name:)) ?? .page
        var result: [String: Any] = [:]
        do {
            if let name = execution.world {
                let settings = Self.settings(for: Self.parseWorld(name)?.worldID, in: registry(for: extensionID).worlds)
                _ = try await webView.evaluateJavaScript(Self.prelude(settings, extensionID: extensionID) + "\n;undefined", in: frame, contentWorld: world)
            }
            var value: Any?
            for code in execution.codes { value = try await webView.evaluateJavaScript(code, in: frame, contentWorld: world) }
            if let plain = ExtensionBridge.plain(value) { result["value"] = plain }
        } catch {
            result["error"] = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        }
        executions[token]?.results[nonce] = result
        return nil
    }

    /// Each frame's result, once every frame named has one (or a while has passed). The execution is then over.
    private func executionResults(_ token: String, nonces: [String]) async -> [String: Any] {
        let deadline = Date().addingTimeInterval(30)
        while let execution = executions[token], !nonces.allSatisfy({ execution.results[$0] != nil }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let results = executions.removeValue(forKey: token)?.results ?? [:]
        return results
    }

    // MARK: Scripts in the worlds

    /// What a user-script world is given before its scripts run: Chrome's messaging API, if the extension turned it
    /// on, and its CSP's eval rule.
    static func prelude(_ settings: WorldSettings, extensionID: String) -> String {
        let config = json(["messaging": settings.messaging, "eval": settings.allowsEval, "inline": settings.allowsInline, "id": extensionID])
        return preludeSource.replacingOccurrences(of: "__CONFIG__", with: config)
    }

    private static let preludeSource = #"""
    (() => {
      if (globalThis.__zigzagUserScriptWorld) return;
      Object.defineProperty(globalThis, '__zigzagUserScriptWorld', { value: true });
      const config = __CONFIG__;
      // An inline script the page won't run, run here instead, where the world's CSP allows inline scripts.
      const run = globalThis.eval;
      if (config.inline) Object.defineProperty(globalThis, '__zigzagInlineScript', { value: (code) => run(String(code)) });
      // Without 'unsafe-eval', strings aren't run as code, as Chrome's CSP for the world has it.
      if (!config.eval) {
        const refuse = () => { throw new EvalError("Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source of script in this world's Content Security Policy."); };
        const guard = (F) => new Proxy(F, { apply: refuse, construct: refuse });
        try { Object.defineProperty(globalThis, 'eval', { value: guard(run), writable: true, configurable: true }); } catch (e) {}
        for (const F of [Function, (async function () {}).constructor, (function* () {}).constructor, (async function* () {}).constructor]) {
          const guarded = guard(F);
          try { Object.defineProperty(F.prototype, 'constructor', { value: guarded, writable: true, configurable: true }); } catch (e) {}
          if (F === Function) { try { Object.defineProperty(globalThis, 'Function', { value: guarded, writable: true, configurable: true }); } catch (e) {} }
        }
      }
      const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
      const handler = config.messaging && handlers && handlers.zigzagUserScript;
      if (!handler) return;
      const post = handler.postMessage.bind(handler);
      const key = (() => { try { return crypto.randomUUID(); } catch (e) { return String(Math.random()).slice(2) + String(Date.now()); } })();
      // What Chrome carries is what JSON carries.
      const plain = (value) => (value === undefined ? null : JSON.parse(JSON.stringify(value)));
      let lastError;
      const withError = (error, callback) => {
        lastError = error ? { message: String((error && error.message) || error) } : undefined;
        try { callback(); } finally { lastError = undefined; }
      };
      const event = (wrap) => {
        const listeners = new Map();
        return {
          listeners,
          addListener(f) { if (typeof f === 'function' && !listeners.has(f)) { listeners.set(f, wrap ? wrap(f) : f); if (this.onAdd) this.onAdd(); } },
          removeListener(f) { listeners.delete(f); },
          hasListener(f) { return listeners.has(f); },
          hasListeners() { return listeners.size > 0; },
        };
      };
      const ports = new Map();
      let lastPort = 0;
      const makePort = (id, name) => {
        let closed = false;
        const api = { name, sender: undefined };
        const onMessage = event((f) => (message) => f(message, api)), onDisconnect = event((f) => () => f(api));
        Object.assign(api, {
          onMessage, onDisconnect,
          postMessage(message) {
            if (closed) throw new Error('Attempting to use a disconnected port object');
            post({ kind: 'post', key, port: id, message: plain(message) }).catch(() => {});
          },
          disconnect() {
            if (closed) return;
            closed = true;
            ports.delete(id);
            post({ kind: 'disconnect', key, port: id }).catch(() => {});
          },
        });
        const fire = (set, ...args) => { for (const f of [...set.values()]) { try { f(...args); } catch (e) { console.error(e); } } };
        return {
          api,
          message: (message) => fire(onMessage.listeners, message),
          disconnected: (error) => { if (closed) return; closed = true; ports.delete(id); withError(error ? { message: error } : null, () => fire(onDisconnect.listeners)); },
        };
      };
      const sendMessage = (...args) => {
        const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        let target = null;
        const looksLikeOptions = (o) => o && typeof o === 'object' && Object.keys(o).every((k) => k === 'includeTlsChannelId');
        if (args.length >= 3 || (args.length === 2 && typeof args[0] === 'string' && !looksLikeOptions(args[1]))) target = args.shift();
        const message = args[0];
        const result = Promise.resolve().then(() => post({ kind: 'send', key, target, message: plain(message) }))
          .then((reply) => (reply ? reply.value : undefined));
        if (!callback) return result;
        result.then((value) => withError(null, () => callback(value)), (error) => withError(error, () => callback()));
        return undefined;
      };
      const connect = (...args) => {
        const target = typeof args[0] === 'string' ? args.shift() : null;
        const info = args[0] && typeof args[0] === 'object' ? args[0] : {};
        const id = ++lastPort;
        const port = makePort(id, info.name === undefined ? '' : String(info.name));
        ports.set(id, port);
        post({ kind: 'connect', key, target, port: id, name: port.api.name }).catch((error) => port.disconnected(error && error.message));
        return port.api;
      };
      const onMessage = event(), onConnect = event();
      onMessage.onAdd = () => { if (!onMessage.told) { onMessage.told = true; post({ kind: 'listen', key }).catch(() => {}); } };
      // The listener lists stay Zigzag's: the events show only Chrome's methods.
      const messageListeners = onMessage.listeners;
      delete onMessage.listeners;
      delete onConnect.listeners;
      // Its ID too, which Chrome gives the world with messaging (Tampermonkey and Violentmonkey read it as they start).
      const runtime = { id: config.id, sendMessage, connect, onMessage, onConnect };
      Object.defineProperty(runtime, 'lastError', { get: () => lastError, enumerable: true });
      Object.defineProperty(globalThis, 'chrome', { value: { runtime }, writable: true, configurable: true });
      // What Zigzag hands this world from the extension: a port's message or end, a message to its tab.
      Object.defineProperty(globalThis, '__zigzagUserScriptReceive', { value: (packet) => {
        if (!packet || packet.key !== key) return { none: true };
        if (packet.kind === 'port-message' || packet.kind === 'port-disconnect') {
          const port = ports.get(packet.port);
          if (port) { if (packet.kind === 'port-message') port.message(packet.message); else port.disconnected(packet.error); }
          return { heard: true };
        }
        if (packet.kind !== 'tab-message') return { none: true };
        const heard = [...messageListeners.values()];
        if (!heard.length) return { none: true };
        return new Promise((resolve) => {
          let done = false, waits = false;
          const respond = (value) => { if (!done) { done = true; resolve({ value: plain(value) }); } };
          for (const f of heard) {
            let result;
            try { result = f(packet.message, packet.sender || {}, respond); } catch (e) { console.error(e); continue; }
            if (result === true) waits = true;
            else if (result && typeof result.then === 'function') { waits = true; result.then(respond, () => respond(undefined)); }
          }
          if (!waits && !done) { done = true; resolve({ heard: true }); }
        });
      } });
    })();
    """#

    /// Hands a packet to a user-script world (its prelude's receiver), in the frame it's for.
    private static let receiveCall = "return globalThis.__zigzagUserScriptReceive ? await globalThis.__zigzagUserScriptReceive(packet) : { none: true };"

    /// Runs in the extension's content-script world, in the frame a user-script world spoke from: passes what it said
    /// on to the extension as WebKit's own messaging, so the extension hears which tab and frame, and keeps the ports.
    static let relayCall = #"""
    const relay = globalThis.__zigzagUserScriptRelay || (() => {
      const api = globalThis.browser || globalThis.chrome;
      const MARK = '__zigzagUserScript';
      const ports = new Map();
      const tell = (packet) => {
        try { const sent = globalThis.webkit.messageHandlers.zigzagUserScriptRelay.postMessage(packet); if (sent && sent.catch) sent.catch(() => {}); } catch (e) {}
      };
      const relay = async (op) => {
        const id = op.worldName + '|' + op.key + '|' + op.port;
        const from = { key: op.key, world: op.worldName };
        switch (op.kind) {
          case 'send':
            return await api.runtime.sendMessage({ [MARK]: Object.assign({ kind: 'message', message: op.message }, from) });
          case 'hello':
            try { await api.runtime.sendMessage({ [MARK]: Object.assign({ kind: 'hello' }, from) }); } catch (e) {}
            return null;
          case 'connect': {
            const port = api.runtime.connect({ name: MARK + JSON.stringify({ name: op.name, key: op.key, world: op.worldName }) });
            ports.set(id, port);
            const base = { key: op.key, worldName: op.worldName, port: op.port };
            port.onMessage.addListener((message) => tell(Object.assign({ kind: 'port-message', message }, base)));
            port.onDisconnect.addListener(() => {
              ports.delete(id);
              const error = api.runtime.lastError;
              tell(Object.assign({ kind: 'port-disconnect', error: error ? String(error.message || error) : null }, base));
            });
            return null;
          }
          case 'post': { const port = ports.get(id); if (port) port.postMessage(op.message); return null; }
          case 'disconnect': { const port = ports.get(id); ports.delete(id); if (port) port.disconnect(); return null; }
        }
        return null;
      };
      Object.defineProperty(globalThis, '__zigzagUserScriptRelay', { value: relay });
      return relay;
    })();
    return await relay(op);
    """#

    // MARK: Registry

    private func registryFile(for extensionID: String) -> URL {
        host.profile.installs.folder(for: extensionID).appendingPathComponent("UserScripts.json")
    }

    private func registry(for extensionID: String) -> Registry {
        if let known = registries[extensionID] { return known }
        var registry = Registry()
        if let data = try? Data(contentsOf: registryFile(for: extensionID)),
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
        if let data = try? JSONSerialization.data(withJSONObject: saved) { try? data.write(to: registryFile(for: extensionID), options: .atomic) }
        refresh()
    }
}

/// Hears the user-script worlds and the extensions' content-script worlds for BridgeUserScripts, holding it weakly:
/// web views keep their handlers for as long as they live.
@available(macOS 15.4, *)
@MainActor
private final class UserScriptMessages: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: BridgeUserScripts?
    init(owner: BridgeUserScripts) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "Could not establish connection. Receiving end does not exist."); return }
        Task { @MainActor in
            let (value, error) = await owner.receive(message)
            replyHandler(value, error)
        }
    }
}

private extension Array where Element == Any {
    /// A list of objects, as `register([…])` passes its scripts.
    func objects(_ index: Int) -> [[String: Any]] { indices.contains(index) ? self[index] as? [[String: Any]] ?? [] : [] }
}
