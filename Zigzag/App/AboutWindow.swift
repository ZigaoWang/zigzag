import AppKit

/// About Zigzag: the system's own About panel, as Safari and every Mac app have it (icon, name, version and
/// copyright), with who made it and where to read more in its credits. Check for Updates sits right under About in
/// the Zigzag menu.
enum AboutWindowController {
    static func show() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let year = Calendar.current.component(.year, from: Date())
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Zigzag",
            .applicationVersion: "\(short) Beta",
            .version: build,
            .credits: credits(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© \(year) Zigao Wang",
        ])
    }

    /// Centered lines: the maker, the links, then the ad blocking lists' credit.
    private static func credits() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: center]
        func link(_ title: String, _ url: String) -> NSAttributedString {
            var attributes = body
            attributes[.link] = URL(string: url)
            return NSAttributedString(string: title, attributes: attributes)
        }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Made by ", attributes: body))
        text.append(link("Zigao Wang", "https://zigao.wang"))
        text.append(NSAttributedString(string: "\n", attributes: body))
        text.append(link("Website", "https://zigzagbrowser.com"))
        text.append(NSAttributedString(string: "\u{2003}", attributes: body))
        text.append(link("Release Notes", "https://zigzagbrowser.com/release-notes"))
        text.append(NSAttributedString(string: "\u{2003}", attributes: body))
        text.append(link("License", "https://github.com/ZigaoWang/zigzag/blob/main/LICENSE"))
        text.append(NSAttributedString(string: "\nAd blocking lists by EasyList, CC BY-SA 3.0", attributes: body))
        return text
    }
}
