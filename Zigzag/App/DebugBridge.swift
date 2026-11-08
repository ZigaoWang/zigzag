import AppKit
import WebKit

/// Debug builds only: lets scripts drive the UI (for screenshots and testing) via distributed notifications.
/// `xcrun swift -e` or the bundled `zz` script posts "app.zigzag.debug" with a command string.
enum DebugBridge {
    #if DEBUG
    static var hovered: [NSView] = []
    private static var scrollLog: [String] = []

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
        DistributedNotificationCenter.default().addObserver(forName: .init(channel), object: nil, queue: .main) { note in
            let command = (note.object as? String) ?? ""
            MainActor.assumeIsolated { run(command) }
        }
        #endif
    }

    #if DEBUG
    static func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
        switch name {
        case "open": if let url = URL(string: arg) { controller.open(url, disposition: .foregroundTab, allowSwitch: false) }
        case "bg": if let url = URL(string: arg) { controller.open(url, disposition: .backgroundTab, allowSwitch: false) }
        case "load": if let url = URL(string: arg) { controller.open(url, disposition: .currentTab) }
        case "sidebar": controller.toggleBrowserSidebar(nil)
        case "reveal": controller.root.holdReveal = arg == "hold"; controller.root.reveal(true)
        case "unreveal": controller.root.holdReveal = false; controller.root.reveal(false)
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
        case "markedfolder": controller.newFolder(with: controller.pinnedIDs(for: controller.sidebar.list.marked)); controller.sidebar.list.clearMarks()
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
        case "suspendtab": controller.tabManager.allTabs.first { $0.url?.absoluteString.hasPrefix(arg) == true }?.suspend()
        case "space": controller.tabManager.switchSpace(by: Int(arg) ?? 1)
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
        case "closetab": controller.closeTab(nil)
        case "flydownload": controller.debugFlyDownload(arg.isEmpty ? "Shanghai Guide.pdf" : arg)
        case "readerjs":
            controller.debugReaderWebView?.evaluateJavaScript(arg) { result, error in
                debugLog("readerjs => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "find": controller.findBar.show(query: arg)
        case "peek": if let url = URL(string: arg) { controller.open(url, disposition: .peek) }
        case "peekclose": controller.peek.close()
        case "switcher": controller.debugSwitcher()
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
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
        case "edgedrag": controller.root.debugEdgeDrag(arg)
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
        case "action": controller.sidebar.address.actionButtons[min(Int(arg) ?? 0, controller.sidebar.address.actionButtons.count - 1)].onClick?(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
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
            if let folder = Library.shared.folders(in: controller.tabManager.currentSpaceID).first { controller.listSetFolderOpen(folder.id, !folder.isOpen) }
        case "listhover": controller.sidebar.list.debugHover(arg != "off")
        case "autofillhint":
            if let webView = controller.selectedWebView as? BrowserWebView { Autofill.shared.debugShow(arg, in: webView) }
        case "autofillmenu":
            debugLog("autofillmenu => \(Autofill.shared.isShowing)")
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
            if #available(macOS 15.4, *), let webView = ExtensionHost.shared.lastAction?.popupWebView {
                let source = "window.__errors = []; addEventListener('error', e => __errors.push(e.message + ' @' + (e.filename||'').split('/').pop() + ':' + e.lineno)); addEventListener('unhandledrejection', e => __errors.push('rejection: ' + (e.reason && (e.reason.message || e.reason))));"
                webView.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                webView.reload()
            }
        case "webstate":
            // webstate: where the tab in front's page is, as WebKit sees it (for a page that never answers scripts).
            if let view = controller.selectedWebView {
                debugLog("webstate url=\(view.url?.absoluteString ?? "-") loading=\(view.isLoading) progress=\(view.estimatedProgress) title=\(view.title ?? "-")")
            }
        case "popupjs":
            if #available(macOS 15.4, *), let webView = ExtensionHost.shared.lastAction?.popupWebView {
                webView.evaluateJavaScript(arg) { result, error in
                    debugLog("popupjs => \(String(describing: result).prefix(2000)) \(String(describing: error))")
                }
            } else { debugLog("popupjs: no popup") }
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
        case "popupjs":
            // Runs a script in the extension popup that's showing, to drive a real extension as you would.
            if #available(macOS 15.4, *) {
                ExtensionHost.shared.lastAction?.popupWebView?.evaluateJavaScript(arg) { result, error in
                    debugLog("popupjs => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
                }
            }
        case "slowmo":
            // slowmo <factor>: every animation in the window runs that many times slower, to film and judge it.
            let factor = max(1, Float(arg) ?? 1)
            controller.window?.contentView?.layer?.speed = 1 / factor
        case "quit": NSApp.terminate(nil)
        case "materials": MaterialsShowcase.debug(arg)
        case "history": HistoryPage.open(in: controller)
        case "newwindow": WindowManager.shared.newWindow(url: URL(string: arg), showCommandBar: false)
        case "closekey": WindowManager.shared.keyController?.window?.performClose(nil)
        case "reopenwindow": WindowManager.shared.reopenClosedWindow()
        case "whatsnew": WhatsNew.show(in: controller)
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
        case "closewindow":
            // closewindow <title>: closes Zigzag's window with that title (Import, Passwords, Settings).
            NSApp.windows.first { $0.title == arg }?.close()
        case "importsuccess":
            ImportWindowController.show()
            (ImportWindowController.shared?.window?.contentView as? ImportView)?.debugShowSuccess()
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
            let named: [String: String] = ["esc": "\u{1b}", "tab": "\t", "return": "\r", "space": " ",
                                           "down": String(UnicodeScalar(NSDownArrowFunctionKey)!), "up": String(UnicodeScalar(NSUpArrowFunctionKey)!)]
            let chars = named[ch] ?? ch
            let codes: [String: UInt16] = ["s": 1, "j": 38, "t": 17, "l": 37, "w": 13, "esc": 53, "tab": 48, "f": 3, "r": 15, "p": 35,
                                          "down": 125, "up": 126, "return": 36, "space": 49]
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: codes[ch] ?? 0) {
                NSApp.postEvent(e, atStart: false)
            }
        case "listscroll": controller.sidebar.debugListScroll(Double(arg).map { CGFloat($0) })
        case "menukey":
            // menukey <char> [cmd|shift|ctrl|opt...]: the key equivalent as the menu bar sees it, then as the window does
            // (which is where a real key press goes), logging which one took it.
            let f = arg.split(separator: " ").map(String.init)
            guard let ch = f.first, let window = controller.window else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in f.dropFirst() {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "ctrl": flags.insert(.control); case "opt": flags.insert(.option); default: break }
            }
            let codes: [String: UInt16] = ["w": 13, "t": 17, "c": 8, "d": 2, "z": 6, "l": 37]
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                           isARepeat: false, keyCode: codes[ch] ?? 0) else { break }
            if NSApp.isActive, NSApp.keyWindow === window {
                // Frontmost: the real path, window first, then the menu bar.
                let handled = window.performKeyEquivalent(with: e)
                debugLog("menukey \(arg): handled=\(handled) tabs=\(controller.tabManager.currentTabs.count) selected=\(controller.tabManager.selectedTab?.displayTitle ?? "nil")")
                break
            }
            // Behind another app there's no key window for the menu to send to, so do what it would: find the item with
            // this key, then the first responder in this window's chain that takes its action, validated as a menu would.
            func find(in menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if let sub = item.submenu, let found = find(in: sub) { return found }
                    if item.keyEquivalent == ch, item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == flags, item.action != nil { return item }
                }
                return nil
            }
            guard let menuItem = NSApp.mainMenu.flatMap(find(in:)), let action = menuItem.action else { debugLog("menukey \(arg): no item"); break }
            var responder: NSResponder? = window.firstResponder ?? window
            while let r = responder, !r.responds(to: action) { responder = r.nextResponder }
            let target: AnyObject? = responder ?? (NSApp.responds(to: action) ? NSApp : NSApp.delegate as AnyObject?)
            let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(menuItem) ?? true
            if enabled { NSApp.sendAction(action, to: target, from: menuItem) }
            debugLog("menukey \(arg): item=\(menuItem.title) target=\(target.map { "\(type(of: $0))" } ?? "nil") enabled=\(enabled) tabs=\(controller.tabManager.currentTabs.count) selected=\(controller.tabManager.selectedTab?.displayTitle ?? "nil") peek=\(controller.peek.isVisible) bar=\(controller.commandBar.isVisible)")
        case "tlshot":
            if let image = (controller.window as? BrowserWindow)?.trafficLightsImage(), let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: arg))
            }
        case "swipe":
            // swipe <dx per step>: a synthetic two-finger horizontal swipe over the sidebar.
            let parts = arg.split(separator: " ")
            guard let window = controller.window, let first = parts.first, let dx = Int32(first) else { break }
            let phaseless = parts.contains("nophase")
            // "page": over the middle of the page instead.
            let onPage = parts.contains("page")
            let screenPoint = window.convertPoint(toScreen: onPage ? NSPoint(x: window.frame.width * 0.6, y: window.frame.height / 2) : NSPoint(x: 100, y: window.frame.height - 300))
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
        case "copylink": controller.copyPageURL(nil)
        case "zoomout": controller.zoomOut(nil)
        case "scrolllog": try? scrollLog.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "settings": SettingsPage.open(in: controller)
        case "engine": if let engine = SearchEngine(rawValue: arg) { Library.shared.searchEngine = engine }
        case "largenames": SpaceHeaderView.isLarge = arg != "off"
        case "sitepanel": SitePanel.toggle(in: controller, from: controller.sidebar.address)
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
        case "about": AboutWindowController.show()
        case "acknowledgements": AcknowledgementsWindowController.show()
        case "exttest":
            // exttest <id> <url>: a fresh install, a page where it should work, then what happened, as one line.
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let page = URL(string: f[1]), #available(macOS 15.4, *) else { break }
            Task { @MainActor in await DebugBridge.extensionTest(f[0], page: page, in: controller) }
        case "reader": controller.toggleReader()
        case "ua": controller.selectedWebView?.customUserAgent = arg.isEmpty ? nil : arg; controller.selectedWebView?.reload()
        case "readerstyle":
            func find(_ v: NSView) -> ReaderControls? { (v as? ReaderControls) ?? v.subviews.lazy.compactMap(find).first }
            if let content = controller.window?.contentView { find(content)?.toggleOptions() }
        case "hidetoasts": Toast.hide(in: controller)
        case "clearsite":
            // clearsite <cache|cookies> <site>
            let f = arg.split(separator: " ").map(String.init)
            if f.count == 2 { Task { await WebsiteData.clear(f[0] == "cache" ? .cache : .cookies, site: f[1]); debugLog("cleared \(f[0]) for \(f[1])") } }
        case "cmd": controller.commandBar.runAction(arg)
        case "settingsfind": controller.tabManager.selectedTab?.settingsView?.debugFind(arg)
        case "settingsbottom":
            if let root = controller.tabManager.selectedTab?.settingsView,
               let scroll = root.subviews.compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
            }
        case "settingspane":
            // settingspane <general|spaces|passwords|privacy|translation|extensions|shortcuts>
            SettingsPage.open(SettingsPane.allCases.first { "\($0)" == arg }, in: controller)
        case "allowads": ContentBlocker.setAllowed(arg != "off", on: controller.tabManager.selectedTab?.url); controller.tabManager.selectedTab?.reload()
        case "addext": controller.installExtension(arg)
        case "storeadd": WebStoreOffer.debugAdd()
        case "sheetcancel": ExtensionSheet.debugCancel()
        case "addextnow": Task { _ = await ExtensionStore.install(arg) }
        case "rmext": ExtensionStore.uninstall(arg)
        case "extupdate": Task { await ExtensionStore.updateIfNewer(arg) }
        case "extreinstall":
            // Removes and freshly installs an extension, as a new user would get it.
            if #available(macOS 15.4, *) {
                ExtensionStore.uninstall(arg)
                Task { let r = await ExtensionStore.install(arg); debugLog("extreinstall \(arg) \(r)") }
            }
        case "extclickpanel":
            // As if clicked in the site panel.
            if #available(macOS 15.4, *), let panel = SitePanel.shown, let anchor = panel.subviews.first?.subviews.last ?? panel.subviews.first,
               let item = ExtensionHost.shared.actions(for: controller.tabManager.selectedTab).first(where: { $0.id == arg }) {
                ExtensionHost.shared.performAction(item, tab: controller.tabManager.selectedTab, anchor: anchor)
            }
        case "extclick":
            // extclick <extension id>: clicks its button, as from the site panel.
            if #available(macOS 15.4, *), let item = ExtensionHost.shared.actions(for: controller.tabManager.selectedTab).first(where: { $0.id == arg }) {
                debugLog("extclick \(item.label) attention=\(item.attention != nil)")
                ExtensionHost.shared.performAction(item, tab: controller.tabManager.selectedTab, anchor: controller.sidebar.address)
            } else { debugLog("extclick: no action for \(arg)") }
        case "loadunpacked": Task { _ = await ExtensionStore.loadUnpacked(URL(fileURLWithPath: arg, isDirectory: true)) }
        case "extaccess":
            // extaccess <id> <all|click|sites> [site,site]
            let f = arg.split(separator: " ").map(String.init)
            if f.count >= 2, let access = ExtensionStore.SiteAccess(rawValue: f[1]) {
                ExtensionStore.setSiteAccess(f[0], access, sites: f.count > 2 ? f[2].split(separator: ",").map(String.init) : nil)
            }
        case "extoffsite":
            // extoffsite <site> on|off
            let f = arg.split(separator: " ").map(String.init)
            if f.count == 2 { var sites = ExtensionStore.extensionsOffSites; if f[1] == "on" { sites.insert(f[0]) } else { sites.remove(f[0]) }; ExtensionStore.extensionsOffSites = sites }
        case "extpopupstate":
            // extpopupstate <id> [script]: where its popup page is, even before WebKit asks to show it.
            if #available(macOS 15.4, *), let item = ExtensionHost.shared.actions(for: controller.tabManager.selectedTab).first(where: { $0.id == String(arg.prefix { $0 != " " }) }),
               let view = item.context.action(for: controller.tabManager.selectedTab)?.popupWebView {
                let script = arg.contains(" ") ? String(arg.drop { $0 != " " }.dropFirst()) : "document.readyState"
                debugLog("extpopupstate url=\(view.url?.absoluteString ?? "-") loading=\(view.isLoading) progress=\(view.estimatedProgress) size=\(view.frame.size)")
                view.evaluateJavaScript(script) { result, error in debugLog("extpopupstate => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")") }
            } else { debugLog("extpopupstate: no popup page") }
        case "extpopup":
            if let item = ExtensionHost.shared.actions(for: controller.tabManager.selectedTab).first(where: { $0.id == arg }) {
                ExtensionHost.shared.performAction(item, tab: controller.tabManager.selectedTab, anchor: controller.sidebar.address)
            }
        case "extapprove": Task { await ExtensionStore.approvePendingUpdate(arg) }
        case "extoff": ExtensionStore.setEnabled(arg, false)
        case "exton": ExtensionStore.setEnabled(arg, true)
        case "settingsid":
            // Settings is a tab now: its window is the browser window it's in.
            if let w = controller.window { try? "\(w.windowNumber)".write(toFile: arg, atomically: true, encoding: .utf8) }
        case "editspace": controller.openSpaceEditor(controller.tabManager.currentSpaceID, anchor: arg == "dot" ? controller.sidebar.dot(for: controller.tabManager.currentSpaceID) : controller.sidebar.list.headerView)
        case "pagemove":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, let window = controller.window, let webView = controller.selectedWebView,
               let e = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: n[0], y: window.frame.height - n[1]), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 0, pressure: 0) {
                webView.mouseMoved(with: e)
            }
        case "closetab": controller.closeTab(nil)
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
                debugLog("audio \(tab.displayTitle.prefix(30)) playing=\(tab.isPlayingAudio) kvo=\(state)")
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
        case "private": WindowManager.shared.newWindow(url: URL(string: arg), isPrivate: true)
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
            if name == "addfav" { _ = Library.shared.addFavorite(url: url, title: title) }
            else { _ = Library.shared.addBookmark(url: url, title: title, to: controller.tabManager.currentSpaceID) }
        case "unfavorite":
            // unfavorite <title>: back to a tab, in whichever window holds its page.
            if let favorite = Library.shared.favorites.first(where: { $0.title == arg }) {
                let owner = WindowManager.shared.controllers.first { $0.tabManager.bookmarkTab(for: favorite.id) != nil } ?? controller
                owner.tabManager.unbookmark(favorite.id, toIndex: 0)
            }
        case "split":
            let tabs = controller.tabManager.currentTabs
            if let current = controller.tabManager.selectedTab, let other = tabs.first(where: { $0 !== current }) {
                controller.tabManager.makeSplit(current, with: other)
            }
        case "save": WindowManager.shared.saveNow()
        case "quit": NSApp.terminate(nil)
        case "materials": MaterialsShowcase.debug(arg)
        default: break
        }
    }

    @available(macOS 15.4, *)
    static func extensionTest(_ id: String, page: URL, in controller: BrowserWindowController) async {
        var report: [String: Any] = ["id": id]
        let had = ExtensionStore.state(id) != nil
        let started = Date()
        if !had { report["install"] = String(describing: await ExtensionStore.install(id)).prefix(160) }
        report["installSeconds"] = Int(Date().timeIntervalSince(started))
        for _ in 0..<60 {
            if ExtensionHost.shared.contexts.contains(where: { $0.uniqueIdentifier == id }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let context = ExtensionHost.shared.contexts.first { $0.uniqueIdentifier == id }
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
        let item = ExtensionHost.shared.actions(for: tab).first { $0.id == id }
        report["button"] = item != nil
        report["badge"] = item?.badge ?? ""
        report["needsAttention"] = item?.attention != nil
        if let item {
            ExtensionHost.shared.lastAction = nil
            let tabs = controller.tabManager.currentTabs.count
            ExtensionHost.shared.performAction(item, tab: tab, anchor: controller.sidebar.address)
            try? await Task.sleep(for: .seconds(3))
            let popup = ExtensionHost.shared.lastAction?.popupWebView
            report["popup"] = popup != nil
            if let popup {
                let text = try? await popup.evaluateJavaScript("(document.body && document.body.innerText || '').trim().length")
                report["popupTextLength"] = (text as? Int) ?? 0
            }
            report["openedTab"] = controller.tabManager.currentTabs.count > tabs
            ExtensionHost.shared.lastAction?.popupPopover?.close()
        }
        debugLog("exttest " + ((try? String(data: JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)) ?? "?") ?? "?")
        while controller.tabManager.currentTabs.count > tabsBefore, let last = controller.tabManager.selectedTab { controller.tabManager.close(last) }
        if !had { ExtensionStore.uninstall(id) }
    }

    static func cpuTime(_ pid: Int32) -> Double { ProcessCPU.seconds(pid) }
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
