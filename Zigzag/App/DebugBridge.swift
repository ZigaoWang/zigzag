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
        case "reveal": controller.root.reveal(true)
        case "unreveal": controller.root.reveal(false)
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
        case "permprompt": Task { _ = await PermissionPrompt.ask(host: "meet.google.com", what: "your camera", symbol: "video.fill", isPrivate: false, in: controller) }
        case "renamepanel": RenamePanel.show(title: "Google", in: controller) { _ in }
        case "importanim": IntoZigzag.shown?.set(arg == "done" ? .done : .importing)
        case "bartab": controller.commandBar.debugTab()
        case "tour": Tutorial.restart(); GuidedTour.start(in: controller)
        case "tourskip": Tutorial.skip()
        case "tourend": Tutorial.isHidden = true; controller.root.overlay.subviews.compactMap { $0 as? GuidedTour }.forEach { $0.removeFromSuperview() }
        case "fullscreen": controller.window?.toggleFullScreen(nil)
        case "settingsspaceedit":
            func rows(_ v: NSView) -> [SpaceSettingsRow] { (v as? SpaceSettingsRow).map { [$0] } ?? v.subviews.flatMap(rows) }
            if let root = SettingsWindowController.shared.window?.contentView { rows(root).first?.openEditor() }
        case "saveprompt": if arg == "close" { SavePasswordPrompt.debugClose() } else { SavePasswordPrompt.debugPreview(in: controller) }
        case "select": controller.tabManager.select(at: Int(arg) ?? 0)
        case "suspendtab": controller.tabManager.allTabs.first { $0.url?.absoluteString.hasPrefix(arg) == true }?.suspend()
        case "space": controller.tabManager.switchSpace(by: Int(arg) ?? 1)
        case "newspace":
            let space = Library.shared.addSpace(name: arg.isEmpty ? nil : arg)
            controller.tabManager.switchToSpace(space.id)
        case "bookmark": if let tab = controller.tabManager.selectedTab { controller.tabManager.bookmarkTab(tab) }
        case "hover": controller.debugHover(index: Int(arg) ?? 0)
        case "desk": controller.toggleDeskView(nil)
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
        case "js":
            controller.selectedWebView?.evaluateJavaScript(arg) { result, error in
                debugLog("js => \(String(describing: result).prefix(1500)) \(error.map { String(describing: $0) } ?? "")")
            }
        case "quit": NSApp.terminate(nil)
        case "history": HistoryWindowController.show()
        case "newwindow": WindowManager.shared.newWindow(url: URL(string: arg), showCommandBar: false)
        case "closekey": WindowManager.shared.keyController?.window?.performClose(nil)
        case "reopenwindow": WindowManager.shared.reopenClosedWindow()
        case "whatsnew": WhatsNew.show(in: controller)
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
            // onboardstep <0-3>: hello, bring, personalize, ready
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
            // Unlocks without Touch ID and lets the window be captured, for checking it by script with test data.
            PasswordAuthentication.unlockForTesting()
            PasswordsWindowController.show()
            PasswordsWindowController.shared?.window?.sharingType = .readOnly
        case "key":
            // key <char> [cmd|shift|ctrl|opt...] — goes through the real event path, menus included.
            let f = arg.split(separator: " ").map(String.init)
            guard let ch = f.first, let window = controller.window else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in f.dropFirst() {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "ctrl": flags.insert(.control); case "opt": flags.insert(.option); default: break }
            }
            let chars = ch == "esc" ? "\u{1b}" : ch == "tab" ? "\t" : ch
            let codes: [String: UInt16] = ["s": 1, "t": 17, "l": 37, "w": 13, "esc": 53, "tab": 48, "f": 3, "r": 15, "p": 35]
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
            // "page": over the middle of the page instead.
            let onPage = parts.contains("page")
            let screenPoint = window.convertPoint(toScreen: onPage ? NSPoint(x: window.frame.width * 0.6, y: window.frame.height / 2) : NSPoint(x: 100, y: window.frame.height - 300))
            let flipped = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y)
            var phases: [Int64] = [1]
            phases += Array(repeating: 2, count: parts.contains("slow") ? 48 : 12)
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
        case "sitepanel": SitePanel.toggle(in: controller, from: controller.sidebar.address)
        case "cancelsheet":
            // Cancels any open confirmation, in every window, without confirming it.
            for window in NSApp.windows {
                func walk(_ view: NSView?) { for sub in view?.subviews ?? [] { (sub as? ConfirmSheet)?.debugCancel(); walk(sub) } }
                walk(window.contentView)
            }
        case "pwseed":
            // Five obviously fake logins for checking the Passwords window; remove them with pwclear.
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
        case "settingsbottom":
            if let root = SettingsWindowController.shared.window?.contentView,
               let scroll = root.subviews.compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
            }
        case "settingspane":
            // settingspane <general|spaces|passwords|privacy|translation|extensions|shortcuts>
            SettingsWindowController.shared.show()
            if let pane = SettingsPane.allCases.first(where: { "\($0)" == arg }) { SettingsWindowController.shared.show(pane) }
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
        case "extpopup":
            if let item = ExtensionHost.shared.actions(for: controller.tabManager.selectedTab).first(where: { $0.id == arg }) {
                ExtensionHost.shared.performAction(item, tab: controller.tabManager.selectedTab, anchor: controller.sidebar.address)
            }
        case "extapprove": Task { await ExtensionStore.approvePendingUpdate(arg) }
        case "extoff": ExtensionStore.setEnabled(arg, false)
        case "exton": ExtensionStore.setEnabled(arg, true)
        case "settingsid":
            if let w = SettingsWindowController.shared.window { try? "\(w.windowNumber)".write(toFile: arg, atomically: true, encoding: .utf8) }
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
