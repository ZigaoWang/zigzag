import AppKit

/// Help › Send Feedback: an email or a GitHub issue. The only thing filled in for the person is which Zigzag and
/// which macOS they're on. Never a page, a tab or anything else from their browsing.
enum Feedback {
    static let address = "a@zigao.wang"
    static let issuesURL = URL(string: "https://github.com/ZigaoWang/zigzag/issues/new?template=bug_report.yml")!

    static func show(in controller: BrowserWindowController) {
        ConfirmSheet.choose(in: controller.root.overlay, title: "Send feedback",
                            message: "Tell us what works, what doesn’t, and what you’d like. Email reaches the developer directly. GitHub Issues are public, so leave out anything personal.",
                            confirmTitle: "Email", alternateTitle: "GitHub Issues") { choice in
            switch choice {
            case .confirm: if let url = emailURL { NSWorkspace.shared.open(url) }
            case .alternate: NSWorkspace.shared.open(issuesURL)
            case .cancel: break
            }
        }
    }

    static var emailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [URLQueryItem(name: "subject", value: "Zigzag feedback"), URLQueryItem(name: "body", value: versions)]
        return components.url
    }

    /// "Zigzag 0.1.2 (3) beta" and "macOS 26.0.1", then room to write.
    static var versions: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)" : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return "Zigzag \(short) (\(build)) beta\nmacOS \(macOS)\n\n"
    }
}
