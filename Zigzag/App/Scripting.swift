import AppKit
import WebKit

/// AppleScript, Shortcuts and `osascript` drive Zigzag the way they drive Safari, through Resources/Zigzag.sdef: its
/// windows, their tabs in every space, and the pages in them. Private windows are never there at all, and running
/// JavaScript in a page waits until you allow it in Settings › Automation, as Safari's Develop menu has it.
enum Scripting {
    /// Settings › Automation. Off until you turn it on: a script that can run JavaScript can read and change
    /// anything on your pages, signed in or not.
    static var allowsJavaScript: Bool {
        get { UserDefaults.standard.bool(forKey: "AllowJavaScriptFromAppleEvents") }
        set { UserDefaults.standard.set(newValue, forKey: "AllowJavaScriptFromAppleEvents") }
    }

    /// A web address a script or another app hands over: http and https only, never one of Zigzag's own pages, an
    /// extension's, a file, or a javascript: or data: one.
    static func webAddress(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host()?.isEmpty == false else { return nil }
        return url
    }

    // MARK: Windows and tabs

    /// The windows scripts see, front to back: never a private one, nor Zigzag Mini.
    static var windows: [BrowserWindowController] {
        let order = NSApp.orderedWindows
        return scriptable(WindowManager.shared.controllers, isPrivate: \.tabManager.isPrivate).sorted { a, b in
            (a.window.flatMap(order.firstIndex) ?? .max) < (b.window.flatMap(order.firstIndex) ?? .max)
        }
    }

    static func scriptable<T>(_ windows: [T], isPrivate: (T) -> Bool) -> [T] { windows.filter { !isPrivate($0) } }

    static func controller(for window: NSWindow?) -> BrowserWindowController? {
        windows.first { $0.window === window }
    }

    /// The window in front, for a command that names no tab or window.
    static var frontWindow: BrowserWindowController? { windows.first }

    /// A window's tabs as a script lists them, in the sidebar's order: the favorites' open pages, then space by space
    /// its pinned tabs' open pages and its tabs. Every window shows the same tabs (#162): a window lists those that are
    /// in it, the ones it has on screen or last had, so each tab is listed once.
    static func tabs(of manager: TabManager) -> [Tab] {
        ordered(favorites: Library.shared.favorites.map(\.id),
                spaces: Library.shared.spaces.map { ($0.id, $0.bookmarks.map(\.id)) },
                bookmarkTabs: manager.bookmarkTabs, tabs: manager.tabs(in:))
            .filter { tab in WindowManager.shared.window(of: tab).map { $0.tabManager === manager } ?? true }
    }

    static func ordered<T>(favorites: [UUID], spaces: [(id: UUID, pinned: [UUID])], bookmarkTabs: [UUID: T], tabs: (UUID) -> [T]) -> [T] {
        favorites.compactMap { bookmarkTabs[$0] } + spaces.flatMap { space in space.pinned.compactMap { bookmarkTabs[$0] } + tabs(space.id) }
    }

    /// Each tab's number for scripts (`tab id 3`): a plain number, as Chrome's are, the same until Zigzag quits.
    private static var ids: [UUID: Int] = [:]
    private static var lastID = 0

    static func id(for tab: UUID) -> Int {
        if let id = ids[tab] { return id }
        lastID += 1
        ids[tab] = lastID
        return lastID
    }

    static func tab<T>(withID id: Int, in tabs: [T], uuid: (T) -> UUID) -> T? {
        tabs.first { ids[uuid($0)] == id }
    }

    // MARK: Pages

    /// Why JavaScript from a script can't run in a page, or nil when it can.
    enum Refusal: Equatable {
        case turnedOff, privateWindow, notAWebPage
    }

    /// Only in a web page or a local file, never in Zigzag's own pages or an extension's, which can do more than a page.
    static func javaScriptRefusal(url: URL?, isPrivate: Bool, allowed: Bool) -> Refusal? {
        if !allowed { return .turnedOff }
        if isPrivate { return .privateWindow }
        return isWebPage(url) ? nil : .notAWebPage
    }

    /// A page whose text and source a script may read: a website or a local file, outside private windows.
    static func isReadable(url: URL?, isPrivate: Bool) -> Bool { !isPrivate && isWebPage(url) }

    private static func isWebPage(_ url: URL?) -> Bool { ["http", "https", "file"].contains(url?.scheme?.lowercased() ?? "") }

    static func message(for refusal: Refusal) -> String {
        switch refusal {
        case .turnedOff:
            String(localized: "JavaScript from Apple Events is turned off. To allow it, turn on “Allow JavaScript from Apple Events” in Zigzag’s Settings › Automation.",
                   comment: "Error a script gets when it runs JavaScript in a page before the setting is on. The setting's name is in quotes.")
        case .privateWindow:
            String(localized: "Scripts can’t run JavaScript in a private window.", comment: "Error a script gets when it runs JavaScript in a private window's tab.")
        case .notAWebPage:
            String(localized: "Scripts can run JavaScript only in web pages.", comment: "Error a script gets when it runs JavaScript in Settings, History or an extension's page.")
        }
    }

    /// A script's top level that has await or return in it can't run as a plain script, and doesn't: run as the body of
    /// an async function instead, its returned value is the result. Nothing ran the first time, so nothing runs twice.
    static func runsAsFunction(source: String, exceptionMessage: String?) -> Bool {
        guard exceptionMessage?.hasPrefix("SyntaxError") == true else { return false }
        return source.range(of: #"\b(await|return)\b"#, options: .regularExpression) != nil
    }

    /// A page's value as a script gets it: text, numbers and true or false as they read, lists and records as JSON,
    /// nothing for undefined and null.
    static func text(of value: Any?) -> String? {
        // An async function's undefined comes back as an optional with nothing in it.
        if let value, Mirror(reflecting: value).displayStyle == .optional { return text(of: Mirror(reflecting: value).children.first?.value) }
        switch value {
        case nil, is NSNull: return nil
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            return double.isFinite && double == double.rounded() && abs(double) < 1e15 ? String(Int64(double)) : "\(double)"
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let value? where JSONSerialization.isValidJSONObject(value):
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) }
        case let value?: return "\(value)"
        }
    }

    /// Runs a script's JavaScript in the page's own world, as Safari does, so it sees what the page's scripts see.
    static func run(_ source: String, in webView: WKWebView, done: @escaping (Result<String?, ScriptError>) -> Void) {
        func failed(_ error: Error) -> ScriptError {
            let error = error as NSError
            if error.domain == WKError.errorDomain, error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
                return ScriptError(number: errAEEventFailed, message: String(localized: "The result can’t be given as text. For a promise, put await before it and return its value.",
                                                                             comment: "Error a script gets when its JavaScript ends on a value like a promise or a page element."))
            }
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String
            return ScriptError(number: errAEEventFailed, message: message.map { "JavaScript: \($0)" } ?? error.localizedDescription)
        }
        webView.evaluateJavaScript(source) { value, error in
            guard let error else { done(.success(text(of: value))); return }
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            guard runsAsFunction(source: source, exceptionMessage: message) else { done(.failure(failed(error))); return }
            webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): done(.success(text(of: value)))
                case .failure(let error): done(.failure(failed(error)))
                }
            }
        }
    }

    /// A tab asleep (Zigzag unloads ones you haven't looked at in a while) wakes for a script, as it would for you,
    /// and the script goes on once its page has loaded, or after a while if it never does.
    static func whenAwake(_ tab: Tab, _ then: @escaping @MainActor (WKWebView) -> Void) {
        if let webView = tab.webView, !webView.isLoading { then(webView); return }
        let webView = tab.ensureWebView()
        let deadline = Date(timeIntervalSinceNow: 20)
        func check() {
            // Woken, it hasn't always started loading yet: done once it has finished.
            guard webView.isLoading || webView.estimatedProgress < 1, Date() < deadline else { then(webView); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
        }
        check()
    }

    /// The page's text or HTML, for a property a script reads now: read in a world of Zigzag's own, so the page's
    /// scripts can't stand in for it. A property is answered on the spot, so this waits here, for a while at most.
    static func read(_ source: String, in tab: Tab) -> String {
        let box = Box<String?>(nil), finished = Box(false)
        whenAwake(tab) { webView in
            // Woken or done loading, it may be on another page now: one of Zigzag's own has nothing to give.
            guard isReadable(url: webView.url, isPrivate: tab.isPrivate) else { finished.value = true; return }
            webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { result in
                box.value = (try? result.get()) as? String
                finished.value = true
            }
        }
        let deadline = Date(timeIntervalSinceNow: 30)
        while !finished.value, Date() < deadline { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        return box.value ?? ""
    }

    static let textSource = "(document.body || document.documentElement)?.innerText ?? ''"
    static let htmlSource = "document.documentElement?.outerHTML ?? ''"

    struct ScriptError: Error {
        let number: Int
        let message: String
    }

    /// Says what went wrong in the command being run, as the script's error.
    static func fail(_ number: Int, _ message: String) {
        guard let command = NSScriptCommand.current() else { return }
        command.scriptErrorNumber = number
        command.scriptErrorString = message
    }

    static var notAWebAddress: String {
        String(localized: "Not a web address. Use a full address, starting with https:// or http://.",
               comment: "Error a script gets when it opens something other than a website in a tab.")
    }
}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Cocoa scripting calls in on the main thread, through methods AppKit doesn't mark as the main actor's.
nonisolated private func onMain<T>(_ body: @MainActor () -> T) -> T { onMain(with: ()) { _ in body() } }

/// The same, with what the command read beforehand going along as `context`.
nonisolated private func onMain<C, T>(with context: C, _ body: @MainActor (C) -> T) -> T {
    let box = UncheckedBox<T?>(nil), input = UncheckedBox(context)
    MainActor.assumeIsolated { box.value = body(input.value) }
    return box.value!
}

nonisolated private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - The application

extension NSApplication {
    @objc var scriptingWindows: [NSWindow] { Scripting.windows.compactMap(\.window) }

    @objc func valueInScriptingWindowsWithUniqueID(_ id: NSNumber) -> NSWindow? {
        scriptingWindows.first { $0.windowNumber == id.intValue }
    }

    @objc var scriptingName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Zigzag" }
    @objc var scriptingVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

// MARK: - Windows

extension BrowserWindow {
    private var scriptController: BrowserWindowController? { Scripting.controller(for: self) }

    @objc var scriptingID: Int { windowNumber }
    @objc var scriptingIndex: Int { (Scripting.windows.firstIndex { $0.window === self } ?? 0) + 1 }

    @objc var scriptTabs: [ScriptTab] {
        guard let controller = scriptController else { return [] }
        return Scripting.tabs(of: controller.tabManager).map { ScriptTab($0, in: controller) }
    }

    @objc func valueInScriptTabsWithUniqueID(_ id: NSNumber) -> ScriptTab? {
        guard let controller = scriptController,
              let tab = Scripting.tab(withID: id.intValue, in: Scripting.tabs(of: controller.tabManager), uuid: \.id) else { return nil }
        return ScriptTab(tab, in: controller)
    }

    /// The tab on screen. Set, it switches to that tab, and to its space.
    @objc var scriptCurrentTab: Any? {
        get { scriptController.flatMap { controller in controller.tabManager.selectedTab.map { ScriptTab($0, in: controller) } } }
        set {
            let value = (newValue as? NSScriptObjectSpecifier)?.objectsByEvaluatingSpecifier ?? newValue
            guard let controller = scriptController, let chosen = value as? ScriptTab,
                  controller.tabManager.tab(with: chosen.tab.id) === chosen.tab else {
                Scripting.fail(errAENoSuchObject, String(localized: "That tab isn’t in this window.", comment: "Error a script gets when it makes a tab from another window the current tab."))
                return
            }
            controller.tabManager.select(chosen.tab)
        }
    }

    @objc var scriptSpace: String { scriptController?.tabManager.currentSpace.name ?? "" }

    override nonisolated var objectSpecifier: NSScriptObjectSpecifier? {
        onMain {
            guard let app = NSApp.classDescription as? NSScriptClassDescription, scriptController != nil else { return nil }
            return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil, key: "scriptingWindows", uniqueID: NSNumber(value: windowNumber))
        }
    }
}

// MARK: - Tabs

/// A tab as a script sees it: made fresh each time it's asked for, and found again by its id.
@objc(ZigzagScriptTab)
final class ScriptTab: NSObject {
    let tab: Tab
    private weak var controller: BrowserWindowController?

    init(_ tab: Tab, in controller: BrowserWindowController) {
        self.tab = tab
        self.controller = controller
    }

    @objc var uniqueID: Int { Scripting.id(for: tab.id) }

    @objc var scriptIndex: Int {
        guard let controller else { return 0 }
        return (Scripting.tabs(of: controller.tabManager).firstIndex { $0 === tab } ?? 0) + 1
    }

    @objc var scriptName: String { tab.displayTitle }

    @objc var scriptURL: String {
        get { tab.url?.absoluteString ?? "" }
        set {
            guard let url = Scripting.webAddress(newValue) else { Scripting.fail(-50, Scripting.notAWebAddress); return }
            tab.load(url)
        }
    }

    @objc var scriptLoading: Bool { tab.isLoading }
    @objc var scriptPinned: Bool { tab.bookmarkID != nil && !tab.isFavorite }
    @objc var scriptFavorite: Bool { tab.isFavorite }
    @objc var scriptSpace: String { Library.shared.space(tab.spaceID)?.name ?? "" }

    /// The page's text, as Safari's `text` is. Not a web page (Settings, History, an extension's): none to give.
    @objc var scriptText: String { read(Scripting.textSource) }
    @objc var scriptSource: String { read(Scripting.htmlSource) }

    private func read(_ source: String) -> String {
        guard Scripting.isReadable(url: tab.url, isPrivate: tab.isPrivate) else { return "" }
        return Scripting.read(source, in: tab)
    }

    func closeTab() { controller?.tabManager.close(tab) }

    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        closeTab()
        return nil
    }

    /// Commands that name a tab come here, as Cocoa scripting sends them to the object they name.
    @objc func handleTabScriptCommand(_ command: NSScriptCommand) -> Any? {
        perform(command.commandDescription.commandName)
        return nil
    }

    @objc func handleExecuteScriptCommand(_ command: NSScriptCommand) -> Any? {
        Scripting.runJavaScript(command.evaluatedArguments?["JavaScript"] as? String ?? "", in: self, for: command)
    }

    func perform(_ command: String) {
        switch command {
        case "go back": tab.goBack()
        case "go forward": tab.goForward()
        case "delete": closeTab()
        default: tab.reload()
        }
    }

    override nonisolated var objectSpecifier: NSScriptObjectSpecifier? {
        onMain {
            guard let container = controller?.window?.objectSpecifier, let description = container.keyClassDescription else { return nil }
            return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: container, key: "scriptTabs",
                                       uniqueID: NSNumber(value: uniqueID))
        }
    }
}

// MARK: - Commands

/// `make new tab [at end of tabs of window 1] [with properties {URL:…}]`, and `make new window`.
@objc(ZigzagMakeCommand)
nonisolated final class ScriptMakeCommand: NSCreateCommand {
    override func performDefaultImplementation() -> Any? {
        let kind = createClassDescription.className
        guard kind == "tab" || kind == "window" else { return super.performDefaultImplementation() }
        let address = resolvedKeyDictionary["scriptURL"] as? String
        let location = arguments?["Location"] as? NSPositionalSpecifier
        location?.evaluate()
        let container = location?.insertionContainer
        return onMain(with: container) { container -> NSScriptObjectSpecifier? in
            var url: URL?
            if let address {
                guard let parsed = Scripting.webAddress(address) else { Scripting.fail(-50, Scripting.notAWebAddress); return nil }
                url = parsed
            }
            if kind == "window" {
                let controller = WindowManager.shared.newWindow(url: url, showCommandBar: false)
                return controller.window?.objectSpecifier
            }
            let named = (container as? NSWindow).flatMap(Scripting.controller(for:))
            let controller = named ?? Scripting.frontWindow ?? WindowManager.shared.newWindow(showCommandBar: false)
            let tab = controller.tabManager.newTab(url: url)
            return ScriptTab(tab, in: controller).objectSpecifier
        }
    }
}

/// The tabs a command names: one tab, a list of them, a window's current tab, or the front window's with none named.
@MainActor
private func namedTabs(_ receivers: Any?) -> [ScriptTab] {
    switch receivers {
    case let tab as ScriptTab: return [tab]
    case let tabs as [Any]: return tabs.flatMap(namedTabs)
    case let window as NSWindow: return [(window as? BrowserWindow)?.scriptCurrentTab as? ScriptTab].compactMap { $0 }
    default:
        guard let window = Scripting.frontWindow?.window as? BrowserWindow else { return [] }
        return [window.scriptCurrentTab as? ScriptTab].compactMap { $0 }
    }
}

/// `reload`, `go back` and `go forward` with no tab named (the front window's current tab) or a window (its current
/// tab). A tab named goes to the tab itself, as `handleTabScriptCommand:`.
@objc(ZigzagTabCommand)
nonisolated final class ScriptTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let name = commandDescription.commandName
        let receivers = directParameter == nil ? nil : evaluatedReceivers
        onMain(with: receivers) { receivers in
            // Deleting is for the tabs named, never one a window stands in for.
            let tabs = name == "delete" ? namedTabs(receivers).filter { _ in receivers is ScriptTab || receivers is [Any] } : namedTabs(receivers)
            for scripted in tabs { scripted.perform(name) }
        }
        return nil
    }
}

/// `do JavaScript "…" in tab …`, as Safari has it. Chrome's `execute tab … javascript "…"` goes to the tab itself.
@objc(ZigzagJavaScriptCommand)
nonisolated final class ScriptJavaScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let isChromes = commandDescription.commandName == "execute"
        let source = (isChromes ? evaluatedArguments?["JavaScript"] : directParameter) as? String ?? ""
        let target: Any? = isChromes ? (directParameter == nil ? nil : evaluatedReceivers) : evaluatedArguments?["Tab"]
        return onMain(with: (self, target)) { command, target in
            Scripting.runJavaScript(source, in: namedTabs(target).first, for: command)
        }
    }
}

extension Scripting {
    /// Runs a script's JavaScript once it's allowed there. The event waits for the page's answer, suspended, without
    /// holding up Zigzag.
    static func runJavaScript(_ source: String, in scripted: ScriptTab?, for command: NSScriptCommand) -> String? {
        guard let scripted else {
            fail(errAENoSuchObject, String(localized: "There’s no tab to run it in.", comment: "Error a script gets when it runs JavaScript with no window open."))
            return nil
        }
        if let refusal = javaScriptRefusal(url: scripted.tab.url, isPrivate: scripted.tab.isPrivate, allowed: allowsJavaScript) {
            fail(refusal == .turnedOff ? errAEEventNotPermitted : errAEEventFailed, message(for: refusal))
            return nil
        }
        command.suspendExecution()
        whenAwake(scripted.tab) { webView in
            // Asked while it slept or loaded, it may be on another page now: one of Zigzag's own (History, an
            // extension's page), where JavaScript could do more than a website's. Checked again, on that page.
            if let refusal = javaScriptRefusal(url: webView.url, isPrivate: scripted.tab.isPrivate, allowed: allowsJavaScript) {
                command.scriptErrorNumber = refusal == .turnedOff ? errAEEventNotPermitted : errAEEventFailed
                command.scriptErrorString = message(for: refusal)
                command.resumeExecution(withResult: nil)
                return
            }
            run(source, in: webView) { result in
                switch result {
                case .success(let text):
                    command.resumeExecution(withResult: text)
                case .failure(let error):
                    command.scriptErrorNumber = error.number
                    command.scriptErrorString = error.message
                    command.resumeExecution(withResult: nil)
                }
            }
        }
        return nil
    }
}
