import WebKit

/// addons.mozilla.org's install button reads "Add to Zigzag" (Resources/Extensions/addons-store.js); its click stays AMO's own (#414).
enum AddonsStoreButton {
    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    /// The Chrome Web Store button's words.
    static let config = ["add": WebStoreButton.config["add"] ?? ""]

    static let source: String = {
        let file = Bundle.main.url(forResource: "addons-store", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else { return file }
        return file.replacingOccurrences(of: "const config = {};", with: "const config = \(json);")
    }()

    static func attach(to configuration: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        configuration.userContentController.addUserScript(script)
    }
}
