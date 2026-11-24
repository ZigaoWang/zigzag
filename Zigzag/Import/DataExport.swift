import AppKit
import UniformTypeIdentifiers

/// File › Export Your Data…: a sheet that saves a bookmarks file any browser imports, a Zigzag backup File › Import
/// restores, or both. Passwords export from the Passwords window, with its own warning.
enum DataExport {
    #if DEBUG
    private(set) static weak var current: FormSheet?
    #endif

    static var title: String { String(localized: "Export Your Data…", comment: "File menu item, Settings button and command bar command: opens the sheet that saves your bookmarks and a Zigzag backup to files.") }

    struct Choice: Equatable {
        var bookmarks = true
        var backup = true
        var openTabs = false
        var history = false
    }

    static func show(in controller: BrowserWindowController) {
        let host = controller.root.overlay
        let bookmarks = ExportChoice(title: String(localized: "Bookmarks file (HTML)", comment: "Choice in the Export Your Data sheet."),
                                     detail: String(localized: "Your spaces as folders of pinned tabs, with your favorites. Any browser can import it.",
                                                    comment: "Under the Bookmarks file choice in the Export Your Data sheet."), isOn: true)
        let backup = ExportChoice(title: String(localized: "Zigzag backup", comment: "Choice in the Export Your Data sheet."),
                                  detail: String(localized: "Spaces, pinned tabs, favorites and settings. Restore it from the Import window.",
                                                 comment: "Under the Zigzag backup choice in the Export Your Data sheet. Choose File… is the Import window's button."), isOn: true)
        let openTabs = ExportChoice(title: String(localized: "Open tabs", comment: "Choice in the Export Your Data sheet."),
                                    detail: String(localized: "The tabs open in each space, besides the pinned ones.", comment: "Under the Open tabs choice in the Export Your Data sheet."), isOn: false)
        let history = ExportChoice(title: String(localized: "History", comment: "Choice in the Export Your Data sheet."),
                                   detail: String(localized: "Every page you’ve visited, in the backup only.", comment: "Under the History choice in the Export Your Data sheet."), isOn: false)
        let line = ColorView(color: Tokens.Color.separator)
        let passwords = ExportPasswordsRow()
        let rows = [
            FormSheet.Row(label: nil, view: bookmarks, height: 0),
            FormSheet.Row(label: nil, view: backup, height: 0),
            FormSheet.Row(label: nil, view: openTabs, height: 0),
            FormSheet.Row(label: nil, view: history, height: 0),
            FormSheet.Row(label: nil, view: line, height: Tokens.Metric.hairline),
            FormSheet.Row(label: nil, view: passwords, height: 0),
        ]
        func choice() -> Choice { Choice(bookmarks: bookmarks.isOn, backup: backup.isOn, openTabs: openTabs.isOn, history: history.isOn) }
        let sheet = FormSheet.show(in: host, title: String(localized: "Export Your Data", comment: "Title of the Export Your Data sheet."), symbol: "square.and.arrow.up",
                                   message: String(localized: "Save your spaces and pinned tabs to files you can keep or take to another browser.",
                                                   comment: "Under the title of the Export Your Data sheet."),
                                   rows: rows, confirmTitle: String(localized: "Export…", comment: "Main button of the Export Your Data sheet."),
                                   canConfirm: { bookmarks.isOn || backup.isOn }) { [weak controller] confirmed in
            guard confirmed, let controller else { return }
            save(choice(), from: controller)
        }
        // History goes only in the backup.
        let follow = { [weak sheet] in
            history.isEnabled = backup.isOn
            sheet?.revalidate()
        }
        for option in [bookmarks, backup] { option.onChange = { _ in follow() } }
        passwords.onOpen = { [weak sheet] in
            sheet?.close()
            PasswordsWindowController.show()
        }
        follow()
        #if DEBUG
        current = sheet
        #endif
    }

    // MARK: Saving

    /// "2026-11-24", in any language.
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func bookmarksName(_ date: Date = Date()) -> String {
        String(localized: "Zigzag Bookmarks \(stamp(date)).html", comment: "Name of the exported bookmarks file. The placeholder is the date, like 2026-11-24. Zigzag is a name.")
    }

    static func backupName(_ date: Date = Date()) -> String {
        String(localized: "Zigzag Backup \(stamp(date)).\(ZigzagBackup.fileExtension)", comment: "Name of the exported Zigzag backup file. The first placeholder is the date, like 2026-11-24; the second the file's extension. Zigzag is a name.")
    }

    /// The files' contents, made before anything is asked: what's here at the moment Export was clicked.
    static func files(_ choice: Choice, managers: [TabManager]) throws -> (bookmarks: Data?, backup: Data?) {
        var bookmarks: Data?
        if choice.bookmarks {
            let pages = ZigzagBackup.make(managers: managers, openTabs: choice.openTabs, history: false, pagesOnly: true)
            bookmarks = Data(BookmarksExport.html(BookmarksExport.tree(pages)).utf8)
        }
        let backup = choice.backup ? try ZigzagBackup.make(managers: managers, openTabs: choice.openTabs, history: choice.history).encoded() : nil
        return (bookmarks, backup)
    }

    /// One file: a save panel with its name. Both: a folder to put them in, each under its own name.
    private static func save(_ choice: Choice, from controller: BrowserWindowController) {
        guard let window = controller.window else { return }
        let made: (bookmarks: Data?, backup: Data?)
        do { made = try files(choice, managers: WindowManager.shared.controllers.map(\.tabManager)) } catch { failed(in: controller); return }
        if let bookmarks = made.bookmarks, let backup = made.backup {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Export", comment: "Button of the folder panel from the Export Your Data sheet, when both files are saved.")
            panel.message = String(localized: "Choose a folder for your bookmarks file and your Zigzag backup.", comment: "Message of the folder panel from the Export Your Data sheet.")
            panel.beginSheetModal(for: window) { [weak controller] response in
                guard response == .OK, let folder = panel.url, let controller else { return }
                let urls = [(bookmarksName(), bookmarks), (backupName(), backup)].map { (unusedFile(named: $0.0, in: folder), $0.1) }
                write(urls, in: controller)
            }
        } else if let one = made.bookmarks.map({ (bookmarksName(), $0, UTType.html) }) ?? made.backup.map({ (backupName(), $0, ZigzagBackup.contentType) }) {
            let (name, data, type) = one
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [type]
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak controller] response in
                guard response == .OK, let url = panel.url, let controller else { return }
                write([(url, data)], in: controller)
            }
        }
    }

    /// `name` in `folder`, or with a number after it when that's taken ("… 2.html").
    static func unusedFile(named name: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = first.pathExtension, base = first.deletingPathExtension().lastPathComponent
        var n = 2
        while exists(folder.appendingPathComponent("\(base) \(n).\(ext)")) { n += 1 }
        return folder.appendingPathComponent("\(base) \(n).\(ext)")
    }

    private static func write(_ files: [(URL, Data)], in controller: BrowserWindowController) {
        for (url, data) in files {
            guard (try? data.write(to: url, options: .atomic)) != nil else { failed(in: controller); return }
        }
        let urls = files.map(\.0)
        Toast.show(String(localized: "Your data is exported", comment: "Toast after Export Your Data saved its files."), symbol: "checkmark.circle",
                   action: (String(localized: "Show in Finder", comment: "Button in the toast after Export Your Data: shows the saved files in Finder."),
                            { NSWorkspace.shared.activateFileViewerSelecting(urls) }),
                   duration: 6, closes: true, in: controller)
    }

    private static func failed(in controller: BrowserWindowController) {
        Toast.show(String(localized: "Couldn’t save the export. Try another folder.", comment: "Toast when Export Your Data couldn't write its files."),
                   symbol: "exclamationmark.triangle", duration: 4, in: controller)
    }
}

/// A choice in the Export sheet: a checkbox and, under its words, a line saying what it brings.
final class ExportChoice: NSView, FormSheetSizing {
    private let box: Checkbox
    private let detail: NSTextField
    var onChange: ((Bool) -> Void)? { didSet { box.onChange = onChange } }
    var isOn: Bool {
        get { box.isOn && box.isEnabled }
        set { box.isOn = newValue }
    }
    var isEnabled: Bool {
        get { box.isEnabled }
        set {
            box.isEnabled = newValue
            detail.alphaValue = newValue ? 1 : Tokens.Opacity.disabled
        }
    }

    init(title: String, detail text: String, isOn: Bool) {
        box = Checkbox(title: title)
        box.isOn = isOn
        detail = .dialogText(text, font: Tokens.Font.detail())
        super.init(frame: .zero)
        [box, detail].forEach(addSubview)
        box.setAccessibilityHelp(text)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private static var textX: CGFloat { Checkbox.side + Checkbox.gap }
    private func detailWidth(_ width: CGFloat) -> CGFloat { width - Self.textX + Label.inset * 2 }

    func height(for width: CGFloat) -> CGFloat {
        box.height(for: width) + Tokens.Space.x1 / 2 + detail.wrappedHeight(detailWidth(width))
    }

    override func layout() {
        super.layout()
        let top = box.height(for: bounds.width)
        box.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        detail.frame = NSRect(x: Self.textX - Label.inset, y: top + Tokens.Space.x1 / 2, width: detailWidth(bounds.width), height: detail.wrappedHeight(detailWidth(bounds.width)))
    }
}

/// The Export sheet's last line: passwords aren't in these files, and a button to where they're exported.
final class ExportPasswordsRow: NSView, FormSheetSizing {
    private let icon = NSImageView()
    private let text = NSTextField.dialogText(String(localized: "Passwords export from the Passwords window.",
                                                     comment: "Last line of the Export Your Data sheet, beside the Open Passwords button."), font: Tokens.Font.detail())
    private let button = PillButton(title: String(localized: "Open Passwords", comment: "Button in the Export Your Data sheet: opens the Passwords window, where passwords are exported."))
    var onOpen: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = Tokens.Symbol.image("key", size: Tokens.TypeSize.body)
        icon.contentTintColor = Tokens.Color.icon
        [icon, text, button].forEach(addSubview)
        button.onClick = { [weak self] _ in self?.onOpen?() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var textX: CGFloat { Checkbox.side + Checkbox.gap }
    private func textWidth(_ width: CGFloat) -> CGFloat { width - textX - Tokens.Space.x3 - button.fittingWidth + Label.inset * 2 }

    func height(for width: CGFloat) -> CGFloat { max(Tokens.Metric.controlHeight, text.wrappedHeight(textWidth(width))) }

    override func layout() {
        super.layout()
        let buttonWidth = button.fittingWidth
        button.frame = NSRect(x: bounds.width - buttonWidth, y: round((bounds.height - Tokens.Metric.controlHeight) / 2), width: buttonWidth, height: Tokens.Metric.controlHeight)
        let h = text.wrappedHeight(textWidth(bounds.width))
        text.frame = NSRect(x: textX - Label.inset, y: round((bounds.height - h) / 2), width: textWidth(bounds.width), height: h)
        let side = Checkbox.side
        icon.frame = NSRect(x: 0, y: round((bounds.height - side) / 2), width: side, height: side)
    }
}
