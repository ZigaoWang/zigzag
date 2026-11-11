import AppKit
import WebKit

/// The tools, run on your windows and tabs: the same windows and tab ids AppleScript sees (never a private window,
/// nor Zigzag Mini), and only websites in them.
nonisolated struct MCPBrowserRunner: MCPToolRunner {
    var tools: [JSON] { MCPTools.definitions }

    func call(_ name: String, arguments: [String: JSON], client: MCPClient) async -> MCPToolResult {
        switch MCPCommand.parse(name, arguments) {
        case .failure(let error): return .error(error.message)
        case .success(let command): return await MCPBrowser.run(command, client: client)
        }
    }
}

@MainActor
enum MCPBrowser {
    static let loadTimeout: TimeInterval = 20

    static func run(_ command: MCPCommand, client: MCPClient) async -> MCPToolResult {
        // Turned off while the request was on its way: nothing happens.
        guard MCPService.isOn else { return .error("Zigzag's MCP server was turned off in Settings.") }
        switch command {
        case .listTabs: return .data(["tabs": .array(listTabs())])
        case .openTab(let url, let background): return await openTab(url, background: background, client: client)
        default: break
        }
        let found: Found
        switch locate(command.tabID) {
        case .failure(let error): return .error(error.message)
        case .success(let value): found = value
        }
        let tab = found.tab
        let needsPage: Bool
        switch command {
        case .activate, .close, .navigate: needsPage = false
        default: needsPage = true
        }
        if let refusal = MCPSafety.refusal(url: tab.url, isPrivate: tab.isPrivate, stopped: AgentControl.shared.isStopped(tab.id), needsPage: needsPage) {
            return .error(MCPSafety.message(refusal))
        }
        AgentControl.shared.touch(tab, by: client)
        switch command {
        case .activate:
            found.controller.tabManager.select(tab)
            // In front of Zigzag's other windows, without taking the keyboard from the app you're in.
            found.controller.window?.orderFront(nil)
            return .data(info(tab, in: found.controller))
        case .close:
            let closed = info(tab, in: found.controller)
            found.controller.tabManager.close(tab)
            return .data(["closed": closed])
        case .navigate(_, let url):
            let before = tab.webView?.backForwardList.currentItem
            tab.load(url)
            await waitForLoad(tab, from: before)
            return .data(info(tab, in: found.controller))
        case .goBack:
            guard tab.canGoBack else { return .error("There's no page to go back to.") }
            let before = tab.webView?.backForwardList.currentItem
            tab.goBack()
            await waitForLoad(tab, from: before)
            return .data(info(tab, in: found.controller))
        case .goForward:
            guard tab.canGoForward else { return .error("There's no page to go forward to.") }
            let before = tab.webView?.backForwardList.currentItem
            tab.goForward()
            await waitForLoad(tab, from: before)
            return .data(info(tab, in: found.controller))
        case .reload:
            tab.reload()
            await waitForLoad(tab, from: nil, expectStart: true)
            return .data(info(tab, in: found.controller))
        case .read(_, let maxChars):
            return await page(tab) { webView in
                switch await MCPPageScript.run("read", ["maxChars": maxChars], in: webView) {
                case .failure(let error): return .error(error.message)
                case .success(let object): return .data(json(object))
                }
            }
        case .links(_, let max):
            return await page(tab) { webView in
                switch await MCPPageScript.run("links", ["max": max], in: webView) {
                case .failure(let error): return .error(error.message)
                case .success(let object): return .data(json(object))
                }
            }
        case .screenshot:
            return await page(tab) { webView in await screenshot(webView, tab: tab, in: found.controller) }
        case .click(_, let selector, let text):
            return await page(tab) { webView in
                let before = webView.backForwardList.currentItem
                var args: [String: Any] = [:]
                if let selector { args["selector"] = selector }
                if let text { args["text"] = text }
                switch await MCPPageScript.run("click", args, in: webView) {
                case .failure(let error): return .error(error.message)
                case .success(let object):
                    // A click often starts a page load: given a moment to begin, then waited for.
                    await waitForLoad(tab, from: before, grace: 0.6)
                    var result = json(object).object ?? [:]
                    result["tab"] = info(tab, in: found.controller)
                    return .data(.object(result))
                }
            }
        case .type(_, let selector, let text, let clear, let submit):
            return await page(tab) { webView in
                let before = webView.backForwardList.currentItem
                switch await MCPPageScript.run("type", ["selector": selector, "text": text, "clear": clear, "submit": submit], in: webView) {
                case .failure(let error):
                    return .error(error.message == "password" ? "That's a password field. Zigzag never lets AI apps type passwords; ask the person to type it." : error.message)
                case .success(let object):
                    if submit { await waitForLoad(tab, from: before, grace: 0.6) }
                    return .data(json(object))
                }
            }
        case .scroll(_, let dy, let selector):
            return await page(tab) { webView in
                var args: [String: Any] = ["dy": dy]
                if let selector { args["selector"] = selector }
                switch await MCPPageScript.run("scroll", args, in: webView) {
                case .failure(let error): return .error(error.message)
                case .success(let object): return .data(json(object))
                }
            }
        case .listTabs, .openTab: return .error("Unexpected.")
        }
    }

    // MARK: Tabs

    struct Found {
        let tab: Tab
        let controller: BrowserWindowController
    }

    /// The windows apps may use, front first: your everyday ones, never a private one.
    private static var windows: [BrowserWindowController] { Scripting.windows }

    /// A tab by its id, or with none, the one in front.
    static func locate(_ id: Int?) -> Result<Found, MCPArgumentError> {
        guard let id else {
            guard let controller = windows.first, let tab = controller.tabManager.selectedTab else { return .failure(.init("No window is open. Use open_tab.")) }
            return .success(Found(tab: tab, controller: controller))
        }
        for controller in windows {
            if let tab = Scripting.tab(withID: id, in: Scripting.tabs(of: controller.tabManager), uuid: \.id) { return .success(Found(tab: tab, controller: controller)) }
        }
        return .failure(.init("No open tab has id \(id). Use list_tabs for the tabs there are now."))
    }

    static func listTabs() -> [JSON] {
        var rows: [JSON] = []
        for (index, controller) in windows.enumerated() {
            for tab in Scripting.tabs(of: controller.tabManager) {
                rows.append(info(tab, in: controller, window: index + 1))
            }
        }
        return rows
    }

    static func info(_ tab: Tab, in controller: BrowserWindowController, window: Int? = nil) -> JSON {
        let manager = controller.tabManager
        let number = window ?? ((windows.firstIndex { $0 === controller } ?? 0) + 1)
        var row: [String: JSON] = [
            "id": .int(Scripting.id(for: tab.id)),
            "title": .string(tab.displayTitle),
            "url": .string(tab.url?.absoluteString ?? ""),
            "active": .bool(manager.selectedTab === tab),
            "window": .int(number),
            "space": .string(Library.shared.space(tab.spaceID)?.name ?? ""),
            "loading": .bool(tab.isLoading),
        ]
        if tab.isFavorite { row["favorite"] = true } else if tab.bookmarkID != nil { row["pinned"] = true }
        // Listed, but not to be used: Settings, History, an extension's page, a stopped tab.
        if let refusal = MCPSafety.refusal(url: tab.url, isPrivate: tab.isPrivate, stopped: AgentControl.shared.isStopped(tab.id), needsPage: false) {
            row["usable"] = false
            row["note"] = .string(MCPSafety.message(refusal))
        }
        return .object(row)
    }

    private static func openTab(_ url: URL, background: Bool, client: MCPClient) async -> MCPToolResult {
        let controller = windows.first ?? WindowManager.shared.newWindow(showCommandBar: false)
        let tab = controller.tabManager.newTab(url: nil, select: !background)
        AgentControl.shared.touch(tab, by: client)
        tab.load(url)
        await waitForLoad(tab, from: nil, expectStart: true)
        return .data(info(tab, in: controller))
    }

    // MARK: Pages

    /// Runs `body` on the tab's page once it's awake and loaded, if it's still a page a tool may use by then.
    private static func page(_ tab: Tab, _ body: @MainActor (WKWebView) async -> MCPToolResult) async -> MCPToolResult {
        let webView = await awake(tab)
        // Woken or done loading, it may be on another page now: checked again, on that page.
        if let refusal = MCPSafety.refusal(url: webView.url ?? tab.url, isPrivate: tab.isPrivate, stopped: AgentControl.shared.isStopped(tab.id)) {
            return .error(MCPSafety.message(refusal))
        }
        return await body(webView)
    }

    /// The tab's web view, woken if it slept, once its page is done loading (or after a while if it never is).
    private static func awake(_ tab: Tab) async -> WKWebView {
        await withCheckedContinuation { continuation in
            Scripting.whenAwake(tab) { webView in continuation.resume(returning: webView) }
        }
    }

    /// Waits for a navigation to start (it may not: a click that only opens a menu) and then to finish, for a while at most.
    private static func waitForLoad(_ tab: Tab, from before: WKBackForwardListItem?, grace: TimeInterval = 1.5, expectStart: Bool = false) async {
        let start = Date()
        var started = false
        while Date().timeIntervalSince(start) < loadTimeout {
            let item = tab.webView?.backForwardList.currentItem
            if tab.isLoading || (before != nil && item !== before) { started = true }
            if started, !tab.isLoading { break }
            if !started, Date().timeIntervalSince(start) > (expectStart ? 5 : grace) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func screenshot(_ webView: WKWebView, tab: Tab, in controller: BrowserWindowController) async -> MCPToolResult {
        guard webView.window != nil, controller.window?.isVisible == true, webView.bounds.width > 0, webView.bounds.height > 0 else {
            return .error("That tab isn't on screen. Use activate_tab first, then take the screenshot.")
        }
        let configuration = WKSnapshotConfiguration()
        // At most 1600 pixels wide: plenty to read, small enough to send.
        let scale = controller.window?.backingScaleFactor ?? 2
        configuration.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 1600 / scale)))
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .error("Zigzag couldn't take a picture of the page.")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return .error("Zigzag couldn't take a picture of the page.") }
        let note: JSON = ["type": "text", "text": .string("\(tab.displayTitle) — \(webView.url?.absoluteString ?? "") (\(cgImage.width)×\(cgImage.height))")]
        return MCPToolResult(content: [["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"], note])
    }

    private static func json(_ object: Any) -> JSON { JSON(foundation: object) ?? .null }
}
