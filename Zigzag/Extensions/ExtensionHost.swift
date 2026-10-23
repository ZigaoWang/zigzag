import AppKit
import WebKit

/// Runs browser extensions with WebKit's extension engine. We use it for exactly one thing:
/// the official 1Password extension, so the password manager works the way it does in other browsers.
@available(macOS 15.4, *)
final class ExtensionHost: NSObject {
    static let shared = ExtensionHost()

    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []
    /// Fires when extensions load or their toolbar actions change.
    let changed = Signal<Void>()
    private var nativePorts: [ObjectIdentifier: NativeMessagingHost] = [:]

    private override init() {
        let configuration = WKWebExtensionController.Configuration(identifier: UUID(uuidString: "6F1E2D6A-5B0C-4C1B-9E1A-2A7B5D3C9E10")!)
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    // MARK: Loading

    /// Loads every installed extension. Called once at launch.
    func loadInstalled() {
        for dir in KnownExtension.installedDirectories() {
            KnownExtension.patch(dir)
            Task { await load(from: dir) }
        }
    }

    @discardableResult
    func load(from directory: URL) async -> WKWebExtensionContext? {
        do {
            let ext = try await WKWebExtension(resourceBaseURL: directory)
            let context = WKWebExtensionContext(for: ext)
            context.uniqueIdentifier = directory.lastPathComponent
            context.isInspectable = true
            // Installing an extension here is a deliberate choice; grant what it asks for up front.
            for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            try controller.load(context)
            contexts.append(context)
            announceExistingWindows(to: context)
            changed.send()
            debugLog("Zigzag: loaded \(ext.displayName ?? "?") errors=\(ext.errors)")
            context.loadBackgroundContent { error in
                debugLog("Zigzag: background loaded error=\(String(describing: error))")
            }
            return context
        } catch {
            debugLog("Zigzag: extension at \(directory.path) failed to load: \(error)")
            return nil
        }
    }

    private func announceExistingWindows(to context: WKWebExtensionContext) {
        for window in WindowManager.shared.controllers {
            controller.didOpenWindow(window)
            for tab in window.tabManager.allTabs { controller.didOpenTab(tab) }
        }
        if let key = WindowManager.shared.keyController { controller.didFocusWindow(key) }
    }

    // MARK: Toolbar actions

    struct ActionItem {
        let context: WKWebExtensionContext
        let icon: NSImage?
        let label: String
    }

    func actions(for tab: Tab?) -> [ActionItem] {
        contexts.compactMap { context in
            guard let action = context.action(for: tab) else { return nil }
            return ActionItem(context: context, icon: action.icon(for: NSSize(width: 16, height: 16)), label: action.label)
        }
    }

    private weak var actionAnchor: NSView?
    weak var lastAction: WKWebExtension.Action?

    func performAction(_ item: ActionItem, tab: Tab?, anchor: NSView) {
        actionAnchor = anchor
        if item.context.uniqueIdentifier == KnownExtension.onePasswordID, onePasswordNeedsApproval,
           let controller = WindowManager.shared.controllers.first(where: { $0.window === anchor.window }) {
            OnePasswordHint.show(below: anchor, in: controller)
            return
        }
        item.context.performAction(for: tab)
    }

    /// Set when the 1Password app has not (yet) been told to trust Zigzag.
    private(set) var onePasswordNeedsApproval = false

    fileprivate func nativeHostReplied(_ message: Any) {
        guard let dict = message as? [String: Any], let content = dict["content"] as? [String: Any],
              let inner = content["content"] as? [String: Any], let type = inner["type"] as? String else {
            onePasswordNeedsApproval = false
            return
        }
        onePasswordNeedsApproval = type == "BrowserVerificationFailed"
    }

    // MARK: Event fan-out from our model

    func tabOpened(_ tab: Tab) { controller.didOpenTab(tab) }
    func tabClosed(_ tab: Tab, windowClosing: Bool = false) { controller.didCloseTab(tab, windowIsClosing: windowClosing) }
    func tabActivated(_ tab: Tab, previous: Tab?) { controller.didActivateTab(tab, previousActiveTab: previous) }
    func tabChanged(_ tab: Tab, _ change: Tab.Change) {
        switch change {
        case .url: controller.didChangeTabProperties([.URL], for: tab)
        case .title: controller.didChangeTabProperties([.title], for: tab)
        case .loading: controller.didChangeTabProperties([.loading], for: tab)
        case .audio: controller.didChangeTabProperties([.playingAudio, .muted], for: tab)
        default: break
        }
    }
    func windowOpened(_ window: BrowserWindowController) { controller.didOpenWindow(window) }
    func windowClosed(_ window: BrowserWindowController) { controller.didCloseWindow(window) }
    func windowFocused(_ window: BrowserWindowController?) { controller.didFocusWindow(window) }

    /// Keyboard shortcuts declared by extensions (1Password's fill shortcut).
    func performCommand(for event: NSEvent) -> Bool {
        for context in contexts where context.performCommand(for: event) { return true }
        return false
    }
}

// MARK: - Controller delegate

@available(macOS 15.4, *)
extension ExtensionHost: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        WindowManager.shared.controllers
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        WindowManager.shared.keyController
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let window = (configuration.window as? BrowserWindowController) ?? WindowManager.shared.keyController ?? WindowManager.shared.newWindow(showCommandBar: false)
        let tab = window.tabManager.newTab(url: configuration.url, select: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let window = WindowManager.shared.newWindow(url: configuration.tabURLs.first, showCommandBar: false)
        for url in configuration.tabURLs.dropFirst() { window.tabManager.newTab(url: url, select: false) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL, let window = WindowManager.shared.keyController {
            window.tabManager.newTab(url: url, title: extensionContext.webExtension.displayName)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        completionHandler(urls, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        changed.send()
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        lastAction = action
        debugLog("Zigzag: present popup popover=\(action.popupPopover != nil) webView=\(action.popupWebView != nil)")
        guard let popover = action.popupPopover else { completionHandler(nil); return }
        let anchor = actionAnchor ?? WindowManager.shared.keyController?.sidebar.address
        guard let anchor, anchor.window != nil else { completionHandler(nil); return }
        popover.behavior = .semitransient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }

    // MARK: Native messaging (the extension talking to the 1Password app)

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        if applicationIdentifier == "app.zigzag.log" {
            debugLog("Extension: \(((message as? [String: Any])?["message"] as? String) ?? String(describing: message))")
            replyHandler(nil, nil)
            return
        }
        debugLog("Zigzag: sendNativeMessage to \(applicationIdentifier ?? "nil"): \(String(describing: message).prefix(200))")
        guard let host = NativeMessagingHost(name: applicationIdentifier, context: extensionContext) else {
            replyHandler(nil, NSError(domain: "Zigzag", code: 1, userInfo: [NSLocalizedDescriptionKey: "No native host"]))
            return
        }
        host.sendOnce(message, reply: replyHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        debugLog("Zigzag: connectNative \(port.applicationIdentifier ?? "nil")")
        guard let host = NativeMessagingHost(name: port.applicationIdentifier, context: extensionContext) else {
            completionHandler(NSError(domain: "Zigzag", code: 1, userInfo: [NSLocalizedDescriptionKey: "No native host"]))
            return
        }
        let key = ObjectIdentifier(port)
        nativePorts[key] = host
        host.connect(port) { [weak self] in self?.nativePorts[key] = nil }
        completionHandler(nil)
    }
}

// MARK: - Our tabs and windows, as extensions see them

@available(macOS 15.4, *)
extension Tab: WKWebExtensionTab {
    private var windowController: BrowserWindowController? {
        WindowManager.shared.controllers.first { $0.tabManager.allTabs.contains { $0 === self } }
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { windowController }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        windowController?.tabManager.navigableTabs.firstIndex { $0 === self } ?? 0
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { windowController?.tabManager.selectedTab === self }
    func isPinned(for context: WKWebExtensionContext) -> Bool { bookmarkID != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { isPlayingAudio }
    func isMuted(for context: WKWebExtensionContext) -> Bool { isMuted }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        windowController?.tabManager.select(self)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        windowController?.tabManager.close(self)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        fromOrigin ? reloadFromOrigin() : reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goBack(); completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goForward(); completionHandler(nil)
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        setMuted(muted); completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension BrowserWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabManager.navigableTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tabManager.selectedTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}

// MARK: - Native messaging host

/// Speaks Chrome's native messaging protocol (length-prefixed JSON over stdio) with a helper app,
/// using the same host manifests Chrome uses. This is how the 1Password extension reaches the 1Password app.
@available(macOS 15.4, *)
final class NativeMessagingHost {
    private let executable: URL
    private let origin: String
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()

    init?(name: String?, context: WKWebExtensionContext) {
        guard let name, let manifest = Self.manifest(named: name),
              let path = manifest["path"] as? String else { return nil }
        executable = URL(fileURLWithPath: path)
        // Hosts only talk to the extension IDs they list; we present the extension's Chrome ID.
        let allowed = (manifest["allowed_origins"] as? [String]) ?? []
        let id = context.uniqueIdentifier
        origin = allowed.first { $0.contains(id) } ?? "chrome-extension://\(id)/"
    }

    static func manifest(named name: String) -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            "Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "Library/Application Support/Chromium/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
        ].map { home.appendingPathComponent($0) } + [URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts")]
        for dir in dirs {
            let file = dir.appendingPathComponent("\(name).json")
            if let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return nil
    }

    private func start(onMessage: @escaping @MainActor (Any) -> Void, onExit: @escaping @MainActor () -> Void) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = [origin]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                guard let self else { return }
                if data.isEmpty { return }
                self.buffer.append(data)
                for message in self.drainMessages() { onMessage(message) }
                }
            }
        }
        process.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { onExit() } } }
        do { try process.run() } catch { return false }
        self.process = process
        input = stdin.fileHandleForWriting
        return true
    }

    private func drainMessages() -> [Any] {
        var messages: [Any] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            if let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) { messages.append(object) }
        }
        return messages
    }

    private func write(_ message: Any?) {
        guard let input, let message,
              let body = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) else { return }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        try? input.write(contentsOf: frame)
    }

    func sendOnce(_ message: Any, reply: @escaping (Any?, (any Error)?) -> Void) {
        var replied = false
        let started = start(onMessage: { [weak self] response in
            guard !replied else { return }
            replied = true
            reply(response, nil)
            self?.process?.terminate()
        }, onExit: {
            if !replied { replied = true; reply(nil, nil) }
        })
        if started { write(message) } else { reply(nil, NSError(domain: "Zigzag", code: 2)) }
    }

    func connect(_ port: WKWebExtension.MessagePort, onClose: @escaping () -> Void) {
        debugLog("Zigzag: native host connect \(executable.lastPathComponent) origin=\(origin)")
        let started = start(onMessage: { message in
            ExtensionHost.shared.nativeHostReplied(message)
            debugLog("Zigzag: native host -> extension \(String(describing: message).prefix(1500))")
            port.sendMessage(message, completionHandler: nil)
        }, onExit: {
            debugLog("Zigzag: native host exited")
            port.disconnect()
            onClose()
        })
        guard started else { port.disconnect(); onClose(); return }
        port.messageHandler = { [weak self] message, _ in self?.write(message) }
        port.disconnectHandler = { [weak self] _ in
            self?.process?.terminate()
            onClose()
        }
    }
}

/// Debug builds write a plain log next to the app's data; release builds stay silent.
func debugLog(_ message: String) {
    #if DEBUG
    let line = "\(Date()) \(message)\n"
    let url = Paths.support.appendingPathComponent("debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
    #endif
}

/// Explains the one step only the person can do: telling 1Password to trust Zigzag.
@available(macOS 15.4, *)
enum OnePasswordHint {
    private static weak var current: FloatingPanelView?

    static func show(below anchor: NSView, in controller: BrowserWindowController) {
        current?.dismiss()
        let panel = FloatingPanelView()
        let title = Label("Let 1Password fill in Zigzag", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
        let body = NSTextField(wrappingLabelWithString: "1Password only connects to browsers it trusts. In 1Password, open Settings › Browser and add Zigzag. You only do this once.")
        body.font = Tokens.Font.body()
        body.textColor = Tokens.Color.textSecondary
        body.isSelectable = false
        let open = TextButton(title: "Open 1Password", font: Tokens.Font.body(.medium))
        open.onClick = { _ in
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
            panel.dismiss()
        }
        let width: CGFloat = 288
        let pad = Tokens.Space.x4
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: width - pad * 2, height: 400)).height)
        let height = pad + title.lineHeight + Tokens.Space.x2 + bodyHeight + Tokens.Space.x3 + Tokens.Space.x8 + Tokens.Space.x3
        let anchorFrame = anchor.convert(anchor.bounds, to: controller.root.overlay)
        panel.frame = NSRect(x: max(Tokens.Metric.cardInset, anchorFrame.maxX - width), y: anchorFrame.maxY + Tokens.Space.x2, width: width, height: height)
        panel.addSubview(title)
        panel.addSubview(body)
        panel.addSubview(open)
        title.frame = NSRect(x: pad, y: pad, width: width - pad * 2, height: title.lineHeight)
        body.frame = NSRect(x: pad, y: title.frame.maxY + Tokens.Space.x2, width: width - pad * 2, height: bodyHeight)
        let ow = open.fittingWidth
        open.frame = NSRect(x: width - pad - ow + Tokens.Space.x2, y: body.frame.maxY + Tokens.Space.x3, width: ow, height: Tokens.Space.x8)
        controller.root.overlay.addSubview(panel)
        panel.present()
        current = panel
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak panel] event in
            guard let panel else { if let m = monitor { NSEvent.removeMonitor(m) }; return event }
            let inside = panel.bounds.contains(panel.convert(event.locationInWindow, from: nil))
            if event.type == .keyDown || !inside {
                panel.dismiss()
                if let m = monitor { NSEvent.removeMonitor(m) }
            }
            return event
        }
    }
}
