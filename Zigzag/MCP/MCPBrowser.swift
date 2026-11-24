import AppKit
import WebKit

/// The tools, run on your windows and tabs: the same windows and tab ids AppleScript sees (never a private window,
/// nor Zigzag Mini), and only websites in them. In the background (Headless), only AI apps' own window, never yours.
nonisolated struct MCPBrowserRunner: MCPToolRunner {
    var tools: [JSON] { MCPTools.definitions }

    func call(_ name: String, arguments: [String: JSON], client: MCPClient) async -> MCPToolResult {
        switch MCPCommand.parse(name, arguments) {
        case .failure(let error): return .error(error.message)
        // Tool results contain page-written content: titles, text, links, fields.
        case .success(let command): return await MCPBrowser.run(command, client: client).markedAsPageContent()
        }
    }
}

@MainActor
enum MCPBrowser {
    static let loadTimeout: TimeInterval = 20

    static func run(_ command: MCPCommand, client: MCPClient) async -> MCPToolResult {
        // Turned off while the request was on its way: nothing happens.
        guard MCPService.isOn else { return .error("Zigzag's MCP server was turned off in Settings.") }
        // Never continue after Stop or an off/on toggle while waiting.
        let generation = AgentControl.shared.generation
        switch command {
        case .listTabs:
            if case .success(let front) = locate(nil) { noteListing(front.tab, by: client) }
            return .data(["tabs": .array(listTabs())])
        case .openTab(let url, let background): return await openTab(url, background: background, client: client)
        default: break
        }
        let found: Found
        switch locate(command.tabID) {
        case .failure(let error): return .error(error.message)
        case .success(let value): found = value
        }
        let tab = found.tab
        let needsPage: Bool, actsOnPage: Bool
        switch command {
        case .activate, .close, .goBack, .goForward, .reload: (needsPage, actsOnPage) = (false, false)
        case .navigate: (needsPage, actsOnPage) = (false, true)
        default: (needsPage, actsOnPage) = (true, true)
        }
        if let refusal = MCPSafety.refusal(url: tab.url, isPrivate: tab.isPrivate, stopped: AgentControl.shared.isStopped(tab.id),
                                           errorPage: actsOnPage && tab.showsErrorPage, outsideHeadless: outsideHeadless(tab), needsPage: needsPage) {
            return .error(MCPSafety.message(refusal))
        }
        AgentControl.shared.touch(tab, by: client)
        return told(await act(command, on: found, since: generation), about: tab)
    }

    /// What the page asked with no one there, reported once with the next answer.
    private static func told(_ result: MCPToolResult, about tab: Tab) -> MCPToolResult {
        telling(result, of: tab.takeUnanswered().map { ($0.kind.rawValue, $0.message, $0.page) })
    }

    /// Does what the tool asks on a tab it may use.
    private static func act(_ command: MCPCommand, on found: Found, since generation: Int) async -> MCPToolResult {
        let tab = found.tab
        switch command {
        case .activate:
            found.controller.tabManager.select(tab)
            // In front of Zigzag's other windows, keyboard left alone; their unseen window stays parked.
            if found.controller !== Headless.window { found.controller.window?.orderFront(nil) }
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
            return await page(tab, since: generation) { webView in
                switch await MCPPageScript.run("read", ["maxChars": maxChars], in: webView) {
                case .failure(let error): return .pageError(error.message)
                case .success(let object): return .data(json(object))
                }
            }
        case .links(_, let max):
            return await page(tab, since: generation) { webView in
                switch await MCPPageScript.run("links", ["max": max], in: webView) {
                case .failure(let error): return .pageError(error.message)
                case .success(let object): return .data(json(object))
                }
            }
        case .snapshot(_, let filter, let depth, let ref, let maxChars):
            return await page(tab, since: generation) { webView in
                var args: [String: Any] = [:]
                if let ref { args["ref"] = ref }
                switch await MCPPageScript.run("snapshot", args, in: webView) {
                case .failure(let error): return .pageError(error.message)
                case .success(let object):
                    guard let answer = JSON(foundation: object), let snapshot = MCPSnapshot(answer) else { return .error("The page gave no snapshot.") }
                    let written = snapshot.text(filter: filter, depth: depth, maxChars: maxChars)
                    // The page's own text goes once, as text; the structured part only says what it is.
                    let about: JSON = ["title": .string(snapshot.title), "url": .string(MCPSnapshot.withoutFragment(snapshot.url)),
                                       "refs": .int(snapshot.refs), "truncated": .bool(written.truncated || snapshot.cut)]
                    return MCPToolResult(content: [["type": "text", "text": .string(written.text)]], structured: about)
                }
            }
        case .screenshot:
            return await page(tab, since: generation) { webView in
                // A background tab of their window is held out of sight for the picture.
                guard webView.window == nil, found.controller === Headless.window else {
                    return await screenshot(webView, tab: tab, in: found.controller)
                }
                return await screenshotOutOfSight(webView, tab: tab, in: found.controller)
            }
        case .click(_, let target):
            return await page(tab, since: generation) { webView in
                let before = webView.backForwardList.currentItem
                switch await MCPPageScript.run("click", target.args, in: webView) {
                case .failure(let error): return .pageError(error.message)
                case .success(let object):
                    // A click often starts a page load: given a moment to begin, then waited for.
                    await waitForLoad(tab, from: before, grace: 0.6)
                    var result = json(object).object ?? [:]
                    result["tab"] = info(tab, in: found.controller)
                    return .data(.object(result))
                }
            }
        case .type(_, let target, let text, let clear, let submit):
            return await page(tab, since: generation) { webView in
                let before = webView.backForwardList.currentItem
                let args = target.args.merging(["text": text, "clear": clear, "submit": submit]) { $1 }
                switch await MCPPageScript.run("type", args, in: webView) {
                case .failure(let error):
                    if error.message == "password" { return .error("That's a password field. Zigzag never lets AI apps type passwords; ask the person to type it.") }
                    return .pageError(error.message)
                case .success(let object):
                    if submit { await waitForLoad(tab, from: before, grace: 0.6) }
                    return .data(json(object))
                }
            }
        case .scroll(_, let dy, let target):
            return await page(tab, since: generation) { webView in
                let args = (target?.args ?? [:]).merging(["dy": dy]) { $1 }
                switch await MCPPageScript.run("scroll", args, in: webView) {
                case .failure(let error): return .pageError(error.message)
                case .success(let object): return .data(json(object))
                }
            }
        case .waitFor(_, let condition, let timeoutMs):
            return await waitFor(condition, timeout: TimeInterval(timeoutMs) / 1000, in: tab, controller: found.controller, since: generation)
        case .pressKey(_, let press, let element):
            return await page(tab, since: generation) { webView in
                let before = webView.backForwardList.currentItem
                let target: [String: Any]
                switch await MCPPageScript.run("keyTarget", element?.args ?? [:], in: webView) {
                case .failure(let error): return .pageError(error.message)
                case .success(let object): target = object
                }
                if press.editsText, target["secret"] as? Bool == true {
                    return .error("The focus is in a password field. Zigzag never lets AI apps type passwords; ask the person to type it.")
                }
                if press.editsText || press.reachesFrame, target["inFrame"] as? Bool == true {
                    return .error("The focus is in a frame from another site inside the page, where Zigzag can't tell what the key would do. Click or focus something in the page itself first.")
                }
                // The page answered after a wait: still allowed, on the same kind of page?
                if let refusal = refusal(for: tab, webView: webView, since: generation) { return .error(MCPSafety.message(refusal)) }
                let after = await MCPKeyDelivery.press(press, in: webView)
                if press.mayNavigate { await waitForLoad(tab, from: before, grace: 0.6) }
                var result: [String: JSON] = ["pressed": .string(press.name)]
                result["target"] = target["focused"].flatMap { json($0) } ?? .null
                result["focused"] = after
                result["tab"] = info(tab, in: found.controller)
                return .data(.object(result))
            }
        case .listTabs, .openTab: return .error("Unexpected.")
        }
    }

    /// wait_for: the tab woken if it slept, then the page watches for the condition, for `timeout` at most.
    private static func waitFor(_ condition: MCPWaitCondition, timeout: TimeInterval, in tab: Tab, controller: BrowserWindowController, since generation: Int) async -> MCPToolResult {
        let webView: WKWebView
        if let awakeView = tab.webView { webView = awakeView } else { webView = await awake(tab) }
        if let refusal = refusal(for: tab, webView: webView, since: generation) {
            return .error(MCPSafety.message(refusal))
        }
        let wait = MCPWait(condition, in: webView, timeout: timeout) { [weak tab, weak webView] in
            guard let tab, !tab.isClosed else { return "The tab was closed while waiting, so the wait ended." }
            guard let webView, tab.webView === webView else { return "The tab went to sleep while waiting, so the wait ended." }
            if !MCPService.isOn { return MCPWait.stoppedMessage }
            // Stopped, or now on a page no tool may use (the load it waited for went to one).
            if let refusal = refusal(for: tab, webView: webView, since: generation) {
                return MCPSafety.message(refusal)
            }
            return nil
        }
        switch await wait.run() {
        case .failed(let message): return .error(message)
        case .matched(let object, let elapsedMs):
            var result: [String: JSON] = ["matched": .string(condition.name), "elapsed_ms": .int(elapsedMs)]
            if let value = condition.value { result["value"] = .string(value) }
            if let element = object["element"] { result["element"] = json(element) }
            result["tab"] = info(tab, in: controller)
            return .data(.object(result))
        }
    }

    // MARK: Tabs

    struct Found {
        let tab: Tab
        let controller: BrowserWindowController
    }

    /// The windows apps may use, front first, never private; in the background only theirs.
    private static var windows: [BrowserWindowController] {
        guard Headless.isActive else { return Scripting.windows }
        return Headless.window.map { [$0] } ?? []
    }

    /// AI apps work in the background, and the tab isn't one of theirs.
    private static func outsideHeadless(_ tab: Tab) -> Bool { Headless.isActive && !Headless.owns(tab) }

    /// A window's tabs as apps list them; in the background only their profile's.
    private static func tabs(of controller: BrowserWindowController) -> [Tab] {
        let all = Scripting.tabs(of: controller.tabManager)
        return Headless.isActive ? all.filter(\.profile.isHeadless) : all
    }

    /// A tab by its id, or with none, the one in front.
    static func locate(_ id: Int?) -> Result<Found, MCPArgumentError> {
        guard let id else {
            guard let controller = windows.first, let tab = controller.tabManager.selectedTab else { return .failure(.init("No window is open. Use open_tab.")) }
            return .success(Found(tab: tab, controller: controller))
        }
        for controller in windows {
            if let tab = Scripting.tab(withID: id, in: tabs(of: controller), uuid: \.id) { return .success(Found(tab: tab, controller: controller)) }
        }
        // One of your tabs, while AI apps work in the background: said as such, not as gone.
        if Headless.isActive, (Scripting.windows + [Headless.window].compactMap { $0 }).contains(where: { Scripting.tab(withID: id, in: Scripting.tabs(of: $0.tabManager), uuid: \.id) != nil }) {
            return .failure(.init(MCPSafety.message(.notHeadless)))
        }
        return .failure(.init("No open tab has id \(id). Use list_tabs for the tabs there are now."))
    }

    /// list_tabs shows on the bar like other tools, over the front tab unless tools can't use it.
    static func noteListing(_ front: Tab, by client: MCPClient, control: AgentControl = .shared) {
        guard MCPSafety.refusal(url: front.url, isPrivate: front.isPrivate, stopped: control.isStopped(front.id), outsideHeadless: outsideHeadless(front),
                                needsPage: false) == nil else { return }
        control.touch(front, by: client)
    }

    static func listTabs() -> [JSON] {
        var rows: [JSON] = []
        for (index, controller) in windows.enumerated() {
            for tab in tabs(of: controller) {
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
        if let refusal = MCPSafety.refusal(url: tab.url, isPrivate: tab.isPrivate, stopped: AgentControl.shared.isStopped(tab.id),
                                           outsideHeadless: outsideHeadless(tab), needsPage: false) {
            row["usable"] = false
            row["note"] = .string(MCPSafety.message(refusal))
        }
        return .object(row)
    }

    private static func openTab(_ url: URL, background: Bool, client: MCPClient) async -> MCPToolResult {
        // While AI apps work in the background, in their own window, never one of yours.
        let controller = Headless.isActive ? Headless.openWindow() : windows.first ?? WindowManager.shared.newWindow(showCommandBar: false)
        let tab = controller.tabManager.newTab(url: nil, select: !background)
        AgentControl.shared.touch(tab, by: client)
        tab.load(url)
        await waitForLoad(tab, from: nil, expectStart: true)
        return told(.data(info(tab, in: controller)), about: tab)
    }

    /// Holds pages pictured out of sight, one per window, under everything where the page is.
    private static let pictureHostID = NSUserInterfaceItemIdentifier("zigzag.mcp.picture-host")

    private static func pictureHost(in controller: BrowserWindowController) -> NSView {
        let root = controller.root
        if let host = root.subviews.first(where: { $0.identifier == pictureHostID }) {
            host.frame = root.cardFrame
            return host
        }
        let host = NSView(frame: root.cardFrame)
        host.identifier = pictureHostID
        root.addSubview(host, positioned: .below, relativeTo: nil)
        return host
    }

    /// Pictures a tab that isn't in front by holding its page out of sight.
    private static func screenshotOutOfSight(_ webView: WKWebView, tab: Tab, in controller: BrowserWindowController) async -> MCPToolResult {
        let host = pictureHost(in: controller)
        guard let letGo = tab.holdOutOfSight(in: host, size: host.bounds.size) else {
            // Now in the window, or with no page yet: pictured as any tab.
            guard webView.window != nil else { return .error("That tab's page hasn't loaded enough to take a picture of yet. Wait for it (wait_for), then try again.") }
            return await screenshot(webView, tab: tab, in: controller)
        }
        defer { letGo() }
        // A moment in the window first, for it to draw.
        try? await Task.sleep(for: .milliseconds(250))
        return await screenshot(webView, tab: tab, in: controller)
    }

    // MARK: Pages

    /// Runs `body` on the tab's page once it's awake and loaded, if it's still a page a tool may use by then.
    private static func page(_ tab: Tab, since generation: Int, _ body: @MainActor (WKWebView) async -> MCPToolResult) async -> MCPToolResult {
        // A page whose process ended while out of sight reloads now, not when someone looks.
        tab.reloadIfItStopped()
        let webView = await awake(tab)
        // Woken or done loading, it may be on another page now, or AI apps turned off meanwhile: checked again.
        if let refusal = refusal(for: tab, webView: webView, since: generation) {
            return .error(MCPSafety.message(refusal))
        }
        return await body(webView)
    }

    /// `result` with what was dismissed on which page, fenced as the page's own words.
    nonisolated static func telling(_ result: MCPToolResult, of asked: [(kind: String, message: String, page: String)]) -> MCPToolResult {
        guard !asked.isEmpty else { return result }
        var told = result
        told.fromPages = true
        let page = { (address: String) in MCPSnapshot.clipped(MCPSnapshot.withoutFragment(plain(address))) }
        let rows: [JSON] = asked.map { ["type": .string($0.kind), "message": .string(plain($0.message)), "page": .string(page($0.page)), "answer": "dismissed"] }
        if var object = result.structured?.object {
            object["dialogs"] = .array(rows)
            told.structured = .object(object)
        }
        let lines = asked.map {
            "- \($0.kind)" + ($0.message.isEmpty ? "" : " " + MCPSnapshot.quote(plain($0.message)))
                + ($0.page.isEmpty ? "" : " on " + MCPSnapshot.quote(page($0.page))) + ": dismissed"
        }
        told.content.append(["type": "text", "text": .string("No one was there to answer, so what the page asked was dismissed:\n" + lines.joined(separator: "\n"))])
        return told
    }

    /// A page's words for one line: no control characters, at most 200.
    nonisolated static func plain(_ text: String) -> String {
        let seen = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator ? " " : scalar
        }.filter { $0.properties.generalCategory != .format && !$0.properties.isDefaultIgnorableCodePoint }))
        return MCPSnapshot.clipped(seen.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    /// Why a tool can't go on with the tab's page now, after a wait: checked again each time one ends.
    private static func refusal(for tab: Tab, webView: WKWebView, since generation: Int) -> MCPSafety.Refusal? {
        MCPSafety.refusal(url: webView.url ?? tab.url, isPrivate: tab.isPrivate,
                          stopped: AgentControl.shared.isStopped(tab.id) || AgentControl.shared.stopped(since: generation),
                          errorPage: tab.showsErrorPage, on: MCPService.isOn, outsideHeadless: outsideHeadless(tab))
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
