import WebKit

/// Settings › Developer › Web Inspector like Chrome: WebKit's own Web Inspector, restyled in Chrome DevTools'
/// colors, docked on the right until you pick another side, with Chrome's Network columns. WebKit already lays
/// its tabs out as Chrome does and has the Esc console drawer, so only its page is changed: inspector-chrome.js and
/// inspector-chrome.css, run in the inspector's own web view, never a site's.
@MainActor
enum ChromeInspector {
    /// Where the choice is kept; tests use their own.
    static var defaults: UserDefaults = .standard

    private static let key = "InspectorLikeChrome"

    /// On until you turn it off. Takes effect at once, in inspectors already open too.
    static var isOn: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set {
            guard newValue != isOn else { return }
            defaults.set(newValue, forKey: key)
            DeveloperTools.changed.send()
            for webView in open.allObjects {
                install(in: webView)
                webView.evaluateJavaScript(source(on: newValue))
            }
        }
    }

    /// The inspectors' own web views that have the script, so a change reaches those already open.
    private static let open = NSHashTable<WKWebView>.weakObjects()

    /// What starts our script, to tell it apart from anything else WebKit puts there.
    static let scriptMark = "// zigzag-chrome-inspector\n"

    /// A page's Web Inspector opened (WKUIDelegatePrivate `_webView:didAttachLocalInspector:`), before its own page
    /// has loaded, so a user script added now runs in it, and again if it reloads.
    static func inspectorOpened(_ inspector: NSObject) {
        let selector = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: selector),
              let webView = inspector.perform(selector)?.takeUnretainedValue() as? WKWebView else { return }
        if ChromeDevTools.isOn {
            ChromeDevTools.install(in: webView.configuration.userContentController)
            return
        }
        open.add(webView)
        install(in: webView)
    }

    /// Our script in the inspector's web view, with the choice as it is now, in place of any earlier copy.
    private static func install(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let others = controller.userScripts.filter { !isOurs($0) }
        if others.count != controller.userScripts.count {
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
        controller.addUserScript(WKUserScript(source: source(on: isOn), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    static func isOurs(_ script: WKUserScript) -> Bool { script.source.hasPrefix(scriptMark) }

    private static func resource(_ name: String, _ ext: String) -> String {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static let template = resource("inspector-chrome", "js")
    private static let css = resource("inspector-chrome", "css")

    /// The script with the choice and the stylesheet written in, each as a JSON literal.
    static func source(on: Bool) -> String {
        let cssLiteral = (try? JSONSerialization.data(withJSONObject: css, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return scriptMark + template
            .replacingOccurrences(of: "__CONFIG__", with: on ? "{\"on\": true}" : "{\"on\": false}")
            .replacingOccurrences(of: "__CSS__", with: cssLiteral)
    }
}
