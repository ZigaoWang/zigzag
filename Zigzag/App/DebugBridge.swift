import AppKit
import WebKit

/// Debug builds only: lets scripts drive the UI (for screenshots and testing) via distributed notifications.
/// `xcrun swift -e` or the bundled `zz` script posts "app.zigzag.debug" with a command string.
enum DebugBridge {
    #if DEBUG
    static var hovered: [NSView] = []
    private static var scrollLog: [String] = []
    private static var dragTimer: Timer?

    static func recordScroll(_ event: NSEvent) {
        scrollLog.append(String(format: "%.3f phase=%lu mom=%lu dx=%.1f dy=%.1f precise=%d swipeEnabled=%d",
                                event.timestamp, event.phase.rawValue, event.momentumPhase.rawValue,
                                event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0,
                                NSEvent.isSwipeTrackingFromScrollEventsEnabled ? 1 : 0))
        if scrollLog.count > 300 { scrollLog.removeFirst(scrollLog.count - 300) }
    }
    #endif

    static func start() {
        #if DEBUG
        // A second debug copy listens on its own channel, so commands for one never reach the other.
        let channel = ProcessInfo.processInfo.environment["ZIGZAG_DEBUG_CHANNEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "app.zigzag.debug"
        // Delivered even while the copy isn't the active app: macOS holds back distributed notifications for an app
        // in the background, and a copy launched behind the app you're using never becomes active by itself.
        DistributedNotificationCenter.default().addObserver(Listener.shared, selector: #selector(Listener.received(_:)),
                                                            name: .init(channel), object: nil, suspensionBehavior: .deliverImmediately)
        #endif
    }

    #if DEBUG
    private final class Listener: NSObject {
        static let shared = Listener()
        @objc func received(_ note: Notification) {
            let command = (note.object as? String) ?? ""
            DispatchQueue.main.async { MainActor.assumeIsolated { DebugBridge.run(command) } }
        }
    }
    #endif

    #if DEBUG
    /// mini [url] (blank: the quick open bar, as ⌃⌘N), miniquick [text] (the quick open bar, with this typed in it),
    /// miniquickenter, miniquickesc, minibar [text] (⌘L's bar over the mini page), miniext <url> (as a link from another app), minisetting on|off,
    /// minitype <text> (typed into the address field and entered), minimove (Open in), miniclose,
    /// minispace [name] (the strip's space menu, or that space chosen), minicopy (Copy Link), miniresize <w> <h>,
    /// minimenu <char> [cmd|shift|ctrl|opt...] (a menu item's action, sent as the menu would to Zigzag Mini),
    /// ministate <path> (JSON), minishot <path> (the window's own drawing, as a PNG; web content may be blank),
    /// miniclosebrowsers, minijs <script> (run in the mini page), miniesc (Esc in the address field), miniquit,
    /// miniask notifications, minianswer allow|deny|notnow (the site's question), minisave save|notnow,
    /// minieval <path> <script>, miniswipe <dx> [slow] [noend] (as `swipe page`, over the mini page),
    /// miniborderless on|off (Settings › Appearance › Borderless page). With no Zigzag Mini open, miniask and minianswer
    /// use the front browser window.
    /// pageprobe <path> [mark]: every tab of every window, whether its page is alive, its web view and process, and
    /// what its page says of itself (when it was loaded, how, its scroll, a marker left by `mark`) (JSON). `mark`
    /// first leaves the marker in each live page, so a later probe shows which pages loaded again since.
    private static func pageProbe(_ arg: String) {
        let f = arg.split(separator: " ").map(String.init)
        guard let path = f.first else { return }
        let mark = f.dropFirst().first == "mark"
        let script = (mark ? "window.__zzMark = window.__zzMark || Date.now();" : "") + """
        JSON.stringify({ mark: window.__zzMark || null, origin: performance.timeOrigin,
          nav: (performance.getEntriesByType('navigation')[0] || {}).type || null, y: scrollY,
          visibility: document.visibilityState, href: location.href })
        """
        var rows: [[String: Any]] = []
        let group = DispatchGroup()
        for controller in WindowManager.shared.controllers {
            for tab in controller.tabManager.allTabs {
                var row: [String: Any] = ["title": tab.displayTitle, "favorite": tab.isFavorite, "selected": tab === controller.tabManager.selectedTab,
                                          "space": Library.shared.space(tab.spaceID)?.name ?? "", "alive": tab.webView != nil]
                guard let webView = tab.webView else { rows.append(row); continue }
                row["webView"] = "\(ObjectIdentifier(webView).hashValue)"
                row["pid"] = EnergyWatch.processID(of: webView) ?? -1
                row["inWindow"] = webView.window != nil
                group.enter()
                webView.evaluateJavaScript(script) { result, _ in
                    row["page"] = result as? String ?? "no answer"
                    rows.append(row)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
        }
    }

    private static func runMini(_ name: String, _ arg: String) {
        let mini = MiniWindowController.all.last
        switch name {
        case "mini":
            if let url = URL(string: arg), !arg.isEmpty { MiniWindowController.open(url: url) } else { MiniQuickOpen.toggle() }
        case "miniquick":
            if !MiniQuickOpen.isShown { MiniQuickOpen.toggle() }
            if !arg.isEmpty { MiniQuickOpen.current?.debugBar.debugType(arg) }
        case "miniquickenter": MiniQuickOpen.current?.debugBar.debugEnter()
        case "miniquickesc": MiniQuickOpen.current?.debugBar.debugEscape()
        case "minibar": mini?.debugBar(arg)
        case "miniesc2":
            // A real Esc through the event path: the page first, then Zigzag Mini if the page left it alone.
            if let window = mini?.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                                    isARepeat: false, keyCode: 53) {
                window.makeKeyAndOrderFront(nil)
                NSApp.postEvent(e, atStart: false)
            }
        case "miniext": if let url = URL(string: arg) { WindowManager.shared.openExternal(url) }
        case "minisetting": MiniWindowController.opensExternalLinks = arg == "on"
        case "minitype": mini?.debugEnter(arg)
        case "minimove": mini?.openInZigzag()
        case "minispace": mini?.debugSpace(arg)
        case "minicopy": mini?.copyPageURL(nil)
        case "miniresize":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, let window = mini?.window {
                var frame = window.frame
                frame.origin.y += frame.height - n[1]
                frame.size = NSSize(width: n[0], height: n[1])
                window.setFrame(frame, display: true)
            }
        case "miniswipe":
            // miniswipe <dx per step> [slow] [noend]: `swipe page`, over the mini page.
            guard let window = mini?.window else { break }
            sendSwipe(arg, to: window, at: NSPoint(x: window.frame.width / 2, y: window.frame.height / 2))
        case "miniborderless": BrowserRootView.isBorderless = arg == "on"
        case "miniclose": mini?.window?.performClose(nil)
        case "miniclosebrowsers": WindowManager.shared.controllers.forEach { $0.window?.performClose(nil) }
        case "minijs": mini?.tab.webView?.evaluateJavaScript(arg, completionHandler: nil)
        case "miniesc": mini?.debugEscape()
        case "miniquit": NSApp.terminate(nil)
        case "miniask":
            // miniask notifications: the question a page's Notification.requestPermission() asks, without the click
            // it needs first.
            let browser = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first
            guard let tab = mini?.tab ?? browser?.tabManager.selectedTab, let origin = SiteOrigin.of(tab.url) else { break }
            let window = mini?.window ?? browser?.window
            Task {
                let answer = await SitePermissions.requestNotifications(origin: origin, window: window, isPrivate: tab.isPrivate, tab: tab)
                debugLog("miniask \(arg): \(answer.map { $0 ? "allowed" : "not allowed" } ?? "put off")")
            }
        case "minianswer":
            guard let host: PromptHost = mini ?? WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { break }
            PermissionPrompt.debugAnswer(arg == "allow" ? .allow : arg == "deny" ? .deny : .notNow, in: host)
        case "minisave": SavePasswordPrompt.debugAnswer(saved: arg == "save")
        case "minieval":
            // minieval <path> <script>: the script's result (it may await), written to the file.
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let webView = mini?.tab.webView else { break }
            Task {
                let result = try? await webView.callAsyncJavaScript(f[1], arguments: [:], in: nil, contentWorld: .page)
                try? String(describing: result ?? "nil").write(toFile: f[0], atomically: true, encoding: .utf8)
            }
        case "minimenu":
            let f = arg.split(separator: " ").map(String.init)
            guard let ch = f.first, let window = mini?.window else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in f.dropFirst() {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "ctrl": flags.insert(.control); case "opt": flags.insert(.option); default: break }
            }
            func find(in menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if let sub = item.submenu, let found = find(in: sub) { return found }
                    if item.keyEquivalent == ch, item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == flags, item.action != nil { return item }
                }
                return nil
            }
            guard let item = NSApp.mainMenu.flatMap(find(in:)), let action = item.action else { debugLog("minimenu \(arg): no item"); break }
            var responder: NSResponder? = window.firstResponder ?? window
            while let r = responder, !r.responds(to: action) { responder = r.nextResponder }
            let target: AnyObject? = responder ?? (NSApp.responds(to: action) ? NSApp : NSApp.delegate as AnyObject?)
            let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
            if enabled { NSApp.sendAction(action, to: target, from: item) }
            debugLog("minimenu \(arg): item=\(item.title) target=\(target.map { "\(type(of: $0))" } ?? "nil") enabled=\(enabled)")
        case "ministate":
            let minis: [[String: Any]] = MiniWindowController.all.map { m in
                let f = m.window?.frame ?? .zero
                return ["frame": [f.minX, f.minY, f.width, f.height], "url": m.tab.url?.absoluteString ?? "", "title": m.window?.title ?? "",
                        "windowNumber": m.window?.windowNumber ?? 0,
                        "key": m.window?.isKeyWindow == true, "visible": m.window?.isVisible == true, "debug": m.debugState,
                        "screen": m.window?.screen.map { [$0.visibleFrame.minX, $0.visibleFrame.minY, $0.visibleFrame.width, $0.visibleFrame.height] } ?? []]
            }
            let windows: [[String: Any]] = WindowManager.shared.controllers.map { c in
                ["tabs": c.tabManager.tabs(in: c.tabManager.currentSpaceID).map { $0.url?.absoluteString ?? "" },
                 "selected": c.tabManager.selectedTab?.url?.absoluteString ?? "",
                 "key": c.window?.isKeyWindow == true, "visible": c.window?.isVisible == true,
                 "pageShown": c.selectedWebView.map { $0.window === c.window } ?? false]
            }
            let saved = JSONStore.load(SessionState.self, from: Paths.session)?.windows.map { $0.spaces.flatMap { $0.tabs.compactMap { $0.url?.absoluteString } } } ?? []
            var json: [String: Any] = ["minis": minis, "windows": windows, "savedTabs": saved, "setting": MiniWindowController.opensExternalLinks]
            if let quick = MiniQuickOpen.current {
                let f = quick.debugPanelFrame
                json["quickOpen"] = ["windowNumber": quick.window?.windowNumber ?? 0, "visible": quick.window?.isVisible == true,
                                     "key": quick.window?.isKeyWindow == true, "bar": [f.minX, f.minY, f.width, f.height]]
            }
            json["browserWindowNumbers"] = WindowManager.shared.controllers.map { $0.window?.windowNumber ?? 0 }
            // The questions on screen, and which window each is in.
            if let mini { json["permissionInMini"] = PermissionPrompt.debugShowing(in: mini) ?? "" }
            json["permissionInBrowsers"] = WindowManager.shared.controllers.map { PermissionPrompt.debugShowing(in: $0) ?? "" }
            if let save = SavePasswordPrompt.debugShowing {
                json["savePrompt"] = save.text
                json["savePromptInMini"] = save.window != nil && save.window === mini?.window
            }
            // Only a test vault is ever read here, never the person's passwords.
            let path = arg
            Task {
                if PasswordStore.isTestVault { json["testVault"] = ((try? await PasswordStore.shared.all()) ?? []).map { "\($0.origin.host) \($0.username)" } }
                if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: path)) }
            }
        case "minishot":
            guard let view = mini?.window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        default: break
        }
    }

    /// A synthetic two-finger horizontal swipe, `arg` as `swipe` takes it, sent to `window` at `point` (window
    /// coordinates) the way the trackpad's events arrive. Only to this window: nothing goes to the system.
    private static func sendSwipe(_ arg: String, to window: NSWindow, at point: NSPoint) {
        let parts = arg.split(separator: " ")
        guard let first = parts.first, let dx = Int32(first) else { return }
        let phaseless = parts.contains("nophase")
        let screenPoint = window.convertPoint(toScreen: point)
        let flipped = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y)
        var phases: [Int64] = [1]
        phases += Array(repeating: 2, count: parts.contains("slow") ? 48 : 12)
        if !parts.contains("noend") { phases.append(4) }
        for (i, phase) in phases.enumerated() {
            let d: Int32 = phase == 2 ? dx : 0
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: d, wheel3: 0) else { continue }
            cg.location = flipped
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseless ? 0 : phase)
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(d))
            cg.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds) + UInt64(i) * 16_000_000
            if let event = NSEvent(cgEvent: cg) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.016) { window.sendEvent(event) }
            }
        }
    }

    /// windowsdump <path>: every window's views, WebKit's own full screen window too, without bringing any forward
    /// (which would take a page out of its full screen).
    /// The extension popup showing, without bringing the browser window forward (that would close it):
    /// popupwinstate <path> (its window: key, first responder; JSON), popupwinclick <x> <y> (a click there, in the
    /// popup's points from its top left), popupwintype <text> (keys pressed one by one, to whichever window is key,
    /// as typing goes), popupwinjs <path> <script> (the script's result in the popup page).
    private static func popupWindow(_ name: String, _ arg: String) {
        guard #available(macOS 15.4, *) else { return }
        let popovers = Profiles.shared.all.compactMap { $0.isDefault ? $0.extensions : $0.startedExtensions }.flatMap(\.debugShownPopovers)
        let popover = popovers.last
        let window = popover?.contentViewController?.view.window
        func findWeb(_ v: NSView?) -> WKWebView? { (v as? WKWebView) ?? v?.subviews.lazy.compactMap(findWeb).first }
        let popupPage = findWeb(popover?.contentViewController?.view)
        switch name {
        case "popupwinstate":
            var webView: NSView? = window?.firstResponder as? NSView
            while let v = webView, !(v is WKWebView) { webView = v.superview }
            let state: [String: Any] = ["popovers": popovers.count, "window": window.map { "\(type(of: $0))" } ?? "none",
                                        "key": window?.isKeyWindow ?? false, "canBecomeKey": window?.canBecomeKey ?? false,
                                        "appKey": NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none",
                                        "firstResponder": window?.firstResponder.map { "\(type(of: $0))" } ?? "none",
                                        "responderInWebView": webView != nil,
                                        "page": popupPage?.url?.absoluteString ?? "-"]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "popupwinclick":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            guard n.count == 2, let window, let content = window.contentView else { break }
            let point = NSPoint(x: n[0], y: content.frame.height - n[1])
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "popupwintype":
            let codes: [Character: UInt16] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "a": 0, "b": 11, "c": 8]
            let target = NSApp.keyWindow ?? window
            for ch in arg {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let target, let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: target.windowNumber, context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch),
                                                                isARepeat: false, keyCode: codes[ch] ?? 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        case "popupwinjs":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let webView = popupPage else {
                debugLog("popupwinjs: no popup"); break
            }
            webView.evaluateJavaScript(f[1]) { result, error in
                try? "\(result.map { "\($0)" } ?? "nil") \(error.map { "\($0)" } ?? "")".write(toFile: f[0], atomically: true, encoding: .utf8)
            }
        default: break
        }
    }

    private static func dumpWindows(to path: String) {
        var out = ""
        func walk(_ v: NSView, _ depth: Int) {
            out += String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden) alpha=\(v.alphaValue)"
                + " autoresizing=\(v.translatesAutoresizingMaskIntoConstraints) constraints=\(v.constraints.count)\n"
            if depth < 8 { v.subviews.forEach { walk($0, depth + 1) } }
        }
        for window in NSApp.windows {
            out += "== \(type(of: window)) #\(window.windowNumber) \(window.frame) visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "fullScreen=\(window.styleMask.contains(.fullScreen)) level=\(window.level.rawValue) title=\(window.title)\n"
            if let frameView = window.contentView?.superview { walk(frameView, 1) }
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The mini player, without bringing the window forward: mpstate <path> (JSON), mphover on|off (its controls, as
    /// the pointer brings them), mppress back|site|double|minimize|close|play|rewind|forward, mpdrag <dx> <dy> [free] (dragged that far and
    /// let go, with ⌘ held for free), mpselect <index> (as `select`), mpwindow <path> (window number and process), mpeval <index> <path> <script>
    /// (the script's result in that tab's page, which it may await, written to the file).
    private static func runMiniPlayer(_ name: String, _ arg: String, in controller: BrowserWindowController) {
        let player = controller.miniPlayer
        switch name {
        case "mpstate":
            if let data = try? JSONSerialization.data(withJSONObject: player.debugState, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "mphover": player.card?.debugHover(arg != "off")
        // mppointer on|off: the pointer counts as on the card (for the sidebar's hover previews).
        case "mppointer": player.debugPointerOnCard = arg != "off"
        case "mppress": player.card?.debugPress(arg)
        case "mpdrag":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count >= 2 { player.card?.debugDrag(dx: n[0], dy: n[1], free: arg.hasSuffix(" free")) }
        // mpresize <edges> <dx> <dy>: those edges (l, r, t, b, or a corner as "tl") dragged that far and let go.
        case "mpresize":
            let f = arg.split(separator: " ").map(String.init)
            if f.count == 3, let dx = Double(f[1]), let dy = Double(f[2]) { player.card?.debugResize(f[0], dx: dx, dy: dy) }
        case "mpselect": controller.tabManager.select(at: Int(arg) ?? 0)
        case "mpwindow":
            if let window = controller.window {
                try? "\(window.windowNumber) \(ProcessInfo.processInfo.processIdentifier)".write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "mpeval":
            let f = arg.split(separator: " ", maxSplits: 2).map(String.init)
            let list = controller.tabManager.navigableTabs
            guard f.count == 3, let i = Int(f[0]), list.indices.contains(i), let webView = list[i].webView else { break }
            Task {
                let result = try? await webView.callAsyncJavaScript(f[2], arguments: [:], in: nil, contentWorld: .page)
                try? String(describing: result ?? "nil").write(toFile: f[1], atomically: true, encoding: .utf8)
            }
        default: break
        }
    }

    /// keepontop [mini|popup] (Window › Keep on Top for the newest Zigzag Mini or pop-up, else the front window),
    /// windowmenu [mini|popup] (Zigzag and that window in front, the Window menu shown over it for four seconds).
    /// The next menu to open closes by itself after these seconds, so a script can capture it and go on.
    private static func closeNextMenu(after seconds: Double) {
        // Zigzag's own drawn menus (the sidebar's + and its empty space) aren't tracked by AppKit: close what's open then.
        let drawn = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { MenuPanel.current?.close(animated: false) } }
        RunLoop.main.add(drawn, forMode: .common)
        menuToClose = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                trackedMenu = menu
                if let token = menuToClose { NotificationCenter.default.removeObserver(token) }
                menuToClose = nil
            }
            let close = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { trackedMenu?.cancelTracking(); trackedMenu = nil } }
            RunLoop.main.add(close, forMode: .common)
        }
    }
    private static var menuToClose: NSObjectProtocol?
    private static var trackedMenu: NSMenu?

    private static func runKeepOnTop(_ name: String, _ arg: String) {
        let window = arg == "mini" ? MiniWindowController.all.last?.window
            : arg == "popup" ? PopupWindowController.all.last?.window : KeepOnTop.frontWindow
        guard let window else { return }
        if name == "keepontop" { KeepOnTop.toggle(window); return }
        guard let menu = NSApp.windowsMenu, let view = window.contentView else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let close = Timer(timeInterval: 4, repeats: false) { _ in MainActor.assumeIsolated { NSApp.windowsMenu?.cancelTracking() } }
        RunLoop.main.add(close, forMode: .common)
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSPoint(x: 80, y: view.isFlipped ? 60 : view.bounds.height - 60), in: view) }
    }

    static func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        // Zigzag Mini windows come first: they work with no browser window open, and must not bring one forward.
        if name.hasPrefix("mini") { runMini(name, arg); return }
        if name == "windowsdump" { dumpWindows(to: arg); return }
        if name == "keepontop" || name == "windowmenu" { runKeepOnTop(name, arg); return }
        // mcp on|off|reset|state <path>: Settings › Automation › Let AI apps use Zigzag, Reset Key, and the server's state (JSON).
        if name == "mcp" {
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch f.first ?? "" {
            case "on": MCPService.setOn(true)
            case "off": MCPService.setOn(false)
            case "reset": MCPService.resetKey()
            case "state":
                if f.count == 2, let data = try? JSONSerialization.data(withJSONObject: MCPService.debugState, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: f[1]))
                }
            default: break
            }
            return
        }
        if name == "relayout" {
            // relayout: every browser window lays its pages out again, as a resize would, without coming forward.
            WindowManager.shared.controllers.forEach { $0.root.needsLayout = true; $0.root.card.needsLayout = true; $0.root.secondCard.needsLayout = true }
            return
        }
        guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
        // pindrag and pindump work on the address as it is, without bringing the window forward.
        if name == "pindrag" { controller.sidebar.address.debugPinDrag(arg); return }
        if name == "pindump" { controller.sidebar.address.debugDump(to: arg); return }
        // pintoggle <extension id>: pins or unpins it, as the pin on its tile in Site Controls does.
        if name == "pintoggle" { controller.tabManager.profile.installs.togglePin(arg); return }
        if name == "pinhover" { SitePanel.shown?.debugHover(arg); return }
        if name.hasPrefix("mp") { runMiniPlayer(name, arg, in: controller); return }
        if name == "pageprobe" { pageProbe(arg); return }
        if name == "speval" {
            // speval <path> <script>: the script's result in the side panel's page, which it may await, written to
            // the file with the panel's address; without bringing the window forward.
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let webView = controller.root.sidePanel.webView else {
                if let path = f.first { try? "no side panel".write(toFile: path, atomically: true, encoding: .utf8) }
                return
            }
            Task {
                let text: String
                do {
                    let result = try await webView.callAsyncJavaScript(f[1], arguments: [:], in: nil, contentWorld: .page)
                    text = String(describing: result ?? "nil")
                } catch { text = "error: \(error)" }
                try? "\(webView.url?.absoluteString ?? "-")\n\(text)".write(toFile: f[0], atomically: true, encoding: .utf8)
            }
            return
        }
        if name.hasPrefix("popupwin") { popupWindow(name, arg); return }
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
        switch name {
        case "open": if let url = URL(string: arg) { controller.open(url, disposition: .foregroundTab, allowSwitch: false) }
        case "bg": if let url = URL(string: arg) { controller.open(url, disposition: .backgroundTab, allowSwitch: false) }
        // child <url>: a link opened in a background tab from the tab you're on, as ⌘-click does.
        case "child": if let url = URL(string: arg), let tab = controller.tabManager.selectedTab { controller.tab(tab, openURL: url, disposition: .backgroundTab) }
        // nest on|off: Settings › Tabs › Open ⌘-clicked links under their tab.
        case "nest": TabManager.nestsOpenedLinks = arg == "on"
        // foldtab <index>: folds or shows the tabs nested under the tab at that place in the space's list.
        case "foldtab":
            let tabs = controller.tabManager.currentTabs
            if let i = Int(arg), tabs.indices.contains(i) { controller.tabManager.setNestedTabsCollapsed(tabs[i], !tabs[i].isCollapsed) }
        // tree <path>: the current space's tabs, each with how deep it's nested and whether it's folded.
        case "tree":
            let m = controller.tabManager
            let levels = TabTree.levels(m.treeNodes(in: m.currentSpaceID))
            let out = m.currentTabs.map { "\(String(repeating: "  ", count: levels[$0.id] ?? 0))\($0.displayTitle)\($0.isCollapsed ? " (folded)" : "")" }
            try? out.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "load": if let url = URL(string: arg) { controller.open(url, disposition: .currentTab) }
        case "sidebar": controller.toggleBrowserSidebar(nil)
        // topbar on|off: Settings › Appearance › Address bar above the page.
        case "topbar": BrowserRootView.addressAbovePage = arg == "on"
        case "reveal": controller.root.holdReveal = arg == "hold"; controller.root.reveal(true)
        case "unreveal": controller.root.holdReveal = false; controller.root.reveal(false)
        // numbers [control|off]: the ⌘ number hints, as holding ⌘ shows them (with control, the spaces' ⌃ ones, as
        // holding ⌃ shows them), even with the window not in front. off hides both.
        case "numbers":
            switch arg {
            case "off": controller.numberHints?.hide(); controller.numberHints?.hideSpaces()
            case "control": controller.numberHints?.debugShowSpaces()
            default: controller.numberHints?.debugShow()
            }
        case "lights":
            let w = controller.window as? BrowserWindow
            let b = w?.standardWindowButton(.closeButton)
            debugLog("lights hidden=\(b?.isHidden ?? true) frame=\(b?.frame ?? .zero) revealed=\(controller.root.isSidebarFloatingVisible) container=\(controller.root.sidebarContainer.frame.minX)")
        case "commandbar":
            // Typing into an open bar only types, as the keyboard would.
            if !controller.commandBar.isVisible { controller.commandBar.show(mode: .newTab) }
            if !arg.isEmpty { controller.commandBar.debugType(arg) }
        case "enter": controller.commandBar.debugEnter()
        case "edit": controller.commandBar.show(mode: .editCurrent); if !arg.isEmpty { controller.commandBar.debugType(arg) }
        case "dismissbar": controller.commandBar.dismiss()
        case "permprompt":
            if arg == "app" {
                Task { _ = await PermissionPrompt.ask(host: "meeting.tencent.com", what: "Calendar", symbol: "arrow.up.forward.app",
                                                      icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Calendar.app"),
                                                      in: controller, title: "Open Calendar", allowTitle: "Open",
                                                      denyTitle: "Don’t Open") }
            } else {
                Task { _ = await PermissionPrompt.ask(host: "meet.google.com", what: "your camera", symbol: "video.fill", in: controller) }
            }
        case "renamepanel": RenamePanel.show(title: "Google", in: controller) { _ in }
        case "importanim": IntoZigzag.shown?.set(arg == "done" ? .done : .importing)
        case "bartab": controller.commandBar.debugTab()
        case "tour": Tutorial.restart(); GuidedTour.start(in: controller)
        case "tourresume": GuidedTour.start(in: controller)
        case "markrow": controller.sidebar.list.debugMark(Int(arg.prefix { $0.isNumber }) ?? 0, shift: arg.hasSuffix("s"))
        case "marked":
            // marked <path>: the picked rows, whether the keys act on them, and what their menu and File › Close say.
            let list = controller.sidebar.list
            let titles = list.marked.isEmpty ? [] : SidebarMenus.markedMenu(for: list.marked, controller: controller).items.map(\.title)
            let close = NSApp.mainMenu.flatMap { $0.items.lazy.compactMap { $0.submenu?.items.first { $0.action == #selector(BrowserWindowController.closeTab(_:)) } }.first }
            if let close { _ = controller.validateMenuItem(close) }
            let json: [String: Any] = ["marked": list.marked.map { String(describing: $0) }, "count": list.marked.count,
                                       "focus": list.marksHaveFocus, "menu": titles, "close": close?.title ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "markedmenu":
            // markedmenu <title>: runs that item of the picked rows' menu, as choosing it would (a submenu's by "Parent>Item").
            let list = controller.sidebar.list
            guard !list.marked.isEmpty else { break }
            let path = arg.split(separator: ">").map(String.init)
            var menu: NSMenu? = SidebarMenus.markedMenu(for: list.marked, controller: controller)
            for name in path.dropLast() { menu = menu?.items.first { $0.title == name }?.submenu }
            if let menu, let last = path.last, case let index = menu.indexOfItem(withTitle: last), index >= 0 { menu.performActionForItem(at: index) }
        case "menuat":
            // menuat <x> <y> <path>: the menu a right-click there would open (window points, top left), as AppKit finds
            // it, from the view under the point up through the views holding it: who answered and its items (JSON).
            let f = arg.split(separator: " ", maxSplits: 2).map(String.init)
            guard f.count == 3, let x = Double(f[0]), let y = Double(f[1]), let window = controller.window, let content = window.contentView else { break }
            let point = NSPoint(x: x, y: window.frame.height - y)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { break }
            var view = content.superview?.hitTest(point) ?? content.hitTest(point)
            let hit = view.map { "\(type(of: $0))" } ?? ""
            var answered = "", items: [String] = []
            while let v = view {
                if let menu = v.menu(for: event) { answered = "\(type(of: v))"; items = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }; break }
                // The sidebar draws its own menu for its empty space (`showBlankMenu`).
                if v === controller.sidebar {
                    answered = "SidebarView"
                    items = SidebarMenus.blankPanel(controller: controller).map { if case .item(let item) = $0 { item.title } else { "-" } }
                    break
                }
                view = v.superview
            }
            let json: [String: Any] = ["hit": hit, "answered": answered, "items": items]
            if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: URL(fileURLWithPath: f[2])) }
        case "rclick":
            // rclick <x> <y> [seconds]: a right-click inside Zigzag at that window point (top left), as `mouse rclick`;
            // the menu it opens closes by itself after the seconds (3), so a script can capture it and go on.
            let f = arg.split(separator: " ").map(String.init)
            guard f.count >= 2, let x = Double(f[0]), let y = Double(f[1]), let window = controller.window else { break }
            closeNextMenu(after: f.count > 2 ? Double(f[2]) ?? 3 : 3)
            let point = NSPoint(x: x, y: window.frame.height - y)
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "plus":
            // plus [seconds]: a click on the + at the bottom of the sidebar; its menu closes by itself after the seconds (3).
            closeNextMenu(after: Double(arg) ?? 3)
            DispatchQueue.main.async { controller.sidebar.showAddMenu() }
        case "addmenu", "blankmenu":
            // addmenu <title>, blankmenu <title>: runs that item of the + menu or the sidebar's empty-space menu, as choosing it would.
            let entries = name == "addmenu" ? SidebarMenus.addPanel(controller: controller) : SidebarMenus.blankPanel(controller: controller)
            for case .item(let item) in entries where item.title == arg { item.action() }
        case "markedfolder":controller.newFolder(with: controller.pinnedIDs(for: controller.sidebar.list.marked)); controller.sidebar.list.clearMarks()
        case "newspaceui": controller.newSpace(nil)
        case "editspace": SpaceEditorPanel.toggle(spaceID: controller.tabManager.currentSpaceID, in: controller)
        case "closeeditor": SpaceEditorPanel.current?.close()
        case "canceleditor": SpaceEditorPanel.current?.cancel()
        case "tourskip": Tutorial.skip()
        case "tourend": Tutorial.isHidden = true; controller.root.overlay.subviews.compactMap { $0 as? GuidedTour }.forEach { $0.removeFromSuperview() }
        case "fullscreen": controller.window?.toggleFullScreen(nil)
        case "settingsspaceedit":
            func rows(_ v: NSView) -> [SpaceSettingsRow] { (v as? SpaceSettingsRow).map { [$0] } ?? v.subviews.flatMap(rows) }
            if let root = controller.tabManager.selectedTab?.settingsView { rows(root).first?.openEditor() }
        case "saveprompt": if arg == "close" { SavePasswordPrompt.debugClose() } else { SavePasswordPrompt.debugPreview(in: controller) }
        case "select": controller.tabManager.select(at: Int(arg) ?? 0)
        case "suspendtab": controller.tabManager.allTabs.first { $0.url?.absoluteString.hasPrefix(arg) == true }?.suspend(because: "debug")
        // pageicon <index> <icon|none>: gives the tab at that sidebar position an icon of its own, as Change Icon… does.
        case "pageicon":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let list = controller.tabManager.navigableTabs
            if let n = f.first.flatMap({ Int($0) }), list.indices.contains(n) {
                let icon = f.count > 1 && f[1] != "none" ? f[1] : nil
                if let id = list[n].bookmarkID { Library.shared.setIcon(icon, forBookmark: id) } else { list[n].customIcon = icon }
            }
        case "killpage":
            // killpage <url prefix>: ends that tab's page process, as macOS does when it takes memory back.
            if let webView = controller.tabManager.allTabs.first(where: { $0.url?.absoluteString.hasPrefix(arg) == true })?.webView,
               let pid = EnergyWatch.processID(of: webView), pid > 0 { kill(pid, SIGKILL) }
        case "lowmemory": MemoryPressure.shared.warned(critical: arg == "critical")
        case "sleepidle": controller.tabManager.sleepIdleTabs()
        case "space": controller.tabManager.switchSpace(by: Int(arg) ?? 1)
        case "newprofile":
            // newprofile <name>
            Library.shared.addProfile(name: arg)
        case "spaceprofile":
            // spaceprofile [name]: puts the space you're in on that profile; with no name, on the first.
            let id = Library.shared.profiles.first { $0.name == arg }?.id ?? Profile.defaultID
            Library.shared.setProfile(id, forSpace: controller.tabManager.currentSpaceID)
        case "profilesheet":
            // profilesheet new | edit <name> | delete <name>: the sheet, over this window.
            guard let host = controller.window?.contentView else { break }
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let named = Library.shared.profiles.first { $0.displayName == (f.count > 1 ? f[1] : "") }
            switch f.first {
            case "new": ProfileSheets.new(in: host)
            case "edit": if let named { ProfileSheets.edit(named.id, in: host) }
            case "delete": if let named { ProfileSheets.confirmDelete(named.id, in: host) }
            default: break
            }
        case "formsheet":
            // formsheet type <text> | confirm | cancel: the form that's up, in any window.
            func find(_ view: NSView?) -> FormSheet? { view?.subviews.lazy.compactMap { ($0 as? FormSheet) ?? find($0) }.first }
            guard let sheet = NSApp.windows.lazy.compactMap({ find($0.contentView) }).first else { debugLog("formsheet: none up"); break }
            if arg.hasPrefix("type ") {
                (sheet.window?.firstResponder as? NSTextView)?.insertText(String(arg.dropFirst(5)), replacementRange: NSRange(location: 0, length: (sheet.window?.firstResponder as? NSTextView)?.string.count ?? 0))
            } else {
                // Confirming for you (a profile's removal, say) only in a test copy; cancelling anywhere.
                guard arg != "confirm" || isTestCopy else { debugLog("formsheet confirm refused: not a test copy"); break }
                sheet.debugAnswer(arg == "confirm")
            }
        case "orphans", "restoreorphan", "eraseorphan":
            // orphans <path>: the IDs of data on disk that's no profile's. restoreorphan / eraseorphan <n>: makes the
            // nth a profile again, or erases it (only in a test copy).
            Task { @MainActor in
                let found = await Profiles.shared.orphans()
                let index = Int(arg) ?? 0
                let chosen = found.indices.contains(index) ? found[index] : nil
                switch name {
                case "orphans": try? JSONSerialization.data(withJSONObject: found.map(\.uuidString)).write(to: URL(fileURLWithPath: arg))
                case "restoreorphan": if let chosen { Library.shared.restoreProfile(chosen, name: "Restored Profile") }
                default:
                    guard isTestCopy, let chosen else { debugLog("eraseorphan refused"); return }
                    await Profiles.shared.eraseOrphan(chosen)
                    debugLog("eraseorphan => deleting \(Library.shared.directory.deleting.count)")
                }
            }
        case "delprofile":
            // delprofile <name>: removes the profile and its data, without asking. Only in a test copy.
            guard isTestCopy else { debugLog("delprofile refused: not a test copy"); break }
            if let id = Library.shared.profiles.first(where: { $0.name == arg && !$0.isDefault })?.id {
                Task {
                    let removed = await Profiles.shared.remove(id)
                    debugLog("delprofile \(arg) => \(removed ? "removed" : "refused") deleting \(Library.shared.directory.deleting.count)")
                }
            }
        case "holdprofile", "releaseprofile":
            // holdprofile <name> / releaseprofile <name>: as an import does while it writes into the profile, so a
            // removal meanwhile can be checked. Only in a test copy.
            guard isTestCopy, let id = Library.shared.profiles.first(where: { $0.name == arg })?.id else { debugLog("\(name) refused"); break }
            if name == "holdprofile" { debugLog("holdprofile \(arg) => \(Profiles.shared.hold(id))") } else { Profiles.shared.done(id); debugLog("releaseprofile \(arg) => in use \(Profiles.shared.inUse.count)") }
        case "profiles":
            // profiles <path>: each profile with its spaces and extensions, and for each tab in this window the
            // profile its page is in and the store that page uses (JSON).
            let library = Library.shared
            let profiles = library.profiles.map { info -> [String: Any] in
                let profile = Profiles.shared.profile(info.id)
                return ["id": info.id.uuidString, "name": info.name ?? "", "first": info.isDefault,
                        "spaces": library.spaces(in: info.id).map(\.name),
                        "extensionsUp": profile.isDefault || profile.startedExtensions != nil,
                        "storeMade": profile.isDefault || profile.storeIfMade != nil,
                        "loaded": (profile.isDefault ? profile.extensions : profile.startedExtensions)?.contexts.map(\.uniqueIdentifier).sorted() ?? [],
                        "favorites": library.favorites(in: info.id).map(\.title),
                        "history": profile.history.recent(limit: 6).map(\.url.absoluteString),
                        "installed": profile.installs.installedIDs]
            }
            let tabs = controller.tabManager.allTabs.map { tab -> [String: Any] in
                let store = tab.webView?.configuration.websiteDataStore
                return ["title": tab.displayTitle, "space": library.space(tab.spaceID)?.name ?? "", "profile": library.directory.profile(tab.profile.id)?.name ?? "",
                        "store": store == nil ? "no page" : store?.identifier?.uuidString ?? (store?.isPersistent == true ? "default" : "private"),
                        "told": tab.toldTo.map { library.directory.profile($0.profile.id)?.name ?? "" } ?? "no one"]
            }
            let json: [String: Any] = ["profiles": profiles, "tabs": tabs, "many": library.hasManyProfiles,
                                       "current": controller.tabManager.currentSpace.name, "selected": controller.tabManager.selectedTab?.displayTitle ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "newspace":
            let space = Library.shared.addSpace(name: arg.isEmpty ? nil : arg)
            controller.tabManager.switchToSpace(space.id)
        case "spacehue": if let degrees = Double(arg) { Library.shared.setHue(degrees / 360, for: controller.tabManager.currentSpaceID) }
        case "bookmark": if let tab = controller.tabManager.selectedTab { controller.tabManager.bookmarkTab(tab) }
        case "hover": controller.debugHover(index: Int(arg) ?? 0)
        case "desk": controller.toggleDeskView(nil)
        case "deskkey": controller.desk.debugKey(arg)
        case "private": WindowManager.shared.newWindow(url: URL(string: arg), showCommandBar: false, isPrivate: true)
        case "pageshot": if let webView = controller.selectedWebView { PageScreenshot.debugCapture(webView, to: URL(fileURLWithPath: arg)) }
        case "reader": controller.toggleReader()
        case "split":
            // Splits the shown tab with the one at this sidebar position.
            let list = controller.tabManager.navigableTabs
            if let tab = controller.tabManager.selectedTab, let n = Int(arg), list.indices.contains(n), list[n] !== tab {
                controller.tabManager.makeSplit(tab, with: list[n])
            }
        case "unsplit": controller.closeSplitView(nil)
        // splitorient: side by side to stacked or back, as the split's own button does.
        case "splitorient": controller.toggleSplitOrientation(nil)
        case "closetab": controller.closeTab(nil)
        case "flydownload": controller.debugFlyDownload(arg.isEmpty ? "Shanghai Guide.pdf" : arg)
        case "readerjs":
            controller.debugReaderWebView?.evaluateJavaScript(arg) { result, error in
                debugLog("readerjs => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "find": controller.findBar.show(query: arg)
        case "findclose": controller.findBar.hide()
        // motionsheet, motionmenu [close]: a confirmation and a menu to watch show up and go (cancelsheet closes the sheet).
        case "motionsheet":
            if let host = controller.window?.contentView {
                ConfirmSheet.show(in: host, title: "Close 3 Tabs?", message: "They stay in History.", confirmTitle: "Close") { _ in }
            }
        case "motionmenu":
            if arg == "close" { MenuPanel.current?.close() } else {
                MenuPanel.show([.item(.init(title: "Copy Link") {}), .item(.init(title: "Share…") {}), .separator,
                                .item(.init(title: "Close Tab") {})], from: controller.sidebar.address)
            }
        case "peek": if let url = URL(string: arg) { controller.open(url, disposition: .peek) }
        case "peekclose": controller.peek.close()
        case "switcher": controller.debugSwitcher()
        // spaceswitcher [down|up|tab|return|esc|again|back|1-9|state <path>]: opens the space switcher (or moves it on, as its
        // shortcut does), presses a key in it, or writes its rows, ">" on the choice and "*" on the space you're in.
        case "spaceswitcher": controller.debugSpaceSwitcher(arg)
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
        // darkpages off|system|always: Settings › Appearance › Dark pages. darksite on|off|follow: the site panel's
        // Dark page row for the page in front. darkstate: what the page script found there, in the debug log.
        // darkblack on|off: Settings › Appearance › Pure black backgrounds.
        case "darkpages": if let mode = DarkPages.Mode(rawValue: arg) { DarkPages.mode = mode }
        case "darkblack": DarkPages.pureBlack = arg == "on"
        case "darksite": DarkPages.setChoice(arg == "follow" ? nil : arg == "on", for: controller.tabManager.selectedTab?.url)
        // keepawake on|off: the site panel's Keep tabs awake row for the page in front.
        case "keepawake": KeepAwake.set(arg == "on", for: controller.tabManager.selectedTab?.url)
        case "darkstate":
            controller.selectedWebView?.callAsyncJavaScript("return window.__zigzagDark ? JSON.stringify(window.__zigzagDark.state()) : 'none'",
                                                            arguments: [:], in: nil, in: DarkPages.world) { result in
                let tab = controller.tabManager.selectedTab?.darkPage
                debugLog("darkstate => \(result) tab=\(String(describing: tab)) analysis=\(DarkPages.lastAnalysis)")
            }
        // darkpalettes forget: drops the profile's dark palettes, as clearing History does.
        case "darkpalettes": if arg == "forget" { DarkPalettes.forget(in: controller.tabManager.profile.store) }
        case "resize":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, let window = controller.window {
                var frame = window.frame
                frame.size = NSSize(width: n[0], height: n[1])
                window.setFrame(frame, display: true)
            }
        case "age":
            // Pretend the tab at index was last looked at N hours ago, to see fading.
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, controller.tabManager.currentTabs.indices.contains(Int(n[0])) {
                controller.tabManager.currentTabs[Int(n[0])].lastActivated = Date().addingTimeInterval(-n[1] * 3600)
                controller.sidebar.list.refreshRows()
            }
        case "agefav":
            // agefav <minutes>: pretend every favorite but the one shown was last looked at that long ago.
            let minutes = Double(arg) ?? 30
            for tab in controller.tabManager.allTabs where tab.isFavorite && tab !== controller.tabManager.selectedTab {
                tab.lastActivated = Date().addingTimeInterval(-minutes * 60)
            }
        case "edgedrag": controller.root.debugEdgeDrag(arg)
        case "spacedrag": controller.sidebar.debugSpaceDrag(arg)
        case "sidebarwidth":
            // sidebarwidth <points>: as a drag of the sidebar's edge would leave it, within its narrowest and widest.
            if let n = Double(arg) {
                controller.root.sidebarWidth = min(max(n, Tokens.Metric.sidebarMinWidth), Tokens.Metric.sidebarMaxWidth)
                controller.root.needsLayout = true
            }
        case "windowid":
            if let window = controller.window {
                let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                let topLeftY = screenHeight - window.frame.maxY
                let info = "\(window.windowNumber) \(ProcessInfo.processInfo.processIdentifier) \(Int(window.frame.minX)) \(Int(topLeftY))"
                try? info.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "layout":
            // layout <path>: every sidebar row, favorite and space dot, with its frame (window points, top left).
            let items = controller.sidebar.favorites.debugTiles() + controller.sidebar.list.debugRows() + controller.sidebar.debugDots()
            let json = items.map { ["name": $0.0, "x": $0.1.minX, "y": $0.1.minY, "w": $0.1.width, "h": $0.1.height] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "state":
            // state <path>: each space's tabs and pinned tabs, the favorites, splits shown as "A|B".
            let m = controller.tabManager
            func pair(_ tab: Tab) -> String { ([tab] + (m.partner(of: tab).map { [$0] } ?? [])).map(\.displayTitle).joined(separator: "|") }
            func pinned(_ ids: [UUID]) -> [String] {
                var out: [String] = [], seen = Set<UUID>()
                for id in ids where !seen.contains(id) {
                    let both = Library.shared.pinnedSplit(containing: id).map { [$0.left, $0.right] } ?? [id]
                    both.forEach { seen.insert($0) }
                    out.append(both.compactMap { Library.shared.bookmark($0)?.title }.joined(separator: "|"))
                }
                return out
            }
            let spaces: [[String: Any]] = Library.shared.spaces.map { space in
                var seen = Set<UUID>()
                let tabs = m.tabs(in: space.id).compactMap { tab -> String? in
                    if seen.contains(tab.id) { return nil }
                    seen.insert(tab.id); if let p = m.partner(of: tab) { seen.insert(p.id) }
                    return pair(tab)
                }
                return ["name": space.name, "tabs": tabs, "pinned": pinned(space.bookmarks.map(\.id)),
                        "folders": (space.folders ?? []).map { f in ["name": f.name, "pages": f.bookmarkIDs.compactMap { Library.shared.bookmark($0)?.title }] }]
            }
            // Every pinned page and favorite as undo must bring it back, and any tab listed twice.
            func detail(_ bookmark: Bookmark) -> [String: Any] {
                ["id": bookmark.id.uuidString, "title": bookmark.title, "url": bookmark.url.absoluteString,
                 "loaded": m.bookmarkTab(for: bookmark.id) != nil, "folder": Library.shared.folderID(containing: bookmark.id)?.uuidString ?? ""]
            }
            let duplicates = m.tabsBySpace.values.reduce(0) { $0 + $1.count - Set($1.map(ObjectIdentifier.init)).count }
            let json: [String: Any] = ["spaces": spaces, "favorites": pinned(Library.shared.favorites.map(\.id)),
                                       "current": Library.shared.space(m.currentSpaceID)?.name ?? "",
                                       "pins": Library.shared.spaces.flatMap(\.bookmarks).map(detail), "favs": Library.shared.favorites.map(detail),
                                       "duplicates": duplicates, "windows": WindowManager.shared.controllers.count,
                                       // Carried copies still on screen: none once every drag is over.
                                       "carried": NSApp.windows.filter { $0 is NSPanel && $0.isVisible && $0.ignoresMouseEvents && $0.level == .floating }.count,
                                       "spaceOrder": Library.shared.spaces.map(\.name)]
            if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "dump":
            var out = ""
            func walk(_ v: NSView, _ depth: Int) {
                out += String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden) alpha=\(v.alphaValue)\n"
                if depth < 6 { v.subviews.forEach { walk($0, depth + 1) } }
            }
            if let frameView = controller.window?.contentView?.superview { walk(frameView, 0) }
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
        case "tl":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2 { (controller.window as? BrowserWindow)?.trafficLightOrigin = NSPoint(x: n[0], y: n[1]) }
        case "wheel":
            // wheel x y dy: a scroll-wheel turn at a point (window points, top-left origin), handed to the window as one
            // would arrive, inside the app only; dy in lines, negative scrolls down.
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count >= 3, let window = controller.window,
                  let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(f[2]), wheel2: 0, wheel3: 0) else { break }
            let screen = window.convertPoint(toScreen: NSPoint(x: f[0], y: window.frame.height - f[1]))
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
        case "mouse":
            // mouse <down|drag|up|move|click|rclick> x y [shift|cmd|opt]  (window points, top-left origin)
            let f = arg.split(separator: " ").map(String.init)
            guard f.count >= 3, let x = Double(f[1]), let y = Double(f[2]), let window = controller.window else { break }
            var flags: NSEvent.ModifierFlags = []
            if f.contains("shift") { flags.insert(.shift) }
            if f.contains("cmd") { flags.insert(.command) }
            if f.contains("opt") { flags.insert(.option) }
            let point = NSPoint(x: x, y: window.frame.height - y)
            func post(_ type: NSEvent.EventType, clicks: Int = 1) {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            switch f[0] {
            case "down": post(.leftMouseDown)
            case "drag": post(.leftMouseDragged)
            case "up": post(.leftMouseUp)
            case "click": post(.leftMouseDown); post(.leftMouseUp)
            case "dclick": post(.leftMouseDown, clicks: 2); post(.leftMouseUp, clicks: 2)
            case "rclick": post(.rightMouseDown); post(.rightMouseUp)
            case "move", "hover":
                // Tracking areas follow the real cursor, so hover is simulated by telling the view directly.
                var view = window.contentView?.hitTest(point)
                while let v = view, !(v is InteractiveView) { view = v.superview }
                for case let other as InteractiveView in DebugBridge.hovered where other !== view { other.isHovered = false }
                if let v = view as? InteractiveView { v.isHovered = true; DebugBridge.hovered = [v] } else { DebugBridge.hovered = [] }
            default: break
            }
        case "downloads": controller.showDownloads(nil)
        case "dl":
            // dl pause|resume|state: acts on the newest download.
            guard let item = DownloadManager.shared.items.first else { debugLog("dl => none"); break }
            if arg == "pause" { DownloadManager.shared.pause(item) }
            if arg == "resume" { DownloadManager.shared.resume(item) }
            if arg == "cancel" { DownloadManager.shared.cancel(item) }
            debugLog("dl => \(item.state) \(item.completedBytes)/\(item.totalBytes) \(item.destination?.lastPathComponent ?? "-")")
        case "action": controller.sidebar.address.siteControlsButton.onClick?(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
        case "importsuggest":
            // Which browsers and profiles the import would start with checked; reads no passwords.
            let sources = ImportCoordinator.detectedSources()
            let picked = ImportCoordinator.suggested(sources)
            debugLog("importsuggest => " + sources.map { (picked.contains($0.id) ? "[x] " : "[ ] ") + $0.id + " " + (ImportCoordinator.lastUsed($0).map { "\($0)" } ?? "?") }.joined(separator: " | "))
        case "cleartabs": controller.listClearTabs()
        case "newfolder":
            // newfolder <n>: a folder holding the space's first n pinned pages.
            let ids = Library.shared.bookmarks(in: controller.tabManager.currentSpaceID).prefix(Int(arg) ?? 0).map(\.id)
            controller.newFolder(with: Array(ids))
        case "spacegrain":
            // spacegrain <0-1>: the current space's grain.
            if let grain = Double(arg) { Library.shared.setGrain(grain, for: controller.tabManager.currentSpaceID) }
        case "namespace":
            // namespace <name>: the current space's name.
            Library.shared.renameSpace(controller.tabManager.currentSpaceID, to: arg)
        case "namefolder":
            // namefolder <name>: the current space's first folder's name, without the inline field.
            if let folder = Library.shared.folders(in: controller.tabManager.currentSpaceID).first {
                controller.window?.makeFirstResponder(nil)
                Library.shared.renameFolder(folder.id, to: arg)
            }
        case "spaceicon":
            // spaceicon <none|symbol or emoji>: the current space's icon.
            Library.shared.setIcon(arg == "none" ? nil : arg, forSpace: controller.tabManager.currentSpaceID)
        case "foldericon":
            // foldericon <picker|none|symbol or emoji>: the first folder's icon, or its picker.
            if let folder = Library.shared.folders(in: controller.tabManager.currentSpaceID).first {
                if arg == "picker" { controller.chooseFolderIcon(folder.id) } else { Library.shared.setIcon(arg == "none" ? nil : arg, forFolder: folder.id) }
            }
        case "togglefolder":
            // togglefolder [name]: opens or shuts the current space's folder of that name (or its first), and logs how
            // long the main thread took to show it.
            let folders = Library.shared.folders(in: controller.tabManager.currentSpaceID)
            if let folder = folders.first(where: { $0.name == arg }) ?? (arg.isEmpty ? folders.first : nil) {
                let start = CACurrentMediaTime()
                controller.listSetFolderOpen(folder.id, !folder.isOpen)
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                controller.window?.displayIfNeeded()
                CATransaction.flush()
                let shown = (CACurrentMediaTime() - start) * 1000
                DispatchQueue.main.async {
                    debugLog(String(format: "togglefolder %@ %@ => %.1f ms, next turn %.1f ms, rows %d", folder.name, folder.isOpen ? "shut" : "open",
                                    shown, (CACurrentMediaTime() - start) * 1000, controller.sidebar.list.debugRows().count))
                }
            }
        case "seedfolders": seedFolders(Int(arg) ?? 2000, in: controller)
        case "scrolllist":
            // scrolllist <y>: scrolls the sidebar's list to that many points from its top, or as far as it goes.
            if let clip = controller.sidebar.list.enclosingScrollView?.contentView, let y = Double(arg) {
                clip.scroll(to: NSPoint(x: 0, y: max(0, min(y, controller.sidebar.list.frame.height - clip.bounds.height))))
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        case "openfolders":
            // openfolders [shut]: opens (or shuts) every folder in the current space at once.
            let start = CACurrentMediaTime()
            Library.shared.together {
                for folder in Library.shared.folders(in: controller.tabManager.currentSpaceID) { Library.shared.setFolderOpen(folder.id, arg != "shut") }
            }
            controller.window?.displayIfNeeded()
            CATransaction.flush()
            debugLog(String(format: "openfolders %@ => %.1f ms", arg, (CACurrentMediaTime() - start) * 1000))
        case "listhover": controller.sidebar.list.debugHover(arg != "off")
        case "autofillhint":
            if let webView = controller.selectedWebView as? BrowserWebView { Autofill.shared.debugShow(arg, in: webView) }
        case "autofillmenu":
            debugLog("autofillmenu => \(Autofill.shared.isShowing) \(Autofill.shared.debugRows)")
        case "autofillclick":
            // autofillclick <css selector>: a click on that element of the page, sent to the window in-process.
            // autofillclick peek <css selector>: the same, in the page peeked at.
            // autofillclick right <css selector>: a right-click there, opening the page's context menu (closed after 3 s).
            if arg.hasPrefix("peek "), let webView = controller.peek.tab?.webView { Autofill.debugClick(String(arg.dropFirst(5)), in: webView) }
            else if arg.hasPrefix("right "), let webView = controller.selectedWebView { closeNextMenu(after: 3); Autofill.debugClick(String(arg.dropFirst(6)), in: webView, right: true) }
            else if let webView = controller.selectedWebView { Autofill.debugClick(arg, in: webView) }
        case "autofillpick":
            // autofillpick <row>: a click on that row of the password menu, sent to the window in-process.
            Autofill.shared.debugPick(Int(arg) ?? 0)
        case "autofillpickactive":
            // autofillpickactive <row>: the same, once this copy is the app in front (for Passwords…).
            Autofill.shared.debugPickWhenActive(Int(arg) ?? 0)
        case "activate":
            // activate: this copy in front, its window key (nothing else happens).
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
        case "menudump":
            // menudump <title>: that menu of the menu bar, with its submenus and their actions (Edit › AutoFill).
            if let menu = NSApp.mainMenu?.items.first(where: { $0.title == arg })?.submenu {
                menu.update()
                debugLog("menudump \(arg): " + BrowserWebView.debugDescribe(menu))
            }
        case "sysautofill":
            // sysautofill <css selector>: once this copy is in front, that field of the page focused and the Mac's
            // AutoFill panel asked for on it, as Passwords… does. Logs whether it was sent; never reads the panel.
            guard let webView = controller.selectedWebView, let origin = Origin(webView.url) else { break }
            let selector = arg
            Task {
                NSApp.activate(ignoringOtherApps: true)
                controller.window?.makeKeyAndOrderFront(nil)
                for _ in 0..<50 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
                _ = try? await webView.callAsyncJavaScript("const el = document.querySelector(sel); window.__zigzagField = el ? new WeakRef(el) : null; return !!el",
                                                           arguments: ["sel": selector], in: nil, contentWorld: .defaultClient)
                let opened = await SystemAutoFillPanel.open(in: webView, frame: nil, origin: origin, inFront: Autofill.isInFront)
                debugLog("sysautofill => available=\(SystemAutoFillPanel.isAvailable) active=\(NSApp.isActive) opened=\(opened)")
            }
        case "importprobe":
            // Lists the browsers found and how many bookmarks and history pages each has; imports nothing.
            Task {
                for source in ImportCoordinator.detectedSources() {
                    let kind = source.kind
                    let batch: ImportBatch = await Task.detached {
                        switch kind {
                        case .chromium(let b): return ChromiumImporter.read(b, [.bookmarks, .history])
                        case .firefox(let b): return FirefoxImporter.read(b, [.bookmarks, .history])
                        case .safari: return SafariImporter.read([.bookmarks, .history])
                        case .orion(let b): return OrionImporter.read(b, [.bookmarks, .history])
                        case .file: return ImportBatch()
                        }
                    }.value
                    debugLog("importprobe \(source.name): \(batch.bookmarks.count) bookmarks, \(batch.history.count) history, problems=\(batch.problems.map(\.message))")
                }
            }
        case "keychainprobe":
            // Adds, reads and deletes a dummy item in Zigzag's data protection keychain group; logs only status codes.
            let group = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? "432GL3WKY2.") + "app.zigzag.passwords"
            let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "app.zigzag.probe", kSecAttrAccount: "probe",
                                         kSecUseDataProtectionKeychain: true, kSecAttrAccessGroup: group, kSecAttrSynchronizable: true]
            SecItemDelete(base as CFDictionary)
            var add = base; add[kSecValueData] = Data("not a password".utf8)
            let added = SecItemAdd(add as CFDictionary, nil)
            var query = base; query[kSecReturnData] = true
            var out: CFTypeRef?
            let read = SecItemCopyMatching(query as CFDictionary, &out)
            let deleted = SecItemDelete(base as CFDictionary)
            debugLog("keychainprobe group=\(group) add=\(added) read=\(read) matches=\((out as? Data) == Data("not a password".utf8)) delete=\(deleted)")
        case "popupcatch":
            // Records the popup's errors from its first line on, then reloads it; read them with popupjs "__errors".
            if #available(macOS 15.4, *), let webView = extensions(in: controller).lastAction?.popupWebView {
                let source = "window.__errors = []; addEventListener('error', e => __errors.push(e.message + ' @' + (e.filename||'').split('/').pop() + ':' + e.lineno)); addEventListener('unhandledrejection', e => __errors.push('rejection: ' + (e.reason && (e.reason.message || e.reason))));"
                webView.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                webView.reload()
            }
        case "webstate":
            // webstate: where the tab in front's page is, as WebKit sees it (for a page that never answers scripts).
            if let view = controller.selectedWebView {
                debugLog("webstate url=\(view.url?.absoluteString ?? "-") loading=\(view.isLoading) progress=\(view.estimatedProgress) title=\(view.title ?? "-")")
            }
        case "allowpopups":
            // allowpopups <url>: that page's site may open pop-ups without a click, as Site Controls allows them.
            if let origin = SiteOrigin.of(URL(string: arg)) { SitePermissions.setPopups(true, origin: origin) }
        case "tabinfo":
            // tabinfo <path>: each tab in this window as the chrome names it, the page WebKit is on, and whether
            // Settings shows over it (JSON).
            let json = controller.tabManager.allTabs.map { tab -> [String: Any] in
                ["title": tab.displayTitle, "url": tab.url?.absoluteString ?? "", "page": tab.webView?.url?.absoluteString ?? "",
                 "settings": tab.settingsView != nil, "loading": tab.isLoading, "selected": tab === controller.tabManager.selectedTab]
            }
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "back": controller.tabManager.selectedTab?.goBack()
        case "forward": controller.tabManager.selectedTab?.goForward()
        case "popupjs":
            if #available(macOS 15.4, *), let webView = extensions(in: controller).lastAction?.popupWebView {
                webView.evaluateJavaScript(arg) { result, error in
                    debugLog("popupjs => \(String(describing: result).prefix(2000)) \(String(describing: error))")
                }
            } else { debugLog("popupjs: no popup") }
        case "tabjs":
            // tabjs <address prefix> <script>: like js, in the first tab of any window (private ones included) whose
            // page starts with that address, selected or not.
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2 else { break }
            let tab = WindowManager.shared.controllers.lazy.flatMap(\.tabManager.allTabs).first { $0.webView?.url?.absoluteString.hasPrefix(f[0]) == true }
            guard let webView = tab?.webView else { debugLog("tabjs: no tab at \(f[0])"); break }
            webView.evaluateJavaScript(f[1]) { result, error in
                debugLog("tabjs => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "jsclient":
            // Like js, in Zigzag's own script world rather than the page's.
            controller.selectedWebView?.evaluateJavaScript(arg, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): debugLog("jsclient => \(String(describing: value).prefix(1500))")
                case .failure(let error): debugLog("jsclient error \(error)")
                }
            }
        case "jump": controller.jumpToSelection(nil)
        case "menukey":
            // menukey <char> [cmd shift opt ctrl]: the main menu's own handling of that shortcut, logged.
            let f = arg.split(separator: " ").map(String.init)
            var flags: NSEvent.ModifierFlags = []
            for m in f.dropFirst() { switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "opt": flags.insert(.option); case "ctrl": flags.insert(.control); default: break } }
            if let ch = f.first, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                                windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                                                                characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 0) {
                debugLog("menukey \(arg): \(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)")
            }
        case "peekjs":
            // peekjs <script>: runs in the peeked page, as js does in the tab's.
            controller.peek.tab?.webView?.evaluateJavaScript(arg) { result, error in
                debugLog("peekjs => \(String(describing: result).prefix(500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "js":
            controller.selectedWebView?.evaluateJavaScript(arg) { result, error in
                debugLog("js => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "slowmo":
            // slowmo <factor>: every animation in the window runs that many times slower, to film and judge it.
            let factor = max(1, Float(arg) ?? 1)
            controller.window?.contentView?.layer?.speed = 1 / factor
        case "quit": NSApp.terminate(nil)
        case "materials": MaterialsShowcase.debug(arg)
        case "history": HistoryPage.open(in: controller)
        case "clearhistory":
            // Clears the history of the profile you're in, undoably, as the menu's Clear History does once confirmed.
            controller.historyChange(HistoryPage.clearHistory) { [tabManager = controller.tabManager] in tabManager.profile.history.remove() }
        case "seedhistory": seedHistory(Int(arg) ?? 50_000)
        case "newwindow": WindowManager.shared.newWindow(url: URL(string: arg), showCommandBar: false)
        case "closekey": WindowManager.shared.keyController?.window?.performClose(nil)
        case "reopenwindow": WindowManager.shared.reopenClosedWindow()
        case "whatsnew": WhatsNew.show(in: controller)
        // whatsnewoffer [open|notnow|state]: the note after an update, shown as an update shows it, or answered;
        // state logs whether it's up and whether the notes are still owed.
        case "whatsnewoffer":
            switch arg {
            case "open", "notnow": WhatsNewOffer.debugAnswer(open: arg == "open", in: controller)
            case "state": debugLog("whatsnewoffer showing=\(WhatsNewOffer.debugShowing(in: controller)) pending=\(WhatsNew.isPending()) sheet=\(WhatsNewSheet.isShowing(in: controller.window))")
            default: WhatsNewOffer.show(in: controller)
            }
        case "hang": Thread.sleep(forTimeInterval: Double(arg) ?? 2)
        case "problemreport": if arg == "sheet" { ProblemReport.show(in: controller) } else { Task { _ = await ProblemReport.write() } }
        case "endsheet": if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: .cancel) }
        case "zoomin": controller.zoomIn(nil)
        case "zoomreset": controller.actualSize(nil)
        case "themes":
            for tab in controller.tabManager.currentTabs {
                let t = tab.themeColor?.usingColorSpace(.sRGB)
                debugLog("theme \(tab.displayTitle.prefix(20)): \(t.map { "h\($0.hueComponent) s\($0.saturationComponent) b\($0.brightnessComponent)" } ?? "nil") tint=\(SiteTint.color(for: tab).map { String(describing: $0) } ?? "nil")")
            }
        case "peekexpand": controller.peek.openAsTab()
        case "linkfrom":
            // Simulates a Cmd-click on a link in the current page.
            if let tab = controller.tabManager.selectedTab, let url = URL(string: arg) { controller.tab(tab, openURL: url, disposition: .foregroundTab) }
        case "arcimport":
            let r = ArcImporter.importAll()
            debugLog("arc import: spaces=\(r.result.spaces) bookmarks=\(r.result.bookmarks) history=\(r.result.historyEntries)")
            if let first = r.firstSpace { controller.tabManager.switchToSpace(first) }
        case "welcome": WelcomeWindowController.show {}
        case "onboardstep":
            // onboardstep <0-4>: hello, bring, sites, ads, ready
            WelcomeWindowController.show {}
            if let view = WelcomeWindowController.shared?.window?.contentView as? OnboardingView,
               let step = Int(arg.prefix(1)).flatMap(OnboardingView.Step.init(rawValue:)) { view.show(step, animated: arg.hasSuffix("a")) }
        case "importwindow": ImportWindowController.show()
        case "importfile":
            // importfile <profile name> <path>: brings a chosen file (a Safari export, a passwords CSV) into that
            // profile, as the Import window does. Only in a test copy, with made-up data.
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard isTestCopy, f.count == 2, let info = Library.shared.profiles.first(where: { $0.displayName == f[0] }) else { debugLog("importfile refused"); break }
            let source = ImportCoordinator.Source(kind: .file(URL(fileURLWithPath: f[1])), name: "Test Browser", bundleID: nil)
            Task {
                let summary = await ImportCoordinator.run(source, [.passwords, .bookmarks, .history], into: Profiles.shared.profile(info.id))
                debugLog("importfile => passwords \(summary.passwords) bookmarks \(summary.bookmarks) history \(summary.history) problems \(summary.problems.count)")
            }
        case "importchoice", "onboardchoice":
            // importchoice <name> <on|off>: a choice in the Import window ("Sign-ins"), as a click would set it;
            // onboardchoice the same on the welcome's import step.
            let words = arg.split(separator: " ").map(String.init)
            if let state = words.last, words.count >= 2 {
                let choice = words.dropLast().joined(separator: " ")
                if name == "importchoice" {
                    (ImportWindowController.shared?.window?.contentView as? ImportView)?.debugChoose(choice, on: state == "on")
                } else {
                    (WelcomeWindowController.shared?.window?.contentView as? OnboardingView)?.debugChoose(choice, on: state == "on")
                }
            }
        case "importgo": (ImportWindowController.shared?.window?.contentView as? ImportView)?.debugImport()
        // The Import window's Not Now, or Don't Add while it asks about extensions.
        case "importnotnow": (ImportWindowController.shared?.window?.contentView as? ImportView)?.debugNotNow()
        case "onboardgo": (WelcomeWindowController.shared?.window?.contentView as? OnboardingView)?.debugNext()
        case "windowof":
            // windowof <title> <path>: as windowid, for Zigzag's window with that title (Import, Welcome to Zigzag).
            if let space = arg.lastIndex(of: " "), let window = NSApp.windows.first(where: { $0.title == String(arg[..<space]) && $0.isVisible }) {
                let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                let info = "\(window.windowNumber) \(ProcessInfo.processInfo.processIdentifier) \(Int(window.frame.minX)) \(Int(screenHeight - window.frame.maxY))"
                try? info.write(toFile: String(arg[arg.index(after: space)...]), atomically: true, encoding: .utf8)
            }
        case "inspector":
            // inspector [toggle|console|pick]: does it, then logs whether the inspector shows and is picking an element.
            switch arg {
            case "toggle": controller.showWebInspector(nil)
            case "console": controller.showJavaScriptConsole(nil)
            case "pick": controller.inspectElement(nil)
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let webView = controller.selectedWebView,
                      let inspector = webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject else { return }
                func flag(_ name: String) -> Bool {
                    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                    return unsafeBitCast(inspector.method(for: NSSelectorFromString(name)), to: Getter.self)(inspector, NSSelectorFromString(name))
                }
                debugLog("inspector \(arg) => visible=\(flag("isVisible")) picking=\(flag("isElementSelectionActive"))")
            }
        case "altsvc":
            // altsvc [forget]: the sites WebKit keeps HTTP/3 for, and the other data they have, before and after forgetting.
            Task { @MainActor in
                let store = WKWebsiteDataStore.default()
                let kept = await store.dataRecords(ofTypes: [NetworkChanges.alternativeServices])
                let sites = Set(kept.map(\.displayName))
                @MainActor func describe() async -> String {
                    let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes().union([NetworkChanges.alternativeServices]))
                    return records.filter { sites.contains($0.displayName) }.map { "\($0.displayName) \($0.dataTypes.sorted())" }.sorted().joined(separator: " | ")
                }
                let before = await describe()
                debugLog("altsvc => \(before)")
                guard arg == "forget" else { return }
                await NetworkChanges.forget()
                let after = await describe()
                debugLog("altsvc after forget => \(after)")
            }
        case "cookies":
            // cookies <path>: the cookies in the default store, in each other profile's in use and in every private
            // window's, by name and domain. Never their values.
            Task { @MainActor in
                func describe(_ cookies: [HTTPCookie]) -> [[String: Any]] {
                    cookies.map { ["name": $0.name, "domain": $0.domain, "path": $0.path, "secure": $0.isSecure, "httpOnly": $0.isHTTPOnly,
                                   "sameSite": $0.sameSitePolicy?.rawValue ?? "", "session": $0.isSessionOnly,
                                   "expires": $0.expiresDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""] }
                }
                var privateCookies: [[String: Any]] = []
                for store in WindowManager.shared.controllers.compactMap(\.tabManager.privateStore) {
                    privateCookies += describe(await store.httpCookieStore.allCookies())
                }
                var profileCookies: [String: Any] = [:]
                for profile in Profiles.shared.opened where !profile.isDefault {
                    profileCookies[profile.id.uuidString] = describe(await profile.store.httpCookieStore.allCookies())
                }
                let json: [String: Any] = ["default": describe(await WKWebsiteDataStore.default().httpCookieStore.allCookies()), "private": privateCookies,
                                           "profiles": profileCookies]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
            }
        case "closewindow":
            // closewindow <title>: closes Zigzag's window with that title (Import, Passwords, Settings).
            NSApp.windows.first { $0.title == arg }?.close()
        case "importsuccess":
            ImportWindowController.show()
            (ImportWindowController.shared?.window?.contentView as? ImportView)?.debugShowSuccess()
        case "keyshot":
            // keyshot <path>: the key window's own drawing, or the Import window's when no window is key, as a PNG. Never
            // the Passwords window.
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.windowController is ImportWindowController }), !(window.windowController is PasswordsWindowController),
                  let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        case "passwordsshow":
            (PasswordsWindowController.shared?.window?.contentView as? PasswordsView)?.debugShow(arg)
        case "passwordswindow":
            // Unlocks without Touch ID and lets the window be captured, for checking it by script. Only on a test
            // vault (ZIGZAG_TEST_VAULT): never the person's own passwords.
            guard PasswordStore.isTestVault else { debugLog("passwordswindow refused: not a test vault"); break }
            PasswordAuthentication.unlockForTesting()
            PasswordsWindowController.show()
            (PasswordsWindowController.shared?.window?.contentView as? PasswordsView)?.debugShow("open")
        case "key":
            // key <char> [cmd|shift|ctrl|opt...] — goes through the real event path, menus included.
            let f = arg.split(separator: " ").map(String.init)
            guard let ch = f.first, let window = controller.window else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in f.dropFirst() {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "ctrl": flags.insert(.control); case "opt": flags.insert(.option); default: break }
            }
            let named: [String: String] = ["esc": "\u{1b}", "tab": "\t", "return": "\r", "space": " ", "delete": "\u{7f}",
                                           "down": String(UnicodeScalar(NSDownArrowFunctionKey)!), "up": String(UnicodeScalar(NSUpArrowFunctionKey)!),
                                           "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "right": String(UnicodeScalar(NSRightArrowFunctionKey)!)]
            let chars = named[ch] ?? ch
            let codes: [String: UInt16] = ["s": 1, "j": 38, "t": 17, "l": 37, "w": 13, "esc": 53, "tab": 48, "f": 3, "r": 15, "p": 35,
                                          "down": 125, "up": 126, "left": 123, "right": 124, "return": 36, "space": 49, "delete": 51, "a": 0]
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: codes[ch] ?? 0) {
                NSApp.postEvent(e, atStart: false)
            }
        case "listscroll": controller.sidebar.debugListScroll(Double(arg).map { CGFloat($0) })
        case "tlshot":
            if let image = (controller.window as? BrowserWindow)?.trafficLightsImage(), let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: arg))
            }
        case "swipe":
            // swipe <dx per step>: a synthetic two-finger horizontal swipe over the sidebar.
            guard let window = controller.window else { break }
            // "page": over the middle of the page instead.
            sendSwipe(arg, to: window, at: arg.split(separator: " ").contains("page") ? NSPoint(x: window.frame.width * 0.6, y: window.frame.height / 2) : NSPoint(x: 100, y: window.frame.height - 300))
        case "copylink": controller.copyPageURL(nil)
        case "zoomout": controller.zoomOut(nil)
        case "scrolllog": try? scrollLog.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "settings": SettingsPage.open(in: controller)
        case "shortcutrecord":
            // shortcutrecord <command name>: starts recording keys on that row of Settings › Shortcuts.
            func rows(in view: NSView) -> [ShortcutRow] { view.subviews.flatMap { ($0 as? ShortcutRow).map { [$0] } ?? rows(in: $0) } }
            if let content = controller.window?.contentView { rows(in: content).first { $0.debugTitle == arg }?.debugRecord() }
        case "engine": if let engine = SearchEngine(rawValue: arg) { Library.shared.searchEngine = engine }
        case "engineinfo":
            // The engine searched with, its address for "zigzag test", and the engines extensions give.
            let engine = Library.shared.searchEngine
            debugLog("engine \(engine.rawValue) \(engine.name) \(engine.searchURL("zigzag test").absoluteString) home=\(engine.homeURL.absoluteString) offered=\(ExtensionSearchProvider.available.map(\.name)) before=\(ExtensionSearchProvider.previousEngine.rawValue)")
        case "largenames": SpaceHeaderView.isLarge = arg != "off"
        case "sitepanel": SitePanel.toggle(in: controller, from: controller.sidebar.address)
        case "confirmsheet":
            // Confirms any open confirmation, in every window. Only in a test copy: what's asked first is asked
            // because it can't be taken back.
            guard isTestCopy else { debugLog("confirmsheet refused: not a test copy"); break }
            for window in NSApp.windows {
                func walk(_ view: NSView?) { for sub in view?.subviews ?? [] { (sub as? ConfirmSheet)?.debugConfirm(); walk(sub) } }
                walk(window.contentView)
            }
        case "movetab":
            // movetab <space name>: sends the selected tab to that space, as its menu's Move to Space would. Of two
            // spaces with the name, the one on another profile.
            if let tab = controller.tabManager.selectedTab {
                let named = Library.shared.spaces.filter { $0.name == arg && $0.id != tab.spaceID }
                if let space = named.first(where: { Library.shared.profileID(ofSpace: $0.id) != tab.profile.id }) ?? named.first {
                    controller.moveToSpaceWithToast(tab, spaceID: space.id)
                }
            }
        case "sheetdest": ExtensionSheet.debugChoose(destination: Int(arg) ?? 0)
        case "cancelsheet":
            // Cancels any open confirmation, in every window, without confirming it.
            for window in NSApp.windows {
                func walk(_ view: NSView?) { for sub in view?.subviews ?? [] { (sub as? ConfirmSheet)?.debugCancel(); walk(sub) } }
                walk(window.contentView)
            }
        case "pwseed":
            // Five obviously fake logins for checking the Passwords window; remove them with pwclear. Only on a test
            // vault, so they never mix with the person's own.
            guard PasswordStore.isTestVault else { debugLog("pwseed refused: not a test vault"); break }
            Task {
                let samples: [(String, String, String)] = [("https://github.com", "sam@example.com", "correct-horse-battery-staple"),
                                                           ("https://figma.com", "sam@example.com", "Password1!"),
                                                           ("https://linear.app", "sam@example.com", "correct-horse-battery-staple"),
                                                           ("https://notion.so", "design@example.com", "Vq7-mBe2-Kp9xZ4"),
                                                           ("https://vercel.com", "sam@example.com", "hunter22")]
                for (site, user, password) in samples {
                    if let origin = Origin(URL(string: site)) { _ = try? await PasswordStore.shared.save(origin: origin, username: user, password: SecretString(password)) }
                }
                debugLog("pwseed done")
            }
        case "pwclear":
            Task {
                let all = (try? await PasswordStore.shared.all()) ?? []
                // Test logins: fake @example.com accounts, and anything saved for the local test site.
                let samples = all.filter { $0.username.hasSuffix("@example.com") || $0.origin.host == "127.0.0.1" }
                for credential in samples { try? await PasswordStore.shared.delete(credential.id) }
                debugLog("pwclear removed \(samples.count)")
            }
        case "pwadd":
            // pwadd <site> <username> <password>: one fake login, as for a local test site. Only on a test vault.
            let f = arg.split(separator: " ").map(String.init)
            guard PasswordStore.isTestVault, f.count == 3, let origin = Origin(URL(string: f[0])) else { debugLog("pwadd refused"); break }
            Task {
                _ = try? await PasswordStore.shared.save(origin: origin, username: f[1], password: SecretString(f[2]))
                debugLog("pwadd done")
            }
        case "dialogstate":
            // dialogstate <path>: the page dialogs showing, with what's in their fields (a password only as its length).
            if let data = try? JSONSerialization.data(withJSONObject: PageDialogSheet.debugState(), options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "dialogsaved": PageDialogSheet.debugShowSaved()
        case "windowshot":
            // windowshot <path>: the window's own drawing, as a PNG; web content may be blank.
            guard let view = controller.window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        case "about": AboutWindowController.show()
        case "acknowledgements": AcknowledgementsWindowController.show()
        case "exttest":
            // exttest <id> <url>: a fresh install, a page where it should work, then what happened, as one line.
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let page = URL(string: f[1]), #available(macOS 15.4, *) else { break }
            Task { @MainActor in await DebugBridge.extensionTest(f[0], page: page, in: controller) }
        case "ua": controller.selectedWebView?.customUserAgent = arg.isEmpty ? nil : arg; controller.selectedWebView?.reload()
        case "readerstyle":
            func find(_ v: NSView) -> ReaderControls? { (v as? ReaderControls) ?? v.subviews.lazy.compactMap(find).first }
            if let content = controller.window?.contentView { find(content)?.toggleOptions() }
        case "hidetoasts": Toast.hide(in: controller)
        case "toast":
            // toast [press]: logs the toast showing and its button; press clicks the button.
            if let toast = controller.root.overlay.subviews.compactMap({ $0 as? ToastView }).last {
                debugLog("toast \(toast.label.stringValue) [\(toast.actionButton.isHidden ? "" : toast.actionButton.title)]")
                if arg == "press", !toast.actionButton.isHidden, let event = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                    toast.actionButton.onClick?(event)
                }
            } else { debugLog("toast none") }
        case "clearsite":
            // clearsite <cache|cookies> <site>
            let f = arg.split(separator: " ").map(String.init)
            if f.count == 2 { Task { await WebsiteData.clear(f[0] == "cache" ? .cache : .cookies, site: f[1], in: controller.tabManager.profile.store); debugLog("cleared \(f[0]) for \(f[1])") } }
        case "cmd": controller.commandBar.runAction(arg)
        case "settingsfind": controller.tabManager.selectedTab?.settingsView?.debugFind(arg)
        case "settingsstate":
            // settingsstate <path>: what the Settings tab in front shows (JSON).
            guard let state = controller.tabManager.selectedTab?.settingsView?.debugState,
                  let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { debugLog("settingsstate: no Settings in front"); break }
            try? data.write(to: URL(fileURLWithPath: arg))
        case "settingsprofile":
            // settingsprofile <name>: chooses a profile in the Settings tab in front, as its menu does.
            if let id = Library.shared.profiles.first(where: { $0.displayName == arg })?.id { controller.tabManager.selectedTab?.settingsView?.choose(profile: id) }
        case "savepasswords":
            // savepasswords on|off: the choice for the profile of the space in front, as Settings › Passwords makes it.
            PasswordCapture.setOffersToSave(arg == "on", in: controller.tabManager.profile)
        case "settingsbottom":
            if let root = controller.tabManager.selectedTab?.settingsView,
               let scroll = root.subviews.compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
            }
        case "settingspane":
            // settingspane <general|appearance|tabs|spaces|search|mini|passwords|privacy|translation|extensions|shortcuts>
            SettingsPage.open(SettingsPane(rawValue: arg), in: controller)
        case "allowads": ContentBlocker.setAllowed(arg != "off", on: controller.tabManager.selectedTab?.url); controller.tabManager.selectedTab?.reload()
        case "addext": controller.installExtension(arg)
        case "storeadd": WebStoreOffer.debugAdd()
        case "sheetcancel": ExtensionSheet.debugCancel()
        case "sheetconfirm": ExtensionSheet.debugConfirm()
        case "addextnow": Task { _ = await ExtensionStore.install(arg, in: controller.tabManager.profile) }
        case "rmext": ExtensionStore.uninstall(arg, from: controller.tabManager.profile)
        case "extupdate": Task { await ExtensionStore.updateIfNewer(arg) }
        case "extreinstall":
            // Removes and freshly installs an extension, as a new user would get it.
            if #available(macOS 15.4, *) {
                ExtensionStore.uninstall(arg, from: controller.tabManager.profile)
                Task { let r = await ExtensionStore.install(arg, in: controller.tabManager.profile); debugLog("extreinstall \(arg) \(r)") }
            }
        case "extclickpanel":
            // As if clicked in the site panel.
            if #available(macOS 15.4, *), SitePanel.shown != nil,
               let item = extensions(in: controller).actions(for: controller.tabManager.selectedTab).first(where: { $0.id == arg }) {
                extensions(in: controller).performAction(item, tab: controller.tabManager.selectedTab, in: controller)
            }
        case "extclick":
            // extclick <extension id>: clicks its button, as from the site panel.
            if #available(macOS 15.4, *), let item = extensions(in: controller).actions(for: controller.tabManager.selectedTab).first(where: { $0.id == arg }) {
                debugLog("extclick \(item.label) attention=\(item.attention != nil)")
                extensions(in: controller).performAction(item, tab: controller.tabManager.selectedTab, in: controller)
            } else { debugLog("extclick: no action for \(arg)") }
        case "loadunpacked": Task { _ = await ExtensionStore.loadUnpacked(URL(fileURLWithPath: arg, isDirectory: true), in: controller.tabManager.profile) }
        case "extaccess":
            // extaccess <id> <all|click|sites> [site,site]
            let f = arg.split(separator: " ").map(String.init)
            if f.count >= 2, let access = ExtensionInstalls.SiteAccess(rawValue: f[1]) {
                controller.tabManager.profile.installs.setSiteAccess(f[0], access, sites: f.count > 2 ? f[2].split(separator: ",").map(String.init) : nil)
            }
        case "extoffsite":
            // extoffsite <site> on|off
            let f = arg.split(separator: " ").map(String.init)
            if f.count == 2 { var sites = ExtensionStore.extensionsOffSites; if f[1] == "on" { sites.insert(f[0]) } else { sites.remove(f[0]) }; ExtensionStore.extensionsOffSites = sites }
        case "extpopupstate":
            // extpopupstate <id> [script]: where its popup page is, even before WebKit asks to show it.
            if #available(macOS 15.4, *), let item = extensions(in: controller).actions(for: controller.tabManager.selectedTab).first(where: { $0.id == String(arg.prefix { $0 != " " }) }),
               let view = item.context.action(for: controller.tabManager.selectedTab)?.popupWebView {
                let script = arg.contains(" ") ? String(arg.drop { $0 != " " }.dropFirst()) : "document.readyState"
                debugLog("extpopupstate url=\(view.url?.absoluteString ?? "-") loading=\(view.isLoading) progress=\(view.estimatedProgress) size=\(view.frame.size)")
                view.evaluateJavaScript(script) { result, error in debugLog("extpopupstate => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")") }
            } else { debugLog("extpopupstate: no popup page") }
        case "extpopup":
            if let item = extensions(in: controller).actions(for: controller.tabManager.selectedTab).first(where: { $0.id == arg }) {
                extensions(in: controller).performAction(item, tab: controller.tabManager.selectedTab, in: controller)
            }
        case "extapprove": Task { await ExtensionStore.approvePendingUpdate(arg) }
        case "extoff": controller.tabManager.profile.installs.setEnabled(arg, false)
        case "exton": controller.tabManager.profile.installs.setEnabled(arg, true)
        case "settingsid":
            // Settings is a tab now: its window is the browser window it's in.
            if let w = controller.window { try? "\(w.windowNumber)".write(toFile: arg, atomically: true, encoding: .utf8) }
        case "pagemove":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, let window = controller.window, let webView = controller.selectedWebView,
               let e = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: n[0], y: window.frame.height - n[1]), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 0, pressure: 0) {
                webView.mouseMoved(with: e)
            }
        case "closematching":
            // closematching <text>: closes this space's tabs whose title or address contains the text.
            let doomed = controller.tabManager.currentTabs.filter { $0.displayTitle.contains(arg) || ($0.url?.absoluteString.contains(arg) ?? false) }
            controller.tabManager.close(doomed)
        case "pip":
            controller.selectedWebView?.callAsyncJavaScript("const v = [...document.querySelectorAll('video')].find(v => !v.paused); if (!v) return 'no video'; v.webkitSetPresentationMode('picture-in-picture'); await new Promise(r => setTimeout(r, 800)); return v.webkitPresentationMode;", arguments: [:], in: nil, in: .page) { result in
                debugLog("pip => \(result)")
            }
        case "undo":
            controller.sidebarUndo.undo()
            debugLog("after undo selected=\(controller.tabManager.selectedTab?.url?.absoluteString ?? "nil")")
        case "menutitles":
            // menutitles <path>: every item of the menu bar, indented under its menu, as the person reads them.
            var lines: [String] = []
            func list(_ menu: NSMenu, _ depth: Int) {
                for item in menu.items where !item.isSeparatorItem {
                    lines.append(String(repeating: "  ", count: depth) + item.title + (item.isHidden ? " (hidden)" : "") + (item.isAlternate ? " (alternate)" : ""))
                    if let sub = item.submenu { list(sub, depth + 1) }
                }
            }
            if let main = NSApp.mainMenu { list(main, 0) }
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "menuaudit":
            var lines: [String] = []
            func walk(_ menu: NSMenu, _ path: String) {
                for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
                    let name = path + " > " + item.title
                    if let sub = item.submenu { walk(sub, name); continue }
                    guard let action = item.action else { lines.append("NO ACTION: \(name)"); continue }
                    var chain: [NSObject] = []
                    if let t = item.target as? NSObject { chain.append(t) }
                    if let w = controller.selectedWebView { chain.append(w) }
                    if let w = controller.window { chain.append(w) }
                    chain += [controller, NSApp, NSApp.delegate as! NSObject]
                    let target: Any? = chain.first { $0.responds(to: action) }
                    if target == nil { lines.append("NO TARGET: \(name) [\(action)]") }
                    else if let v = target as? NSMenuItemValidation, !v.validateMenuItem(item) { lines.append("disabled: \(name)") }
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "audio":
            for tab in controller.tabManager.allTabs where !tab.isSuspended {
                let state: String
                if let w = tab.webView, w.responds(to: NSSelectorFromString("_isPlayingAudio")) { state = "\(w.value(forKey: "_isPlayingAudio") ?? "?")" } else { state = "n/a" }
                let muted = tab.webView.flatMap { $0.responds(to: NSSelectorFromString("_mediaMutedState")) ? $0.value(forKey: "_mediaMutedState") : nil }
                debugLog("audio \(tab.displayTitle.prefix(30)) playing=\(tab.isPlayingAudio) kvo=\(state) muted=\(tab.isMuted) webkitMuted=\(muted.map { "\($0)" } ?? "n/a")")
            }
        case "closeurl":
            for tab in controller.tabManager.allTabs where tab.url?.absoluteString.contains(arg) == true { controller.tabManager.close(tab) }
        case "controls":
            // Every clickable control in the window, with its center in window coordinates (top-left origin).
            var out = ""
            func walk(_ v: NSView) {
                if let iv = v as? InteractiveView, !iv.isHiddenOrHasHiddenAncestor, let window = controller.window {
                    let r = iv.convert(iv.bounds, to: nil)
                    let label = iv.accessibilityLabel() ?? iv.toolTip ?? ""
                    out += String(format: "%@\t%.0f\t%.0f\t%@\n", "\(type(of: iv))", r.midX, window.frame.height - r.midY, label)
                }
                v.subviews.forEach(walk)
            }
            if let root = controller.window?.contentView { walk(root) }
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
        case "seldrag", "seldragdirect":
            // seldrag x y toY seconds: presses at x,y (window points, top left) and drags straight down to toY,
            // then holds there, as selecting text past the page's bottom does: 60 drags a second, sent through the
            // window in this process (seldragdirect: straight to the web view, past everything of Zigzag's). Logs
            // each frame the web view and its card had along the way, then lets go.
            let n = arg.split(separator: " ").compactMap { Double($0) }
            guard n.count == 4, let window = controller.window else { break }
            let height = window.frame.height
            let direct = name == "seldragdirect"
            let send: @MainActor (NSEvent.EventType, Double) -> Void = { type, y in
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: n[0], y: height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    if direct, let webView = controller.selectedWebView {
                        switch type {
                        case .leftMouseDown: webView.mouseDown(with: event)
                        case .leftMouseUp: webView.mouseUp(with: event)
                        default: webView.mouseDragged(with: event)
                        }
                    } else {
                        window.sendEvent(event)
                    }
                }
            }
            BrowserWebView.takesFirstMouse = true
            send(.leftMouseDown, n[1])
            let start = Date()
            var frames: [String] = []
            dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let t = Date().timeIntervalSince(start)
                    let y = t < 0.4 ? n[1] + (n[2] - n[1]) * t / 0.4 : n[2]
                    if t > n[3] {
                        dragTimer?.invalidate()
                        send(.leftMouseUp, y)
                        BrowserWebView.takesFirstMouse = false
                        debugLog("seldrag frames " + Set(frames).sorted().joined(separator: " | "))
                        return
                    }
                    send(.leftMouseDragged, y)
                    if let webView = controller.selectedWebView {
                        frames.append("\(webView.frame) in \(webView.superview?.frame ?? .zero)")
                    }
                }
            }
        case "hit":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, let window = controller.window, let frameView = window.contentView?.superview {
                let p = NSPoint(x: n[0], y: window.frame.height - n[1])
                let hit = frameView.hitTest(frameView.convert(p, from: nil))
                debugLog("hit at \(n): \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        case "flash":
            func walk(_ v: NSView) { if let s = v as? NSScrollView { s.flashScrollers() }; v.subviews.forEach(walk) }
            if let root = controller.window?.contentView { walk(root) }
        case "shortcutsaudit":
            debugLog("custom shortcuts: " + Shortcuts.allItems.filter(Shortcuts.isCustom).map { "\($0.title)=\($0.keyEquivalent)" }.joined(separator: ", "))
        case "removespaceundo":
            if let space = Library.shared.spaces.first(where: { $0.name == arg }) { controller.removeSpaceWithUndo(space.id) }
        case "spacenames": debugLog("spaces " + Library.shared.spaces.map(\.name).joined(separator: ","))
        case "removespace":
            if let space = Library.shared.spaces.first(where: { $0.name == arg }) { Library.shared.removeSpace(space.id) }
        case "menutest":
            if let bookmark = Library.shared.allBookmarks.first?.0 {
                let menu = SidebarMenus.bookmarkMenu(for: bookmark, controller: controller)
                let index = menu.indexOfItem(withTitle: arg)
                debugLog("menutest \(arg) index=\(index) target=\(String(describing: menu.item(at: max(index,0))?.target))")
                if index >= 0 { menu.performActionForItem(at: index) }
                debugLog("pasteboard=\(NSPasteboard.general.string(forType: .string) ?? "nil")")
            } else { debugLog("menutest: no bookmarks") }
        case "sundo": _ = controller.handleUndoKey(redo: arg == "redo")
        case "movewindow":
            // movewindow x y: the key window's top-left corner, in screen points from the top-left of the main screen.
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, let window = controller.window, let screen = NSScreen.screens.first {
                window.setFrameTopLeftPoint(NSPoint(x: n[0], y: screen.frame.height - n[1]))
            }
        case "focus":
            // focus <n>: the nth window comes to the front, for commands that follow.
            let all = WindowManager.shared.controllers
            if let n = Int(arg), all.indices.contains(n) {
                all[n].window?.makeKeyAndOrderFront(nil)
                // With another app in front, the window can't take key: commands follow it all the same.
                WindowManager.shared.windowBecameKey(all[n])
            }
        case "reducemotion": Tokens.Motion.debugReduceMotion = arg != "off"
        // contrast on|off|system: Increase Contrast's colors for this app alone, or the Mac's setting again.
        case "contrast":
            Tokens.Contrast.debugOverride = arg == "system" ? nil : arg != "off"
            Tokens.Contrast.redraw()
        case "dropdown":
            // dropdown <n>: opens the nth dropdown on the page (0 first), as a click would; "close" closes the open menu.
            if arg == "close" { MenuPanel.current?.close(); break }
            func all(_ v: NSView) -> [DropdownButton] { (v as? DropdownButton).map { [$0] } ?? v.subviews.flatMap(all) }
            if let root = controller.window?.contentView {
                let found = all(root).filter { !$0.isHiddenOrHasHiddenAncestor }
                if found.indices.contains(Int(arg) ?? 0) { found[Int(arg) ?? 0].openMenu() }
            }
        case "focusview":
            // focusview <Class>: keyboard focus on the first visible view of that class in any window (the wheel).
            InteractiveView.debugKeyboardAccess = true
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            for window in NSApp.windows {
                if let root = window.contentView?.superview,
                   let found = views(root).first(where: { "\(type(of: $0))" == arg && !$0.isHiddenOrHasHiddenAncestor }) {
                    debugLog("focusview \(arg): \(window.makeFirstResponder(found))")
                    break
                }
            }
        case "keyfocus":
            // keyfocus <n>: keyboard focus on the nth drawn control in the window, as Tab with Full Keyboard Access gives it.
            InteractiveView.debugKeyboardAccess = true
            func all(_ v: NSView) -> [InteractiveView] { ((v as? InteractiveView).map { [$0] } ?? []) + v.subviews.flatMap(all) }
            if let root = controller.window?.contentView {
                // keyfocus <n> [Class]: the nth of that kind of control, or of any kind.
                let f = arg.split(separator: " ").map(String.init)
                let found = all(root).filter { !$0.isHiddenOrHasHiddenAncestor && $0.onClick != nil && (f.count < 2 || "\(type(of: $0))" == f[1]) }
                let n = Int(f.first ?? "") ?? 0
                if found.indices.contains(n) {
                    let ok = controller.window?.makeFirstResponder(found[n]) ?? false
                    debugLog("keyfocus \(type(of: found[n])): \(ok)")
                }
            }
        case "unload":
            // unload <title>: a pinned page or favorite goes back to not loaded.
            if let id = (Library.shared.spaces.flatMap(\.bookmarks) + Library.shared.favorites).first(where: { $0.title == arg })?.id,
               let tab = controller.tabManager.bookmarkTab(for: id) { controller.tabManager.close(tab) }
        case "renamepin":
            // renamepin <old>|<new>
            let names = arg.components(separatedBy: "|")
            if names.count == 2, let id = Library.shared.spaces.flatMap(\.bookmarks).first(where: { $0.title == names[0] })?.id {
                controller.listRenameBookmark(id, to: names[1])
            }
        case "settingsrows":
            // settingsrows <path>: Settings' space rows, as layout writes the sidebar's.
            func rows(_ v: NSView) -> [SpaceSettingsRow] { (v as? SpaceSettingsRow).map { [$0] } ?? v.subviews.flatMap(rows) }
            if let root = controller.tabManager.selectedTab?.settingsView, let window = controller.window {
                let json = rows(root).map { row -> [String: Any] in
                    let r = row.convert(row.bounds, to: nil).flippedIn(window)
                    return ["name": "space:" + (Library.shared.space(row.spaceID)?.name ?? ""), "x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
                }
                if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: URL(fileURLWithPath: arg)) }
            }
        case "openfav":
            // openfav <title>: opens that favorite, whichever profile's, as choosing it in the command bar would.
            if let favorite = Library.shared.favorites.first(where: { $0.title == arg }) { controller.tabManager.openBookmark(favorite) }
        case "favorite":
            if let tab = controller.tabManager.selectedTab { controller.tabManager.favoriteTab(tab) }
        case "pagecorner":
            if let r = Double(arg) { PageCardView.attachedRadius = r; controller.root.card.needsLayout = true; controller.root.secondCard.needsLayout = true }
        case "spacedepth":
            // spacedepth <0-1>: the current space's shade, the window's mode following it.
            if let depth = Double(arg) { Library.shared.setBrightness(depth, for: controller.tabManager.currentSpaceID) }
        case "spacecolor":
            // spacecolor <sky|sage|sand|...>: the current space takes that curated color, following light and dark.
            if let color = SpaceColor(rawValue: arg), var look = Library.shared.space(controller.tabManager.currentSpaceID) {
                SpaceLook.curated(color).apply(to: &look)
                Library.shared.setLook(look)
            }
        case "spacepreset":
            // spacepreset <index>: the current space takes that preset from the editor's row.
            if let i = Int(arg), SpaceLook.presets.indices.contains(i), var look = Library.shared.space(controller.tabManager.currentSpaceID) {
                SpaceLook.presets[i].apply(to: &look)
                Library.shared.setLook(look)
            }
        case "spacelook":
            // spacelook <hue 0-360> <second hue or -> <see-through 0-1> [clear]: the current space's color, gradient and glass.
            let f = arg.split(separator: " ").map(String.init)
            guard f.count >= 3, var look = Library.shared.space(controller.tabManager.currentSpaceID) else { break }
            look.clearGlass = f.count > 3 && f[3] == "frosted" ? false : nil
            look.hue = Double(f[0]).map { $0 / 360 }
            look.intensity = look.hue == nil ? nil : 0.6
            look.hue2 = Double(f[1]).map { $0 / 360 }
            look.intensity2 = look.hue2 == nil ? nil : 0.6
            look.translucency = Double(f[2]).flatMap { $0 > 0 ? $0 : nil }
            Library.shared.setLook(look)
        case "addfav", "addpin":
            // addfav <url> <title>, addpin <url> <title>: a favorite or a pinned page, without loading its page.
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard let url = f.first.flatMap(URL.init(string:)) else { break }
            let title = f.count > 1 ? f[1] : url.host() ?? ""
            if name == "addfav" { _ = Library.shared.addFavorite(url: url, title: title, in: controller.tabManager.profile.id) }
            else { _ = Library.shared.addBookmark(url: url, title: title, to: controller.tabManager.currentSpaceID) }
        case "unfavorite":
            // unfavorite <title>: back to a tab, in whichever window holds its page.
            if let favorite = Library.shared.favorites.first(where: { $0.title == arg }) {
                let owner = WindowManager.shared.controllers.first { $0.tabManager.bookmarkTab(for: favorite.id) != nil } ?? controller
                owner.tabManager.unbookmark(favorite.id, toIndex: 0)
            }
        case "save": WindowManager.shared.saveNow(synchronously: true)
        default: break
        }
    }

    /// The extensions a command means: those of the profile of the tab you're on.
    @available(macOS 15.4, *)
    private static func extensions(in controller: BrowserWindowController) -> ExtensionHost {
        controller.tabManager.selectedTab?.extensionHost ?? controller.tabManager.profile.extensions
    }

    /// Whether this is a copy set up for scripted checks: its own data folder and a test vault. The verbs that
    /// confirm for you, or delete, work only there: never on the data and passwords you use.
    private static var isTestCopy: Bool {
        ProcessInfo.processInfo.environment["ZIGZAG_DATA_DIR"] != nil && PasswordStore.isTestVault
    }

    @available(macOS 15.4, *)
    static func extensionTest(_ id: String, page: URL, in controller: BrowserWindowController) async {
        var report: [String: Any] = ["id": id]
        let had = controller.tabManager.profile.installs.state(id) != nil
        let started = Date()
        if !had { report["install"] = String(describing: await ExtensionStore.install(id, in: controller.tabManager.profile)).prefix(160) }
        report["installSeconds"] = Int(Date().timeIntervalSince(started))
        for _ in 0..<60 {
            if extensions(in: controller).contexts.contains(where: { $0.uniqueIdentifier == id }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let context = extensions(in: controller).contexts.first { $0.uniqueIdentifier == id }
        report["loaded"] = context != nil
        report["name"] = context?.webExtension.displayName ?? ""
        let tabsBefore = controller.tabManager.currentTabs.count
        controller.tabManager.newTab(url: page)
        try? await Task.sleep(for: .seconds(9))
        let tab = controller.tabManager.selectedTab
        if let pid = tab?.webView?.value(forKey: "_webProcessIdentifier") as? Int32 {
            let a = cpuTime(pid)
            try? await Task.sleep(for: .seconds(4))
            report["pageCPU"] = Int((cpuTime(pid) - a) / 4 * 100)
        }
        let item = extensions(in: controller).actions(for: tab).first { $0.id == id }
        report["button"] = item != nil
        report["badge"] = item?.badge ?? ""
        report["needsAttention"] = item?.attention != nil
        if let item {
            extensions(in: controller).lastAction = nil
            let tabs = controller.tabManager.currentTabs.count
            extensions(in: controller).performAction(item, tab: tab, in: controller)
            try? await Task.sleep(for: .seconds(3))
            let popup = extensions(in: controller).lastAction?.popupWebView
            report["popup"] = popup != nil
            if let popup {
                let text = try? await popup.evaluateJavaScript("(document.body && document.body.innerText || '').trim().length")
                report["popupTextLength"] = (text as? Int) ?? 0
            }
            report["openedTab"] = controller.tabManager.currentTabs.count > tabs
            extensions(in: controller).lastAction?.popupPopover?.close()
        }
        debugLog("exttest " + ((try? String(data: JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)) ?? "?"))
        while controller.tabManager.currentTabs.count > tabsBefore, let last = controller.tabManager.selectedTab { controller.tabManager.close(last) }
        if !had { ExtensionStore.uninstall(id, from: controller.tabManager.profile) }
    }

    static func cpuTime(_ pid: Int32) -> Double { ProcessCPU.seconds(pid) }

    /// A made-up year of browsing, for timing History with a big one: sittings of pages on a few thousand sites, titles
    /// in English and Chinese, and an icon for every other site. Only into a test copy's own data.
    static func seedHistory(_ count: Int) {
        guard ProcessInfo.processInfo.environment["ZIGZAG_DATA_DIR"] != nil else { debugLog("seedhistory refused: not a test copy"); return }
        var rng = SystemRandomNumberGenerator()
        let words = ["swift", "release", "notes", "guide", "design", "kitchen", "travel", "shanghai", "weather", "github", "issue",
                     "pull", "request", "video", "music", "review", "price", "laptop", "garden", "recipe", "news", "market",
                     "python", "docs", "api", "school", "map", "train", "flight", "hotel", "photo", "camera", "game", "chess",
                     "上海", "天气", "新闻", "视频", "音乐", "美食", "旅行", "地图", "学习", "编程", "文档", "电影", "游戏", "购物"]
        let tlds = ["com", "org", "net", "io", "cn", "dev", "co.uk"]
        let hosts = (0..<2500).map { i in
            (i % 3 == 0 ? "www." : "") + words[i % words.count].unicodeScalars.filter(\.isASCII).map(String.init).joined()
                + "\(i)" + "." + tlds[i % tlds.count]
        }
        let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
        }
        if let tiff = icon.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            for host in hosts.enumerated() where host.offset % 2 == 0 {
                let site = host.element.hasPrefix("www.") ? String(host.element.dropFirst(4)) : host.element
                try? png.write(to: Paths.favicons.appendingPathComponent(site + ".png"))
            }
        }
        var entries: [(URL, String, Int, Date)] = []
        var time = Date().addingTimeInterval(-60)
        while entries.count < count {
            // A sitting of a few dozen pages, a handful of sites in turn, then a break.
            let sitting = Int.random(in: 10...80, using: &rng)
            var host = hosts[Int.random(in: 0..<hosts.count, using: &rng)]
            for _ in 0..<sitting {
                if Int.random(in: 0..<4, using: &rng) == 0 { host = hosts[Int.random(in: 0..<hosts.count, using: &rng)] }
                let title = (0..<Int.random(in: 2...6, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
                let path = title.unicodeScalars.filter(\.isASCII).map(String.init).joined().replacingOccurrences(of: " ", with: "-")
                guard let url = URL(string: "https://\(host)/\(path)/\(entries.count)") else { continue }
                entries.append((url, title.capitalized, Int.random(in: 1...20, using: &rng), time))
                time.addTimeInterval(-Double.random(in: 10...300, using: &rng))
            }
            time.addTimeInterval(-Double.random(in: 3600...30000, using: &rng))
        }
        Profiles.shared.default.history.importVisits(entries)
        debugLog("seedhistory => \(entries.count) visits back to \(time)")
    }

    /// A made-up bookmarks tree as a big Chrome import brings it, for timing the sidebar's folders: `count` pages in
    /// about 150 folders, up to eight deep, one of them holding 400 pages of its own, all shut but the outermost. Only into a test copy's own data.
    static func seedFolders(_ count: Int, in controller: BrowserWindowController) {
        guard ProcessInfo.processInfo.environment["ZIGZAG_DATA_DIR"] != nil else { debugLog("seedfolders refused: not a test copy"); return }
        let names = ["Spring", "Boot", "Config", "Profiles", "Notes", "Guides", "Docs", "Tools", "Archive", "Old", "设计", "学习"]
        var paths: [[String]] = []
        func grow(_ path: [String], branches: Int) {
            paths.append(path)
            guard path.count < 8 else { return }
            for b in 0..<branches { grow(path + [names[(path.count + b) % names.count] + (b == 0 ? "" : " \(b + 1)")], branches: path.count < 2 ? 2 : 1) }
        }
        let root = "资料文档"
        for top in ["Java", "Web", "正则表达式"] { grow([root, top], branches: 2) }
        paths += [[root, "Linux"], [root, "Linux", "Docker"], [root, "Linux", "vpn"], [root, "镜像"]]
        for i in 1...10 { grow(["收藏 \(i)"], branches: 2) }
        // The big one: a folder of 400 pages, opened and shut while timing.
        let big = [root, "镜像"]
        let hosts = (0..<300).map { "site\($0)." + ($0 % 2 == 0 ? "com" : "test") }
        let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemTeal.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
        }
        if let tiff = icon.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            for host in hosts where host.hasSuffix(".com") { try? png.write(to: Paths.favicons.appendingPathComponent(host + ".png")) }
        }
        var pages: [(url: URL, title: String)] = [], folders: [[String]] = []
        for i in 0..<count {
            let path = i < 400 ? big : paths[i % paths.count]
            guard let url = URL(string: "https://\(hosts[i % hosts.count])/page/\(i)") else { continue }
            pages.append((url, "\(path.last ?? "") page \(i)"))
            folders.append(path)
        }
        let space = Library.shared.addSpace(name: "Seeded")
        _ = Library.shared.appendBookmarks(pages, to: space.id, folders: folders)
        // Shut but the outermost, as you'd keep a big tree, so each one can be opened while timing.
        Library.shared.together {
            for folder in Library.shared.folders(in: space.id) where folder.name != root { Library.shared.setFolderOpen(folder.id, false) }
        }
        controller.tabManager.switchToSpace(space.id)
        debugLog("seedfolders => \(pages.count) pages in \(Library.shared.folders(in: space.id).count) folders, deepest \(Library.shared.folders(in: space.id).map { Library.shared.depth(ofFolder: $0.id) }.max() ?? 0)")
    }
    #endif
}

#if DEBUG
extension NSRect {
    /// From window coordinates (bottom left) to the top-left ones the debug commands use.
    func flippedIn(_ window: NSWindow) -> NSRect {
        NSRect(x: minX, y: window.frame.height - maxY, width: width, height: height)
    }
}
#endif
