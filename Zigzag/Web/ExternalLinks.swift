import AppKit
import WebKit

/// Links for other apps (zoommtg:, steam:, mailto:). A page doesn't get to open an app on your Mac by itself:
/// frames inside it can't at all, everyday links you click (mail, phone, FaceTime) open at once, and anything
/// else asks first, naming the app.
@MainActor
enum ExternalLinks {
    /// What the web view handles itself; everything else is for another app.
    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "webkit-extension"]
    private static let everyday: Set<String> = ["mailto", "tel", "facetime", "facetime-audio", "sms"]

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !webSchemes.contains(scheme)
    }

    static func open(_ url: URL, isMainFrame: Bool, isClick: Bool, from webView: WKWebView) {
        guard isMainFrame else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        // A background tab has no window, and a popup's isn't a browser window: ask in the tab's own window, or the
        // front one, so the link never just does nothing.
        let controller = WindowManager.shared.controllers.first { $0.window === webView.window }
            ?? ((webView as? BrowserWebView)?.owner?.host as? BrowserWindowController)
            ?? WindowManager.shared.keyController
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if let controller { Toast.show("No app on this Mac opens “\(scheme):” links", symbol: "questionmark.app", duration: 3, in: controller) }
            return
        }
        if isClick && everyday.contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let controller else { return }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        Toast.show("Open this link in \(name)?", symbol: "arrow.up.forward.app", action: ("Open", { NSWorkspace.shared.open(url) }),
                   duration: 10, in: controller)
    }
}
