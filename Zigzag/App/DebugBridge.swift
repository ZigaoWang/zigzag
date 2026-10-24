import AppKit

/// Debug builds only: lets scripts drive the UI (for screenshots and testing) via distributed notifications.
/// `xcrun swift -e` or the bundled `zz` script posts "app.zigzag.debug" with a command string.
enum DebugBridge {
    static var hovered: [NSView] = []
    private static var scrollLog: [String] = []

    static func recordScroll(_ event: NSEvent) {
        scrollLog.append(String(format: "%.3f phase=%lu mom=%lu dx=%.1f dy=%.1f precise=%d swipeEnabled=%d",
                                event.timestamp, event.phase.rawValue, event.momentumPhase.rawValue,
                                event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0,
                                NSEvent.isSwipeTrackingFromScrollEventsEnabled ? 1 : 0))
        if scrollLog.count > 300 { scrollLog.removeFirst(scrollLog.count - 300) }
    }

    static func start() {
        #if DEBUG
        DistributedNotificationCenter.default().addObserver(forName: .init("app.zigzag.debug"), object: nil, queue: .main) { note in
            let command = (note.object as? String) ?? ""
            MainActor.assumeIsolated { run(command) }
        }
        #endif
    }

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
        case "reveal": controller.root.reveal(true)
        case "unreveal": controller.root.reveal(false)
        case "lights":
            let w = controller.window as? BrowserWindow
            let b = w?.standardWindowButton(.closeButton)
            debugLog("lights hidden=\(b?.isHidden ?? true) frame=\(b?.frame ?? .zero) revealed=\(controller.root.isSidebarFloatingVisible) container=\(controller.root.sidebarContainer.frame.minX)")
        case "commandbar": controller.commandBar.show(mode: .newTab); if !arg.isEmpty { controller.commandBar.debugType(arg) }
        case "enter": controller.commandBar.debugEnter()
        case "edit": controller.commandBar.show(mode: .editCurrent); if !arg.isEmpty { controller.commandBar.debugType(arg) }
        case "select": controller.tabManager.select(at: Int(arg) ?? 0)
        case "space": controller.tabManager.switchSpace(by: Int(arg) ?? 1)
        case "newspace":
            let space = Library.shared.addSpace(name: arg.isEmpty ? nil : arg)
            controller.tabManager.switchToSpace(space.id)
        case "bookmark": if let tab = controller.tabManager.selectedTab { controller.tabManager.bookmarkTab(tab) }
        case "hover": controller.debugHover(index: Int(arg) ?? 0)
        case "desk": controller.toggleDeskView(nil)
        case "find": controller.findBar.show(query: arg)
        case "peek": if let url = URL(string: arg) { controller.open(url, disposition: .peek) }
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
        case "windowid":
            if let window = controller.window {
                let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                let topLeftY = screenHeight - window.frame.maxY
                let info = "\(window.windowNumber) \(ProcessInfo.processInfo.processIdentifier) \(Int(window.frame.minX)) \(Int(topLeftY))"
                try? info.write(toFile: arg, atomically: true, encoding: .utf8)
            }
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
            // mouse <down|drag|up|move|click|rclick> x y  (window points, top-left origin)
            let f = arg.split(separator: " ").map(String.init)
            guard f.count == 3, let x = Double(f[1]), let y = Double(f[2]), let window = controller.window else { break }
            let point = NSPoint(x: x, y: window.frame.height - y)
            func post(_ type: NSEvent.EventType, clicks: Int = 1) {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            switch f[0] {
            case "down": post(.leftMouseDown)
            case "drag": post(.leftMouseDragged)
            case "up": post(.leftMouseUp)
            case "click": post(.leftMouseDown); post(.leftMouseUp)
            case "rclick": post(.rightMouseDown); post(.rightMouseUp)
            case "move", "hover":
                // Tracking areas follow the real cursor, so hover is simulated by telling the view directly.
                var view = window.contentView?.hitTest(point)
                while let v = view, !(v is InteractiveView) { view = v.superview }
                for case let other as InteractiveView in DebugBridge.hovered where other !== view { other.isHovered = false }
                if let v = view as? InteractiveView { v.isHovered = true; DebugBridge.hovered = [v] } else { DebugBridge.hovered = [] }
            default: break
            }
        case "downloads": controller.sidebarShowDownloads(from: controller.sidebar.downloadsAnchor)
        case "action": controller.sidebar.address.actionButtons[min(Int(arg) ?? 0, controller.sidebar.address.actionButtons.count - 1)].onClick?(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
        case "popupjs":
            if #available(macOS 15.4, *), let webView = ExtensionHost.shared.lastAction?.popupWebView {
                webView.evaluateJavaScript(arg) { result, error in
                    debugLog("popupjs => \(String(describing: result).prefix(2000)) \(String(describing: error))")
                }
            } else { debugLog("popupjs: no popup") }
        case "js":
            controller.selectedWebView?.evaluateJavaScript(arg) { result, error in
                debugLog("js => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
            }
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
        case "welcome": controller.showWelcome()
        case "key":
            // key <char> [cmd|shift|ctrl|opt...] — goes through the real event path, menus included.
            let f = arg.split(separator: " ").map(String.init)
            guard let ch = f.first, let window = controller.window else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in f.dropFirst() {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "ctrl": flags.insert(.control); case "opt": flags.insert(.option); default: break }
            }
            let chars = ch == "esc" ? "\u{1b}" : ch == "tab" ? "\t" : ch
            let codes: [String: UInt16] = ["s": 1, "t": 17, "l": 37, "w": 13, "esc": 53, "tab": 48, "f": 3]
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: codes[ch] ?? 0) {
                NSApp.postEvent(e, atStart: false)
            }
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
            let screenPoint = window.convertPoint(toScreen: NSPoint(x: 100, y: window.frame.height - 300))
            let flipped = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y)
            var phases: [Int64] = [1]
            phases += Array(repeating: 2, count: 12)
            phases.append(4)
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
        case "settings": SettingsWindowController.shared.show()
        case "addext": controller.installExtension(arg)
        case "rmext": ExtensionStore.uninstall(arg)
        case "extoff": ExtensionStore.setEnabled(arg, false)
        case "exton": ExtensionStore.setEnabled(arg, true)
        case "settingsid":
            if let w = SettingsWindowController.shared.window { try? "\(w.windowNumber)".write(toFile: arg, atomically: true, encoding: .utf8) }
        case "editspace": controller.openSpaceEditor(controller.tabManager.currentSpaceID, anchor: controller.sidebar.list.headerView)
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
                for item in menu.items where !item.isSeparatorItem {
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
        case "favorite":
            if let tab = controller.tabManager.selectedTab { controller.tabManager.favoriteTab(tab) }
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
        default: break
        }
    }
}
