import AppKit

/// Settings › Search › Site Search: adds a site to search with Tab, or changes one you added.
enum SiteSearchSheet {
    @discardableResult
    static func edit(_ existing: CustomSiteSearch?, in host: NSView) -> FormSheet {
        let name = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the name field in the sheet that adds a site to Site Search in Settings › Search."))
        let keyword = FilledField(placeholder: String(localized: "Keyword", comment: "Placeholder of the keyword field in the sheet that adds a site to Site Search in Settings › Search: what you type before Tab to search the site."))
        let address = FilledField(placeholder: "https://example.com/search?q=%s")
        name.stringValue = existing?.name ?? ""
        keyword.stringValue = existing?.keyword ?? ""
        address.stringValue = existing?.template ?? ""
        let note = NSTextField.dialogText(help, font: Tokens.Font.detail())
        let id = existing?.id ?? UUID()
        weak var presented: FormSheet?
        let sheet = FormSheet.show(in: host,
            title: existing == nil ? String(localized: "Add a Site", comment: "Title of the sheet that adds a site to Site Search in Settings › Search.")
                : String(localized: "Edit Site", comment: "Title of the sheet that changes a site you added to Site Search in Settings › Search."),
            symbol: "magnifyingglass",
            rows: [.init(label: String(localized: "Name", comment: "Label of the name field in the sheet that adds a site to Site Search in Settings › Search."), view: name),
                   .init(label: String(localized: "Keyword", comment: "Label of the keyword field in the sheet that adds a site to Site Search in Settings › Search: what you type before Tab to search the site."), view: keyword),
                   .init(label: String(localized: "Address", comment: "Label of the search address field in the sheet that adds a site to Site Search in Settings › Search."), view: address),
                   .init(label: nil, view: note, height: 0)],
            confirmTitle: existing == nil ? String(localized: "Add", comment: "Button that adds the site, in the sheet that adds a site to Site Search.")
                : String(localized: "Save", comment: "Button that saves the site, in the sheet that changes a site in Site Search."),
            canConfirm: {
                let problem = SiteSearches.problem(name: name.stringValue, keyword: keyword.stringValue, template: address.stringValue, editing: id)
                // Said once there's something to say about: an empty field just holds the button.
                let shown: String? = switch problem {
                case .keywordTaken(let other): String(localized: "“\(keyword.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))” is already the keyword for \(other).",
                                                      comment: "In the sheet that adds a site to Site Search, when another site has the keyword typed. The placeholders are the keyword and that site's name, like YouTube.")
                case .spaceInKeyword: String(localized: "A keyword is one word, with no spaces.", comment: "In the sheet that adds a site to Site Search, when the keyword typed has a space.")
                case .keywordTooShort where !keyword.stringValue.trimmingCharacters(in: .whitespaces).isEmpty:
                    String(localized: "A keyword has at least two letters.", comment: "In the sheet that adds a site to Site Search, when the keyword typed is one letter.")
                case .invalidTemplate where !address.stringValue.trimmingCharacters(in: .whitespaces).isEmpty:
                    String(localized: "The address needs one %s where your search words go.", comment: "In the sheet that adds a site to Site Search, when the address typed can't search. Keep %s as it is: it's typed in the address.")
                default: nil
                }
                keyword.isInvalid = { if case .keywordTaken = problem { true } else { problem == .spaceInKeyword } }()
                address.isInvalid = problem == .invalidTemplate && shown != nil
                let text = shown ?? help
                if note.stringValue != text {
                    note.stringValue = text
                    note.textColor = shown == nil ? Tokens.Color.textSecondary : Tokens.Color.destructive
                    presented?.needsLayout = true
                }
                return problem == nil
            }) { confirmed in
                guard confirmed else { return }
                SiteSearches.save(CustomSiteSearch(id: id, name: name.stringValue, keyword: keyword.stringValue, template: address.stringValue,
                                                   isEnabled: existing?.isEnabled ?? true))
            }
        presented = sheet
        return sheet
    }

    private static var help: String {
        String(localized: "Put %s in the address where your search words go. Type the keyword in the address bar, then press Tab to search the site.",
               comment: "Under the fields of the sheet that adds a site to Site Search in Settings › Search. Keep %s as it is: it's typed in the address.")
    }
}
