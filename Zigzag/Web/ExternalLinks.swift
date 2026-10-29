import AppKit
import WebKit

/// Links for other apps (zoommtg:, wemeet:, steam:, mailto:). A page doesn't get to open an app on your Mac by
/// itself: everyday links you click (mail, phone, FaceTime) open at once, anything else asks first, naming the app,
/// and a site you've said Open to opens that app straight away from then on, as in Chrome.
@MainActor
enum ExternalLinks {
    /// What the web view handles itself; everything else is for another app.
    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "webkit-extension"]
    private static let everyday: Set<String> = ["mailto", "tel", "facetime", "facetime-audio", "sms"]
    /// One question at a time per page: meeting pages fire the same link a few times while they wait.
    private static var asking: Set<String> = []

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !webSchemes.contains(scheme)
    }

    /// Frames count too: meeting pages often open their app from a hidden frame, and the question keeps that honest.
    static func open(_ url: URL, isMainFrame: Bool, isClick: Bool, from webView: WKWebView) {
        let scheme = url.scheme?.lowercased() ?? ""
        // A background tab has no window, and a popup's isn't a browser window: ask in the tab's own window, or the
        // front one, so the link never just does nothing.
        let controller = WindowManager.shared.controllers.first { $0.window === webView.window }
            ?? ((webView as? BrowserWebView)?.owner?.host as? BrowserWindowController)
            ?? WindowManager.shared.keyController
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if isMainFrame, let controller { Toast.show("No app on this Mac opens “\(scheme):” links", symbol: "questionmark.app", duration: 3, in: controller) }
            return
        }
        let host = webView.url?.host()?.lowercased() ?? ""
        if isClick && everyday.contains(scheme) || !host.isEmpty && SitePermissions.opensApp(host: host, scheme: scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let controller, !asking.contains("\(host)|\(scheme)") else { return }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let isPrivate = (webView as? BrowserWebView)?.owner?.isPrivate ?? false
        asking.insert("\(host)|\(scheme)")
        Task { @MainActor in
            let answer = await PermissionPrompt.ask(host: host.isEmpty ? name : host, what: name, symbol: "arrow.up.forward.app",
                                                    isPrivate: isPrivate, in: controller, title: "Open \(name)?", allowTitle: "Open")
            asking.remove("\(host)|\(scheme)")
            guard answer == .allow else { return }
            if !isPrivate, !host.isEmpty { SitePermissions.allowOpeningApp(host: host, scheme: scheme) }
            NSWorkspace.shared.open(url)
        }
    }
}
