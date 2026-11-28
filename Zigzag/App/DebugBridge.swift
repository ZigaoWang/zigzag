import AppKit
import WebKit
import os
#if DEBUG
import ScreenCaptureKit
#endif

/// Debug builds only: lets scripts drive the UI (for screenshots and testing) via distributed notifications.
/// `xcrun swift -e` or the bundled `zz` script posts "app.zigzag.debug" with a command string.
enum DebugBridge {
    #if DEBUG
    static var hovered: [NSView] = []
    /// ZIGZAG_MUTE_ALL=1: every tab's page is muted from the moment its web view is made, and nothing plays until
    /// asked, so a test copy can open video pages without a sound.
    static let mutesEverything = ProcessInfo.processInfo.environment["ZIGZAG_MUTE_ALL"] == "1"
    private static var scrollLog: [String] = []
    private static var dragTimer: Timer?
    /// A pane carried by `panedrag`, and where it is now (on screen).
    private static var debugPaneDrag: PaneDrag?
    private static var debugPaneDragPoint: NSPoint?

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
        // ZIGZAG_DEBUG_COMMANDS: commands to run once launched, split by " ;; ", one every 1.5 s after a short wait,
        // for when the Mac doesn't pass notifications along.
        MainActor.assumeIsolated { DebugMenu.install() }
        let script = ProcessInfo.processInfo.environment["ZIGZAG_DEBUG_COMMANDS"] ?? ""
        for (i, command) in script.components(separatedBy: " ;; ").filter({ !$0.isEmpty }).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(i) * 1.5) { MainActor.assumeIsolated { run(command) } }
        }
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
    /// mini [url], miniquick [text], miniquickenter, miniquickesc, minibar [text], miniext <url>, minisetting on|off,
    /// minitype <text>, minimove, miniclose, minifind [text|close], minispace [name], minicopy, miniresize <w> <h>,
    /// minimenu <char> [cmd|shift|ctrl|opt...], ministate <path> (JSON), minishot <path> (PNG; web content may be
    /// blank), miniclosebrowsers, minijs <script>, miniesc, miniquit, miniask notifications, minianswer
    /// allow|always|alternate|deny|notnow|<action>, minisave save|notnow, minieval <path> <script>, miniswipe <dx> [slow]
    /// [noend], miniborderless on|off, miniclick x y [real] (a click in its page; real counts it for
    /// pop-ups), minikey on|off (taken for the key window), miniprompts on|off (questions show though it isn't key). Without a mini window, miniask and minianswer use the front browser window.
    /// pageprobe <path> [mark]: each tab's page state as JSON; `mark` tags live pages so a later probe shows which
    /// reloaded.
    /// capture [area|element|full|visible] (Capture begun in that mode, or switched to it), capture toggle (⇧⌘2),
    /// capture cancel, capture drag x y w h (an area drawn, in the page's points), capture hover x y (the pointer
    /// there), capture go (Return), capture key <char> (a key while capturing), capture state <path> (JSON),
    /// capture card copy|save|share|close (the card after it).
    private static func runCapture(_ arg: String, in controller: BrowserWindowController) {
        let f = arg.split(separator: " ").map(String.init)
        let capture = controller.capture
        let modes: [String: PageCapture.Mode] = ["area": .area, "element": .element, "full": .fullPage, "visible": .visible]
        let numbers = f.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
        switch f.first ?? "" {
        case "toggle": capture.toggle()
        case "cancel": capture.cancel()
        case "drag": if numbers.count == 4 { capture.debugDrag(NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])) }
        case "hover": if numbers.count == 2 { capture.debugHover(NSPoint(x: numbers[0], y: numbers[1])) }
        case "go": capture.confirm()
        case "key":
            guard f.count == 2, let window = controller.window else { break }
            let codes: [String: UInt16] = ["esc": 53, "return": 36, "left": 123, "right": 124, "down": 125, "up": 126]
            let chars = codes[f[1]] == nil ? f[1] : ""
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: codes[f[1]] ?? 0) {
                _ = capture.handle(event)
            }
        case "state":
            guard f.count == 2, let data = try? JSONSerialization.data(withJSONObject: capture.debugState, options: [.prettyPrinted, .sortedKeys]) else { break }
            try? data.write(to: URL(fileURLWithPath: f[1]))
        case "card": if f.count == 2 { capture.debugPreview?.debugPress(f[1]) }
        case let name:
            let mode = modes[name]
            if capture.isActive, let mode { capture.choose(mode) } else { capture.begin(mode) }
        }
    }

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

    /// webapp install (the Install as App sheet over the front tab), webapp confirm|cancel (its answer),
    /// webapp open|close <id> (as the app's small app asks), webapp remove <id>, webapp closeall, webapp removeall,
    /// webapp eval <path> <script>, webapp hide|minimize|offscreen (the first app's window), webapp state <path> (JSON: the list,
    /// the open windows), webapp settings (Settings › General), webapp toolbar on|off (the first app's), webapp front |
    /// browserfront (the menu bar for that window in front), webapp menukey <char> (⌘<char>'s item, run), webapp menu
    /// <path> (the menu bar's items), webapp sidebutton <back|forward> x y (in the first app's window), webapp site (its
    /// Site Controls, opened or closed).
    private static func runWebApp(_ arg: String) {
        let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = f.count > 1 ? f[1] : ""
        switch f.first ?? "" {
        case "install":
            if let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first { controller.installAsApp(nil) }
        case "confirm": WebAppInstallSheet.current?.debugAnswer(true)
        case "cancel": WebAppInstallSheet.current?.debugAnswer(false)
        case "open": WebAppStore.handle(WebAppLink.make(.open, id: rest))
        case "close": WebAppStore.handle(WebAppLink.make(.close, id: rest))
        case "remove": WebAppStore.shared.remove(rest)
        case "closeall": WebAppWindowController.all.forEach { $0.window?.close() }
        case "sidebutton": if let window = WebAppWindowController.all.first?.window { sendSideButton(rest, to: window) }
        case "site": WebAppWindowController.all.first?.showSiteControls()
        case "removeall": WebAppStore.shared.apps.forEach { WebAppStore.shared.remove($0.id) }
        case "eval":
            // eval <path> <script>: the first app's page runs the script; its result goes to the file.
            let g = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard g.count == 2, let webView = WebAppWindowController.all.first?.tab.webView else { break }
            webView.evaluateJavaScript(g[1]) { result, error in
                try? (result.map { "\($0)" } ?? "error \(String(describing: error))").write(toFile: g[0], atomically: true, encoding: .utf8)
            }
        case "hide": WebAppWindowController.all.first?.hideWebApp(nil)
        case "minimize": WebAppWindowController.all.first?.window?.miniaturize(nil)
        case "offscreen":
            // offscreen: the first app's window moved wholly past every screen, where macOS counts it as covered.
            guard let window = WebAppWindowController.all.first?.window else { break }
            // Not remembered for the app's next window.
            window.setFrameAutosaveName("")
            window.setFrame(NSRect(origin: NSPoint(x: -20000, y: -20000), size: window.frame.size), display: false)
        case "toolbar":
            // toolbar on|off: the first app's toolbar, as Settings' switch sets it.
            if let app = WebAppStore.shared.apps.first { WebAppStore.shared.setShowsToolbar(rest == "on", for: app.id) }
        case "front":
            // front: the menu bar as it is with the first app's window in front (a copy behind other apps never
            // becomes key on its own).
            WebAppMenuBar.shared?.follow(WebAppWindowController.all.first?.window)
        case "browserfront":
            WebAppMenuBar.shared?.follow(WindowManager.shared.controllers.first?.window)
        case "menukey":
            // menukey <char>: what ⌘<char> does in the menu bar now: its item's action, sent as the menu would, to the
            // key window or, with none (behind other apps), the first app's window.
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if let sub = item.submenu, let found = find(sub) { return found }
                    if item.keyEquivalent == rest, item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command { return item }
                }
                return nil
            }
            guard let item = NSApp.mainMenu.flatMap(find), let action = item.action else { debugLog("webapp menukey \(rest): no item"); break }
            let target: Any? = item.target ?? (NSApp.keyWindow == nil && !NSApp.responds(to: action) ? WebAppWindowController.all.first : nil)
            debugLog("webapp menukey \(rest): \(item.title) \(action) -> \(NSApp.sendAction(action, to: target, from: item))")
        case "menu":
            // menu <path>: the menu bar's titles, each item with its action, indented under its menu.
            var lines: [String] = []
            func list(_ menu: NSMenu, _ depth: Int) {
                for item in menu.items where !item.isSeparatorItem {
                    let keys = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.contains(.option) ? "⌥" : "")\(item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")⌘\(item.keyEquivalent)]"
                    lines.append(String(repeating: "  ", count: depth) + item.title + keys + (item.action.map { " <\(NSStringFromSelector($0))>" } ?? "") + (item.isHidden ? " (hidden)" : ""))
                    if let sub = item.submenu { list(sub, depth + 1) }
                }
            }
            if let main = NSApp.mainMenu { list(main, 0) }
            try? lines.joined(separator: "\n").write(toFile: rest, atomically: true, encoding: .utf8)
        case "settings":
            if let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first { SettingsPage.open(.general, in: controller) }
        case "state":
            let apps: [[String: Any]] = WebAppStore.shared.apps.map {
                ["id": $0.id, "name": $0.name, "url": $0.url.absoluteString, "bundle": $0.bundlePath,
                 "running": !WebAppStore.runningLauncher(of: $0.id).isEmpty]
            }
            let state: [String: Any] = ["apps": apps, "windows": WebAppWindowController.all.map(\.debugState), "folder": WebApps.folder.path,
                                        "browserWindows": WindowManager.shared.controllers.count, "sessionWaiting": WindowManager.shared.sessionWaiting,
                                        "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "active": NSApp.isActive]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: rest)) }
        default: break
        }
    }

    /// `<back|forward> x y`: a mouse's side button pressed and let go at a point (window points, top left origin),
    /// handed to the window as the press and release would arrive.
    private static func sendSideButton(_ arg: String, to window: NSWindow) {
        let f = arg.split(separator: " ").map(String.init)
        guard f.count >= 3, let x = Double(f[1]), let y = Double(f[2]) else { return }
        let screen = window.convertPoint(toScreen: NSPoint(x: x, y: window.frame.height - y))
        let location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        let button = CGMouseButton(rawValue: f[0] == "forward" ? 4 : 3) ?? .center
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button),
                  let event = NSEvent(cgEvent: cg) else { continue }
            let start = CACurrentMediaTime()
            window.sendEvent(event)
            debugLog("sidebutton \(f[0]) \(type == .otherMouseDown ? "down" : "up") button \(event.buttonNumber) took \(Int((CACurrentMediaTime() - start) * 1000)) ms")
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
        case "mininote": mini?.debugLinksNote(arg)
        case "minispace": mini?.debugSpace(arg)
        case "minicopy": mini?.copyPageURL(nil)
        case "minihover": mini?.debugHoverStrip(arg)
        case "minisite": mini?.showSiteControls()
        case "minifind": mini?.debugFind(arg)
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
        case "miniendsheet": if let window = mini?.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        case "miniclosebrowsers": WindowManager.shared.controllers.forEach { $0.window?.performClose(nil) }
        case "minisidebutton": if let window = mini?.window { sendSideButton(arg, to: window) }
        case "minijs": mini?.tab.webView?.evaluateJavaScript(arg, completionHandler: nil)
        case "miniprompts": MiniWindowController.debugPromptsShow = arg != "off"
        case "miniclick":
            // `pageclick`, in the newest Zigzag Mini (window points, top left).
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count >= 2, let window = mini?.window else { break }
            BrowserWebView.takesFirstMouse = true
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: f[0], y: window.frame.height - f[1]), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
            BrowserWebView.takesFirstMouse = false
            // `real`: counted as your own click for the page's pop-ups (`PopupNotice.noteInput`).
            if arg.contains("real"), let webView = mini?.tab.webView { PopupNotice.noteInput(in: webView) }
        case "minikey":
            // As if Zigzag Mini were the key window (NSApp.keyWindow), for a test copy kept behind.
            DebugKeyWindow.pretend(arg == "off" ? nil : mini?.window)
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
            let answer: PermissionAnswer?
            switch arg {
            case "allow": answer = PermissionAnswer(action: "allow", remember: false)
            case "always": answer = PermissionAnswer(action: "allow", remember: true)
            case "alternate": answer = PermissionAnswer(action: "screen", remember: false)
            case "deny": answer = PermissionAnswer(action: "deny", remember: false)
            case "notnow", "": answer = nil
            // Any other action by name, as the pop-up question's dropdown gives it (mini, thisTab, newTab).
            default: answer = PermissionAnswer(action: arg, remember: false)
            }
            PermissionPrompt.debugAnswer(answer, in: host)
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
            let delegate = (NSApp.delegate as AnyObject?).flatMap { $0.responds(to: action) ? $0 : nil }
            let target: AnyObject? = responder ?? (NSApp.responds(to: action) ? NSApp : delegate)
            // No target: dimmed, as for a real key.
            let enabled = target != nil && ((target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true)
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
            json["permissionButtons"] = WindowManager.shared.controllers.map { PermissionPrompt.debugButtons(in: $0) }
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
        // "reverse": the fingers come back over the last half.
        let turn = parts.contains("reverse") ? phases.count / 2 : phases.count
        for (i, phase) in phases.enumerated() {
            let d: Int32 = phase == 2 ? (i > turn ? -dx : dx) : 0
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

    /// Which page has the keyboard: the selected tab's, or something else.
    static func responderName(in controller: BrowserWindowController) -> String {
        let responder = controller.window?.firstResponder
        if let page = controller.selectedWebView, responder === page { return "tab" }
        return responder.map { String(describing: type(of: $0)) } ?? "nil"
    }

    /// One event of a trackpad flick: when, its gesture and momentum phases (CGEvent's values), and how far it moves.
    struct FlickStep { var time: Double; var phase: Int64; var momentum: Int64; var dx: Double }

    /// A two-finger flick as a trackpad reports it, at 120 events a second: the fingers speed up over 60% of
    /// `seconds` and travel 42% of `width`, lift, and momentum dies away over the rest. Positive dx moves right.
    static func flick(width: Double, seconds: Double, rate: Double = 120) -> [FlickStep] {
        let dt = 1 / rate, fingers = seconds * 0.6, coast = seconds - fingers, distance = width * 0.42
        let n = max(3, Int((fingers / dt).rounded()))
        // Ease-in: still at the start, fastest as the fingers lift.
        let travel = { (u: Double) in distance * (1 - cos(u * .pi / 2)) }
        var steps = [FlickStep(time: 0, phase: 1, momentum: 0, dx: 0)]
        for k in 1...n { steps.append(FlickStep(time: Double(k) * dt, phase: 2, momentum: 0, dx: travel(Double(k) / Double(n)) - travel(Double(k - 1) / Double(n)))) }
        let lift = Double(n + 1) * dt
        steps.append(FlickStep(time: lift, phase: 4, momentum: 0, dx: 0))
        // The fingers' speed as they lift, points a second, which momentum carries on from.
        let speed = distance * .pi / 2 / fingers
        let m = max(2, Int((coast / dt).rounded()))
        for j in 1...m {
            let last = j == m
            steps.append(FlickStep(time: lift + Double(j) * dt, phase: 0, momentum: j == 1 ? 1 : last ? 3 : 2,
                                   dx: last ? 0 : speed * dt * exp(-Double(j) * dt / (coast / 3))))
        }
        return steps
    }

    /// Sends `flick` to the window's own event handling, each event made as it's due, so the sidebar sees the times
    /// and speeds a trackpad gives. Nothing goes to the system.
    private static func sendFlick(toNext: Bool, seconds: Double, width: CGFloat, to window: NSWindow, at point: NSPoint) {
        let screenPoint = window.convertPoint(toScreen: point)
        let flipped = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y)
        // Fingers moving left bring in the next space.
        let sign: Double = toNext ? -1 : 1
        let start = DispatchTime.now()
        // The event carries whole points: what's rounded off goes into the next one, so a slow flick still gets there.
        var carried = 0.0
        for step in flick(width: Double(max(width, 1)), seconds: max(seconds, 0.1)) {
            let dx = (step.dx * sign + carried).rounded()
            carried += step.dx * sign - dx
            DispatchQueue.main.asyncAfter(deadline: start + step.time) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
                cg.location = flipped
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: step.momentum)
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
                cg.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
                if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
            }
        }
    }

    /// sip state <path> (the newest pop-up window: JSON), sip js <script>, sip endsheet (cancels its sheet), sip open
    /// (Open in New Tab), sip copy, sip select (its address, selected), sip shot <path> (its drawing, as a PNG), sip menu
    /// <char> [cmd|shift|opt|ctrl] [send] (the menu item for that shortcut with the pop-up as if key: what takes it and
    /// whether it's on; send runs it). None brings Zigzag forward.
    private static func runSignInPopup(_ arg: String) {
        let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = f.count > 1 ? f[1] : ""
        guard let popup = PopupWindowController.all.max(by: { ($0.window?.windowNumber ?? 0) < ($1.window?.windowNumber ?? 0) }),
              let window = popup.window else { debugLog("sip: no pop-up"); return }
        switch f.first ?? "" {
        case "state":
            var state = popup.debugState
            state["window"] = window.windowNumber
            state["level"] = window.level.rawValue
            state["visible"] = window.isVisible
            state["sheet"] = window.attachedSheet.map { "\(type(of: $0))" } ?? "none"
            state["sheetWindow"] = window.attachedSheet?.windowNumber ?? 0
            state["firstResponder"] = window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: rest)) }
        case "js":
            popup.webView.evaluateJavaScript(rest) { result, error in
                debugLog("sip js => \(String(describing: result).prefix(500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "endsheet": if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        case "open": popup.openInTab()
        case "copy": popup.copyPageURL(nil)
        case "select": popup.debugSelectAddress()
        case "shot":
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: rest))
        case "menu":
            let g = rest.split(separator: " ").map(String.init)
            guard let ch = g.first else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in g.dropFirst() {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "ctrl": flags.insert(.control); case "opt": flags.insert(.option); default: break }
            }
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if let sub = item.submenu, let found = find(sub) { return found }
                    if item.keyEquivalent == ch, item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == flags { return item }
                }
                return nil
            }
            let pretended = DebugKeyWindow.window
            DebugKeyWindow.pretend(window)
            defer { DebugKeyWindow.pretend(pretended) }
            guard let item = NSApp.mainMenu.flatMap(find), let action = item.action else { debugLog("sip menu \(rest): no item"); break }
            var chain: [AnyObject] = []
            var next: NSResponder? = window.firstResponder
            while let r = next { chain.append(r); next = r.nextResponder }
            if let delegate = window.delegate, !chain.contains(where: { $0 === delegate }) { chain.append(delegate) }
            chain.append(NSApp)
            if let delegate = NSApp.delegate { chain.append(delegate) }
            let found = chain.first { $0.responds(to: action) }
            let valid: Bool = {
                guard let found else { return false }
                if let v = found as? NSMenuItemValidation { return v.validateMenuItem(item) }
                return true
            }()
            debugLog("sip menu \(rest): item=\(item.title) target=\(found.map { "\(type(of: $0))" } ?? "nil") enabled=\(valid)")
            if g.contains("send"), let found, valid { NSApp.sendAction(action, to: found, from: item) }
        default: debugLog("sip: unknown \(arg)")
        }
    }

    /// windowsdump <path>: every window's views, without bringing any forward (that would exit page full screen). Popup
    /// commands, which never bring the browser forward (that closes the popup): popupwinstate <path> (JSON),
    /// popupwinclick <x> <y> (points from top left), popupwintype <text> (to the key window), popupwinjs <path>
    /// <script>, popupwinesc.
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
                                        "page": popupPage?.url?.absoluteString ?? "-",
                                        "windows": NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) key=\($0.isKeyWindow) firstResponder=\($0.firstResponder.map { "\(type(of: $0))" } ?? "none")" }]
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
        case "popupwinesc":
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let window, let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                            isARepeat: false, keyCode: 53) {
                    window.sendEvent(event)
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
    /// the pointer brings them), mppress back|site|double|minimize|close|play|rewind|forward|previous|next, mpdrag <dx> <dy> (dragged that far and
    /// let go), mpselect <index> (as `select`), mpwindow <path> (window number and process), mpeval <index> <path> <script>
    /// (the script's result in that tab's page, which it may await, written to the file).
    private static func runMiniPlayer(_ name: String, _ arg: String, in controller: BrowserWindowController) {
        let player = controller.miniPlayer
        switch name {
        case "mpstate":
            if let data = try? JSONSerialization.data(withJSONObject: player.debugState, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "mphover": player.card?.debugHover(arg != "off")
        // mpoff: Turn Off Mini Player, from its menu.
        case "mpoff": player.turnOff()
        // mpbutton <site|minimize|close|rewind|play|forward|previous|next> <hover|press|off>: one of the card's controls as the pointer has it.
        case "mpbutton":
            let f = arg.split(separator: " ").map(String.init)
            if f.count == 2 { player.card?.debugButton(f[0], f[1]) }
        // mppointer on|off: the pointer counts as on the card (for the sidebar's hover previews).
        case "mppointer": player.debugPointerOnCard = arg != "off"
        case "mppress": player.card?.debugPress(arg)
        case "mpdrag":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count >= 2 { player.card?.debugDrag(dx: n[0], dy: n[1]) }
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

    /// A sidebar menu as a right-click at `point` in `view` shows it.
    private static func showDrawn(_ menu: NSMenu, from view: NSView, at point: NSPoint) {
        MenuPanel.show(menu: menu, from: view, placement: .at(view.convert(point, to: nil)))
    }
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

    /// Logs what the developer tools changed on a tab's page, for `devjs` and `devpage`.
    static func logDeveloperPage(of tab: Tab) {
        let script = "[navigator.userAgent.includes('iPhone') ? 'iPhone' : navigator.userAgent.includes('iPad') ? 'iPad' : navigator.userAgent.includes('Chrome') ? 'Chrome' : navigator.userAgent.includes('Firefox') ? 'Firefox' : 'Zigzag', document.title, !!document.getElementById('\(PageOutlines.styleID)'), 'img=' + (document.images[0] ? document.images[0].naturalWidth : '-'), 'sheets=' + document.styleSheets.length].join(' | ')"
        let preferences = tab.webView.map { webView in
            "styles=\(webView.configuration.preferences.value(forKey: PageStyles.key) as? Bool ?? true) imagesWanted=\(PageImages.isOff(in: webView)) imageRule=\(PageImages.isOn(in: webView))"
        } ?? "-"
        let state = tab.developer
        tab.webView?.evaluateJavaScript(script, in: nil, in: PageOutlines.world) { result in
            let page = (try? result.get()) as? String ?? "-"
            debugLog("devpage => tab=\(tab.url?.host() ?? "-") js=\(state.javaScriptOff ? "off" : "on") images=\(state.imagesOff ? "off" : "on") styles=\(state.stylesOff ? "off" : "on") ua=\(state.userAgent) outline=\(state.outlines) prefs: \(preferences) page: \(page)")
        }
    }

    #if DEBUG
    /// Drives the screen-edge sidebar: `edge show|hide|hold on|off|hover <url>|preview <url>|click <url>|frames`, against
    /// the front browser window.
    private static func runEdge(_ arg: String, in controller: BrowserWindowController) {
        let f = arg.split(separator: " ").map(String.init)
        let edge = EdgeSidebar.shared
        func tab(_ part: String) -> Tab? {
            controller.tabManager.allTabs.first { $0.url?.absoluteString.contains(part) == true }
        }
        let visible = controller.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        switch f.first ?? "" {
        case "show": edge.show(on: visible, for: controller)
        case "hide": edge.hide(animated: false)
        case "hold": EdgeSidebar.debugHoldsOpen = f.dropFirst().first != "off"
        case "hover": if f.count > 1, let t = tab(f[1]) { edge.hover(t, in: controller) }
        case "preview": if f.count > 1, let t = tab(f[1]) { edge.previewNow(t, in: controller) }
        case "click": if f.count > 1, let t = tab(f[1]) { controller.listSelect(t) }
        // plus, downloads: the panel's own bottom-bar buttons. pageclick: a click in the middle of the page beside it.
        // pagekey: the page takes the keyboard, as a click into it gives it. esc: Esc in the panel. key <c>: ⌘<c> sent
        // to the panel as the app would deliver it.
        case "plus": controller.edgeSidebar?.showAddMenu()
        case "downloads":
            if let button = controller.edgeSidebar?.downloadsButton { controller.sidebarShowDownloads(from: button) }
        case "pageclick":
            guard let window = edge.pagePreview?.window else { break }
            let point = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        case "pagekey": edge.pagePreview?.window?.makeKey()
        case "esc": edge.dismissPreview()
        case "key":
            guard f.count > 1, let panel = NSApp.windows.first(where: { edge.isPanel($0) }),
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                               windowNumber: panel.windowNumber, context: nil, characters: f[1],
                                               charactersIgnoringModifiers: f[1], isARepeat: false, keyCode: 0) else { break }
            panel.makeKey()
            NSApp.sendEvent(event)
        case "frames":
            let mini = edge.pagePreview
            debugLog("edge showing=\(edge.isShowing) mini=\(mini?.window.map { NSStringFromRect($0.frame) } ?? "-")"
                + " url=\(mini?.tab.url?.absoluteString ?? "-") card=\(mini?.asleepCardTitle ?? "-")"
                + " selected=\(controller.tabManager.selectedTab?.url?.lastPathComponent ?? "-")"
                + " shown=\(controller.root.card.webView.map { $0.window === controller.window } ?? false)"
                + " key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "-") active=\(NSApp.isActive)"
                + " pageVisible=\(mini?.window?.isVisible ?? false) menu=\(MenuPanel.current.map { NSStringFromRect($0.frame) } ?? "-")"
                + " tabs=\(controller.tabManager.allTabs.count) windowKey=\(controller.window?.isKeyWindow ?? false)")
        default: break
        }
    }
    #endif

    static func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        // Zigzag Mini windows come first: they work with no browser window open, and must not bring one forward.
        if name.hasPrefix("mini") { runMini(name, arg); return }
        if name == "windowsdump" { dumpWindows(to: arg); return }
        if name == "webapp" { runWebApp(arg); return }
        if name == "keepontop" || name == "windowmenu" { runKeepOnTop(name, arg); return }
        if name == "sip" { runSignInPopup(arg); return }
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
        // headless show|close|sleep: show their window, hide it, or sleep its front tab.
        if name == "headless" {
            switch arg {
            case "show": Headless.showWindow()
            case "close": Headless.window?.window?.performClose(nil)
            case "sleep": Headless.window?.tabManager.selectedTab?.suspend(because: "debug")
            default: break
            }
            return
        }
        if name == "relayout" {
            // relayout: every browser window lays its pages out again, as a resize would, without coming forward.
            WindowManager.shared.controllers.forEach { $0.root.needsLayout = true; $0.root.paneCards.forEach { $0.needsLayout = true } }
            return
        }
        guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
        #if DEBUG
        if name == "edge" { runEdge(arg, in: controller); return }
        #endif
        // pindrag and pindump work on the address as it is, without bringing the window forward.
        if name == "pindrag" { controller.sidebar.address.debugPinDrag(arg); return }
        if name == "pindump" { controller.sidebar.address.debugDump(to: arg); return }
        // pintoggle <extension id>: pins or unpins it, as Pin to Address in its menu does.
        if name == "pintoggle" { controller.tabManager.profile.installs.togglePin(arg); return }
        if name.hasPrefix("mp") { runMiniPlayer(name, arg, in: controller); return }
        if name == "pageprobe" { pageProbe(arg); return }
        // handoff <path> [askey]: the page Handoff would offer and the activity offering it (JSON); askey offers it as
        // if the window were key, without bringing it forward.
        if name == "handoff" {
            let f = arg.split(separator: " ").map(String.init)
            guard let path = f.first else { return }
            if f.dropFirst().first == "askey" { controller.updateHandoff(asKey: true) }
            var state: [String: Any] = ["key": controller.window?.isKeyWindow == true, "private": controller.tabManager.isPrivate]
            if case let .page(url, title)? = controller.handoffPage { state["page"] = ["url": url.absoluteString, "title": title] }
            if let activity = controller.handoff {
                state["activity"] = ["type": activity.activityType, "url": activity.webpageURL?.absoluteString ?? "", "title": activity.title ?? ""]
            }
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
            return
        }
        if name == "scrollbench" { ScrollBench.run(arg, in: controller); return }
        if name == "fpsbench" { FrameRateBench.run(arg, in: controller); return }
        if name == "perfsuite" { PerfBench.run(arg); return }
        if name == "idle" { IdleWorkCommand.run(arg); return }
        if name == "redraws" { RedrawCounter.run(arg); return }
        // glassvariant <name>: draws clear glass another way (`GlassVariant`), until relaunch.
        if name == "glassvariant" { if let variant = GlassVariant(rawValue: arg) { DebugMenu.apply(variant) }; return }
        // card [tilt <x> <y>|tilt off|finish <name>|flip|hover <n>|save <path>|shot <path>|close]: About with Your Zigzag Card, opened behind, leaning as if
        // the pointer were there (-1 to 1 from its middle, y up), its picture saved, or its window captured by number.
        // card start <yyyy-mm-dd> <version> [exact]: the kept start, replaced, for a test copy.
        if name == "card" {
            let f = arg.split(separator: " ").map(String.init)
            if f.first == "start", f.count >= 3, let date = ISO8601DateFormatter().date(from: f[1] + "T12:00:00Z") {
                CardStart.defaults.set(date, forKey: CardStart.dateKey)
                CardStart.defaults.set(f[2], forKey: CardStart.versionKey)
                CardStart.defaults.set(f.contains("exact"), forKey: CardStart.exactKey)
                return
            }
            if let about = AboutWindowController.shared, !f.isEmpty { about.debugCard(f) } else { AboutWindowController.show() }
            return
        }
        // updateready <version>|off: a pretend staged update (Restart only logs); updatedismiss: the card's close
        // button; updatestate <path>: menu title and staged update (JSON).
        if name == "updateready" { Updater.shared.debugStage(arg == "off" || arg.isEmpty ? nil : arg); return }
        if name == "updatedismiss" { Updater.shared.dismissCard(); return }
        // updateoffer <version>|off: a pretend update on offer, as with automatic installs off; updateskip: its Skip.
        if name == "updateoffer" { Updater.shared.debugOffer(arg == "off" || arg.isEmpty ? nil : arg); return }
        if name == "updateskip" { Updater.shared.skipOffered(); return }
        // updatesim <version> [share|preparing]: Check for Updates… with a pretend download, held at that step if
        // given.
        if name == "updatesim" {
            let f = arg.split(separator: " ").map(String.init)
            Updater.shared.debugSimulate(f.first ?? "0.9.2-beta.1", holdAt: f.count > 1 ? f[1] : nil)
            return
        }
        if name == "updatestate" {
            let readiness = Updater.shared.readiness
            let state: [String: Any] = ["menu": Updater.shared.menuTitle, "staged": readiness.staged?.version ?? "", "card": readiness.showsCard, "state": Updater.shared.cardState.map { "\($0)" } ?? "", "floats": Updater.shared.cardFloats, "offered": Updater.shared.offer.available?.version ?? "",
                                        "shown": !controller.sidebar.updateCard.isHidden, "frame": NSStringFromRect(controller.sidebar.updateCard.frame)]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
            return
        }
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
        // Each command is a step of its own for ⌘Z, as a click or a key is: AppKit closes the undo manager's group
        // once an event has been handled, and with no event between them one command's group would take in the
        // next's, so ⌘Z would take back both. An event of our own after it closes it.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
        switch name {
        case "open": if let url = URL(string: arg) { controller.open(url, disposition: .foregroundTab, allowSwitch: false) }
        case "bg": if let url = URL(string: arg) { controller.open(url, disposition: .backgroundTab, allowSwitch: false) }
        // pdf in|out|actual|dark|twoup|sidebar|page <n>|find <text>: the PDF viewer's own controls, on the tab in front.
        case "pdf": controller.selectedTab?.pdfViewer?.debug(arg)
        // child <url>: a link opened in a background tab from the tab you're on, as ⌘-click does.
        case "child": if let url = URL(string: arg), let tab = controller.tabManager.selectedTab { controller.tab(tab, openURL: url, disposition: .backgroundTab) }
        // nest on|off: Settings › Tabs › Open ⌘-clicked links under their tab.
        case "nest": TabManager.nestsOpenedLinks = arg == "on"
        // sharetabs on|off: Windows share a space's tabs (#162).
        case "sharetabs": TabStore.windowsShareTabs = arg == "on"
        // showhere: Show Here for a tab another window shows (#162).
        case "showhere": if let tab = controller.tabManager.selectedTab { controller.showHere(tab) }
        // foldtab <index>: folds or shows the tabs nested under the tab at that place in the space's list.
        case "foldtab":
            let tabs = controller.tabManager.currentTabs
            if let i = Int(arg), tabs.indices.contains(i) { controller.tabManager.setNestedTabsCollapsed(tabs[i], !tabs[i].isCollapsed) }
        // grouptabs <i,j,…>: groups the tabs at those indexes (#209).
        case "grouptabs":
            let tabs = controller.tabManager.currentTabs
            controller.groupWithUndo(arg.split(separator: ",").compactMap { Int($0) }.filter(tabs.indices.contains).map { tabs[$0] })
        // groupfold <n>: toggles the nth group.
        case "groupfold":
            let groups = controller.tabManager.groups(in: controller.tabManager.currentSpaceID)
            if let i = Int(arg), groups.indices.contains(i) { controller.listSetGroupOpen(groups[i].id, !groups[i].isOpen) }
        // groupmenu <n> <title>: runs that item of the nth group's menu.
        case "groupmenu":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let groups = controller.tabManager.groups(in: controller.tabManager.currentSpaceID)
            guard f.count == 2, let i = Int(f[0]), groups.indices.contains(i) else { break }
            let menu = SidebarMenus.groupMenu(for: groups[i], controller: controller)
            if case let index = menu.indexOfItem(withTitle: f[1]), index >= 0 { menu.performActionForItem(at: index) }
        // groups <path>: the space's groups with name, open state and tabs.
        case "groups":
            let m = controller.tabManager
            let json: [[String: Any]] = m.groups(in: m.currentSpaceID).map { group in
                ["name": group.name, "open": group.isOpen, "tabs": m.tabs(inGroup: group.id).map(\.displayTitle)]
            }
            if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: URL(fileURLWithPath: arg)) }
        // tree <path>: the current space's tabs, each with how deep it's nested and whether it's folded.
        case "tree":
            let m = controller.tabManager
            let levels = TabTree.levels(m.treeNodes(in: m.currentSpaceID))
            let out = m.currentTabs.map { "\(String(repeating: "  ", count: levels[$0.id] ?? 0))\($0.displayTitle)\($0.isCollapsed ? " (folded)" : "")" }
            try? out.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        // pinfold on|off: folds or opens the current space's pinned section, kept in memory only.
        case "pinfold":
            if SidebarListView.debugCollapsed == nil { SidebarListView.debugCollapsed = [] }
            SidebarListView.setCollapsed(controller.tabManager.currentSpaceID, arg == "on")
            controller.tabManager.forgetClosedPins()
            controller.sidebar.list.reload(animated: false)
        case "load": if let url = URL(string: arg) { controller.open(url, disposition: .currentTab) }
        case "sidebar": controller.toggleBrowserSidebar(nil)
        // newtabnote <path>: each new tab row out from the hidden sidebar (frame in window points, top left, and title),
        // then the selected tab.
        case "newtabnote":
            let rows = controller.newTabNote.debugPeeks.map { "\(NSStringFromRect($0.0)) \($0.1)" }
            try? (rows + [controller.tabManager.selectedTab?.displayTitle ?? "-"]).joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        // newtabclick <i>: clicks the i-th of those rows.
        case "newtabclick": controller.newTabNote.debugClick(Int(arg) ?? 0)
        // topbar off|autohide|always|on: Settings › Appearance › Address bar above the page.
        case "topbar":
            switch arg {
            case "on", "always": BrowserRootView.addressBarPlace = .always
            case "autohide": BrowserRootView.addressBarPlace = .autohide
            default: BrowserRootView.addressBarPlace = .off
            }
        // sidebarside right|left: Settings › Appearance › Sidebar position.
        case "sidebarside": BrowserRootView.sidebarOnRight = arg == "right"
        // sideframes: where the sidebar, the page and the traffic lights are, in the debug log.
        case "sideframes":
            let r = controller.root, close = controller.window?.standardWindowButton(.closeButton)
            debugLog("sideframes right=\(r.sidebarOnRight) sidebar=\(r.sidebarContainer.frame) card=\(r.cardFrame) bar=\(r.showsTopBar ? r.topBarFrame : .zero) "
                     + "lights=\(close.map { $0.convert($0.bounds, to: nil) } ?? .zero) hidden=\(close?.isHidden ?? true)")
        case "reveal": controller.root.holdReveal = arg == "hold"; controller.root.reveal(true)
        case "unreveal": controller.root.holdReveal = false; controller.root.reveal(false)
        // edgepointer <x> <y>|off: the pointer counts as there for the sidebar's edge (top-down, left of the window
        // is negative), wherever the real one is. edgestate: whether the sidebar is out, in the debug log.
        case "edgepointer":
            let f = arg.split(separator: " ").compactMap { Double($0) }
            controller.root.debugEdgePointer(f.count == 2 ? NSPoint(x: f[0], y: f[1]) : nil)
        // touchpull <x> <dx> | end <velocity>: a finger landing x in from the edge pulls the hidden sidebar dx out,
        // held there; end lets go.
        case "touchpull":
            let f = arg.split(separator: " ")
            if f.first == "end" {
                controller.root.touchPullEnded(velocity: f.count > 1 ? Double(f[1]).map { CGFloat($0) } ?? 0 : 0, cancelled: false)
            } else if f.count == 2, let x = Double(f[0]), let dx = Double(f[1]) {
                controller.root.touchPullBegan(.pull, base: x)
                controller.root.touchPullMoved(by: dx)
            }
        // touchrecent: as if a finger had just landed in the window, so the touch grabber shows.
        case "touchrecent": controller.root.debugTouchedRecently()
        // touchreveal: as if a finger had tapped where the hidden lights and sidebar toggle sit, so they show.
        case "touchreveal": controller.root.debugRevealTap()
        // touchrowmenu <title>: a finger held on that tab's row until its menu opens, then lifted off it, so it
        // stays open; it closes by itself after 6 s.
        case "touchrowmenu":
            guard let tab = controller.tabManager.currentTabs.first(where: { $0.displayTitle == arg }),
                  let row = controller.sidebar.list.tabRow(tab.id) as? InteractiveView else { break }
            let point = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
            guard let hold = row.beginTouchHold(at: point) else { break }
            hold.showMenu()
            hold.lifted(at: point)
            closeNextMenu(after: 6)
            debugLog("touchrowmenu \(arg) => \(MenuPanel.current?.debugState ?? [:])")
        // touchtarget <x> <y>: where a finger's click at that window point (bottom-up) lands, in the debug log.
        case "touchtarget":
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count == 2, let window = controller.window else { break }
            let point = NSPoint(x: f[0], y: f[1])
            let to = TouchTargets.point(for: point, in: window)
            let hit = to.flatMap { TouchTargets.hit(at: $0, in: window) }
            let under = sequence(first: TouchTargets.hit(at: point, in: window), next: { $0?.superview }).prefix(6).compactMap { $0.map { String(describing: type(of: $0)) } }
            debugLog("touchtarget under \(Int(point.x)),\(Int(point.y)): \(under.joined(separator: " < "))")
            debugLog("touchtarget \(Int(point.x)),\(Int(point.y)) => \(to.map { "\(Int($0.x)),\(Int($0.y)) \(hit.map { String(describing: type(of: $0)) } ?? "") \(hit?.toolTip ?? "")" } ?? "none")")
        // edgefollow: one look at the pointer for the floating sidebar, as its timer takes (none runs in a covered window).
        case "edgefollow": controller.root.followPointer()
        case "edgestate": debugLog("edgestate \(controller.root.isSidebarFloatingVisible ? "out" : controller.root.sidebarVisible ? "docked" : "hidden")")
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
            // lights tree: the title bar's view tree and what draws its background.
            if arg == "tree", let top = b?.superview?.superview {
                func dump(_ view: NSView, _ depth: Int) {
                    debugLog(String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) window=\(view.window.map { "\(type(of: $0))" } ?? "-")")
                    view.subviews.forEach { dump($0, depth + 1) }
                }
                dump(top, 0)
                debugLog("lights transparent=\(w?.titlebarAppearsTransparent ?? false) fullScreen=\(w?.styleMask.contains(.fullScreen) ?? false)")
            }
        case "commandbar":
            // Typing into an open bar only types, as the keyboard would.
            if !controller.commandBar.isVisible { controller.commandBar.show(mode: .newTab) }
            if !arg.isEmpty { controller.commandBar.debugType(arg) }
        // enter [cmd] [shift] [opt]: Return in the bar, with those keys held.
        case "enter":
            let words = Set(arg.split(separator: " ").map(String.init))
            var keys: NSEvent.ModifierFlags = []
            if words.contains("cmd") { keys.insert(.command) }
            if words.contains("shift") { keys.insert(.shift) }
            if words.contains("opt") { keys.insert(.option) }
            controller.commandBar.debugEnter(keys)
        case "barrows":
            if let data = try? JSONSerialization.data(withJSONObject: controller.commandBar.debugState, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }
        case "baresc": controller.commandBar.debugEscape()
        case "barback": controller.commandBar.debugBackspace()
        case "edit": controller.commandBar.show(mode: .editCurrent); if !arg.isEmpty { controller.commandBar.debugType(arg) }
        case "dismissbar": controller.commandBar.dismiss()
        // bardrag <dx> <dy> [hold]: drags the open bar by its edge (hold: keeps the guides); barreset: double-clicks
        // its edge; barframe: logs its frame.
        case "bardrag":
            let f = arg.split(separator: " ")
            let n = f.prefix(2).compactMap { Double($0) }
            if n.count == 2 { controller.commandBar.debugDrag(n[0], n[1], ending: f.dropFirst(2).first != "hold") }
        case "barreset": controller.commandBar.debugResetPosition()
        case "barframe": debugLog("barframe \(NSStringFromRect(controller.commandBar.debugPanelFrame)) overlay=\(NSStringFromRect(controller.root.overlay.bounds)) page=\(NSStringFromRect(controller.root.cardFrame))")
        case "permprompt":
            // permprompt app [mini] [name]: the open-an-app question for a made-up app; never opens anything.
            if arg == "app" || arg.hasPrefix("app ") {
                var words = arg.split(separator: " ").dropFirst().map(String.init)
                let inMini = words.first == "mini"
                if inMini { words.removeFirst(); MiniWindowController.debugPromptsShow = true }
                let host: PromptHost = inMini ? (MiniWindowController.all.last ?? controller) : controller
                let tab = host.promptFrontTab
                let origin = SiteOrigin.of(tab?.url) ?? "https://example.com"
                let name = words.isEmpty ? "Lantern" : words.joined(separator: " ")
                Task {
                    let answer = await ExternalLinks.ask(app: name, icon: NSWorkspace.shared.icon(for: .applicationBundle), origin: origin,
                                                         answerKey: "\(origin)|x-lantern", in: host, tab: tab, canRemember: tab?.isPrivate != true)
                    debugLog("permprompt app: \(answer.map { "\($0.action) remember=\($0.remember)" } ?? "put off")")
                }
            } else {
                Task { _ = await PermissionPrompt.ask(host: "meet.google.com", what: "your camera", symbol: "video.fill", in: controller) }
            }
        // permremember on|off [mini], permkey <keyCode> [focused] [mini], permframes [mini], permmenu [mini]: the
        // showing question (permmenu opens its answering split's menu).
        case "permremember", "permkey", "permframes", "permmenu":
            let words = arg.split(separator: " ").map(String.init)
            let host: PromptHost = words.contains("mini") ? (MiniWindowController.all.last ?? controller) : controller
            if name == "permremember" { PermissionPrompt.debugRemember(words.first == "on", in: host) }
            if name == "permkey", let code = words.first.flatMap(UInt16.init) {
                PermissionPrompt.debugKey(code, focused: words.contains("focused"), in: host)
            }
            if name == "permframes" { debugLog("permframes \(PermissionPrompt.debugFrames(in: host).sorted { $0.key < $1.key })") }
            if name == "permmenu" { PermissionPrompt.debugOpenAnswerMenu(in: host) }
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
                // Sidebar rows draw their menu from `onRightClick` and give AppKit none.
                if let menu = ((v as? InteractiveView)?.drawsMenu == true ? (v as? InteractiveView)?.onRightClick?(event) : v.menu(for: event)) {
                    answered = "\(type(of: v))"; items = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }; break
                }
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
        // ownprofile on|off: Give new spaces their own profile (#291).
        case "ownprofile": Library.newSpacesGetOwnProfile = arg == "on"
        case "editspace": SpaceEditorPanel.toggle(spaceID: controller.tabManager.currentSpaceID, in: controller)
        case "closeeditor": SpaceEditorPanel.current?.close()
        case "canceleditor": SpaceEditorPanel.current?.cancel()
        // editornewprofile: the space editor's New Profile, as its menu item does. editorname <name>: types that name.
        case "editornewprofile": SpaceEditorPanel.current?.debugNewProfile()
        case "editorname": SpaceEditorPanel.current?.debugType(arg)
        // editorbackground <path>: picks that background file; with no path, removes it.
        case "editorbackground":
            if arg.isEmpty { SpaceEditorPanel.current?.debugRemoveBackground() } else { SpaceEditorPanel.current?.debugSetBackground(URL(fileURLWithPath: arg)) }
        // editorcustom: toggles the Custom swatch's wheel and Shade.
        case "editorcustom": SpaceEditorPanel.current?.debugToggleCustom()
        // editorcustomclick: a click on the Custom swatch.
        case "editorcustomclick": SpaceEditorPanel.current?.debugClickCustom()
        // editoreffects, editorsecond: Effects opened or folded, a second color added or removed.
        case "editoreffects": SpaceEditorPanel.current?.debugToggleEffects()
        case "editorsecond": SpaceEditorPanel.current?.debugToggleSecondColor()
        // editordrag <knob> <hue> <amount>: that wheel knob pressed and dragged to the spot (0...1 each).
        case "editordrag":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 3 { SpaceEditorPanel.current?.debugDrag(Int(n[0]), to: ColorWheel.Spot(hue: n[1], amount: n[2])) }
        // editorprobe: the panel's place and what a press on each knob lands on, logged.
        case "editorprobe": debugLog("editorprobe \(SpaceEditorPanel.current?.debugProbe() ?? "closed")")
        // editfrom header|dot|dotclick|blank|plus|menubar: opens the editor the way that place does.
        case "editfrom":
            let id = controller.tabManager.currentSpaceID
            let edit = String(localized: "Edit Space…", comment: "Item in a space's context menu.")
            func perform(_ menu: NSMenu?, _ title: String) {
                if let menu, case let index = menu.indexOfItem(withTitle: title), index >= 0 { menu.performActionForItem(at: index) }
            }
            switch arg {
            case "header": perform(controller.listMenu(for: .header), edit)
            case "dot": perform(controller.sidebarSpaceMenu(for: id), edit)
            case "dotclick": controller.sidebar.onEditSpace?(id)
            case "blank", "plus":
                let entries = arg == "blank" ? SidebarMenus.blankPanel(controller: controller) : SidebarMenus.addPanel(controller: controller)
                let title = arg == "blank" ? edit : String(localized: "New Space", comment: "Item in the menu of the sidebar's + and its empty space: adds a space and opens it to be named.")
                for case .item(let item) in entries where item.title == title { item.action() }
            case "menubar":
                func find(_ menu: NSMenu) -> NSMenuItem? {
                    for item in menu.items {
                        if let sub = item.submenu, let found = find(sub) { return found }
                        if item.title == edit { return item }
                    }
                    return nil
                }
                if let item = NSApp.mainMenu.flatMap(find), let action = item.action, let window = controller.window { _ = (window.firstResponder ?? window).tryToPerform(action, with: item) }
            default: break
            }
        case "tourskip": Tutorial.skip()
        case "tourend": Tutorial.isHidden = true; controller.root.overlay.subviews.compactMap { $0 as? GuidedTour }.forEach { $0.removeFromSuperview() }
        case "fullscreen": controller.window?.toggleFullScreen(nil)
        case "settingsspaceedit":
            func rows(_ v: NSView) -> [SpaceSettingsRow] { (v as? SpaceSettingsRow).map { [$0] } ?? v.subviews.flatMap(rows) }
            if let root = controller.tabManager.selectedTab?.settingsView { rows(root).first?.openEditor() }
        case "saveprompt": if arg == "close" { SavePasswordPrompt.debugClose() } else { SavePasswordPrompt.debugPreview(in: controller) }
        case "select": controller.tabManager.select(at: Int(arg) ?? 0)
        // lightswatch <seconds> <path>: logs traffic light positions per frame and every AppKit move
        // (`TrafficLightWatch`).
        case "lightswatch":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if f.count == 2, let seconds = Double(f[0]), let window = controller.window {
                TrafficLightWatch.start(seconds: seconds, path: f[1], window: window)
            }
        // retile <count> <interval>: forces title bar relayouts by changing the subtitle.
        case "retile":
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count == 2, let window = controller.window else { break }
            for i in 0..<Int(f[0]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * f[1]) {
                    MainActor.assumeIsolated { window.subtitle = i % 2 == 0 ? " " : "" }
                }
            }
        // selectloop <count> <interval>: cycles through the first four tabs.
        case "selectloop":
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count == 2 else { break }
            for i in 0..<Int(f[0]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * f[1]) {
                    MainActor.assumeIsolated { controller.tabManager.select(at: i % max(1, min(controller.tabManager.currentTabs.count, 4))) }
                }
            }
        // groundprobe select <index> | load <url> | open <url>: does that, then for 1.5 s writes to the debug log what's
        // behind the page in front every 50 ms (#134): the web view's own ground, its under-page color, the card's, and
        // what the page script has put in (Dark Reader's mode, the prepaint ground, darkened).
        case "groundprobe":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2 else { break }
            switch f[0] {
            case "select": controller.tabManager.select(at: Int(f[1]) ?? 0)
            case "load": if let url = URL(string: f[1]) { controller.open(url, disposition: .currentTab) }
            case "open": if let url = URL(string: f[1]) { controller.open(url, disposition: .foregroundTab, allowSwitch: false) }
            default: break
            }
            let start = Date()
            func hex(_ c: NSColor?) -> String {
                guard let c = c?.usingColorSpace(.sRGB) else { return "nil" }
                return String(format: "#%02x%02x%02x/%.2f", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), c.alphaComponent)
            }
            for i in 0...30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                    MainActor.assumeIsolated {
                        let tab = controller.tabManager.selectedTab
                        guard let webView = tab?.webView else { debugLog("groundprobe \(i) no web view"); return }
                        let own = webView.responds(to: NSSelectorFromString("_backgroundColor")) ? webView.value(forKey: "_backgroundColor") as? NSColor : nil
                        let layer = webView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
                        let native = String(format: "t=%.3f own=%@ layer=%@ under=%@ page=%@ url=%@ loading=%d", Date().timeIntervalSince(start),
                                            hex(own), hex(layer), hex(webView.underPageBackgroundColor), hex(tab?.pageColor),
                                            webView.url?.absoluteString ?? "nil", webView.isLoading ? 1 : 0)
                        webView.callAsyncJavaScript("""
                            const p = document.querySelector('style[data-zigzag-dark=prepaint]');
                            return JSON.stringify({ ready: document.readyState, darkreader: document.documentElement && document.documentElement.getAttribute('data-darkreader-mode'),
                              fallback: !!document.querySelector('.darkreader--fallback'), prepaint: !!p,
                              prefersDark: matchMedia('(prefers-color-scheme: dark)').matches, mode: document.documentElement && document.documentElement.getAttribute('data-color-mode'),
                              darkened: window.__zigzagDark ? window.__zigzagDark.state().darkened : null });
                            """, arguments: [:], in: nil, in: DarkPages.world) { result in
                            debugLog("groundprobe \(i) \(native) js=\((try? result.get()).map { "\($0)" } ?? "none")")
                        }
                    }
                }
            }
        // suspendtab [energy] <url prefix>: puts that tab to sleep, with "energy" as EnergyWatch does.
        case "suspendtab":
            let energy = arg.hasPrefix("energy ")
            let prefix = energy ? String(arg.dropFirst(7)) : arg
            controller.tabManager.allTabs.first { $0.url?.absoluteString.hasPrefix(prefix) == true }?.suspend(because: energy ? EnergyWatch.sleepReason : "debug")
        // networkprocess: the process id of WebKit's network process for the shown tab's store, in the debug log.
        case "networkprocess":
            let store = controller.tabManager.selectedTab?.webView?.configuration.websiteDataStore
            debugLog("networkprocess \(store.map(NetworkProcessCookies.process) ?? 0)")
        // iconpicker <index>: the Change Icon… grid beside the tab at that sidebar position, as its menu item opens it.
        case "iconpicker":
            let list = controller.tabManager.navigableTabs
            if let n = Int(arg), list.indices.contains(n) { controller.chooseIcon(for: list[n]) }
        // iconsearch [text]: puts text in the open icon grid's field, as if typed (#163). iconreturn, iconesc: those keys.
        case "iconsearch": IconPickerPanel.current?.grid.type(arg)
        case "iconreturn": IconPickerPanel.current?.grid.pickFirstResult()
        case "iconesc": IconPickerPanel.current?.grid.endSearch()
        // iconclose: closes the icon grid.
        case "iconclose": IconPickerPanel.current?.close()
        // pageicon <index> <icon|none>: gives the tab at that sidebar position an icon of its own, as Change Icon… does.
        case "pageicon":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let list = controller.tabManager.navigableTabs
            if let n = f.first.flatMap({ Int($0) }), list.indices.contains(n) {
                let icon = f.count > 1 && f[1] != "none" ? f[1] : nil
                if let id = list[n].bookmarkID { Library.shared.setIcon(icon, forBookmark: id) } else { list[n].customIcon = icon }
            }
        // pageiconfile <index> <path>: Choose Image… for the tab at that sidebar index.
        case "pageiconfile":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let list = controller.tabManager.navigableTabs
            if f.count == 2, let n = Int(f[0]), list.indices.contains(n) {
                let tab = list[n]
                controller.usePageImage(URL(fileURLWithPath: f[1])) { icon in
                    if let id = tab.bookmarkID { controller.setIconWithUndo(icon, forBookmark: id) } else { controller.setIconWithUndo(icon, for: tab) }
                }
            }
        // siteicon <icon|none>: sets the front tab's site icon (#310; private windows only for themselves).
        // siteiconfile <path>: its Choose Image….
        case "siteicon", "siteiconfile":
            guard let tab = controller.tabManager.selectedTab, let site = SiteIcons.site(of: tab.url) else { break }
            let store = controller.tabManager.privateStore
            if name == "siteiconfile" {
                controller.usePageImage(URL(fileURLWithPath: arg)) { SiteIcons.set($0, forSite: site, privateStore: store) }
            } else {
                SiteIcons.set(arg == "none" ? nil : arg, forSite: site, privateStore: store)
            }
            debugLog("siteicon \(site) => \(SiteIcons.icon(forSite: site, privateStore: store) ?? "-") kept=\(SiteIcons.all)")
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
        // route <site> <space name|any>: routes the site to a space (#286). routes: logs routes and every window's
        // spaces and tabs.
        case "route":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard let text = f.first else { break }
            let match = SiteRoutes.suggestedMatch(for: text)
            guard let site = SiteRoutes.entry(from: text, match: match) else { break }
            let existing = Library.shared.siteRoutes.first { $0.site == site && $0.match == match }
            let name = f.count > 1 ? f[1] : "any"
            if let space = Library.shared.spaces.first(where: { $0.name == name }) {
                Library.shared.saveRoute(.init(id: existing?.id ?? UUID(), match: match, site: site, spaceID: space.id))
            } else if name == "any", let existing { Library.shared.removeRoute(existing.id) }
        // sendclick x y [cmd]: a click handed straight to the window (window points, top-left origin), for a copy that
        // stays behind the app you're using, where posted events don't reach the page.
        case "sendclick":
            let f = arg.split(separator: " ").map(String.init)
            guard f.count >= 2, let x = Double(f[0]), let y = Double(f[1]), let window = controller.window else { break }
            let point = NSPoint(x: x, y: window.frame.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: f.contains("cmd") ? [.command] : [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
        // linkroute <url> [new|bg] [signin]: routes a link click as Tab does (plain, ⌘⇧ or ⌘), else loads it.
        case "linkroute":
            let f = arg.split(separator: " ").map(String.init)
            guard let url = f.first.flatMap(URL.init(string:)), let tab = controller.tabManager.selectedTab else { break }
            let newTab = f.contains("new") || f.contains("bg")
            if !controller.tab(tab, routesLink: url, arrival: newTab ? .linkNewTab : .linkClick, inBackground: f.contains("bg")) {
                if newTab { controller.tab(tab, openURL: url, disposition: f.contains("bg") ? .backgroundTab : .foregroundTab) } else { tab.load(url, by: .page) }
            }
        // routehelp: presses the last match-type help button in the window (Settings › Spaces, a rule's sheet).
        case "routehelp":
            func buttons(in view: NSView) -> [IconButton] { [view as? IconButton].compactMap { $0 } + view.subviews.flatMap(buttons) }
            _ = controller.window?.contentView.map(buttons)?.last { $0.accessibilityLabel() == String(localized: "About Match Types", comment: "Button opening space rule help.") }?.accessibilityPerformPress()
        case "routes":
            let list = Library.shared.siteRoutes.map { "\($0.site)→\(Library.shared.space($0.spaceID)?.name ?? "?")" }
            let tabs = controller.tabManager.allTabs.map { "\(Library.shared.space($0.spaceID)?.name ?? "?"):\($0.url?.absoluteString ?? "-")" }
            debugLog("routes [\(list.joined(separator: ", "))] shown=\(controller.tabManager.currentSpace.name) tabs=\(tabs)")
        case "spacehue": if let degrees = Double(arg) { Library.shared.setHue(degrees / 360, for: controller.tabManager.currentSpaceID) }
        case "spacedefaults":
            if let panel = SpaceEditorPanel.current { panel.useDefaultColors() } else { Library.shared.useDefaultColors(forSpace: controller.tabManager.currentSpaceID) }
        case "bookmark": if let tab = controller.tabManager.selectedTab { controller.tabManager.bookmarkTab(tab) }
        case "hover": controller.debugHover(index: Int(arg) ?? 0)
        case "desk": controller.toggleDeskView(nil)
        case "deskkey": controller.desk.debugKey(arg)
        case "private": WindowManager.shared.newWindow(url: URL(string: arg), showCommandBar: false, isPrivate: true)
        case "pageshot": if let webView = controller.selectedWebView { PageScreenshot.debugCapture(webView, to: URL(fileURLWithPath: arg)) }
        case "capture": runCapture(arg, in: controller)
        case "reader": controller.toggleReader()
        case "translate": controller.translatePage()
        // translatemenu: the address bar's translate button, as a click. translateoptions: the offer's … button.
        // translatestub: the page marked translated, without Apple's translation.
        case "translatemenu": controller.showTranslateMenu()
        case "translateoptions":
            let toast = controller.root.overlay.subviews.compactMap { $0 as? ToastView }.last
            toast?.optionsButton.onClick?(NSEvent())
        case "translatestub": controller.debugMarkTranslated()
        case "translatesettings": SettingsPage.open(.translation, in: controller)
        case "split":
            // Splits the shown tab with the one at this sidebar position.
            let list = controller.tabManager.navigableTabs
            if let tab = controller.tabManager.selectedTab, let n = Int(arg), list.indices.contains(n), list[n] !== tab {
                controller.tabManager.makeSplit(tab, with: list[n])
            }
        case "tile":
            // tile <n> <region>: the tab at this sidebar position into the shown page's split or tile group, where a
            // drop on that region of the page puts it (#160): left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight.
            let parts = arg.split(separator: " ").map(String.init)
            let list = controller.tabManager.navigableTabs
            if parts.count == 2, let n = Int(parts[0]), list.indices.contains(n), let region = TileRegion(rawValue: parts[1]),
               let current = controller.tabManager.selectedTab, list[n] !== current,
               let placed = TileShape.placing(region, beside: controller.tabManager.split(for: current)?.shape.regions ?? []) {
                controller.tabManager.tile(list[n], beside: current, .place(region: region, regions: placed))
            }
        case "tilehint":
            // tilehint <x> <y> [n]: the hint a tab dragged to that point of the page (shares of its width and height) shows;
            // tilehint alone puts it away.
            let parts = arg.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 2, let current = controller.tabManager.selectedTab {
                // A third number: the tab at that sidebar position is the one carried, named in the hint.
                let list = controller.tabManager.navigableTabs
                controller.root.splitDropHint.incoming = parts.count == 3 && list.indices.contains(Int(parts[2]))
                    ? controller.carried(.tab(list[Int(parts[2])].id)) : nil
                let area = controller.root.cardFrame
                let point = NSPoint(x: area.minX + area.width * parts[0], y: area.minY + area.height * parts[1])
                controller.showDropHint(at: controller.root.convert(point, to: nil), beside: current)
            } else {
                controller.root.splitDropHint.show(nil)
            }
        case "panedrag":
            // panedrag <pane> <x> <y>: the group's pane at that index picked up by its strip and carried to that point
            // (shares of the page area's width and height; below 0 is the sidebar), as a drag would (#160). Again moves
            // it on; panedrag alone calls it off (Esc), panedrop [opt] lets go (opt: with ⌥ held).
            let parts = arg.split(separator: " ").compactMap { Double($0) }
            guard parts.count == 3, let window = controller.window, let current = controller.tabManager.selectedTab,
                  let pair = controller.tabManager.split(for: current), pair.ids.indices.contains(Int(parts[0])),
                  let tab = controller.tabManager.tab(with: pair.ids[Int(parts[0])]) else {
                debugLog("panedrag \(arg): no pane (selected \(controller.tabManager.selectedTab?.title ?? "none"))")
                debugPaneDrag?.cancel()
                debugPaneDrag = nil
                debugPaneDragPoint = nil
                break
            }
            let area = controller.root.cardFrame
            let point = window.convertPoint(toScreen: controller.root.convert(NSPoint(x: area.minX + area.width * parts[1], y: area.minY + area.height * parts[2]), to: nil))
            if debugPaneDrag?.tab !== tab {
                debugPaneDrag?.cancel()
                let card = controller.root.paneCards[Int(parts[0])]
                debugPaneDrag = PaneDrag(controller: controller, tab: tab, card: card, at: window.convertPoint(toScreen: card.header.convert(NSPoint(x: card.header.bounds.midX, y: card.header.bounds.midY), to: nil)))
                debugPaneDrag?.lift()
            }
            debugPaneDrag?.moved(to: point)
            debugPaneDragPoint = point
            debugLog("panedrag \(arg) => \(String(describing: debugPaneDrag?.target)) at \(point)")
        case "rowdrop", "rowjoin":
            // rowdrop <carried>|<target>|<left|right>: the row titled <carried> resting on the middle of <target>'s row
            // (a tab's or a pinned page's), the offer it shows; rowdrop alone puts it away. rowjoin: that drop, undoably.
            let f = arg.components(separatedBy: "|")
            func item(_ title: String) -> SidebarItem? {
                if let tab = controller.tabManager.currentTabs.first(where: { $0.displayTitle.contains(title) }) { return .tab(tab.id) }
                return Library.shared.bookmarks(in: controller.tabManager.currentSpaceID).first { $0.title.contains(title) }.map { .bookmark(SidebarListView.rowID($0.id)) }
            }
            let carried = f.count == 3 ? item(f[0]) : nil, target = f.count == 3 ? item(f[1]) : nil
            if name == "rowjoin" {
                if case .tab(let id)? = carried, let tab = controller.tabManager.tab(with: id), case .tab(let t)? = target, let other = controller.tabManager.tab(with: t), controller.tabManager.split(for: other) != nil {
                    controller.listJoinSplit(.tab(tab.id), onto: .tab(other.id), onRight: f[2] == "right")
                } else if let carried, case .bookmark(let t)? = target {
                    let page: TabManager.RowPage? = switch carried { case .tab(let id): .tab(id); case .bookmark(let id): .pinned(id); default: nil }
                    if let page { controller.listJoinSplit(page, onto: .pinned(t), onRight: f[2] == "right") }
                }
                controller.sidebar.list.debugOfferSplit(nil, onto: nil, onRight: false)
                debugLog("rowjoin \(arg) done")
            } else {
                debugLog("rowdrop \(arg) offered=\(controller.sidebar.list.debugOfferSplit(carried, onto: target, onRight: f.count == 3 && f[2] == "right"))")
            }
        case "rowhover":
            // rowhover <n>: the row of the tab at this place in the list as if the pointer were over it; off: none.
            let tabs = controller.tabManager.currentTabs
            for tab in tabs { (controller.sidebar.list.row(for: tab) as? SidebarRowView)?.isHovered = false }
            if let n = Int(arg), tabs.indices.contains(n) { (controller.sidebar.list.row(for: tabs[n]) as? SidebarRowView)?.isHovered = true }
        case "groupnamed":
            // groupnamed <word>|<word>|...: the tabs whose titles have these words, side by side as a split (two), a
            // half and two quarters (three) or a grid (four).
            let words = arg.components(separatedBy: "|")
            let tabs = words.compactMap { word in controller.tabManager.currentTabs.first { $0.title.contains(word) } }
            let regions: [[TileRegion]] = [[.left, .right], [.left, .topRight, .bottomRight], [.topLeft, .topRight, .bottomLeft, .bottomRight]]
            if tabs.count == words.count, (2...4).contains(tabs.count) {
                controller.tabManager.makeGroup(tabs, shape: TileShape(regions: regions[tabs.count - 2]))
            }
        case "selectnamed":
            if let tab = controller.tabManager.currentTabs.first(where: { $0.title.contains(arg) }) { controller.tabManager.select(tab) }
        case "rowhovernamed":
            for tab in controller.tabManager.currentTabs { (controller.sidebar.list.row(for: tab) as? SidebarRowView)?.isHovered = false }
            if let tab = controller.tabManager.currentTabs.first(where: { $0.title.contains(arg) }) {
                (controller.sidebar.list.row(for: tab) as? SidebarRowView)?.isHovered = true
            }
        case "pinhovernamed":
            // pinhovernamed <title>: hovers the pinned row or favorite whose title starts with this; otherwise clears
            // hover.
            for case let row as SidebarRowView in controller.sidebar.list.subviews { row.isHovered = false }
            for mark in Library.shared.favorites { (controller.sidebar.favorites.tile(for: mark.id) as? InteractiveView)?.isHovered = false }
            if let mark = (Library.shared.spaces.flatMap(\.bookmarks) + Library.shared.favorites).first(where: { $0.title.hasPrefix(arg) }) {
                let view = Library.shared.isFavorite(mark.id) ? controller.sidebar.favorites.tile(for: mark.id) : controller.sidebar.list.bookmarkRow(mark.id)
                (view as? InteractiveView)?.isHovered = true
                debugLog("pinhovernamed \(arg) => \(view.map { String(describing: type(of: $0)) } ?? "none")")
            }
        case "zoompane":
            // zoompane <n>: the shown group's pane n zoomed over the rest, or put back, as ⇧-clicking its part of the
            // row does; zoompane alone puts any zoomed pane back.
            if let n = Int(arg), let current = controller.tabManager.selectedTab, let pair = controller.tabManager.split(for: current),
               pair.ids.indices.contains(n), let tab = controller.tabManager.tab(with: pair.ids[n]) {
                controller.listZoomPane(tab)
            } else {
                controller.unzoomPane()
            }
        case "moveregion":
            // moveregion: whether a press would move the window, at points across each pane's strip and elsewhere in
            // the title bar's band, from the drag region AppKit last gave the window server (which starts the move
            // before the app sees the press), in the debug log.
            guard let window = controller.window, let content = window.contentView else { break }
            let band = window.standardWindowButton(.closeButton)?.superview?.superview?.frame ?? .zero
            func probe(_ name: String, _ point: NSPoint) -> String {
                let moves = windowServerMoves(window, at: point).map { $0 ? "MOVES" : "stays" } ?? "?"
                return "\(name)(\(Int(point.x)),\(Int(point.y))\(band.contains(point) ? " band" : ""))=\(moves)"
            }
            var probes: [String] = []
            for (i, card) in controller.root.paneCards.enumerated() where card.window != nil && !card.isHiddenOrHasHiddenAncestor {
                let header = card.header
                guard !header.isHiddenOrHasHiddenAncestor, !header.isInBar else { continue }
                let r = header.convert(header.bounds, to: nil)
                probes += [probe("strip\(i).lead", NSPoint(x: r.minX + 2, y: r.midY)),
                           probe("strip\(i).mid", NSPoint(x: r.midX, y: r.maxY - 2)),
                           probe("strip\(i).trail", NSPoint(x: r.maxX - 2, y: r.midY)),
                           probe("strip\(i).line", NSPoint(x: r.midX + 7, y: r.minY + 0.5))]
                if !header.address.isHidden { let a = header.address.convert(header.address.bounds, to: nil); probes.append(probe("strip\(i).address", NSPoint(x: a.midX, y: a.midY))) }
                let b = header.back.convert(header.back.bounds, to: nil)
                probes.append(probe("strip\(i).back", NSPoint(x: b.midX, y: b.midY)))
            }
            let top = content.bounds.maxY - 3
            let side = controller.root.sidebarContainer
            if !side.isHiddenOrHasHiddenAncestor, side.frame.width > 0 {
                let s = side.convert(side.bounds, to: nil)
                probes.append(probe("sidebar.top", NSPoint(x: s.midX, y: min(s.maxY, top + 3) - 6)))
            }
            probes.append(probe("frame.topEdge", NSPoint(x: content.bounds.maxX - 40, y: content.bounds.maxY - 1)))
            debugLog("moveregion band=\(band) " + probes.joined(separator: " "))
        case "rowdump":
            // rowdump: the shown tab's row's parts, where each is and whether it shows, in the debug log.
            if let tab = controller.tabManager.selectedTab, let row = controller.sidebar.list.row(for: tab) {
                debugLog("rowdump \(row.frame) " + row.subviews.map { "\(type(of: $0)) \($0.frame) hidden=\($0.isHidden) alpha=\($0.alphaValue)" }.joined(separator: " | "))
            }
        case "rowrename":
            // rowrename <n>: the shown tab's row starts renaming the page in its part n, as a double-click there does.
            if let tab = controller.tabManager.selectedTab, let row = controller.sidebar.list.row(for: tab) as? TabRowView,
               let n = Int(arg), row.pages.indices.contains(n) {
                row.beginRename(page: row.pages[n])
            }
        case "panedrop":
            guard let drag = debugPaneDrag, let point = debugPaneDragPoint else { break }
            drag.drop(at: point, option: arg == "opt")
            debugPaneDrag = nil
        case "unsplit": controller.closeSplitView(nil)
        // splitorient: side by side to stacked or back, as the split's own button does.
        case "splitorient": controller.toggleSplitOrientation(nil)
        // swapsplit: the two pages trade places, as the strip's swap button does.
        case "swapsplit": if let tab = controller.tabManager.selectedTab { controller.tabManager.swapSplit(for: tab) }
        // panestate: the pane you're in, each pane's page and frame, the find bar's frame, and the keyboard's page.
        case "panestate":
            let m = controller.tabManager
            let ids = m.selectedTab.flatMap { m.split(for: $0) }?.ids ?? []
            let names = ids.map { m.tab(with: $0)?.displayTitle ?? "?" }
            let responder = controller.window?.firstResponder as? NSView
            let keyboard = controller.root.paneCards.firstIndex { card in responder.map { $0.isDescendant(of: card) } ?? false }
            debugLog("panestate selected=\(m.selectedTab?.displayTitle ?? "-") panes=\(names) frames=\(controller.root.tileFrames.map(NSStringFromRect)) focused=\(NSStringFromRect(controller.focusedPaneFrame)) cards=\(controller.root.paneCards.prefix(ids.count).map { ($0.webView as? BrowserWebView)?.owner?.displayTitle ?? "-" }) keyboardCard=\(keyboard.map(String.init) ?? "-") responder=\(responder.map { String(describing: type(of: $0)) } ?? "nil") find=\(controller.findBar.debugFrame)")
        case "closetab": controller.closeTab(nil)
        case "flydownload": controller.debugFlyDownload(arg.isEmpty ? "Shanghai Guide.pdf" : arg)
        case "readerjs":
            controller.debugReaderWebView?.evaluateJavaScript(arg) { result, error in
                debugLog("readerjs => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "find": controller.findBar.show(query: arg)
        case "findclose": controller.findBar.hide()
        // findnext, findprev: Return and Shift-Return. findstate <path>: bar, ticks and marks (JSON). findtick <n>:
        // clicks the nth tick.
        case "findnext": controller.findBar.next(backwards: false)
        case "findprev": controller.findBar.next(backwards: true)
        case "findstate": controller.findBar.debugState(to: arg)
        case "findtick": controller.findBar.debugPickTick(Int(arg) ?? 0)
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
        // shiftclick <url>: opens the link as a ⇧-click on the selected tab's page does, in Zigzag Mini over the window.
        case "shiftclick": if let url = URL(string: arg) { controller.open(url, disposition: .mini, opener: controller.tabManager.selectedTab, by: .page) }
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
        // darkforce on|off: the site panel's Force dark row for the page in front.
        case "darkforce": DarkPages.setForced(arg == "on", for: controller.tabManager.selectedTab?.url)
        // cookiebanners reject|leave: Settings › Privacy › Cookie banners. cookiesite on|off|follow: the site panel's
        // Cookie banners row for the page in front (without its reload). cookiestate: what was found on that page, in
        // the debug log.
        case "cookiebanners": if let mode = CookieBanners.Mode(rawValue: arg) { CookieBanners.mode = mode }
        case "cookiesite": CookieBanners.setChoice(arg == "follow" ? nil : arg == "on", for: controller.tabManager.selectedTab?.url)
        case "cookiestate":
            let url = controller.tabManager.selectedTab?.url
            let found = CookieBanners.outcome(in: controller.selectedWebView, site: CookieBanners.site(of: url) ?? "")
            debugLog("cookiestate \(url?.absoluteString ?? "") handles=\(CookieBanners.handles(url)) found=\(found.map { "\($0)" } ?? "nothing")")
        // keepawake on|off: the site panel's Keep tabs awake row for the page in front.
        case "keepawake": KeepAwake.set(arg == "on", for: controller.tabManager.selectedTab?.url)
        // fsfill screen|page: Settings › Tabs › Full screen videos fill. fssite page|screen|follow: the site panel's
        // Keep full screen in the window row for the page in front. fsesc: Esc in the window, as the key would be.
        // fsstate <path>: whether each tab of the window fills its page (JSON).
        case "fsfill": if let fill = PageFullScreen.Fill(rawValue: arg) { PageFullScreen.fill = fill }
        case "fssite": PageFullScreen.setChoice(arg == "follow" ? nil : PageFullScreen.Fill(rawValue: arg), for: controller.tabManager.selectedTab?.url)
        case "fsesc": if let tab = controller.tabManager.selectedTab { PageFullScreen.exit(tab) }
        case "fsstate":
            let rows = controller.tabManager.navigableTabs.map { ["title": $0.displayTitle, "fills": $0.isInPageFullScreen, "selected": $0 === controller.tabManager.selectedTab] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: ["tabs": rows, "fill": PageFullScreen.fill.rawValue, "windowFullScreen": controller.window?.styleMask.contains(.fullScreen) == true], options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }
        case "fsgeom":
            // fsgeom <path>: each card with a page: the card's page area, the page's holder and the page itself (window
            // points), what WebKit keeps clear at the page's edges, its full screen state and the size the page sees (JSON).
            var rows: [[String: Any]] = []
            let group = DispatchGroup()
            func rect(_ r: NSRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
            for card in controller.root.paneCards where !card.isHidden {
                guard let webView = card.webView else { continue }
                var row: [String: Any] = ["card": rect(card.convert(card.bounds, to: nil)), "page": rect(webView.convert(webView.bounds, to: nil)),
                                          "pageFrame": rect(webView.frame), "parent": webView.superview.map { "\(type(of: $0))" } ?? "none",
                                          "holderInCard": (webView as? BrowserWebView)?.owner?.pageHolder.map { $0.isDescendant(of: card) } ?? false,
                                          "fullscreen": webView.fullscreenState.rawValue, "inWindow": webView.window === controller.window,
                                          "magnification": webView.magnification,
                                          "safeArea": [webView.safeAreaInsets.top, webView.safeAreaInsets.left, webView.safeAreaInsets.bottom, webView.safeAreaInsets.right]]
                for key in ["_topContentInset", "_automaticallyAdjustsContentInsets", "_pageScale", "_viewScale"] where webView.responds(to: NSSelectorFromString(key)) {
                    row[key] = "\(webView.value(forKey: key) ?? "nil")"
                }
                if let holder = webView.superview {
                    row["holder"] = rect(holder.convert(holder.bounds, to: nil))
                    row["holderViews"] = holder.subviews.map { "\(type(of: $0)) \(rect($0.frame))" }
                }
                if #available(macOS 26.0, *) {
                    let i = webView.obscuredContentInsets
                    row["insets"] = [i.top, i.left, i.bottom, i.right]
                }
                group.enter()
                webView.evaluateJavaScript("[innerWidth, innerHeight, document.documentElement.clientWidth, document.documentElement.clientHeight, devicePixelRatio, !!document.fullscreenElement].join(' ')") { result, _ in
                    row["inner"] = result as? String ?? "?"
                    rows.append(row)
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
            }
        // developer on|off: Settings › Developer › Developer tools. devsite add|remove <site>: its list.
        // devstate: the switch, the list and which open tabs are development tabs, in the debug log.
        case "developer": DeveloperTools.isOn = arg == "on"
        // visitanyway: the certificate warning's "Visit anyway", on the tab you're in.
        case "visitanyway": controller.tabManager.selectedTab?.debugVisitAnyway()
        // devtrust on|off: Settings › Developer › Trust certificates of servers on this Mac.
        case "devtrust": DeveloperTools.trustsLocalServers = arg == "on"
        case "devsite":
            let parts = arg.split(separator: " ").map(String.init)
            if parts.count == 2, let site = DevelopmentSites.entry(from: parts[1]) {
                if parts[0] == "add" { DevelopmentSites.add(site) } else if parts[0] == "remove" { DevelopmentSites.remove(site) }
            }
        // devlook follow|light|dark and devprint on|off: the developer tools' Page Appearance and Show Print Styles for
        // the tab in front. devlook alone: what the tab chose, what's in effect and what the page itself sees.
        case "devlook", "devprint":
            guard let tab = controller.tabManager.selectedTab else { break }
            if name == "devprint", arg == "on" || arg == "off" { tab.developer.printStyles = arg == "on" }
            if name == "devlook" {
                switch arg {
                case "follow": tab.developer.appearance = .followsMac
                case "light": tab.developer.appearance = .light
                case "dark": tab.developer.appearance = .dark
                default: break
                }
            }
            let chosen = tab.developer, effect = tab.developerInEffect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let script = "[matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light', matchMedia('print').matches ? 'print' : 'screen', getComputedStyle(document.documentElement).filter].join(' ')"
                tab.webView?.evaluateJavaScript(script) { result, _ in
                    debugLog("devlook => chose=\(chosen.appearance) print=\(chosen.printStyles) effect=\(effect.appearance) print=\(effect.printStyles) view=\(tab.webView?.appearance?.name.rawValue ?? "-") media=\(tab.webView?.mediaType ?? "-") page: \(result as? String ?? "-") darkened=\(tab.darkPage?.darkened ?? false)")
                }
            }
        // devjs, devimages, devstyles, devoutline on|off, devua zigzag|iphone|ipad|chrome|firefox: the developer tools'
        // toggles for the front tab; after reload, logs the page's state.
        case "devjs", "devimages", "devstyles", "devua", "devoutline":
            guard let tab = controller.tabManager.selectedTab else { break }
            if name == "devjs", arg == "on" || arg == "off" { tab.developer.javaScriptOff = arg == "off" }
            if name == "devimages", arg == "on" || arg == "off" { tab.developer.imagesOff = arg == "off" }
            if name == "devstyles", arg == "on" || arg == "off" { tab.developer.stylesOff = arg == "off" }
            if name == "devoutline", arg == "on" || arg == "off" { tab.developer.outlines = arg == "on" }
            if name == "devua", let agent = ["zigzag": DeveloperState.UserAgent.zigzag, "iphone": .iPhone, "ipad": .iPad, "chrome": .chrome, "firefox": .firefox][arg] {
                tab.developer.userAgent = agent
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { DebugBridge.logDeveloperPage(of: tab) }
        // devpage [n]: logs the same line for the front tab or the tab at n, changing nothing.
        case "devpage":
            let tabs = controller.tabManager.currentTabs
            guard let tab = Int(arg).flatMap({ tabs.indices.contains($0) ? tabs[$0] : nil }) ?? controller.tabManager.selectedTab else { break }
            DebugBridge.logDeveloperPage(of: tab)
        // devsize <width> <height> | fill | rotate: the developer tools' Page Size for the tab in front; then the
        // page's size and its holder's, and what's docked in it, in the debug log.
        case "devsize":
            guard let tab = controller.tabManager.selectedTab else { break }
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2 { tab.developer.size = CGSize(width: n[0], height: n[1]) }
            if arg == "fill" { tab.developer.size = nil }
            if arg == "rotate" { tab.developer.size = tab.developer.rotatedSize }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                controller.root.layoutSubtreeIfNeeded()
                let holder = tab.pageHolder
                let subs = (holder?.subviews ?? []).map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: " | ")
                debugLog("devsize => chose=\(tab.developer.size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "fill") card=\(controller.root.card.pageSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "fill") holder=\(holder.map { NSStringFromRect($0.frame) } ?? "-") docked=\(holder.map { NSStringFromSize($0.dockedRoom) } ?? "-") subs: \(subs) color=\(tab.pageColor != nil) scale=\(controller.root.card.pageScale)")
            }
        // devbar on|off: Settings › Developer › Tools above the page. devbar: where the tools are, in the debug log.
        case "devbar":
            if arg == "on" || arg == "off" { DeveloperTools.showsInBar = arg == "on" }
            let card = controller.root.card
            let tools = controller.root.topBar.accessory as? DeveloperBarTools
            let on = controller.tabManager.selectedTab
            debugLog("devbar => tab=\(on?.url?.host() ?? "-") development=\(on?.isDevelopment ?? false) errors=\(on?.pageErrorCount ?? 0) shows=\(tools != nil) frame=\(tools.map { NSStringFromRect($0.frame) } ?? "-") buttons=\(tools?.shown ?? 0) page=\(card.webView?.superview.map { NSStringFromRect($0.frame) } ?? "-")")
        // devphone: View › Developer › Open on Your Phone… for the tab in front, and the address it gives, in the debug log.
        case "devphone":
            controller.openOnPhone(nil)
            debugLog("devphone => lan=\(PhoneLink.lanAddress() ?? "-") url=\(controller.tabManager.selectedTab?.url.flatMap { PhoneLink.url(for: $0, lanAddress: PhoneLink.lanAddress()) }?.absoluteString ?? "-")")
        // devmode: View › Developer › Turn On (or Off) Developer Mode for This Site, toast and all.
        case "devmode": controller.toggleDevelopmentSite(nil)
        case "devstate":
            let tabs = controller.tabManager.allTabs.map { "\($0.url?.host() ?? "-"):\($0.url?.port ?? 0)=\($0.isDevelopment)" }.sorted()
            let front = controller.tabManager.selectedTab
            debugLog("devstate => on=\(DeveloperTools.isOn) sites=\(DevelopmentSites.sites) tabs=\(tabs) front=\(front?.displayTitle ?? "-") failed=\(front?.showsErrorPage ?? false)")
        // addressdrop <sidebar|pane1..4|mini> <hold|release|text>: the drop ring on that address field, or text (a link,
        // an address, words) let go on it, through the same steps a drop takes (#182).
        case "addressdrop":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2 else { break }
            let drop: AddressDrop?
            if f[0] == "sidebar" { drop = controller.sidebar.address.drop }
            else if f[0] == "mini" { drop = MiniWindowController.all.last?.debugAddressDrop }
            else if f[0].hasPrefix("pane"), let n = Int(f[0].dropFirst(4)), controller.root.paneCards.indices.contains(n - 1) { drop = controller.root.paneCards[n - 1].header.address.drop }
            else { drop = nil }
            switch f[1] {
            case "hold": drop?.debugHold(true)
            case "release": drop?.debugHold(false)
            default: debugLog("addressdrop \(f[0]) handled=\(drop?.debugDrop(f[1]) ?? false)")
            }
        case "darkstate":
            controller.selectedWebView?.callAsyncJavaScript("return window.__zigzagDark ? JSON.stringify(window.__zigzagDark.state()) : 'none'",
                                                            arguments: [:], in: nil, in: DarkPages.world) { result in
                let tab = controller.tabManager.selectedTab?.darkPage
                let color = controller.tabManager.selectedTab?.pageColor.map(DarkPages.hex) ?? "none"
                let look = controller.selectedWebView?.appearance?.name.rawValue ?? "none"
                debugLog("darkstate => \(result) tab=\(String(describing: tab)) pageColor=\(color) look=\(look)")
            }
        // lookprobe [label]: the front page's look as WebKit was asked for it and as the page sees it.
        case "lookprobe":
            guard let webView = controller.selectedWebView else { debugLog("lookprobe \(arg) no web view"); break }
            let views = "view=\(webView.appearance?.name.rawValue ?? "nil") effective=\(webView.effectiveAppearance.name.rawValue) window=\(controller.window?.effectiveAppearance.name.rawValue ?? "-") app=\(NSApp.effectiveAppearance.name.rawValue) appSet=\(NSApp.appearance?.name.rawValue ?? "nil")"
            webView.evaluateJavaScript("JSON.stringify({url: location.href, prefersDark: matchMedia('(prefers-color-scheme: dark)').matches, mode: document.documentElement.getAttribute('data-color-mode'), bg: getComputedStyle(document.body).backgroundColor})") { result, _ in
                debugLog("lookprobe \(arg) \(views) page=\(result as? String ?? "-")")
            }
        // reloadtab: the front tab loads again, as ⌘R does.
        case "reloadtab": controller.tabManager.selectedTab?.reload()
        // darkseen forget: drops the profile's sites seen dark, as clearing History does.
        case "darkseen": if arg == "forget" { DarkSeen.forget(in: controller.tabManager.profile.store) }
        case "resize":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            // resize <w> <h> [x y]: the window's size, and its place on screen (bottom left) when given.
            if n.count == 2 || n.count == 4, let window = controller.window {
                var frame = window.frame
                frame.size = NSSize(width: n[0], height: n[1])
                if n.count == 4 { frame.origin = NSPoint(x: n[2], y: n[3]) }
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
        case "chromestate": controller.sidebar.debugChromeState(arg)
        case "fakesound":
            // fakesound <tab index|selected|title word> <playing|muted|off>: the tab's speaker as if, with no sound played.
            let f = arg.split(separator: " ").map(String.init)
            let tabs = controller.tabManager.currentTabs
            let tab = f.first.flatMap(Int.init).flatMap { tabs.indices.contains($0) ? tabs[$0] : nil }
                ?? (f.first == "selected" ? controller.tabManager.selectedTab : controller.tabManager.allTabs.first { $0.title.contains(f.first ?? "-") })
            if f.count == 2, let tab { tab.debugShowSound(playing: f[1] == "playing", muted: f[1] == "muted") }
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
            func pair(_ tab: Tab) -> String { m.panes(of: tab).map(\.displayTitle).joined(separator: "|") }
            func pinned(_ ids: [UUID]) -> [String] {
                var out: [String] = [], seen = Set<UUID>()
                for id in ids where !seen.contains(id) {
                    let both = Library.shared.pinnedSplit(containing: id).map(\.ids) ?? [id]
                    both.forEach { seen.insert($0) }
                    out.append(both.compactMap { Library.shared.bookmark($0)?.title }.joined(separator: "|"))
                }
                return out
            }
            let spaces: [[String: Any]] = Library.shared.spaces.map { space in
                var seen = Set<UUID>()
                let tabs = m.tabs(in: space.id).compactMap { tab -> String? in
                    if seen.contains(tab.id) { return nil }
                    seen.insert(tab.id); m.partners(of: tab).forEach { seen.insert($0.id) }
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
        case "trackpad":
            // trackpad x y dx dy [steps]: a two-finger trackpad scroll at a point (window points, top left), its began,
            // changed and ended phases 16 ms apart, handed to the window inside the app only; dy > 0 scrolls up.
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count >= 4, let window = controller.window else { break }
            let screen = window.convertPoint(toScreen: NSPoint(x: f[0], y: window.frame.height - f[1]))
            let location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            let steps = f.count > 4 ? Int(f[4]) : 12
            let phases: [Int64] = [1] + Array(repeating: 2, count: max(1, steps)) + [4]
            for (i, phase) in phases.enumerated() {
                let dx = phase == 2 ? Int32(f[2]) : 0, dy = phase == 2 ? Int32(f[3]) : 0
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { continue }
                cg.location = location
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                cg.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds) + UInt64(i) * 16_000_000
                if let event = NSEvent(cgEvent: cg) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.016) { window.sendEvent(event) }
                }
            }
        case "pageclick":
            // pageclick x y [shift|cmd]: a left click at a point (window points, top left) handed to the window, taken
            // by a page even with the copy behind other apps. Then logs which page has the keyboard.
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count >= 2, let window = controller.window else { break }
            var flags: NSEvent.ModifierFlags = []
            if arg.contains("shift") { flags.insert(.shift) }
            if arg.contains("cmd") { flags.insert(.command) }
            BrowserWebView.takesFirstMouse = true
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: f[0], y: window.frame.height - f[1]), modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
            BrowserWebView.takesFirstMouse = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { debugLog("pageclick responder \(DebugBridge.responderName(in: controller))") }
        case "pointermove":
            // pointermove x y: a pointer move (window points, top left) given to every page tracking area under it, as
            // the window server does, then logs which pages heard it and which ignore the pointer.
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count >= 2, let window = controller.window,
                  let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: f[0], y: window.frame.height - f[1]), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { break }
            var heard: [String] = []
            func walk(_ view: NSView) {
                if let page = view as? WKWebView {
                    let moved = #selector(NSResponder.mouseMoved(with:))
                    let inside = page.visibleRect.contains(page.convert(event.locationInWindow, from: nil))
                    for area in page.trackingAreas where inside && area.options.contains(.mouseMoved) {
                        guard let owner = area.owner as? NSObject, owner.responds(to: moved) else { continue }
                        owner.perform(moved, with: event)
                        heard.append(page === controller.selectedWebView ? "tab" : "page")
                    }
                }
                view.subviews.forEach(walk)
            }
            if let frame = window.contentView?.superview { walk(frame) }
            debugLog("pointermove heard by \(heard)")
        case "responder": debugLog("responder \(responderName(in: controller))")
        case "dragpath":
            // dragpath x y1 y2: an in-app press at y1 dragged to y2 and let go (window points, top left).
            let n = arg.split(separator: " ").compactMap { Double($0) }
            guard n.count == 3, let window = controller.window else { break }
            func event(_ type: NSEvent.EventType, _ y: Double) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: n[0], y: window.frame.height - y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            }
            event(.leftMouseDown, n[1]).map(window.sendEvent)
            for step in 2...8 { event(.leftMouseDragged, n[1] + (n[2] - n[1]) * Double(step) / 8).map { NSApp.postEvent($0, atStart: false) } }
            event(.leftMouseUp, n[2]).map { NSApp.postEvent($0, atStart: false) }
            event(.leftMouseDragged, n[1] + (n[2] - n[1]) / 8).map(window.sendEvent)
            debugLog("dragpath \(arg) done")
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
        case "sidebutton":
            // sidebutton <back|forward> x y (`sendSideButton`): inside the app only, never posted to the system. How
            // long each took goes to the debug log (#170). minisidebutton and webapp sidebutton do the same there.
            if let window = controller.window { sendSideButton(arg, to: window) }
        case "downloads": controller.showDownloads(nil)
        case "dlfinished": controller.debugRevealFinished()
        case "menupanel":
            // menupanel View/Tabs: that menu of the menu bar, or a submenu of it, drawn as Zigzag draws menus near the
            // window's top, for a picture of what it holds without opening the menu bar.
            let path = arg.split(separator: "/").map(String.init)
            var menu = NSApp.mainMenu?.items.first { $0.title == path.first }?.submenu
            for name in path.dropFirst() { menu = menu?.items.first { $0.title == name }?.submenu }
            guard let menu, let host = controller.window?.contentView else { debugLog("menupanel \(arg): none"); break }
            menu.update()
            let anchor = NSView(frame: NSRect(x: 340, y: host.bounds.height - 40, width: 1, height: 1))
            host.addSubview(anchor)
            _ = MenuPanel.show(MenuPanel.entries(from: menu), from: anchor) { anchor.removeFromSuperview() }
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
        case "clearhover": debugLog("clearhover => \(controller.sidebar.list.debugClearHover(arg != "off"))")
        case "newfolder":
            // newfolder <n>: a folder holding the space's first n pinned pages.
            let ids = Library.shared.bookmarks(in: controller.tabManager.currentSpaceID).prefix(Int(arg) ?? 0).map(\.id)
            controller.newFolder(with: Array(ids))
        case "livefolder":
            // livefolder <address>: a live folder of that feed at the top of the pins, fetched now.
            if let url = LiveFolderSheet.address(from: arg),
               let made = Library.shared.addLiveFolder(named: url.host() ?? "Live", source: .feed(url), limit: 25, namedByFeed: true, in: controller.tabManager.currentSpaceID) {
                LiveFolders.shared.refreshNow(made.id)
            }
        case "livegithub":
            // livegithub <user>: a live folder of that user's pull requests at the top of the pins, fetched now.
            if let made = Library.shared.addLiveFolder(named: "Pull Requests", source: .gitHub(.pullRequests, user: arg), limit: 10, namedByFeed: false, in: controller.tabManager.currentSpaceID) {
                LiveFolders.shared.refreshNow(made.id)
            }
        case "livesheet":
            // livesheet: the New Live Folder sheet.
            controller.newLiveFolder()
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
        case "pintree":
            // pintree <base url>: pinned pages in nested folders, Work › Docs › Old, and Reading with 12 (#343).
            guard let base = URL(string: arg) else { break }
            let pages: [(String, [String])] = [("a", ["Work"]), ("b", ["Work", "Docs"]), ("c", ["Work", "Docs"]), ("d", ["Work", "Docs", "Old"]), ("e", ["Work"]), ("f", [])]
                + (1...12).map { ("r\($0)", ["Reading"]) }
            _ = Library.shared.appendBookmarks(pages.map { (base.appendingPathComponent("\($0.0).html"), $0.0.uppercased()) }, to: controller.tabManager.currentSpaceID, folders: pages.map(\.1))
        case "rowmenu":
            // rowmenu <title> | fav <title> | group <name> | marked: the right-click menu of the tab, pinned page, favorite or group with
            // that title (a split's page gets its own), or of the picked rows, at its row; it closes after 4 s.
            let list = controller.sidebar.list
            let m = controller.tabManager
            var menu: NSMenu?, anchor: NSView?
            if arg == "marked", let first = list.marked.first {
                menu = SidebarMenus.markedMenu(for: list.marked, controller: controller)
                if case .tab(let id) = first { anchor = list.tabRow(id) } else if case .bookmark(let id) = first { anchor = list.bookmarkRow(id) }
            } else if arg.hasPrefix("group "), let group = m.groups(in: m.currentSpaceID).first(where: { $0.name == String(arg.dropFirst(6)) }) {
                menu = SidebarMenus.groupMenu(for: group, controller: controller)
                anchor = list.groupRow(group.id)
            } else if arg.hasPrefix("fav "),let fav = Library.shared.favorites(in: m.profile.id).first(where: { $0.title == String(arg.dropFirst(4)) }) {
                menu = SidebarMenus.favoriteMenu(for: fav, controller: controller)
                anchor = controller.sidebar.favorites.tile(for: fav.id)
            } else if let tab = m.currentTabs.first(where: { $0.displayTitle == arg }) {
                menu = controller.listMenu(for: .tab(tab.id), page: tab) ?? SidebarMenus.tabMenu(for: tab, controller: controller)
                anchor = list.tabRow(tab.id)
            } else if let bookmark = Library.shared.bookmarks(in: m.currentSpaceID).first(where: { $0.title == arg }) {
                menu = SidebarMenus.bookmarkMenu(for: Library.shared.pinnedSplit(containing: bookmark.id).flatMap { Library.shared.bookmark($0.ids[0]) } ?? bookmark, controller: controller)
                anchor = list.bookmarkRow(Library.shared.pinnedSplit(containing: bookmark.id)?.ids[0] ?? bookmark.id)
            }
            func titles(_ menu: NSMenu) -> [String] {
                menu.items.map { $0.isSeparatorItem ? "-" : $0.title + ($0.keyEquivalent.isEmpty ? "" : " [\($0.keyEquivalent)]") + ($0.submenu.map { " ▸ " + titles($0).joined(separator: "|") } ?? "") }
            }
            debugLog("rowmenu \(arg) => \(menu.map(titles) ?? [])")
            if let menu, let anchor {
                closeNextMenu(after: 4)
                DispatchQueue.main.async { showDrawn(menu, from: anchor, at: NSPoint(x: 60, y: anchor.bounds.midY)) }
            }
        case "foldermenu":
            // foldermenu <folder>[>item]: that item of the folder's menu, as choosing it does; no item, the menu at its
            // row, which closes by itself after 4 s.
            let path = arg.split(separator: ">", maxSplits: 1).map(String.init)
            guard let folder = Library.shared.folders(in: controller.tabManager.currentSpaceID).first(where: { $0.name == path.first }) else { break }
            let menu = SidebarMenus.folderMenu(for: folder, controller: controller)
            debugLog("foldermenu \(folder.name) => \(menu.items.map { $0.isSeparatorItem ? "-" : $0.title })")
            if path.count == 2 {
                if case let index = menu.indexOfItem(withTitle: path[1]), index >= 0 { menu.performActionForItem(at: index) }
            } else if let row = controller.sidebar.list.row(forFolder: folder.id) {
                closeNextMenu(after: 4)
                DispatchQueue.main.async { showDrawn(menu, from: row, at: NSPoint(x: 60, y: row.bounds.midY)) }
            }
        case "spacemenu":
            // spacemenu [item]: that item of the right-click menu above the pinned tabs, as choosing it does; no item,
            // the menu at the space's name, which closes by itself after 4 s.
            guard let header = controller.sidebar.list.headerView as? SpaceHeaderView, let event = NSApp.currentEvent ?? NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0),
                  let menu = header.onRightClick?(event) else { break }
            debugLog("spacemenu => \(menu.items.map { $0.isSeparatorItem ? "-" : $0.title })")
            if !arg.isEmpty {
                if case let index = menu.indexOfItem(withTitle: arg), index >= 0 { menu.performActionForItem(at: index) }
            } else {
                closeNextMenu(after: 4)
                DispatchQueue.main.async { showDrawn(menu, from: header, at: NSPoint(x: 40, y: header.bounds.midY)) }
            }
        case "dotmenu":
            // dotmenu <space name>: the right-click menu of that space's icon at the bottom of the sidebar, drawn; it
            // closes by itself after 4 s.
            guard let space = Library.shared.spaces.first(where: { $0.name == arg }), let dot = controller.sidebar.dot(for: space.id),
                  let menu = controller.sidebarSpaceMenu(for: space.id) else { break }
            closeNextMenu(after: 4)
            DispatchQueue.main.async { showDrawn(menu, from: dot, at: NSPoint(x: dot.bounds.midX, y: dot.bounds.midY)) }
        case "drawnkey":
            // drawnkey up|down|left|right|return|esc: that key in the open drawn menu, as typed.
            let codes: [String: UInt16] = ["up": 126, "down": 125, "left": 123, "right": 124, "return": 36, "esc": 53]
            if let code = codes[arg] { MenuPanel.current?.debugKey(code) }
        case "drawnopen":
            // drawnopen <title>: opens that item's submenu in the open drawn menu, as hovering it does.
            MenuPanel.current?.debugOpenSubmenu(arg)
        case "drawnmenu":
            // drawnmenu <path>: the open drawn menu's titles, and its open submenus', as JSON.
            if let menu = MenuPanel.current, let data = try? JSONSerialization.data(withJSONObject: menu.debugState) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }
        case "folderstate":

            debugLog("folderstate \(Library.shared.folders(in: controller.tabManager.currentSpaceID).map { "\($0.name)=\($0.isOpen ? "open" : "shut")" }) loaded=\(Library.shared.bookmarks(in: controller.tabManager.currentSpaceID).filter { controller.tabManager.bookmarkTab(for: $0.id) != nil }.map(\.title)) selected=\(controller.tabManager.selectedTab?.displayTitle ?? "")")
        case "seedfolders": seedFolders(Int(arg) ?? 2000, in: controller)
        case "syncremove":
            // syncremove: Remove from iCloud…, in a test copy launched with --sync-with-icloud only, so a live test can
            // start from an empty zone. The zone is the dev build's own: never removed by a copy that wasn't asked to sync.
            guard ProcessInfo.processInfo.environment["ZIGZAG_DATA_DIR"] != nil else { debugLog("syncremove refused: not a test copy"); break }
            guard CommandLine.arguments.contains(DevDefaults.syncArgument) else { debugLog("syncremove refused: launched without \(DevDefaults.syncArgument)"); break }
            Task {
                let removed = await ICloudSync.shared.removeFromICloud()
                debugLog("syncremove \(removed)")
            }
        case "seedfavorites":
            // seedfavorites <n>: n blank favorites with symbol icons, into a test copy's own data only.
            guard ProcessInfo.processInfo.environment["ZIGZAG_DATA_DIR"] != nil else { debugLog("seedfavorites refused: not a test copy"); break }
            let symbols = ["star", "heart", "bolt", "leaf", "flame", "moon", "sun.max", "cloud", "book", "music.note", "camera", "gift"]
            let marks = (0..<(Int(arg) ?? 45)).compactMap { i in
                URL(string: "about:blank#fav\(i)").map { Bookmark(url: $0, title: "Favorite \(i + 1)", icon: symbols[i % symbols.count]) }
            }
            debugLog("seedfavorites => \(Library.shared.appendFavorites(marks, in: controller.tabManager.profile.id))")
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
        // nowplaying hover|off|hide|state: hovers, unhovers or closes the top Now Playing card, or logs which tabs the
        // cards show.
        case "nowplaying":
            let cards = controller.sidebar.nowPlayingCards.filter { !$0.isLeaving }
            switch arg {
            case "hover", "off": cards.first?.isHovered = arg == "hover"
            case "hide": if let tab = cards.first?.tab { controller.hideNowPlaying(tab) }
            default: debugLog("nowplaying \(cards.isEmpty ? "hidden" : cards.map { $0.tab?.displayTitle ?? "-" }.joined(separator: " | "))")
            }
        case "autofillhint":
            if let webView = controller.selectedWebView as? BrowserWebView { Autofill.shared.debugShow(arg, in: webView) }
        // autofillpreview [n]: the password menu with made-up logins over the page; with n, its highlight moves n rows.
        case "autofillpreview": Autofill.shared.debugPreview(in: controller.root.overlay, move: Int(arg) ?? 0)
        case "autofillmenu":
            debugLog("autofillmenu => \(Autofill.shared.isShowing) \(Autofill.shared.debugRows)")
        case "autofillclick":
            // autofillclick <css selector>: a click on that element of the page, sent to the window in-process.
            // autofillclick mini <css selector>: the same, in the last Zigzag Mini's page.
            // autofillclick right <css selector>: a right-click there, opening the page's context menu (closed after 3 s).
            if arg.hasPrefix("mini "), let webView = MiniWindowController.all.last?.tab.webView { Autofill.debugClick(String(arg.dropFirst(5)), in: webView) }
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
                 "settings": tab.settingsView != nil, "loading": tab.isLoading, "selected": tab === controller.tabManager.selectedTab,
                 "picture": tab.snapshot != nil, "pictureDark": tab.snapshotIsDark.map { $0 ? "dark" : "light" } ?? "unknown",
                 "pictureStale": tab.snapshotIsStale(windowDark: controller.root.effectiveAppearance.isDark)]
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
        case "menuitemkey":
            // menuitemkey <char>: the menu bar item ⌘<char> is, validated and sent up this window's responder chain
            // from its first responder, as pressing it in front would; works with the copy behind other apps.
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if let sub = item.submenu, let found = find(sub) { return found }
                    if item.keyEquivalent == arg, item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command { return item }
                }
                return nil
            }
            guard let item = NSApp.mainMenu.flatMap(find), let action = item.action, let window = controller.window else { debugLog("menuitemkey \(arg): no item"); break }
            let enabled = controller.validateMenuItem(item)
            let sent = enabled && (window.firstResponder ?? window).tryToPerform(action, with: item)
            debugLog("menuitemkey \(arg): \(item.title) \(action) enabled=\(enabled) sent=\(sent)")
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
        case "textcheck":
            // textcheck [<selector>]: sends a spelling or substitution toggle to the selected page, then logs the saved
            // choices.
            if !arg.isEmpty { controller.selectedWebView?.perform(NSSelectorFromString(arg), with: nil) }
            let values = PageTextChecking.shared.current().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            debugLog("textcheck \(values.joined(separator: " ")) system=\(NSSpellChecker.isAutomaticSpellingCorrectionEnabled) sent=\(PageTextChecking.shared.sent)")
        case "js":
            controller.selectedWebView?.evaluateJavaScript(arg) { result, error in
                debugLog("js => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "framejs":
            // framejs <path> <body>: runs <body> (a function body; `return` its answer, awaited) in the page and in every
            // frame that has said hello, as the page's own script, and writes each frame's address and answer (JSON).
            guard let webView = controller.selectedWebView, let space = arg.firstIndex(of: " ") else { break }
            let path = String(arg[..<space]), body = String(arg[arg.index(after: space)...])
            let frames: [WKFrameInfo?] = [nil] + PageFrames.shared.frames(in: webView)
            var rows: [[String: Any]] = []
            let group = DispatchGroup()
            for frame in frames {
                group.enter()
                webView.callAsyncJavaScript(body, arguments: [:], in: frame, in: .page) { result in
                    var row: [String: Any] = ["frame": frame?.request.url?.absoluteString ?? "main", "origin": frame?.securityOrigin.host ?? ""]
                    switch result {
                    case .success(let value): row["result"] = String(describing: value)
                    case .failure(let error): row["error"] = String(describing: error)
                    }
                    rows.append(row)
                    group.leave()
                }
            }
            let write = {
                if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: path)) }
            }
            group.notify(queue: .main, execute: write)
            // A frame that never answers doesn't hold back the others'.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !FileManager.default.fileExists(atPath: path) { rows.append(["frame": "unanswered", "count": frames.count]); write() }
            }
        case "mutestate":
            // mutestate: each tab's mute, as Zigzag has it and as WebKit has the page.
            for tab in WindowManager.shared.controllers.flatMap(\.tabManager.allTabs) {
                let page = tab.webView?.pageMutedState.map { WKWebView.isAudioMuted($0) ? "muted" : "sounding" } ?? "no page"
                debugLog("mutestate \(tab.url?.absoluteString ?? "") tab=\(tab.isMuted ? "muted" : "sounding") page=\(page)")
            }
        case "slowmo":
            // slowmo <factor>: every animation in the window runs that many times slower, to film and judge it.
            let factor = max(1, Float(arg) ?? 1)
            controller.window?.contentView?.layer?.speed = 1 / factor
        case "motionlog":
            // motionlog <path> [ms]: logs each panel, sheet and scrim's on-screen opacity, scale and offset per frame
            // (default 3000 ms).
            let f = arg.split(separator: " ").map(String.init)
            guard let path = f.first, let root = controller.window?.contentView else { break }
            DebugBridge.logMotion(in: root, for: (f.count > 1 ? Double(f[1]) : nil) ?? 3000, to: path)
        case "quit": NSApp.terminate(nil)
        case "updaterelaunch":
            // updaterelaunch: quits as Sparkle does to restart for an update (its willRelaunch first); launching the
            // copy again is the restart.
            UpdateRelaunch.prepare()
            NSApp.terminate(nil)
        case "materials": MaterialsShowcase.debug(arg)
        case "history": HistoryPage.open(in: controller)
        case "archive": ArchivePage.open(in: controller)
        case "seedarchive":
            // seedarchive [n]: adds n archived tabs (default 6) across spaces and recent days, without opening them.
            let spaces = Library.shared.spaces.filter { Library.shared.profileID(ofSpace: $0.id) == controller.tabManager.profile.id }
            let sites = [("https://www.apple.com/", "Apple"), ("https://github.com/", "GitHub"), ("https://en.wikipedia.org/wiki/Zigzag", "Zigzag - Wikipedia"),
                         ("https://news.ycombinator.com/", "Hacker News"), ("https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer Documentation"),
                         ("https://www.example.com/", "Example Domain")]
            let n = Int(arg) ?? 6
            TabArchive.shared.add(contentsOf: (0..<n).reversed().compactMap { i in
                let site = sites[i % sites.count]
                guard let url = URL(string: site.0 + (i < sites.count ? "" : "?\(i)")), let space = spaces.isEmpty ? nil : spaces[i % spaces.count] else { return nil }
                return ArchivedTab(url: url, title: site.1, spaceID: space.id, archivedAt: Date().addingTimeInterval(-Double(i) * 16 * 3600 - 600))
            })
        case "clearhistory":
            // Clears the history of the profile you're in, undoably, as the menu's Clear History does once confirmed.
            controller.historyChange(HistoryPage.clearHistory) { [tabManager = controller.tabManager] in tabManager.profile.history.remove() }
        case "seedhistory": seedHistory(Int(arg) ?? 50_000)
        case "newwindow": WindowManager.shared.newWindow(url: URL(string: arg), showCommandBar: false)
        // newwindowkey: a new window as ⌘N opens it (the command bar up), and the next commands go to it.
        case "newwindowkey": WindowManager.shared.debugTarget = WindowManager.shared.newWindow()
        // usewindow <n>: the next commands go to the nth browser window (in the order they opened), which comes forward.
        case "usewindow":
            let all = WindowManager.shared.controllers
            if let n = Int(arg), all.indices.contains(n - 1) {
                WindowManager.shared.debugTarget = all[n - 1]
                all[n - 1].window?.makeKeyAndOrderFront(nil)
            }
        case "movetonewwindow":
            if let tab = controller.tabManager.selectedTab { controller.moveToNewWindow(tab) }
            WindowManager.shared.debugTarget = WindowManager.shared.controllers.last
        // dragout <n> <x> <y>: the nth tab of this space (0: the tab you're on) let go at that point on screen, as a
        // drag out of the sidebar ends there: into a new window, or onto another window's page (#167).
        case "dragout":
            let f = arg.split(separator: " ").compactMap { Double($0) }
            let list = controller.tabManager.currentTabs
            guard f.count == 3, let tab = list.indices.contains(Int(f[0]) - 1) ? list[Int(f[0]) - 1] : controller.tabManager.selectedTab else { break }
            debugLog("dragout \(tab.displayTitle) handled=\(controller.listDropOutside([tab], at: NSPoint(x: f[1], y: f[2])))")
            WindowManager.shared.debugTarget = WindowManager.shared.keyController
        // droplist <n> <window> <index>: the nth tab of this space (0: the tab you're on) dropped in another window's
        // sidebar, at that place among its tabs, as where its line showed (#167).
        case "droplist":
            let f = arg.split(separator: " ").compactMap { Int($0) }
            let list = controller.tabManager.currentTabs, all = WindowManager.shared.controllers
            guard f.count == 3, all.indices.contains(f[1] - 1),
                  let tab = list.indices.contains(f[0] - 1) ? list[f[0] - 1] : controller.tabManager.selectedTab else { break }
            debugLog("droplist \(tab.displayTitle) handled=\(controller.listMoveToWindow([tab], controller: all[f[1] - 1], index: f[2]))")
            WindowManager.shared.debugTarget = all[f[1] - 1]
        // droppage <window>: the tab you're on let go over the middle of another window's page.
        case "droppage":
            let all = WindowManager.shared.controllers
            guard let n = Int(arg), all.indices.contains(n - 1), let tab = controller.tabManager.selectedTab, let target = all[n - 1].window else { break }
            let frame = target.frame
            debugLog("droppage \(tab.displayTitle) handled=\(controller.listDropOutside([tab], at: NSPoint(x: frame.maxX - 200, y: frame.midY)))")
            WindowManager.shared.debugTarget = all[n - 1]
        // hoverline <window> <x> <y>: that window's sidebar shows its line for a tab from another window carried to
        // that point on screen (none: hidden), as during a drag.
        case "hoverline":
            let f = arg.split(separator: " ").compactMap { Double($0) }, all = WindowManager.shared.controllers
            guard let n = f.first.map(Int.init), all.indices.contains(n - 1) else { break }
            all[n - 1].sidebar.list.externalHover(at: f.count == 3 ? NSPoint(x: f[1], y: f[2]) : nil)
        // tabtomini [n] [x y]: the tab menu's Open in Zigzag Mini for the nth tab of this space (1 = the first; none:
        // the tab you're on), or, with a point on screen, the tab let go there with ⌥ held. Logs whether it's offered.
        case "tabtomini":
            let parts = arg.split(separator: " ").compactMap { Double($0) }
            let list = controller.tabManager.tabs(in: controller.tabManager.currentSpaceID)
            let tab = parts.first.flatMap { n in list.indices.contains(Int(n) - 1) ? list[Int(n) - 1] : nil } ?? controller.tabManager.selectedTab
            guard let tab else { debugLog("tabtomini: no tab"); break }
            debugLog("tabtomini offered=\(controller.canOpenInMini(tab)) title=\(tab.displayTitle)")
            controller.openInMini(tab, at: parts.count == 3 ? NSPoint(x: parts[1], y: parts[2]) : nil)
        // selecttitle <text>: the tab here whose title starts so, chosen as a click on its row chooses it.
        case "selecttitle":
            if let tab = controller.tabManager.allTabs.first(where: { $0.displayTitle.hasPrefix(arg) }) { controller.listSelect(tab) }
        case "windows":
            // windows <path>: each browser window's space, chosen tab and its list.
            let rows: [[String: Any]] = WindowManager.shared.controllers.enumerated().map { i, c in
                let m = c.tabManager
                return ["window": i + 1, "private": m.isPrivate, "space": m.currentSpace.name,
                        "selected": m.selectedTab?.displayTitle ?? "", "tabs": m.currentTabs.map(\.displayTitle),
                        "elsewhere": m.selectedTab.map(m.isShownElsewhere) ?? false, "shared": m.store.isShared,
                        "host": m.currentTabs.map { tab in (WindowManager.shared.controllers.firstIndex { $0 === tab.host } ?? -1) + 1 },
                        "frame": c.window.map { NSStringFromRect($0.frame) } ?? "", "number": c.window?.windowNumber ?? 0]
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: arg)) }
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
        case "magnify":
            // magnify <scale>: the front page pinch-zoomed to scale, around its middle.
            if let webView = controller.selectedWebView, let scale = Double(arg) {
                webView.setMagnification(scale, centeredAt: NSPoint(x: webView.bounds.midX, y: webView.bounds.midY))
            }
        case "themes":
            for tab in controller.tabManager.currentTabs {
                let t = tab.themeColor?.usingColorSpace(.sRGB)
                debugLog("theme \(tab.displayTitle.prefix(20)): \(t.map { "h\($0.hueComponent) s\($0.saturationComponent) b\($0.brightnessComponent)" } ?? "nil") tint=\(SiteTint.color(for: tab).map { String(describing: $0) } ?? "nil")")
            }
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
        case "exportsheet": (WindowManager.shared.keyController ?? WindowManager.shared.controllers.first).map { DataExport.show(in: $0) }
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
        // The Import window looks for browsers again, as it does when it comes forward with none found.
        case "importrescan": (ImportWindowController.shared?.window?.contentView as? ImportView)?.reloadSources()
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
        // pbsave / pblen / pbrestore: keeps what's on the clipboard, logs how long its text is now, puts it back.
        case "pbsave": DebugKeyWindow.savedClipboard = NSPasteboard.general.pasteboardItems?.map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
            } ?? []
        case "pblen": debugLog("pblen \(NSPasteboard.general.string(forType: .string)?.count ?? -1)")
        case "pbrestore":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(DebugKeyWindow.savedClipboard.map { saved in
                let item = NSPasteboardItem()
                for (type, data) in saved { item.setData(data, forType: type) }
                return item
            })
        case "keyprobe":
            // keyprobe <char> [cmd|shift|ctrl|opt...] [focus] [mini] [dry|send|post]: the shortcut as the window gets it
            // (its key equivalents, then the first responder), with the copy left behind other apps. Logs the first
            // responder, the menu item it matches, whether it's enabled and what takes it, then the page's selection
            // and any sheet (cancelled). Copy, Cut and Paste reach the real clipboard: check them dry, or pbsave first.
            let f = arg.split(separator: " ").map(String.init)
            // keyprobe … mini: in the last Zigzag Mini window instead.
            let mini = f.contains("mini") ? MiniWindowController.all.last : nil
            guard let ch = f.first, let window = f.contains("mini") ? mini?.window : controller.window else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in f.dropFirst() {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "ctrl": flags.insert(.control); case "opt": flags.insert(.option); default: break }
            }
            // As if key, without bringing Zigzag forward: menu validation looks for its targets in the key window.
            let pretended = DebugKeyWindow.window
            DebugKeyWindow.pretend(window)
            // keyprobe … focus: the page has the keyboard first.
            if f.contains("focus"), let page = mini?.tab.webView ?? controller.selectedWebView { window.makeFirstResponder(page) }
            let codes: [String: UInt16] = ["a": 0, "s": 1, "c": 8, "v": 9, "x": 7, "z": 6, "f": 3, "p": 35, "l": 37]
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if let sub = item.submenu, let found = find(sub) { return found }
                    if item.keyEquivalent == ch, item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == flags { return item }
                }
                return nil
            }
            let item = NSApp.mainMenu.flatMap(find)
            let responder = window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
            // The window isn't key behind other apps, so NSApp finds no target: walk its chain as AppKit would.
            var chain: [AnyObject] = []
            var next: NSResponder? = window.firstResponder
            while let r = next { chain.append(r); next = r.nextResponder }
            if let delegate = window.delegate, !chain.contains(where: { $0 === delegate }) { chain.append(delegate) }
            chain.append(NSApp)
            if let delegate = NSApp.delegate { chain.append(delegate) }
            let found = item?.action.flatMap { action in chain.first { $0.responds(to: action) } }
            let valid: Bool = {
                guard let item, let found else { return false }
                if let v = found as? NSMenuItemValidation { return v.validateMenuItem(item) }
                if let v = found as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
                return true
            }()
            let target = found.map { "\(type(of: $0))" } ?? "nil"
            item?.menu?.update()
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                           isARepeat: false, keyCode: codes[ch] ?? 0) else { break }
            // keyprobe … send: the item's action straight to the target found, as the menu sends it once enabled.
            let handled: Bool
            if f.contains("dry") {
                // keyprobe … dry: only what the menu would do, nothing sent (Copy, Cut and Paste reach the clipboard).
                handled = false
            } else if f.contains("send"), let item, let action = item.action, let found, valid {
                handled = NSApp.sendAction(action, to: found, from: item)
            } else if f.contains("post") {
                // keyprobe … post: into the app's event queue, so it meets the event monitors and NSApp as a typed key does.
                NSApp.postEvent(e, atStart: false)
                handled = true
            } else {
                handled = window.performKeyEquivalent(with: e)
                if !handled { window.sendEvent(e) }
            }
            debugLog("keyprobe \(arg): responder=\(responder) item=\(item?.title ?? "none") enabled=\(item?.isEnabled ?? false) target=\(target) validates=\(valid) handled=\(handled)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    DebugKeyWindow.pretend(pretended)
                    let sheet = window.attachedSheet
                    debugLog("keyprobe \(arg) after: responder=\(window.firstResponder.map { "\(type(of: $0))" } ?? "nil") sheet=\(sheet.map { "\(type(of: $0))" } ?? "none") editorSelection=\((window.firstResponder as? NSTextView)?.selectedRange().length ?? -1)")
                    if let sheet { window.endSheet(sheet, returnCode: .cancel) }
                    (mini?.tab.webView ?? controller.selectedWebView)?.evaluateJavaScript("(() => { const a = document.activeElement; const s = String(getSelection()).length; const f = a && 'selectionStart' in a && a.selectionStart != null ? a.selectionEnd - a.selectionStart : -1; return s + ' field=' + f + ' active=' + (a ? a.tagName : '') })()") { result, _ in
                        debugLog("keyprobe \(arg) page selection: \(String(describing: result))")
                    }
                }
            }
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
        case "swipestep":
            // swipestep back|forward <0...1> | off: holds the front page mid-swipe.
            let f = arg.split(separator: " ")
            let direction = f.first == "forward" ? 1 : -1
            let value = f.count > 1 ? Double(f[1]).map { CGFloat($0) } : nil
            (controller.selectedTab?.webView as? BrowserWebView)?.debugHoldSwipe(direction: direction, progress: value)
        case "swipe":
            // swipe <dx per step>: a synthetic two-finger horizontal swipe over the sidebar.
            guard let window = controller.window else { break }
            // "page": over the middle of the page instead.
            sendSwipe(arg, to: window, at: arg.split(separator: " ").contains("page") ? NSPoint(x: window.frame.width * 0.6, y: window.frame.height / 2) : NSPoint(x: 100, y: window.frame.height - 300))
        case "swipespace":
            // swipespace next|prev [seconds]: a trackpad flick between spaces over the sidebar, 0.4 s by default.
            guard let window = controller.window else { break }
            let f = arg.split(separator: " ")
            let seconds = f.dropFirst().first.flatMap { Double($0) } ?? 0.4
            let sidebar = controller.sidebar
            sendFlick(toNext: f.first != "prev", seconds: seconds, width: sidebar.bounds.width, to: window,
                      at: sidebar.convert(NSPoint(x: sidebar.bounds.midX, y: sidebar.bounds.midY), to: nil))
        case "copylink": controller.copyPageURL(nil)
        case "zoomout": controller.zoomOut(nil)
        case "scrolllog": try? scrollLog.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        // touchlog <path>: the last 50 touch decisions on pages.
        case "touchlog": try? TouchLog.lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "settings": SettingsPage.open(in: controller)
        // settingsprivacy: Settings › Privacy. flipblocking: its Block ads and trackers switch, as a click does.
        case "settingsprivacy": SettingsPage.open(.privacy, in: controller)
        // settingspane <name>: that pane of Settings (tabs, appearance…).
        case "settingspane": if let pane = SettingsPane(rawValue: arg) { SettingsPage.open(pane, in: controller) }
        // settingsfold open <name> | top <heading>: a box in Settings opened as a click does, or the page scrolled to a heading.
        case "settingsfold": controller.tabManager.selectedTab?.settingsView?.debugFold(arg)
        case "flipblocking": controller.tabManager.selectedTab?.settingsView?.debugFlipBlocking()
        // getextensions: Settings › Extensions' Get Extensions menu, open.
        case "getextensions": controller.tabManager.selectedTab?.settingsView?.debugShowGetExtensionsMenu()
        case "shortcutrecord":
            // shortcutrecord <command name>: starts recording keys on that row of Settings › Shortcuts, its menu's box opened.
            controller.tabManager.selectedTab?.settingsView?.debugRecordShortcut(arg)
        case "engine": if let engine = SearchEngine(rawValue: arg) { Library.shared.searchEngine = engine }
        case "engineinfo":
            // The engine searched with, its address for "zigzag test", and the engines extensions give.
            let engine = Library.shared.searchEngine
            debugLog("engine \(engine.rawValue) \(engine.name) \(engine.searchURL("zigzag test").absoluteString) home=\(engine.homeURL.absoluteString) offered=\(ExtensionSearchProvider.available.map(\.name)) before=\(ExtensionSearchProvider.previousEngine.rawValue)")
        case "largenames": SpaceHeaderView.isLarge = arg != "off"
        case "sidebarsize": if let size = Tokens.Sidebar.Size(rawValue: arg) { Tokens.Sidebar.size = size }
        case "newtabplace": if let place = TabManager.NewTabPlace(rawValue: arg) { TabManager.newTabPlace = place }
        case "sitepanel": SitePanel.toggle(in: controller, from: controller.sidebar.address)
        // sitepanelrow <index> <row title>: picks that choice in the open panel's This Site row.
        case "sitepanelrow": SitePanel.shown?.debugChooseRow(arg)
        // sitepanelmenu <row title> | action <row title>: opens that row's dropdown, or runs its action.
        case "sitepanelmenu": SitePanel.shown?.debugRowMenu(arg)
        case "panesite", "panemore":
            // panesite <pane>: that split pane's Site Controls button, as a click on it (#160). panemore <pane>: its ⋯.
            let cards = controller.root.paneCards
            guard let n = Int(arg), cards.indices.contains(n), let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { break }
            let header = cards[n].header
            (name == "panemore" ? header.more : header.address.siteControls).onClick?(click)
            debugLog("\(name) \(n): site controls \(header.address.showsSiteControls ? "in the address" : "in ⋯"), panel for \(SitePanel.shown.map { $0.describes(header.tab) } == true ? "this pane" : "another page")")
        // sitepage <main|connection|permissions|morepage>: the open site panel's page, as its rows and back button go.
        // sitezoom in|out|reset: its Zoom row. sitepermrow <row> <ask|allow|block> | reset: a permission row's
        // dropdown, or Reset Permissions. sitepanelstate <path>: what it shows (JSON). sitext open|fold: its
        // Extensions header. sitextcount <n>: panels opened from now on show n extensions (0: as they are).
        case "sitepage": SitePanel.shown?.debugPage(arg)
        // zap <css selector>: Zap Element on the first match. zapmode on|off: the picker. zaphover <css selector>: its
        // outline. zapstate: logs the site's boosts.
        case "zap": if let tab = controller.tabManager.selectedTab { ZapPicker.debugZap(arg, in: tab) }
        case "zapmode":
            if arg == "off" { ZapPicker.current?.stop() } else if let tab = controller.tabManager.selectedTab { ZapPicker.start(in: tab, controller: controller) }
        case "zaphover": ZapPicker.debugHover(arg)
        // boostsheet: Edit Style… for the front page. boostcss <css> | save | cancel: types into it ("\n" is a newline)
        // or closes it.
        case "boostsheet": if let tab = controller.tabManager.selectedTab { SiteStyleSheet.show(for: tab, in: controller) }
        case "boostcss": SiteStyleSheet.debug(arg)
        case "zapstate":
            let tab = controller.tabManager.selectedTab
            let boost = SiteBoosts.boost(for: tab?.webView?.url, privateStore: tab?.privateStore)
            debugLog("zapstate \(SiteBoosts.site(of: tab?.webView?.url) ?? "-") picking=\(ZapPicker.current != nil) zaps=\(boost.zaps) style=\(boost.style.count)")
        case "sitecert": SitePanel.shown?.debugCertificate(Int(arg) ?? 0)
        case "sitext": SitePanel.shown?.extensionsSection?.debugCommand(arg)
        case "sitextmenu":
            // sitextmenu <extension id>: logs that tile's menu and the pin marks, and shows the menu at the tile for 4 s.
            guard let section = SitePanel.shown?.extensionsSection, let button = section.debugButton(arg),
                  let event = NSApp.currentEvent ?? NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0),
                  let menu = button.onRightClick?(event) else { debugLog("sitextmenu \(arg): none"); break }
            debugLog("sitextmenu \(arg) => \(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }) marks=\(section.debugPinMarks)")
            closeNextMenu(after: 4)
            DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: button.bounds.midY), in: button) }
        case "sitextcount": SitePanel.debugExtensionCount = Int(arg) ?? 0
        case "sitextforget": SiteExtensionsSection.chosenOpen = nil
        case "sitezoom": SitePanel.shown?.debugZoom(arg)
        case "sitepermrow": SitePanel.shown?.debugPermissionRow(arg)
        // webrtcoffer: the no-WebRTC call prompt for the front tab.
        case "webrtcoffer": if let tab = controller.tabManager.selectedTab { Task { let allowed = await WebRTCProtection.offer(in: tab); debugLog("webrtcoffer => \(allowed)") } }
        // sitedark <automatic|on|off|force>: the Dark page row's dropdown.
        case "sitedark": SitePanel.shown?.debugDark(arg)
        // sitecompat <on|off>: the Compatibility mode switch.
        case "sitecompat": SitePanel.shown?.debugCompatibility(arg)
        // sitejs <allowed|blocked>: the JavaScript row. javascript <on|off>: Settings › Privacy › JavaScript.
        case "sitejs": SitePanel.shown?.debugJavaScript(arg)
        case "javascript": if arg == "on" || arg == "off" { SiteJavaScript.isAllowed = arg == "on" }
        case "sitepanelstate":
            guard let state = SitePanel.shown?.debugState,
                  let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { debugLog("sitepanelstate: no panel"); break }
            try? data.write(to: URL(fileURLWithPath: arg))
        case "siteperm":
            // siteperm <camera|microphone|location|notifications|popups|downloads|apps|webrtc> <ask|allow|block|asked>:
            // sets the front site's permission, or simulates a request.
            let f = arg.split(separator: " ").map(String.init)
            let kinds: [String: SitePermission] = ["camera": .camera, "microphone": .microphone, "location": .location, "notifications": .notifications, "popups": .popups, "downloads": .downloads, "apps": .apps, "webrtc": .webRTC]
            guard f.count == 2, let permission = kinds[f[0]], let origin = SiteOrigin.of(controller.tabManager.selectedTab?.url) else { debugLog("siteperm refused"); break }
            if f[1] == "asked" {
                SitePermissions.noteAsked(permission, origin: origin, isPrivate: false)
            } else if let choice = ["ask": PermissionChoice.ask, "allow": .allow, "block": .block][f[1]] {
                SitePermissions.setChoice(choice, for: permission, origin: origin)
            }
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
        case "dialogcancel": PageDialogSheet.debugCancel()
        case "dialogchoose":
            // dialogchoose <index> [on|off]: picks a choice in the open sheet, sets "always", and continues.
            let f = arg.split(separator: " ")
            PageDialogSheet.debugChoose(Int(f.first ?? "") ?? 0, remember: f.count > 1 ? f[1] == "on" : nil)
        case "clientcerts":
            // clientcerts: logs the saved site certificates.
            debugLog("clientcerts \(ClientCertificates.sites.sorted().map { "\($0)=\(ClientCertificates.kept(host: $0)?.name ?? "")" })")
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
        case "readerstyle": controller.toggleReaderOptions()
        // readerbutton: the address's Reader button, as a click. readeraa: the page's Aa button, as a click.
        // readerswatchhover <n|off>: a color dot under the pointer.
        case "readerbutton": controller.sidebar.address.readerButton.onClick?(NSEvent())
        case "readeraa": controller.readerHere?.optionsButton.button.onClick?(NSEvent())
        // readerpointer <on|off>: the pointer in the reading page's top band, or out of it.
        case "readerpointer": controller.readerHere?.debugPointerNearTop(arg == "on")
        case "readerswatchhover": ReaderOptions.debugHoverSwatch(Int(arg))
        case "readerprefs":
            // readerprefs <auto|light|sepia|dark> <serif|sans> <narrow|medium|wide> [size]: Reader's choices, applied to the open article.
            let f = arg.split(separator: " ").map(String.init)
            func find(_ v: NSView) -> ReaderView? { (v as? ReaderView) ?? v.subviews.lazy.compactMap(find).first }
            guard f.count >= 3, let content = controller.window?.contentView, let reader = find(content) else { break }
            reader.apply(Reader.Preferences(size: f.count > 3 ? Int(f[3]) ?? 20 : 20, face: .init(rawValue: f[1]) ?? .serif,
                                               theme: .init(rawValue: f[0]) ?? .auto, width: .init(rawValue: f[2]) ?? .medium))
        case "readerjs":
            // readerjs <script>: runs in the open article, in Zigzag's own script world.
            controller.debugReaderWebView?.runOwnScript(arg)
        case "hidetoasts": Toast.hide(in: controller)
        // showtoast <text>: a plain toast for six seconds.
        case "showtoast": Toast.show(arg, symbol: "checkmark", duration: 6, in: controller)
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
        // viewtree <path>: every view in the window with its frame in window points (top left), for measuring.
        case "viewtree":
            guard let content = controller.window?.contentView else { break }
            var out = ""
            func walk(_ v: NSView, _ depth: Int) {
                let r = v.convert(v.bounds, to: nil)
                let text = (v as? NSTextField)?.stringValue.prefix(40) ?? ""
                out += String(repeating: " ", count: depth) + "\(type(of: v)) x=\(r.minX) y=\(content.bounds.height - r.maxY) w=\(r.width) h=\(r.height)\(v.isHidden ? " hidden" : "") \(text)\n"
                if !v.isHidden { v.subviews.forEach { walk($0, depth + 1) } }
            }
            walk(content, 0)
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
        // quitfromloop: quits from the run loop, as ⌘Q does, not from inside a main-queue block: what quitting waits
        // for (downloads pausing, cookies clearing) comes back on the main queue.
        case "quitfromloop": NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        // keptcookies clear | add | quit on|off | top: Settings › Privacy's kept cookies (#334). keptcookiesstate <path>:
        // each profile's kept sites and quit choice, as JSON.
        case "keptcookies": controller.tabManager.selectedTab?.settingsView?.debugKeptCookies(arg)
        // clearsonquit on|off: Clear cookies when Zigzag quits for the front window's profile, without Settings open.
        case "clearsonquit": KeptCookies.setClearsOnQuit(arg == "on", in: controller.tabManager.profile.id)
        case "keptcookiesstate":
            let state = Profiles.shared.all.map { ["profile": $0.id.uuidString, "sites": KeptCookies.sites(in: $0.id).sorted(), "clearsOnQuit": KeptCookies.clearsOnQuit(in: $0.id)] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        // passwordfiller zigzag|iCloud: Settings › Passwords › Password manager (#248).
        case "passwordfiller": controller.tabManager.selectedTab?.settingsView?.debugChoosePasswordFiller(arg)
        // sitedata seed <count> | bench <path>: made-up sites in the profile of the space in front, or Settings'
        // list of what websites keep timed (#207).
        case "sitedata":
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let store = controller.tabManager.profile.store
            if f.first == "seed", let count = f.count > 1 ? Int(f[1]) : nil { Task { await SiteDataBench.seed(count, in: store) } }
            if f.first == "storage", let count = f.count > 1 ? Int(f[1]) : nil { Task { await SiteDataBench.seedStorage(count, in: store) } }
            if f.first == "bench", f.count > 1, let settings = controller.tabManager.selectedTab?.settingsView {
                Task { await SiteDataBench.run(settings, to: f[1]) }
            } else if f.first != "seed", f.first != "storage" {
                controller.tabManager.selectedTab?.settingsView?.debugSiteData(arg)
            }
        // flags find <text> | all | top: Settings › Developer › Feature Flags in the tab in front. flagset <key> on|off|default,
        // flagsreset: a WebKit feature flag changed, or all of them back to WebKit's (#173).
        case "flags": controller.tabManager.selectedTab?.settingsView?.debugFlags(arg)
        case "flagset":
            let f = arg.split(separator: " ").map(String.init)
            if f.count == 2, let flag = FeatureFlags.flags?.first(where: { $0.key == f[0] }) {
                FeatureFlags.set(f[1] == "default" ? flag.defaultValue : f[1] == "on", for: flag)
            }
        case "flagsreset": FeatureFlags.reset()
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
               // settingsbottom [column]: the page, or the column of sections (the narrower of the two).
               let scroll = root.subviews.compactMap({ $0 as? NSScrollView }).sorted(by: { $0.frame.width < $1.frame.width })[arg == "column" ? 0 : 1] as NSScrollView?,
               let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
            }
        case "allowads": ContentBlocker.setAllowed(arg != "off", on: controller.tabManager.selectedTab?.url); controller.tabManager.selectedTab?.reload()
        case "adfilters":
            // adfilters update (downloads the lists now, whether or not they've expired), adfilters <path> (JSON: the
            // engine, its lists, and the site filters in the front tab's web view).
            let engine = AdEngine.shared
            if arg == "update" { engine.refresh(force: true); break }
            let status = engine.status
            let scripts = controller.selectedWebView?.configuration.userContentController.userScripts.filter(PageFilters.isOurs) ?? []
            let state: [String: Any] = [
                "generation": status.generation, "ready": status.ready, "filters": status.filters, "scriptlets": status.scriptlets,
                "builtInMs": Int(status.builtIn * 1000), "loadedInMs": Int(status.loadedIn * 1000),
                "checked": engine.listsChecked.map { ISO8601DateFormatter().string(from: $0) } ?? "", "error": status.lastError ?? "",
                "hosts": controller.selectedWebView.map { PageFilters.hosts(in: $0.configuration.userContentController).sorted() } ?? [],
                "tabScripts": scripts.count, "tabScriptBytes": scripts.reduce(0) { $0 + $1.source.utf8.count },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "userscripts":
            // userscripts <path>: each live tab's page scripts, how many and how big, the largest by their first
            // line (JSON). What a new page's process is sent as it starts, so it should stay the same as you browse.
            var rows: [[String: Any]] = []
            for window in WindowManager.shared.controllers {
                for tab in window.tabManager.allTabs {
                    guard let webView = tab.webView else { continue }
                    let userContent = webView.configuration.userContentController
                    let scripts = Array(userContent.userScripts)
                    let largest = scripts.sorted { $0.source.utf8.count > $1.source.utf8.count }.prefix(8).map {
                        "\($0.source.utf8.count) \($0.source.prefix(60).replacingOccurrences(of: "\n", with: " "))"
                    }
                    rows.append(["url": tab.url?.absoluteString ?? "", "controller": "\(ObjectIdentifier(userContent).hashValue)",
                                 "count": scripts.count, "bytes": scripts.reduce(0) { $0 + $1.source.utf8.count }, "largest": largest])
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
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
            if f.count == 2 { var sites = ExtensionStore.extensionsOffSites(in: controller.tabManager.profile); if f[1] == "on" { sites.insert(f[0]) } else { sites.remove(f[0]) }; ExtensionStore.setExtensionsOffSites(sites, in: controller.tabManager.profile) }
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
        case "extprivate":
            // extprivate <id> on|off: Settings › Extensions › Allow in private windows.
            let f = arg.split(separator: " ").map(String.init)
            if f.count == 2 { controller.tabManager.profile.installs.setAllowsPrivate(f[0], f[1] == "on") }
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
        case "floaters":
            // floaters <path>: every window of Zigzag's that's up, and what keeps it on screen as you go to another
            // app or desktop: its level, collection behavior, whether it hides when Zigzag isn't in front (JSON).
            let behaviors: [(String, NSWindow.CollectionBehavior)] = [("canJoinAllSpaces", .canJoinAllSpaces), ("moveToActiveSpace", .moveToActiveSpace),
                                                                      ("stationary", .stationary), ("fullScreenAuxiliary", .fullScreenAuxiliary),
                                                                      ("ignoresCycle", .ignoresCycle), ("transient", .transient), ("managed", .managed)]
            let rows = NSApp.windows.filter(\.isVisible).map { window -> [String: Any] in
                ["class": "\(type(of: window))", "number": window.windowNumber, "level": window.level.rawValue, "frame": NSStringFromRect(window.frame),
                 "hidesOnDeactivate": window.hidesOnDeactivate, "canHide": window.canHide, "onActiveSpace": window.isOnActiveSpace,
                 "behavior": behaviors.filter { window.collectionBehavior.contains($0.1) }.map(\.0)]
            }
            let state: [String: Any] = ["active": NSApp.isActive, "windows": rows]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "pip":
            controller.selectedWebView?.callAsyncJavaScript("const v = [...document.querySelectorAll('video')].find(v => !v.paused); if (!v) return 'no video'; v.webkitSetPresentationMode('picture-in-picture'); await new Promise(r => setTimeout(r, 800)); return v.webkitPresentationMode;", arguments: [:], in: nil, in: .page) { result in
                debugLog("pip => \(result)")
            }
        case "undo":
            debugLog("undo \(controller.sidebarUndo.undoActionName) groups=\(controller.sidebarUndo.groupingLevel)")
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
                debugLog("audio \(tab.displayTitle.prefix(30)) playing=\(tab.isPlayingAudio) kvo=\(state) media=\(tab.webView.map { PageVideos.shared.playsSound(in: $0) } ?? false) muted=\(tab.isMuted) webkitMuted=\(muted.map { "\($0)" } ?? "n/a")")
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
                    debugLog("keyfocus \(type(of: found[n])): \(ok) '\(found[n].accessibilityLabel() ?? "")' \(found[n].convert(found[n].bounds, to: nil))")
                }
            }
        case "keyloop":
            // keyloop: logs the key view loop from the first responder (Full Keyboard Access).
            InteractiveView.debugKeyboardAccess = true
            guard let window = controller.window else { break }
            window.recalculateKeyViewLoop()
            var stop = (window.firstResponder as? NSView) ?? window.contentView
            var seen: [ObjectIdentifier] = []
            for i in 0..<60 {
                guard let next = stop?.nextValidKeyView, !seen.contains(ObjectIdentifier(next)) else { break }
                seen.append(ObjectIdentifier(next))
                debugLog("keyloop \(i) \(type(of: next)) '\(next.accessibilityLabel() ?? "")' \(next.convert(next.bounds, to: nil)) hidden=\(next.isHiddenOrHasHiddenAncestor) alpha=\(next.alphaValue)")
                stop = next
            }
        case "unload":
            // unload <title or host>: unloads a pinned page or favorite.
            if let id = (Library.shared.spaces.flatMap(\.bookmarks) + Library.shared.favorites).first(where: { $0.title == arg || $0.url.host() == arg })?.id,
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
        case "pinsel":
            // pinsel [n]: the tab you're on dropped among the pinned tabs at place n (none: the end), as a drag there
            // does, undoably; a split's or tile group's row pins all its pages (#203).
            if let tab = controller.tabManager.selectedTab { controller.listBookmark(tab, at: Int(arg) ?? Int.max, in: controller.tabManager.currentSpaceID) }
        case "favsel":
            // favsel [n]: the tab you're on dropped on the favorites at tile n (none: the end), undoably.
            if let tab = controller.tabManager.selectedTab { controller.favoriteWithUndo(tab, at: Int(arg)) }
        case "unpinnamed":
            // unpinnamed <title>: that pinned page (or favorite) dropped among the tabs at the top, undoably.
            if let id = (Library.shared.spaces.flatMap(\.bookmarks) + Library.shared.favorites).first(where: { $0.title.contains(arg) })?.id {
                if Library.shared.isFavorite(id) { controller.unfavoriteWithUndo(id, to: 0) } else { controller.listUnbookmark(id, to: 0) }
            }
        case "openpinnamed":
            // openpinnamed <title>: that pinned page or favorite opened, as a click on it does.
            if let mark = (Library.shared.spaces.flatMap(\.bookmarks) + Library.shared.favorites).first(where: { $0.title.contains(arg) }) {
                controller.tabManager.openBookmark(mark)
            }
        case "folderpinnamed":
            // folderpinnamed <title>: that pinned page (with its split or group) into the space's first folder, undoably.
            if let id = Library.shared.bookmarks(in: controller.tabManager.currentSpaceID).first(where: { $0.title.contains(arg) })?.id,
               let folder = Library.shared.folders(in: controller.tabManager.currentSpaceID).first {
                controller.listSetFolder(of: id, to: folder.id)
            }
            let space = controller.tabManager.currentSpaceID
            debugLog("pinstate folders=\(Library.shared.folders(in: space).map { "\($0.name) \($0.bookmarkIDs.compactMap { Library.shared.bookmark($0)?.title })" }) list=\(Library.shared.bookmarks(in: space).map(\.title))")
        case "capture":
            // capture <path>: this window as it shows on screen, web pages and all, by its own window number (so never
            // another app's or another copy's window), as a PNG.
            guard let number = controller.window?.windowNumber else { break }
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", "\(number)", arg]
            try? shot.run()
        case "pinstate":
            // pinstate: the pinned splits and favorite splits, with their pages' names and places, in the debug log.
            func names(_ split: PinnedSplit) -> String {
                split.ids.map { Library.shared.bookmark($0)?.title.prefix(12).description ?? "?" }.joined(separator: "|") + " regions=\(split.regions?.map(\.rawValue) ?? [])"
            }
            let pinned = Library.shared.pinnedSplits(in: controller.tabManager.currentSpaceID).map(names)
            let favorites = Library.shared.favoriteSplits.map(names)
            let splits = controller.tabManager.splits.map { pair in pair.ids.compactMap { controller.tabManager.tab(with: $0)?.displayTitle.prefix(12).description }.joined(separator: "|") + " \(pair.shape.regions.map(\.rawValue))" }
            debugLog("pinstate pinned=\(pinned) favorites=\(favorites) onscreen=\(splits) tabs=\(controller.tabManager.currentTabs.map { $0.displayTitle.prefix(12) })")
        case "pagecorner":
            PageCardView.attachedRadiusOverride = Double(arg).map { CGFloat($0) }; controller.root.paneCards.forEach { $0.needsLayout = true }
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

    /// `motionlog`: samples the panels, sheets and scrims each frame; one line per view: ms, view, opacity, transform
    /// scale and offset, hit-testable.
    static func logMotion(in root: NSView, for milliseconds: Double, to path: String) {
        let start = CACurrentMediaTime()
        var lines: [String] = []
        motionTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
            @MainActor func watched(_ view: NSView) -> [NSView] {
                let mine = view is FloatingPanelView || view is ScrimView || view is ConfirmSheet || view is FormSheet
                    || view is PageDialogSheet || view is WhatsNewSheet || view is TabPreviewView || view is EmptySpaceMark
                return (mine ? [view] : []) + view.subviews.flatMap(watched)
            }
            @MainActor func shownOpacity(_ view: NSView) -> Float {
                var opacity: Float = 1
                var current: NSView? = view
                while let v = current, v !== root {
                    let layer = v.layer?.presentation() ?? v.layer
                    opacity *= (layer?.opacity ?? 1) * (v.isHidden ? 0 : 1)
                    current = v.superview
                }
                return opacity
            }
                let ms = (CACurrentMediaTime() - start) * 1000
                // Not committed to the render server yet.
                for view in watched(root) where view.layer?.presentation() != nil {
                    let t = (view.layer?.presentation() ?? view.layer)?.transform ?? CATransform3DIdentity
                    let window = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                    let hit = root.window?.contentView?.superview?.hitTest(root.window?.contentView?.superview?.convert(window, from: nil) ?? .zero)
                    let reaches = hit.map { $0 === view || $0.isDescendant(of: view) } ?? false
                    lines.append(String(format: "%7.1f %@ opacity=%.3f scale=%.4f dx=%.1f dy=%.1f clicks=%d", ms, String(describing: type(of: view)),
                                        shownOpacity(view), t.m11, t.m41, t.m42, reaches ? 1 : 0))
                }
                guard ms >= milliseconds else { return }
                motionTimer?.invalidate()
                motionTimer = nil
                try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private static var motionTimer: Timer?

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

    /// Whether the window server would start moving the window on a press at this point (window coordinates), read
    /// from the drag region AppKit last gave it; nil where that can't be read (it's AppKit's own, unpublished). The
    /// region comes as rows from the bottom up, each 32-bit: its y, its length in words, then the x where each run
    /// the window moves from starts and ends; a row holds until the next one.
    static func windowServerMoves(_ window: NSWindow, at point: NSPoint) -> Bool? {
        let selector = NSSelectorFromString("_lastDragRegionData")
        guard window.responds(to: selector), let data = window.perform(selector)?.takeUnretainedValue() as? Data,
              data.count >= 8, data.count % 4 == 0 else { return nil }
        let words = data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        var runs: [Int32] = []
        var i = 2
        while i + 1 < words.count {
            let y = words[i], length = Int(words[i + 1])
            guard length >= 2, i + length <= words.count else { return nil }
            if CGFloat(y) > point.y { break }
            runs = Array(words[(i + 2)..<(i + length)])
            i += length
        }
        return stride(from: 0, to: runs.count - 1, by: 2).contains { CGFloat(runs[$0]) <= point.x && point.x < CGFloat(runs[$0 + 1]) }
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

#if DEBUG
/// For `keyprobe`: NSApp answers as if `window` were key and main, so the menu bar validates and sends its shortcuts
/// as it does in front, while the test copy stays behind the app you're using.
@MainActor
enum DebugKeyWindow {
    nonisolated(unsafe) static var window: NSWindow?
    private static var swapped = false
    static var savedClipboard: [[NSPasteboard.PasteboardType: Data]] = []

    static func pretend(_ window: NSWindow?) {
        if !swapped {
            swapped = true
            for (original, stand) in [("keyWindow", "zz_keyWindow"), ("mainWindow", "zz_mainWindow")] {
                if let a = class_getInstanceMethod(NSApplication.self, NSSelectorFromString(original)),
                   let b = class_getInstanceMethod(NSApplication.self, NSSelectorFromString(stand)) {
                    method_exchangeImplementations(a, b)
                }
            }
        }
        self.window = window
    }
}

extension NSApplication {
    // After the exchange, these names call AppKit's own.
    @objc func zz_keyWindow() -> NSWindow? { DebugKeyWindow.window ?? zz_keyWindow() }
    @objc func zz_mainWindow() -> NSWindow? { DebugKeyWindow.window ?? zz_mainWindow() }
}
#endif

#if DEBUG
/// Debug only: `lightswatch` logs traffic light positions at each Core Animation commit and every AppKit move with its
/// caller, so a one-frame jump shows.
@MainActor
enum TrafficLightWatch {
    private static var observer: CFRunLoopObserver?
    private static var lines: [String] = []
    private static var last = ""
    private static var commits = 0
    private static var start = Date()

    static var isWatching: Bool { observer != nil }

    /// AppKit moved a button, before it's put back.
    static func moved(_ view: NSView, in window: NSWindow) {
        guard isWatching else { return }
        let stack = Thread.callStackReturnAddresses.dropFirst(5).prefix(32).map { address -> String in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address.uintValue), &info) != 0, let name = info.dli_sname else { return "?" }
            return String(cString: name)
        }.joined(separator: " < ")
        lines.append(String(format: "%.4f moved %@ to %@ by %@", Date().timeIntervalSince(start),
                            String(describing: type(of: view)), NSStringFromRect(view.convert(view.bounds, to: nil)), stack))
    }

    static func start(seconds: Double, path: String, window: NSWindow) {
        stop(path: nil)
        lines = []; last = ""; commits = 0; start = Date()
        watched = window
        // Reads the lights as each Core Animation commit goes out, via a commit handler set on every run loop pass.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { askForCommit() }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { stop(path: path) } }
    }

    private static weak var watched: NSWindow?
    private static var asked = false

    /// `+[CATransaction addCommitHandler:forPhase:]` (private; phase 1 is just before the commit).
    private static func askForCommit() {
        guard observer != nil, !asked else { return }
        let selector = NSSelectorFromString("addCommitHandler:forPhase:")
        guard let method = class_getClassMethod(CATransaction.self, selector) else { return }
        typealias Add = @convention(c) (AnyClass, Selector, AnyObject, Int32) -> Void
        let add = unsafeBitCast(method_getImplementation(method), to: Add.self)
        let handler: @convention(block) () -> Void = {
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                asked = false
                guard let window = watched else { return }
                commits += 1
                let state = describe(window)
                if state != last {
                    lines.append(String(format: "%.4f commit %d %@", Date().timeIntervalSince(start), commits, state))
                    last = state
                }
            }
        }
        asked = true
        add(CATransaction.self, selector, unsafeBitCast(handler, to: AnyObject.self), 1)
    }

    private static func stop(path: String?) {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
        guard let path else { return }
        lines.append("commits \(commits)")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func describe(_ window: NSWindow) -> String {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        let frames = buttons.map { b -> String in
            let r = b.convert(b.bounds, to: nil)
            return "\(Int(r.minX)),\(Int(r.minY))\(b.isHidden ? "h" : "")"
        }
        let container = buttons.first?.superview?.superview?.frame ?? .zero
        let titlebar = buttons.first?.superview?.frame ?? .zero
        return "lights=\(frames.joined(separator: " ")) container=\(NSStringFromRect(container)) titlebar=\(NSStringFromRect(titlebar))"
    }
}
#endif

#if DEBUG
/// scrollbench <path> [seconds] [js|wheel] [points per frame]: scrolls the front page and writes frame gaps (JSON), in
/// the page (animation frames) and on the main thread (display link). `js` uses `scrollBy`; `wheel` sends synthetic
/// trackpad events to the web view only, `window` through the window and its event monitors.
@MainActor
enum ScrollBench {
    private final class Ticker: NSObject {
        var last: CFTimeInterval = 0
        var gaps: [Double] = []
        var tick: ((CADisplayLink) -> Void)?
        var beat: (() -> Void)?
        @objc func beatFired(_ timer: Timer) { beat?() }
        /// WebKit's page layers; counts display frames where any moved.
        weak var root: CALayer?
        var previous: [ObjectIdentifier: CGFloat] = [:]
        var movedTicks = 0
        var ticks = 0
        @objc func fire(_ link: CADisplayLink) {
            if last > 0 { gaps.append((link.timestamp - last) * 1000) }
            last = link.timestamp
            if let root {
                var now: [ObjectIdentifier: CGFloat] = [:]
                var stack = [root]
                while let layer = stack.popLast(), now.count < 4000 {
                    let shown = layer.presentation() ?? layer
                    now[ObjectIdentifier(layer)] = shown.bounds.origin.y + shown.position.y * 3
                    stack.append(contentsOf: layer.sublayers ?? [])
                }
                if !previous.isEmpty {
                    ticks += 1
                    if now.contains(where: { key, value in previous[key].map { abs($0 - value) > 0.01 } ?? false }) { movedTicks += 1 }
                }
                previous = now
            }
            tick?(link)
        }
    }

    static func stats(_ gaps: [Double], frame: Double) -> [String: Any] {
        guard !gaps.isEmpty else { return ["count": 0] }
        let sorted = gaps.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) }
        return ["count": gaps.count, "p50": pct(0.5), "p95": pct(0.95), "p99": pct(0.99), "max": sorted.last!,
                "mean": gaps.reduce(0, +) / Double(gaps.count), "dropped": dropped, "over1.5frames": gaps.filter { $0 > frame * 1.5 }.count]
    }

    static func run(_ arg: String, in controller: BrowserWindowController) {
        let f = arg.split(separator: " ").map(String.init)
        guard let path = f.first else { return }
        let seconds = f.count > 1 ? Double(f[1]) ?? 5 : 5
        let mode = f.count > 2 ? f[2] : "js"
        let step = f.count > 3 ? Double(f[3]) ?? 12 : 12
        guard let webView = controller.selectedWebView, let window = webView.window else {
            try? "no page".write(toFile: path, atomically: true, encoding: .utf8); return
        }
        let screenFPS = window.screen?.maximumFramesPerSecond ?? 0
        let ticker = Ticker()
        var direction = 1.0
        var sent = 0
        // How long each scroll took to hand over, in microseconds.
        var dispatch: [Double] = []
        if mode == "wheel" || mode == "window" {
            let throughWindow = mode == "window"
            let center = NSPoint(x: webView.bounds.midX, y: webView.bounds.midY)
            let inWindow = webView.convert(center, to: nil)
            let onScreen = window.convertPoint(toScreen: inWindow)
            let flippedY = (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y
            var phaseStart = CACurrentMediaTime()
            var began = false
            let send: (CFTimeInterval) -> Void = { now in
                // Alternates direction every 1.5 s.
                if now - phaseStart > 1.5 { phaseStart = now; direction = -direction; began = false
                    if let end = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) {
                        end.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
                        end.location = CGPoint(x: onScreen.x, y: flippedY)
                        if let e = NSEvent(cgEvent: end) { if throughWindow { window.sendEvent(e) } else { webView.scrollWheel(with: e) } }
                    }
                }
                let dy = Int32(-direction * step)
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: began ? 2 : 1)
                cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
                cg.location = CGPoint(x: onScreen.x, y: flippedY)
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                began = true
                if let event = NSEvent(cgEvent: cg) {
                    let start = CACurrentMediaTime()
                    if throughWindow { window.sendEvent(event) } else { webView.scrollWheel(with: event) }
                    dispatch.append((CACurrentMediaTime() - start) * 1_000_000)
                    sent += 1
                }
            }
            // Through the window, on a clock of its own: a display link stops while the window is covered.
            if throughWindow {
                ticker.beat = { send(CACurrentMediaTime()) }
                let clock = Timer(timeInterval: 1.0 / 120, target: ticker, selector: #selector(Ticker.beatFired(_:)), userInfo: nil, repeats: true)
                RunLoop.main.add(clock, forMode: .common)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { clock.invalidate() }
            } else {
                ticker.tick = { link in send(link.timestamp) }
            }
        }
        ticker.root = webView.layer
        let link = webView.displayLink(target: ticker, selector: #selector(Ticker.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        let pageScript = """
        const scrolls = mode === 'js';
        const gaps = []; let last = 0, dir = 1, y0 = scrollY, moved = 0;
        const end = performance.now() + seconds * 1000;
        await new Promise((done) => {
          const frame = (t) => {
            if (last) gaps.push(t - last);
            last = t;
            if (scrolls) {
              const max = document.scrollingElement.scrollHeight - innerHeight;
              if (scrollY >= max - 1) dir = -1; else if (scrollY <= 0) dir = 1;
              window.scrollBy(0, dir * step);
            }
            moved += Math.abs(scrollY - y0); y0 = scrollY;
            if (t < end) requestAnimationFrame(frame); else done();
          };
          requestAnimationFrame(frame);
        });
        return JSON.stringify({ gaps, moved, height: document.scrollingElement.scrollHeight, visibility: document.visibilityState });
        """
        Task {
            var result: [String: Any] = ["mode": mode, "seconds": seconds, "screenFPS": screenFPS, "step": step,
                                         "occluded": !window.occlusionState.contains(.visible), "key": window.isKeyWindow]
            do {
                let value = try await webView.callAsyncJavaScript(pageScript, arguments: ["mode": mode, "seconds": seconds, "step": step],
                                                                  in: nil, contentWorld: .defaultClient)
                if let text = value as? String, let data = text.data(using: .utf8),
                   let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let gaps = page["gaps"] as? [Double] ?? []
                    result["page"] = stats(gaps, frame: 1000 / Double(max(screenFPS, 60)))
                    result["pageMoved"] = page["moved"]
                    result["pageHeight"] = page["height"]
                    result["visibility"] = page["visibility"]
                }
            } catch { result["error"] = "\(error)" }
            link.invalidate()
            result["mainThread"] = stats(ticker.gaps, frame: 1000 / Double(max(screenFPS, 60)))
            result["wheelEvents"] = sent
            let byTime = dispatch.sorted()
            if !byTime.isEmpty {
                result["dispatchMicros"] = ["p50": byTime[byTime.count / 2], "p95": byTime[byTime.count * 95 / 100], "max": byTime.last!,
                                            "mean": byTime.reduce(0, +) / Double(byTime.count)]
            }
            result["layerMovedTicks"] = ticker.movedTicks
            result["layerTicks"] = ticker.ticks
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
#endif

#if DEBUG
/// fpsbench [seconds] [path|-] [window|js]: scrolls the front page up and down, by trackpad-like scrolls sent through
/// the window (`window`, 12 pt at 120 Hz) or in the page (`js`, 12 pt an animation frame), and measures how often the
/// window's part of the screen is presented, from ScreenCaptureKit when Screen Recording is allowed, and the display
/// link's beat. Results go to debug.log, the file if given, and a label in the window's corner while it runs.
@MainActor
enum FrameRateBench {
    private static var running = false

    /// Frames of the screen under one window, as ScreenCaptureKit sees them presented.
    nonisolated private final class Presented: NSObject, SCStreamOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        private var stream: SCStream?
        private let scale: Double = {
            var base = mach_timebase_info_data_t()
            mach_timebase_info(&base)
            return Double(base.numer) / Double(base.denom) / 1_000_000
        }()

        func start(window number: Int) async throws {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(number) }),
                  let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else { throw CocoaError(.featureUnsupported) }
            let config = SCStreamConfiguration()
            // The window's part of the display, small: only when frames come matters.
            let rect = window.frame.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.sourceRect = rect
            config.width = 320
            config.height = max(2, Int(320 * rect.height / max(rect.width, 1)))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
            config.queueDepth = 8
            config.showsCursor = false
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "fpsbench"))
            try await stream.startCapture()
            lock.withLock { self.stream = stream }
        }

        func stop() async {
            let stream = lock.withLock { self.stream }
            try? await stream?.stopCapture()
        }

        /// Display times of the frames so far, in ms.
        var frames: [Double] { lock.withLock { times } }

        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = attachments.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            let time = (info[.displayTime] as? UInt64).map { Double($0) * scale } ?? CMSampleBufferGetPresentationTimeStamp(buffer).seconds * 1000
            lock.withLock { times.append(time) }
        }
    }

    private final class Beat: NSObject {
        var times: [Double] = []
        @objc func fire(_ link: CADisplayLink) { times.append(link.timestamp * 1000) }
    }

    private static func gaps(_ times: [Double]) -> [Double] { zip(times.dropFirst(), times).map { $0 - $1 } }

    private static func summary(_ gaps: [Double]) -> (p50: Double, p95: Double, fps: Double)? {
        guard gaps.count > 4 else { return nil }
        let sorted = gaps.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        return (p50, p95, 1000 * Double(gaps.count) / gaps.reduce(0, +))
    }

    private static func line(_ name: String, _ gaps: [Double]) -> String {
        guard let s = summary(gaps) else { return "\(name) none" }
        return String(format: "%@ %.0f fps  p50 %.2f ms  p95 %.2f ms", name, s.fps, s.p50, s.p95)
    }

    static func run(_ arg: String, in controller: BrowserWindowController) {
        guard !running, let webView = controller.selectedWebView, let window = webView.window, let content = window.contentView else { return }
        let f = arg.split(separator: " ").map(String.init)
        let seconds = f.first.flatMap(Double.init) ?? 6
        let path = f.count > 1 && f[1] != "-" ? f[1] : nil
        let inPage = f.count > 2 && f[2] == "js"
        running = true

        let hud = NSTextField(labelWithString: "Measuring…")
        hud.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hud.textColor = .white
        hud.drawsBackground = true
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        hud.maximumNumberOfLines = 3
        content.addSubview(hud)
        func placeHUD() {
            hud.sizeToFit()
            hud.frame.origin = NSPoint(x: content.bounds.maxX - hud.frame.width - 12,
                                       y: content.isFlipped ? content.bounds.maxY - hud.frame.height - 12 : 12)
        }
        placeHUD()

        let beat = Beat()
        let link = webView.displayLink(target: beat, selector: #selector(Beat.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        let presented = Presented()
        let allowed = CGPreflightScreenCaptureAccess()
        let started = CACurrentMediaTime() * 1000
        // The figure so far, twice a second.
        let ticker = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime() * 1000
                let recent = (allowed ? presented.frames : beat.times).filter { $0 > now - 500 }
                hud.stringValue = String(format: "%@ %.0f fps", allowed ? "presented" : "display link", Double(max(recent.count - 1, 0)) * 2)
                placeHUD()
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        if !inPage { scrollThroughWindow(webView, seconds: seconds) }

        let script = """
        const scrolls = inPage;
        let dir = 1, frames = 0;
        const end = performance.now() + seconds * 1000;
        await new Promise((done) => {
          const frame = (t) => {
            const max = document.scrollingElement.scrollHeight - innerHeight;
            if (scrollY >= max - 1) dir = -1; else if (scrollY <= 0) dir = 1;
            if (scrolls) window.scrollBy(0, dir * 12);
            frames++;
            if (t < end) requestAnimationFrame(frame); else done();
          };
          requestAnimationFrame(frame);
        });
        return frames;
        """
        Task {
            var note = ""
            if allowed {
                do { try await presented.start(window: window.windowNumber) } catch { note = "capture failed: \(error)" }
            } else {
                note = "no Screen Recording: display link only"
            }
            let value = try? await webView.callAsyncJavaScript(script, arguments: ["seconds": seconds, "inPage": inPage], in: nil, contentWorld: .defaultClient)
            let pageFrames = (value as? NSNumber)?.intValue ?? 0
            await presented.stop()
            ticker.invalidate()
            link.invalidate()
            // The first half second settles.
            let shown = gaps(presented.frames.filter { $0 > started + 500 })
            let beats = gaps(beat.times.filter { $0 > started + 500 })
            let screen = window.screen?.maximumFramesPerSecond ?? 0
            let opaque = window.isOpaque
            let text = [note.isEmpty ? line("presented", shown) : note, line("display link", beats),
                        "\(inPage ? "js" : "window")  \(GlassVariant.now.rawValue)  opaque \(opaque)  screen \(screen) Hz  page \(Int(Double(pageFrames) / seconds)) fps"].joined(separator: "\n")
            debugLog("fpsbench \(text.replacingOccurrences(of: "\n", with: " | "))")
            hud.stringValue = text
            placeHUD()
            if let path {
                var result: [String: Any] = ["variant": GlassVariant.now.rawValue, "mode": inPage ? "js" : "window", "opaque": opaque, "screenFPS": screen, "seconds": seconds,
                                             "pageFPS": Double(pageFrames) / seconds, "note": note, "key": window.isKeyWindow,
                                             "visible": window.occlusionState.contains(.visible)]
                if let s = summary(shown) { result["presented"] = ["p50": s.p50, "p95": s.p95, "fps": s.fps, "count": shown.count] }
                if let s = summary(beats) { result["displayLink"] = ["p50": s.p50, "p95": s.p95, "fps": s.fps, "count": beats.count] }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
            }
            running = false
            try? await Task.sleep(for: .seconds(4))
            hud.removeFromSuperview()
        }
    }

    /// Trackpad-like scrolls through the window at 120 Hz, 12 pt each, turning every 1.5 s, as `scrollbench window`.
    private static func scrollThroughWindow(_ webView: WKWebView, seconds: Double) {
        guard let window = webView.window else { return }
        let inWindow = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let at = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y)
        func send(_ dy: Int32, phase: Int64) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
            cg.location = at
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
        }
        let start = CACurrentMediaTime()
        var turn = start, direction: Int32 = 1, began = false
        let clock = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                guard now - start < seconds else { return }
                if now - turn > 1.5 { turn = now; send(0, phase: 4); direction = -direction; began = false }
                send(-direction * 12, phase: began ? 2 : 1)
                began = true
            }
        }
        RunLoop.main.add(clock, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { clock.invalidate(); send(0, phase: 4) }
    }
}

/// Debug builds only: a Debug menu in the menu bar, for what's easier to start with the mouse.
@MainActor
final class DebugMenu: NSObject, NSMenuItemValidation {
    static let shared = DebugMenu()

    static func install() {
        guard let main = NSApp.mainMenu, !main.items.contains(where: { $0.title == "Debug" }) else { return }
        let menu = NSMenu(title: "Debug")
        let measure = NSMenuItem(title: "Measure Frame Rate", action: #selector(measure(_:)), keyEquivalent: "")
        measure.target = shared
        menu.addItem(measure)
        let variants = NSMenu(title: "Glass Variant")
        for variant in GlassVariant.allCases {
            let item = NSMenuItem(title: variant.rawValue, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = shared
            item.representedObject = variant.rawValue
            variants.addItem(item)
        }
        let variantItem = NSMenuItem(title: "Glass Variant", action: nil, keyEquivalent: "")
        variantItem.submenu = variants
        menu.addItem(variantItem)
        let top = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        top.submenu = menu
        main.insertItem(top, at: max(0, main.items.count - 1))
    }

    static func apply(_ variant: GlassVariant) {
        GlassVariant.now = variant
        WindowManager.shared.controllers.forEach { $0.debugApplyGlassVariant() }
        debugLog("glass variant \(variant.rawValue)")
    }

    @objc func measure(_ sender: Any?) {
        guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
        FrameRateBench.run("6", in: controller)
    }

    @objc func choose(_ sender: NSMenuItem) {
        if let variant = (sender.representedObject as? String).flatMap(GlassVariant.init(rawValue:)) { Self.apply(variant) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(choose(_:)) { item.state = item.representedObject as? String == GlassVariant.now.rawValue ? .on : .off }
        return true
    }
}
#endif

#if DEBUG
/// perfsuite <plan.json>: measured scrolls of pages, for comparing Zigzag's tab with a plain web view. Each run loads a
/// page in the front tab (`tab`, less the page scripts named in `skip`) or in a plain web view laid over it (`bare`:
/// WebKit's defaults with Zigzag's feature flags and ad list, no scripts), waits, then scrolls it (`wheel`: trackpad
/// scrolls through the window at 120 Hz; `js`: scrollBy each animation frame; `idle`: none) and notes the page
/// process's and Zigzag's CPU time, Zigzag's main thread busy time, the page's animation frame gaps, and the messages
/// and script calls between page and Zigzag. Results go to the plan's `out` as JSON.
@MainActor
enum PerfBench {
    struct Run {
        var url: URL
        var variant: String
        var mode: String
        var seconds: Double
        var skip: Set<String>
        var settle: Double
        var name: String
    }

    private static var running = false
    /// Messages from scripts to Zigzag, by handler name, for the page measured.
    private static var messages: [String: Int] = [:]
    /// Scripts Zigzag ran in the page measured, by how.
    private static var scriptCalls: [String: Int] = [:]
    private static weak var measured: WKWebView?
    private static var counting = false

    // MARK: Plan

    static func run(_ arg: String) {
        guard !running, let data = FileManager.default.contents(atPath: arg),
              let plan = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { debugLog("perfsuite: no plan at \(arg)"); return }
        running = true
        installCounters()
        FramePacing.keepsRate = plan["keepRate"] as? Bool ?? true
        let out = plan["out"] as? String ?? arg + ".out.json"
        var runs: [Run] = []
        for entry in plan["runs"] as? [[String: Any]] ?? [] {
            guard let url = (entry["url"] as? String).flatMap(URL.init(string:)) else { continue }
            let run = Run(url: url, variant: entry["variant"] as? String ?? "tab", mode: entry["mode"] as? String ?? "wheel",
                          seconds: entry["seconds"] as? Double ?? 8, skip: Set(entry["skip"] as? [String] ?? []),
                          settle: entry["settle"] as? Double ?? 3, name: entry["name"] as? String ?? "")
            for _ in 0..<max(1, entry["repeat"] as? Int ?? 1) { runs.append(run) }
        }
        let quits = plan["quit"] as? Bool ?? false
        // Behind other apps, App Nap would slow the copy to a few frames a second partway through.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled], reason: "perfsuite")
        Task { @MainActor in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var results: [[String: Any]] = []
            for (i, run) in runs.enumerated() {
                debugLog("perfsuite \(i + 1)/\(runs.count) \(run.variant) \(run.mode) \(run.url.host() ?? "") skip=\(run.skip.sorted())")
                results.append(await measure(run))
                write(["runs": results, "done": false], to: out)
            }
            write(["runs": results, "done": true, "inventory": inventory()], to: out)
            running = false
            if quits { NSApp.terminate(nil) }
        }
    }

    private static func write(_ object: [String: Any], to path: String) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Page scripts

    /// A short name for a page script: its marking comment, the first handler it posts to, or its start.
    static func label(_ script: WKUserScript) -> String {
        let source = script.source
        let head = String(source.prefix(160))
        if head.hasPrefix("/* zigzag"), let end = head.range(of: "*/") {
            return String(head[head.index(head.startIndex, offsetBy: 3)..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if let range = source.range(of: "messageHandlers.") {
            let name = source[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name) }
        }
        if source.contains("__zigzagTyped") { return "pageState" }
        if source.contains("__zigzagSecret") { return "secretWatch" }
        return String(head.prefix(40)).replacingOccurrences(of: "\n", with: " ")
    }

    /// Every page script of the front tab, with its size and where it runs.
    private static func inventory() -> [[String: Any]] {
        guard let webView = WindowManager.shared.controllers.first?.tabManager.selectedTab?.webView else { return [] }
        return webView.configuration.userContentController.userScripts.map {
            ["label": label($0), "bytes": $0.source.utf8.count, "mainFrameOnly": $0.isForMainFrameOnly,
             "start": $0.injectionTime == .atDocumentStart]
        }
    }

    private static func filter(_ controller: WKUserContentController, skipping skip: Set<String>) -> [String] {
        guard !skip.isEmpty else { return [] }
        let all = controller.userScripts.map { $0 }
        let everything = skip.contains("*")
        let kept = all.filter { !everything && !skip.contains(label($0)) }
        guard kept.count != all.count else { return [] }
        controller.removeAllUserScripts()
        kept.forEach(controller.addUserScript)
        return all.filter { everything || skip.contains(label($0)) }.map(label)
    }

    private static func restore(_ controller: WKUserContentController, to scripts: [WKUserScript]) {
        controller.removeAllUserScripts()
        scripts.forEach(controller.addUserScript)
    }

    // MARK: Counting

    /// Counts the messages Zigzag's own handlers get, and the scripts it runs in pages.
    private static func installCounters() {
        var count: UInt32 = 0
        // Only Zigzag's own classes: touching every class in the process wakes some that abort.
        guard let image = class_getImageName(PageMessages.self), let names = objc_copyClassNamesForImage(image, &count) else { return }
        let plain = NSSelectorFromString("userContentController:didReceiveScriptMessage:")
        let reply = NSSelectorFromString("userContentController:didReceiveScriptMessage:replyHandler:")
        for i in 0..<Int(count) {
            guard let cls = objc_getClass(names[i]) as? AnyClass else { continue }
            var methods: UInt32 = 0
            guard let list = class_copyMethodList(cls, &methods) else { continue }
            for j in 0..<Int(methods) {
                let method = list[j]
                let name = method_getName(method)
                if name == plain {
                    typealias F = @convention(c) (AnyObject, Selector, AnyObject, WKScriptMessage) -> Void
                    let original = unsafeBitCast(method_getImplementation(method), to: F.self)
                    let block: @convention(block) (AnyObject, AnyObject, WKScriptMessage) -> Void = { object, controller, message in
                        counted(message)
                        original(object, plain, controller, message)
                    }
                    method_setImplementation(method, imp_implementationWithBlock(block))
                } else if name == reply {
                    typealias F = @convention(c) (AnyObject, Selector, AnyObject, WKScriptMessage, AnyObject) -> Void
                    let original = unsafeBitCast(method_getImplementation(method), to: F.self)
                    let block: @convention(block) (AnyObject, AnyObject, WKScriptMessage, AnyObject) -> Void = { object, controller, message, handler in
                        counted(message)
                        original(object, reply, controller, message, handler)
                    }
                    method_setImplementation(method, imp_implementationWithBlock(block))
                }
            }
            free(list)
        }
        for (selector, how) in [("evaluateJavaScript:completionHandler:", "evaluate"),
                                ("evaluateJavaScript:inFrame:inContentWorld:completionHandler:", "evaluateIn"),
                                ("callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", "callAsync")] {
            let sel = NSSelectorFromString(selector)
            guard let method = class_getInstanceMethod(WKWebView.self, sel) else { continue }
            switch method_getNumberOfArguments(method) {
            case 4:
                typealias F = @convention(c) (WKWebView, Selector, AnyObject, AnyObject?) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: F.self)
                let block: @convention(block) (WKWebView, AnyObject, AnyObject?) -> Void = { webView, a, b in
                    calledScript(webView, how)
                    original(webView, sel, a, b)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            case 6:
                typealias F = @convention(c) (WKWebView, Selector, AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: F.self)
                let block: @convention(block) (WKWebView, AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { webView, a, b, c, d in
                    calledScript(webView, how)
                    original(webView, sel, a, b, c, d)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            case 7:
                typealias F = @convention(c) (WKWebView, Selector, AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: F.self)
                let block: @convention(block) (WKWebView, AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void = { webView, a, b, c, d, e in
                    calledScript(webView, how)
                    original(webView, sel, a, b, c, d, e)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            default:
                break
            }
        }
    }

    nonisolated private static func counted(_ message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard counting, message.webView === measured else { return }
            let type = ((message.body as? [String: Any])?["type"] as? String).map { ":" + $0 } ?? ""
            messages[message.name + type, default: 0] += 1
        }
    }

    nonisolated private static func calledScript(_ webView: WKWebView, _ how: String) {
        MainActor.assumeIsolated {
            guard counting, webView === measured else { return }
            scriptCalls[how, default: 0] += 1
        }
    }

    // MARK: Clocks

    private static let ticksToNanos: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom)
    }()

    /// CPU time of a process, in ms.
    private static func cpu(_ pid: pid_t) -> Double? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { return nil }
        return Double(info.ri_user_time + info.ri_system_time) * ticksToNanos / 1_000_000
    }

    /// CPU time of Zigzag's main thread, in ms.
    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    private static func pid(_ webView: WKWebView, _ key: String) -> pid_t {
        guard webView.responds(to: NSSelectorFromString(key)) else { return 0 }
        return (webView.value(forKey: key) as? NSNumber)?.int32Value ?? 0
    }

    /// Main thread busy time: from each wake of the main run loop to its next wait.
    private final class Busy {
        var total = 0.0
        var longest = 0.0
        var over16 = 0
        var over50 = 0
        private var last = CACurrentMediaTime()
        private var awake = true
        private var segment = 0.0
        private var observer: CFRunLoopObserver?

        func start() {
            // Last of the run loop's observers, so the drawing Core Animation does before a wait counts.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, CFIndex.max) { [unowned self] _, activity in
                let now = CACurrentMediaTime()
                if self.awake {
                    let gap = (now - self.last) * 1000
                    self.total += gap
                    self.segment += gap
                }
                if activity == .beforeWaiting || activity == .exit {
                    if self.segment > 16 { self.over16 += 1 }
                    if self.segment > 50 { self.over50 += 1 }
                    self.longest = max(self.longest, self.segment)
                    self.segment = 0
                    self.awake = false
                } else {
                    self.awake = true
                }
                self.last = now
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }
    }

    // MARK: A run

    private static func wait(for webView: WKWebView, timeout: Double = 25) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while Date() < end, webView.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private static var overlay: WKWebView?

    /// `with`: Zigzag's own settings added one by one (`store`, `ext`, `dev`, `fraud`), or `config` for the whole of
    /// `WebKitSetup.makeConfiguration` with none of a tab's own work.
    private static func bareWebView(over page: WKWebView, with: Set<String> = [], profile: Profile) -> WKWebView {
        overlay?.removeFromSuperview()
        let configuration = with.contains("config") ? WebKitSetup.makeConfiguration(for: profile) : WKWebViewConfiguration()
        if !with.contains("config") {
            configuration.websiteDataStore = with.contains("store") ? profile.store : .nonPersistent()
            configuration.applicationNameForUserAgent = WebKitSetup.applicationNameForUserAgent
            FeatureFlags.apply(to: configuration.preferences)
            if ContentBlocker.isEnabled, let list = ContentBlocker.activeList { configuration.userContentController.add(list) }
            if #available(macOS 15.4, *), with.contains("ext") { configuration.webExtensionController = profile.extensions.controller }
            if with.contains("dev") { configuration.preferences.setValue(true, forKey: "developerExtrasEnabled") }
            configuration.preferences.isFraudulentWebsiteWarningEnabled = with.contains("fraud")
        }
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: page.frame, configuration: configuration)
        webView.autoresizingMask = page.autoresizingMask
        page.superview?.addSubview(webView, positioned: .above, relativeTo: page)
        Tab.setWatchesCover(false, of: webView)
        overlay = webView
        return webView
    }

    private static func measure(_ run: Run) async -> [String: Any] {
        var result: [String: Any] = ["name": run.name, "url": run.url.absoluteString, "variant": run.variant, "mode": run.mode,
                                     "seconds": run.seconds, "skip": run.skip.sorted()]
        guard let controller = WindowManager.shared.controllers.first, let tab = controller.tabManager.selectedTab,
              let page = tab.webView, let window = page.window else { result["error"] = "no tab"; return result }
        var webView: WKWebView = page
        var snapshot: [WKUserScript]?
        let scripts = page.configuration.userContentController
        overlay?.removeFromSuperview()
        overlay = nil
        tab.load(URL(string: "about:blank")!)
        await wait(for: page)
        if run.variant.hasPrefix("bare") {
            let with = Set(run.variant.split(separator: ":").dropFirst().first.map { $0.split(separator: ",").map(String.init) } ?? [])
            webView = bareWebView(over: page, with: with, profile: tab.profile)
            webView.load(URLRequest(url: run.url))
            await wait(for: webView)
        } else {
            snapshot = scripts.userScripts.map { $0 }
            result["scripts"] = scripts.userScripts.count
            result["removed"] = filter(scripts, skipping: run.skip)
            debugLog("perfsuite scripts \(scripts.userScripts.count) of \(snapshot?.count ?? 0)")
            tab.load(run.url)
            await wait(for: page)
            debugLog("perfsuite loaded \(page.url?.absoluteString ?? "")")
            // Scripts Zigzag puts back on its way to a page: taken out again, and the page loaded once more.
            let back = run.skip.contains("*") ? scripts.userScripts.map(label) : scripts.userScripts.map(label).filter(run.skip.contains)
            if !back.isEmpty {
                result["putBack"] = back
                _ = filter(scripts, skipping: run.skip)
                page.reload()
                await wait(for: page)
            }
        }
        try? await Task.sleep(for: .seconds(run.settle))
        _ = try? await webView.callAsyncJavaScript("window.scrollTo(0, 0)", arguments: [:], in: nil, contentWorld: .defaultClient)
        try? await Task.sleep(for: .milliseconds(400))
        debugLog("perfsuite measuring")

        let screenFPS = Double(window.screen?.maximumFramesPerSecond ?? 60)
        let webContent = pid(webView, "_webProcessIdentifier")
        let gpu = pid(webView, "_gpuProcessIdentifier")
        var changes: [String: Int] = [:]
        let token = run.variant == "tab" ? tab.changed.observe { change in changes["\(change)", default: 0] += 1 } : nil
        messages = [:]
        scriptCalls = [:]
        measured = webView
        let busy = Busy()
        let started = (wc: cpu(webContent), gpu: cpu(gpu), app: cpu(getpid()), main: mainThreadCPU(), at: CACurrentMediaTime())
        counting = true
        busy.start()

        // Trackpad-like scrolls through the window, 12 pt at 120 Hz, down for 2 s then up for 1 s.
        var sender: Timer?
        if run.mode == "wheel" {
            let inWindow = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
            let onScreen = window.convertPoint(toScreen: inWindow)
            let at = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y)
            let begin = CACurrentMediaTime()
            var began = false
            var down = true
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let downNow = (CACurrentMediaTime() - begin).truncatingRemainder(dividingBy: 3) < 2
                    if downNow != down {
                        down = downNow
                        began = false
                        if let end = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) {
                            end.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
                            end.location = at
                            if let e = NSEvent(cgEvent: end) { window.sendEvent(e) }
                        }
                    }
                    let dy: Int32 = down ? -12 : 12
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
                    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: began ? 2 : 1)
                    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
                    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
                    cg.location = at
                    cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                    cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                    began = true
                    if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            sender = timer
        }
        let script = """
        const gaps = []; let last = 0, dir = 1, y0 = scrollY, moved = 0;
        const end = performance.now() + seconds * 1000;
        await new Promise((done) => {
          const frame = (t) => {
            if (last) gaps.push(t - last);
            last = t;
            if (mode === 'js') {
              const max = document.scrollingElement.scrollHeight - innerHeight;
              if (scrollY >= max - 1) dir = -1; else if (scrollY <= 0) dir = 1;
              window.scrollBy(0, dir * 12);
            }
            moved += Math.abs(scrollY - y0); y0 = scrollY;
            if (t < end) requestAnimationFrame(frame); else done();
          };
          requestAnimationFrame(frame);
        });
        return JSON.stringify({ gaps, moved, height: document.scrollingElement.scrollHeight,
          nodes: document.getElementsByTagName('*').length, visibility: document.visibilityState });
        """
        let value = try? await webView.callAsyncJavaScript(script, arguments: ["mode": run.mode, "seconds": run.seconds], in: nil, contentWorld: .defaultClient)
        sender?.invalidate()
        counting = false
        busy.stop()
        token?.cancel()
        func delta(_ before: Double?, _ after: Double?) -> Any { before.flatMap { b in after.map { $0 - b } } ?? NSNull() }
        result["ms"] = (CACurrentMediaTime() - started.at) * 1000
        result["webContentCPU"] = delta(started.wc, cpu(webContent))
        result["gpuCPU"] = delta(started.gpu, cpu(gpu))
        result["appCPU"] = delta(started.app, cpu(getpid()))
        result["mainThreadCPU"] = mainThreadCPU() - started.main
        result["mainBusy"] = busy.total
        result["mainLongest"] = busy.longest
        result["mainOver16"] = busy.over16
        result["mainOver50"] = busy.over50
        result["messages"] = messages
        result["messageCount"] = messages.values.reduce(0, +)
        result["scriptCalls"] = scriptCalls
        result["changes"] = changes
        result["screenFPS"] = screenFPS
        result["occluded"] = !window.occlusionState.contains(.visible)
        result["near60"] = FramePacing.holds(webView)
        if let text = value as? String, let data = text.data(using: .utf8),
           let measuredPage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let gaps = measuredPage["gaps"] as? [Double] ?? []
            let interval = 1000 / screenFPS
            let missed = gaps.reduce(0) { $0 + max(0, Int(($1 / interval).rounded()) - 1) }
            let sorted = gaps.sorted()
            func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            result["frames"] = gaps.count
            result["fps"] = gaps.isEmpty ? 0 : 1000 * Double(gaps.count) / gaps.reduce(0, +)
            result["missed"] = missed
            result["missedShare"] = gaps.isEmpty ? 0 : Double(missed) / Double(missed + gaps.count)
            result["gapP50"] = pct(0.5)
            result["gapP95"] = pct(0.95)
            result["gapP99"] = pct(0.99)
            result["gapMax"] = sorted.last ?? 0
            result["over2frames"] = gaps.filter { $0 > interval * 2.5 }.count
            result["moved"] = measuredPage["moved"]
            result["height"] = measuredPage["height"]
            result["nodes"] = measuredPage["nodes"]
            result["visibility"] = measuredPage["visibility"]
        } else {
            result["error"] = "page script failed"
        }
        if let snapshot { restore(scripts, to: snapshot) }
        overlay?.removeFromSuperview()
        overlay = nil
        return result
    }
}
#endif

#if DEBUG
/// idle audit <path> | idle back | idle front | idle stopanims | idle clearbg [class]: what keeps the window server drawing windows
/// that sit still; `back` orders them behind every other app's, `clearbg` makes shadowed see-through windows wholly clear again.
@MainActor
enum IdleWorkCommand {
    static func run(_ arg: String) {
        let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let windows = NSApp.windows.filter(\.isVisible)
        switch f.first {
        case "audit":
            let rows: [[String: Any]] = windows.map { window in
                ["class": "\(type(of: window))", "frame": NSStringFromRect(window.frame), "opaque": window.isOpaque,
                 "background": window.backgroundColor.description, "shadow": window.hasShadow,
                 "occlusionVisible": window.occlusionState.contains(.visible), "key": window.isKeyWindow,
                 "firstResponder": window.firstResponder.map { "\(type(of: $0))" } ?? "none",
                 "animations": IdleWork.animations(in: window, longerThan: 1), "blurs": IdleWork.liveBlurs(in: window),
                 "hdr": IdleWork.extendedRangeLayers(in: window), "glass": (window.contentView as? SpaceFrameView)?.debugGlass ?? [:]]
            }
            if let path = f.dropFirst().first, let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        case "back": windows.forEach { $0.orderBack(nil) }
        case "front": windows.forEach { $0.orderFrontRegardless() }
        case "powerpulse":
            // powerpulse <n>: the power source reports a change once a second, n times, as some Macs' do.
            let n = f.dropFirst().first.flatMap { Int($0) } ?? 10
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) { NotificationCenter.default.post(name: PowerSaving.changed, object: nil) }
            }
        case "librarypulse":
            // librarypulse <n>: the library says it changed once a second, n times, with nothing changed.
            let n = f.dropFirst().first.flatMap { Int($0) } ?? 10
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) { MainActor.assumeIsolated { Library.shared.changed.send() } }
            }
        case "clearbg":
            let only = f.dropFirst().first
            windows.filter { !$0.isOpaque && $0.hasShadow && (only == nil || "\(type(of: $0))" == only) }.forEach { $0.backgroundColor = .clear }
        case "stopanims":
            func walk(_ layer: CALayer) {
                for key in layer.animationKeys() ?? [] where layer.animation(forKey: key).map(IdleWork.isEndless) == true {
                    layer.removeAnimation(forKey: key)
                }
                (layer.sublayers ?? []).forEach(walk)
            }
            windows.compactMap { $0.contentView?.superview?.layer }.forEach(walk)
        default: break
        }
    }
}
#endif

#if DEBUG
/// Debug only: counts view redraws, layouts and layer changes while on, by kind, class and the app's caller.
@MainActor
enum RedrawCounter {
    nonisolated(unsafe) private(set) static var isOn = false
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated private static let offMain = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
    private static var swapped = false

    private static let swaps: [(AnyClass, String, String)] = [
        (NSView.self, "setNeedsDisplayInRect:", "zz_setNeedsDisplayInRect:"),
        (NSView.self, "setNeedsLayout:", "zz_setNeedsLayout:"),
        (NSView.self, "layout", "zz_layout"),
        (NSView.self, "drawRect:", "zz_drawRect:"),
        (CALayer.self, "setNeedsDisplay", "zz_setNeedsDisplay"),
        (CALayer.self, "display", "zz_display"),
        (CALayer.self, "setOpacity:", "zz_setOpacity:"),
        (CALayer.self, "setBackgroundColor:", "zz_setBackgroundColor:"),
        (CALayer.self, "setContents:", "zz_setContents:"),
        (CALayer.self, "setHidden:", "zz_setHidden:"),
        (CALayer.self, "setPosition:", "zz_setPosition:"),
        (CALayer.self, "setBounds:", "zz_setBounds:"),
        (CALayer.self, "addAnimation:forKey:", "zz_addAnimation:forKey:"),
    ]

    private static func exchange() {
        swapped.toggle()
        for (cls, original, stand) in swaps {
            if let a = class_getInstanceMethod(cls, NSSelectorFromString(original)),
               let b = class_getInstanceMethod(cls, NSSelectorFromString(stand)) {
                method_exchangeImplementations(a, b)
            }
        }
    }

    static func start() {
        counts = [:]
        if !swapped { exchange() }
        isOn = true
    }

    /// Stops counting and returns "kind class <- caller" with how many times, most first.
    static func stop() -> [(String, Int)] {
        isOn = false
        if swapped { exchange() }
        offMain.withLock { counts.merge($0, uniquingKeysWith: +); $0 = [:] }
        return counts.sorted { $0.value > $1.value }
    }

    nonisolated static func note(_ kind: String, _ object: AnyObject) {
        guard isOn else { return }
        guard Thread.isMainThread else {
            let key = "\(kind) \(type(of: object)) off main"
            offMain.withLock { $0[key, default: 0] += 1 }
            return
        }
        do {
            isOn = false
            defer { isOn = true }
            let name: String
            let owner: AnyObject = (object as? CALayer)?.delegate ?? object
            var named = "\(type(of: owner))"
            if let view = owner as? NSView {
                if let field = view as? NSTextField { named += " '\(field.stringValue.prefix(24))'" }
                named += " in \(view.superview.map { "\(type(of: $0))" } ?? "-")/\(view.superview?.superview.map { "\(type(of: $0))" } ?? "-")"
                if view.window == nil { named += " no window" }
            }
            name = named
            // The first frames of the app's own code above this call.
            let caller = Thread.callStackSymbols.dropFirst(2).map { $0.split(separator: " ", omittingEmptySubsequences: true) }
                .filter { $0.count > 3 && $0[1].hasPrefix("Zigzag") && !$0[3].contains("zz_") && !$0[3].contains("RedrawCounter") }
                .prefix(8).map { String($0[3]) }
            counts["\(kind) \(name) <- \(caller.joined(separator: " | "))", default: 0] += 1
        }
    }

    /// redraws key: the app counts as active and its windows as key from now on, as if in front.
    static func pretendKey() {
        for (cls, original, stand) in [(NSWindow.self as AnyClass, "isKeyWindow", "zz_isKeyWindow"), (NSWindow.self, "isMainWindow", "zz_isKeyWindow"),
                                       (NSApplication.self, "isActive", "zz_isActive")] {
            if let a = class_getInstanceMethod(cls, NSSelectorFromString(original)), let b = class_getInstanceMethod(cls, NSSelectorFromString(stand)) {
                method_setImplementation(a, method_getImplementation(b))
            }
        }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for window in NSApp.windows where window.isVisible {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        }
    }

    /// redraws <seconds> <path>: counts for that long, then writes the counts as JSON.
    static func run(_ arg: String) {
        if arg == "key" { pretendKey(); return }
        let f = arg.split(separator: " ").map(String.init)
        guard f.count >= 2, let seconds = Double(f[0]) else { return }
        start()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                let rows = stop().map { ["what": $0.0, "count": $0.1] as [String: Any] }
                if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: f[1]))
                }
            }
        }
    }
}

extension NSView {
    // After the exchange, these names call AppKit's own.
    @objc func zz_setNeedsDisplayInRect(_ rect: NSRect) { RedrawCounter.note("needsDisplay", self); zz_setNeedsDisplayInRect(rect) }
    @objc func zz_setNeedsLayout(_ flag: Bool) { if flag { RedrawCounter.note("needsLayout", self) }; zz_setNeedsLayout(flag) }
    @objc func zz_layout() { RedrawCounter.note("layout", self); zz_layout() }
    @objc func zz_drawRect(_ rect: NSRect) { RedrawCounter.note("draw", self); zz_drawRect(rect) }
}

extension NSWindow {
    @objc func zz_isKeyWindow() -> Bool { isVisible }
}

extension NSApplication {
    @objc func zz_isActive() -> Bool { true }
}

extension CALayer {
    @objc func zz_setNeedsDisplay() { RedrawCounter.note("layerNeedsDisplay", self); zz_setNeedsDisplay() }
    @objc func zz_display() { RedrawCounter.note("layerDisplay", self); zz_display() }
    @objc func zz_setOpacity(_ value: Float) { if value != opacity { RedrawCounter.note("opacity", self) }; zz_setOpacity(value) }
    @objc func zz_setBackgroundColor(_ value: CGColor?) { if value != backgroundColor { RedrawCounter.note("backgroundColor", self) }; zz_setBackgroundColor(value) }
    @objc func zz_setContents(_ value: Any?) { RedrawCounter.note("contents", self); zz_setContents(value) }
    @objc func zz_setHidden(_ value: Bool) { if value != isHidden { RedrawCounter.note("hidden", self) }; zz_setHidden(value) }
    @objc func zz_setPosition(_ value: CGPoint) { if value != position { RedrawCounter.note("position", self) }; zz_setPosition(value) }
    @objc func zz_setBounds(_ value: CGRect) { if value != bounds { RedrawCounter.note("bounds", self) }; zz_setBounds(value) }
    @objc func zz_addAnimation(_ animation: CAAnimation, forKey key: String?) { RedrawCounter.note("animation \(key ?? "-")", self); zz_addAnimation(animation, forKey: key) }
}
#endif
