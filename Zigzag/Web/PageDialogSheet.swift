import AppKit
import WebKit

/// A website's alert, confirm, prompt or sign-in, drawn as Zigzag's own sheet over the page that asked: who's asking,
/// what they say, their fields, and Zigzag buttons. It belongs to that page, so it dims only its pane, never the
/// sidebar or another tab, goes with the tab when another is in front and comes back with it. From a page's second
/// dialog on, it offers to block the rest, so a page stuck showing dialogs can't take the window hostage.
final class PageDialogSheet: NSView {
    struct Field {
        let placeholder: String
        var value: String = ""
        var secure = false
    }

    enum Result {
        case confirmed([String])
        case cancelled
        /// Don't show this page's dialogs any more (until it loads something new).
        case blocked
    }

    /// Saved passwords a sign-in sheet offers, behind a quiet button: picking one fills the fields with what `fill`
    /// gives (nil leaves them as they are).
    struct SavedLogins {
        let logins: [Credential]
        let origin: Origin
        let fill: (Credential) async -> [String]?
    }

    private let panel = FloatingPanelView()
    private let header: DialogHeader
    private let body: NSTextField
    private var inputs: [FilledField] = []
    private let buttons = DialogButtons()
    private let confirm: PillButton
    private let cancel = PillButton(title: String(localized: "Cancel", comment: "Button in a page's JavaScript dialog sheet."), style: .plain)
    private let block = PillButton(title: String(localized: "Block Dialogs", comment: "Button in a page's JavaScript dialog sheet, once it has shown a second dialog."), style: .quiet)
    private let saved = PillButton(title: String(localized: "Saved Passwords", comment: "Button in a site's HTTP sign-in sheet: lists the passwords saved for the site, to fill one in."), style: .quiet)
    private var savedLogins: SavedLogins?
    private var savedMenu: AutofillMenu?
    /// Says which question it answers, so another way of answering it (an extension) can close it.
    private var answers: String?
    private var monitor: Any?
    private var closeObserver: Any?
    /// The page that asked, when a page did: the sheet sits on it, and goes when the page does.
    private weak var page: WKWebView?
    /// The window it was asked in: closing that window answers it, even while its tab isn't in front.
    private weak var homeWindow: NSWindow?
    private static var open: [WeakBox] = []
    private struct WeakBox { weak var sheet: PageDialogSheet? }
    private var completion: (Result) -> Void
    /// Narrower in a narrow pane, so it never runs past the page it belongs to.
    private var width: CGFloat { min(Tokens.Dialog.width, max(240, bounds.width - Tokens.Space.x4 * 2)) }
    private let pad = Tokens.Dialog.padding

    private init(title: String, message: String, fields: [Field], confirmTitle: String, showsCancel: Bool, offersBlock: Bool,
                 savedLogins: SavedLogins?, completion: @escaping (Result) -> Void) {
        header = DialogHeader(title: title)
        body = NSTextField(wrappingLabelWithString: message)
        confirm = PillButton(title: confirmTitle, style: .prominent)
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
        body.font = Tokens.Font.body()
        body.textColor = Tokens.Color.textPrimary
        body.isSelectable = true
        body.maximumNumberOfLines = 12
        addSubview(panel)
        [header, body, buttons].forEach { panel.addSubview($0) }
        for field in fields {
            let input = FilledField(placeholder: field.placeholder, secure: field.secure)
            input.stringValue = field.value
            panel.addSubview(input)
            inputs.append(input)
        }
        buttons.trailing = showsCancel ? [cancel, confirm] : [confirm]
        if offersBlock {
            block.toolTip = String(localized: "Don’t let this page show more dialogs", comment: "Tooltip of Block Dialogs in a page's JavaScript dialog sheet.")
            buttons.leading = [block]
        } else if let savedLogins, !savedLogins.logins.isEmpty {
            self.savedLogins = savedLogins
            buttons.leading = [saved]
            saved.onClick = { [weak self] _ in self?.toggleSavedMenu() }
        }
        confirm.onClick = { [weak self] _ in self?.finish(.confirmed(self?.inputs.map(\.stringValue) ?? [])) }
        cancel.onClick = { [weak self] _ in self?.finish(.cancelled) }
        block.onClick = { [weak self] _ in self?.finish(.blocked) }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @MainActor
    static func ask(in window: NSWindow, title: String, message: String, fields: [Field] = [], confirmTitle: String = String(localized: "OK", comment: "Button that answers a page's JavaScript dialog sheet."),
                    showsCancel: Bool, offersBlock: Bool, page: WKWebView? = nil, savedLogins: SavedLogins? = nil, tag: String? = nil) async -> Result {
        // Over the page that asked, so it stays with its tab; a dialog without a page covers the window.
        guard let host = page ?? window.contentView else { return .cancelled }
        // One at a time on a page: a second question (two sign-ins at once) waits for the first, never stacks on it.
        let key = ObjectIdentifier(host)
        let before = queue[key]
        let task = Task { @MainActor in
            _ = await before?.value
            return await present(in: window, host: host, title: title, message: message, fields: fields, confirmTitle: confirmTitle,
                                 showsCancel: showsCancel, offersBlock: offersBlock, page: page, savedLogins: savedLogins, tag: tag)
        }
        queue[key] = task
        let result = await task.value
        if queue[key] == task { queue[key] = nil }
        return result
    }

    private static var queue: [ObjectIdentifier: Task<Result, Never>] = [:]

    @MainActor
    private static func present(in window: NSWindow, host: NSView, title: String, message: String, fields: [Field], confirmTitle: String,
                                showsCancel: Bool, offersBlock: Bool, page: WKWebView?, savedLogins: SavedLogins?, tag: String?) async -> Result {
        return await withCheckedContinuation { continuation in
            let sheet = PageDialogSheet(title: title, message: message, fields: fields, confirmTitle: confirmTitle, showsCancel: showsCancel,
                                        offersBlock: offersBlock, savedLogins: savedLogins) { continuation.resume(returning: $0) }
            sheet.page = page
            sheet.answers = tag
            sheet.homeWindow = window
            open = open.filter { $0.sheet != nil } + [WeakBox(sheet: sheet)]
            // Closing the window doesn't take its views down with it: the page hears "cancel", not silence. Its tab
            // may be out of sight, or have moved to another window, so it's the window it's on now, else where it asked.
            sheet.closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak sheet] note in
                let closing = ObjectIdentifier(note.object as AnyObject)
                MainActor.assumeIsolated {
                    guard let sheet, let window = sheet.window ?? sheet.homeWindow, ObjectIdentifier(window) == closing else { return }
                    sheet.finish(.cancelled)
                }
            }
            sheet.frame = host.bounds
            sheet.autoresizingMask = [.width, .height]
            sheet.layer?.backgroundColor = sheet.cgColor(Tokens.Color.scrim)
            // Return answers (the page asked, and is waiting); Escape cancels. Only while it's on screen, and only when
            // the keyboard is on its page: typing in the sidebar's address, or another pane, stays there.
            sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
                guard let sheet, let window = sheet.window, event.window === window, sheet.ownsKeyboard else { return event }
                // Return that commits a word being composed (Chinese, Japanese) belongs to the field.
                if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
                // While the saved passwords are listed, the keys choose among them.
                if let menu = sheet.savedMenu {
                    switch event.keyCode {
                    case 125: menu.move(1); return nil
                    case 126: menu.move(-1); return nil
                    case 36, 76: if case .login(let login)? = menu.selected { sheet.pickSaved(login) }; return nil
                    case 53: sheet.closeSavedMenu(); return nil
                    default: break
                    }
                }
                switch event.keyCode {
                case 36, 76: sheet.finish(.confirmed(sheet.inputs.map(\.stringValue))); return nil
                case 53: sheet.finish(sheet.cancel.superview == nil ? .confirmed([]) : .cancelled); return nil
                default: return event
                }
            }
            // On a tab out of sight, it waits there until the tab is in front again; `viewDidMoveToWindow` shows it.
            host.addSubview(sheet)
        }
    }

    /// Whether the keyboard is with this dialog: in one of its fields, or on the page it covers.
    private var ownsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return page == nil }
        if responder.isDescendant(of: self) { return true }
        guard let page else { return true }
        return responder.isDescendant(of: page)
    }

    /// Answered another way (an extension gave the sign-in it asks for): the sheet tagged so goes, with these values.
    static func answer(tag: String, with values: [String]) {
        for box in open where box.sheet?.answers == tag { box.sheet?.finish(.confirmed(values)) }
        open = open.filter { $0.sheet != nil && $0.sheet?.superview != nil }
    }

    // MARK: Saved passwords

    /// The saved passwords, in the menu that fills a sign-in form, under the button.
    private func toggleSavedMenu() {
        if savedMenu != nil { closeSavedMenu(); return }
        guard let savedLogins else { return }
        let menu = AutofillMenu(items: savedLogins.logins.prefix(8).map { .login($0) }, origin: savedLogins.origin)
        menu.onPick = { [weak self] item in if case .login(let login) = item { self?.pickSaved(login) } }
        let anchor = convert(saved.bounds, from: saved)
        let width = min(max(anchor.width, 260), 360), height = menu.contentHeight
        var y = anchor.maxY + Tokens.Space.x1
        if y + height > bounds.maxY - Tokens.Space.x2 { y = anchor.minY - Tokens.Space.x1 - height }
        let x = min(max(anchor.minX, Tokens.Space.x2), bounds.maxX - width - Tokens.Space.x2)
        menu.frame = NSRect(x: x, y: max(Tokens.Space.x2, y), width: width, height: height)
        addSubview(menu)
        menu.present(always: true)
        savedMenu = menu
    }

    private func closeSavedMenu() {
        savedMenu?.removeFromSuperview()
        savedMenu = nil
    }

    private func pickSaved(_ login: Credential) {
        closeSavedMenu()
        guard let fill = savedLogins?.fill else { return }
        Task { @MainActor [weak self] in
            guard let values = await fill(login), let self, self.superview != nil else { return }
            for (input, value) in zip(self.inputs, values) { input.stringValue = value }
            self.window?.makeFirstResponder(self.inputs.last?.field)
        }
    }

    #if DEBUG
    /// For the debug bridge: each dialog showing, its title and fields, a secure field only as its length.
    static func debugState() -> [[String: Any]] {
        open.compactMap(\.sheet).filter { $0.superview != nil }.map { sheet in
            ["title": sheet.header.title.stringValue, "fields": sheet.inputs.map { $0.field is NSSecureTextField ? "\($0.stringValue.count) characters" : $0.stringValue },
             "savedButton": sheet.saved.superview != nil, "savedMenu": sheet.savedMenu != nil]
        }
    }

    /// Opens the saved passwords' menu on the sign-in sheet showing.
    static func debugShowSaved() {
        open.compactMap(\.sheet).first { $0.savedMenu == nil && $0.saved.superview != nil }?.toggleSavedMenu()
    }
    #endif

    /// The page closed (its tab, or a new process): its dialogs answer "cancel" and go.
    static func cancel(for page: WKWebView) {
        for box in open where box.sheet?.page === page { box.sheet?.finish(.cancelled) }
        open = open.filter { $0.sheet != nil && $0.sheet?.superview != nil }
    }

    private func finish(_ result: Result) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // Typing goes back to the page, not nowhere.
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
            window.makeFirstResponder(page)
        }
        let completion = self.completion
        self.completion = { _ in }
        removeFromSuperview()
        completion(result)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitor != nil else { return }
        guard let window else {
            // Over the whole window, and that window went: the page hears "cancel" rather than waiting forever. On a
            // page, it's only that page's tab going out of sight; it waits for the tab to come back.
            if page == nil { finish(.cancelled) }
            return
        }
        needsLayout = true
        panel.present(always: true)
        // The card puts the keyboard on the page as the tab comes in front; the dialog's field takes it after that.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            if let first = self.inputs.first {
                window.makeFirstResponder(first.field)
            } else if !(window.firstResponder is NSView), let page = self.page {
                // Nothing has the keyboard: the page does, so Return answers.
                window.makeFirstResponder(page)
            }
        }
    }

    // Clicks, scrolling and right-clicks on the backdrop don't reach the page underneath. A click there puts away the
    // saved passwords' menu.
    override func mouseDown(with event: NSEvent) { closeSavedMenu() }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    private var bodyHeight: CGFloat { ceil(body.sizeThatFits(NSSize(width: width - pad * 2, height: 600)).height) }
    private let fieldHeight: CGFloat = 36

    override func layout() {
        super.layout()
        let fields = CGFloat(inputs.count) * (fieldHeight + Tokens.Space.x2)
        let height = pad + header.height(for: width - pad * 2) + Tokens.Space.x2 + bodyHeight + Tokens.Dialog.gap + fields
            + Tokens.Space.x2 + DialogButtons.height + pad
        panel.frame = NSRect(x: round((bounds.width - width) / 2), y: max(0, round((bounds.height - height) / 2.4)), width: width, height: height)
    }

    private func layoutPanel() {
        let inner = panel.bounds.width - pad * 2
        header.frame = NSRect(x: pad, y: pad, width: inner, height: header.height(for: inner))
        body.frame = NSRect(x: pad, y: header.frame.maxY + Tokens.Space.x2, width: inner, height: bodyHeight)
        var y = body.frame.maxY + Tokens.Dialog.gap
        for input in inputs {
            input.frame = NSRect(x: pad, y: y, width: inner, height: fieldHeight)
            y += fieldHeight + Tokens.Space.x2
        }
        y += inputs.isEmpty ? 0 : Tokens.Space.x2
        buttons.frame = NSRect(x: pad, y: y, width: inner, height: DialogButtons.height)
    }
}
