import AppKit

/// Edit Style… from Site Controls: a site's custom CSS in a sheet. The page previews it while typing; Save keeps it
/// (private windows: for the window only), Cancel reverts. Empty turns it off. Plain CSS only: no scripts or external
/// loads (`SiteBoosts.styleProblem`).
enum SiteStyleSheet {
    static let title = String(localized: "Edit Style…", comment: "Item in the … menu of the site panel: opens a sheet to write CSS of your own for the site's pages.")
    static let rules = String(localized: "Plain CSS only: no @import, scripts or web addresses.", comment: "Under the code field of the Edit Style sheet: what a site's style may hold.")

    /// The open sheet, for debugging.
    private(set) static weak var shown: FormSheet?
    private(set) static weak var shownField: MultilineField?

    @discardableResult
    static func show(for tab: Tab, in controller: BrowserWindowController) -> FormSheet? {
        guard ZapPicker.canZap(tab), let host = controller.window?.contentView,
              let site = SiteBoosts.site(of: tab.webView?.url ?? tab.url) else { return nil }
        ZapPicker.current?.stop()
        let privateStore = tab.privateStore
        let field = MultilineField(text: SiteBoosts.boost(forSite: site, privateStore: privateStore).style, font: Tokens.Font.code(12))
        field.setAccessibilityLabel(String(localized: "CSS for \(site)", comment: "VoiceOver name of the code field in the Edit Style sheet. The site is a domain, like example.com."))
        let note = NSTextField.dialogText(rules, font: Tokens.Font.detail())
        weak var sheetRef: FormSheet?
        field.onChange = { [weak tab, weak note] text in
            let problem = SiteBoosts.styleProblem(text)
            note?.stringValue = problem?.message ?? rules
            note?.textColor = problem == nil ? Tokens.Color.textSecondary : Tokens.Color.destructive
            sheetRef?.revalidate()
            sheetRef?.needsLayout = true
            // Live preview; invalid CSS leaves the last valid style.
            guard let tab, problem == nil else { return }
            var preview = SiteBoosts.boost(forSite: site, privateStore: privateStore)
            preview.style = text
            PageBoosts.show(preview, site: site, in: tab)
        }
        let rows = [FormSheet.Row(label: nil, view: field, height: 220), FormSheet.Row(label: nil, view: note, height: 0)]
        let sheet = FormSheet.show(in: host, title: String(localized: "Style for \(site)", comment: "Title of the Edit Style sheet. The site is a domain, like example.com."),
                                   symbol: "paintbrush",
                                   message: String(localized: "CSS of your own for this site’s pages, shown as you type. Leave it empty to turn it off.", comment: "Under the title of the Edit Style sheet."),
                                   rows: rows, confirmTitle: String(localized: "Save", comment: "Button of the Edit Style sheet: keeps the CSS for the site."),
                                   canConfirm: { [weak field] in SiteBoosts.styleProblem(field?.text ?? "") == nil }) { [weak tab, weak field] confirmed in
            if confirmed, let field { SiteBoosts.setStyle(field.text, forSite: site, privateStore: privateStore) }
            // Saved or reverted.
            if let tab { PageBoosts.refresh(tab) }
        }
        sheet.heldUpNote = { [weak field] in SiteBoosts.styleProblem(field?.text ?? "")?.message }
        sheetRef = sheet
        shown = sheet
        shownField = field
        field.focus()
        return sheet
    }

    #if DEBUG
    /// boostcss <css> | save | cancel: pastes the CSS into the open sheet, or saves or cancels it.
    static func debug(_ arg: String) {
        switch arg {
        case "save": shown?.debugAnswer(true)
        case "cancel": shown?.debugAnswer(false)
        default:
            guard let field = shownField else { debugLog("boostcss: no sheet"); return }
            field.text = arg.replacingOccurrences(of: "\\n", with: "\n")
            field.textDidChange(Notification(name: NSText.didChangeNotification))
        }
    }
    #endif
}
