import AppKit
import WebKit
import UniformTypeIdentifiers

/// Dialogs pages are allowed to ask for. Always sheets on the window, never free-floating.
enum PageDialogs {
    private static func originText(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        return origin.host.isEmpty ? "This page" : origin.host
    }

    private static func run(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    static func alert(message: String, frame: WKFrameInfo, window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = "\(originText(frame)) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await run(alert, window: window)
    }

    static func confirm(message: String, frame: WKFrameInfo, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(originText(frame)) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await run(alert, window: window) == .alertFirstButtonReturn
    }

    static func prompt(message: String, defaultText: String?, frame: WKFrameInfo, window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = "\(originText(frame)) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await run(alert, window: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func openPanel(parameters: WKOpenPanelParameters, window: NSWindow?) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }
}

/// HTTP authentication (basic/digest) and client certificate prompts.
enum AuthenticationPrompt {
    static func respond(to challenge: URLAuthenticationChallenge, window: NSWindow?) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodNTLM else {
            return (.performDefaultHandling, nil)
        }
        if challenge.previousFailureCount == 0, let saved = URLCredentialStorage.shared.defaultCredential(for: challenge.protectionSpace) {
            return (.useCredential, saved)
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.protectionSpace.host)"
        alert.informativeText = challenge.previousFailureCount > 0 ? "That name or password didn’t work. Try again." : "This site needs a name and password."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = Tokens.Space.x2
        let user = NSTextField()
        user.placeholderString = "Name"
        user.contentType = .username
        let pass = NSSecureTextField()
        pass.placeholderString = "Password"
        pass.contentType = .password
        for field in [user, pass] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(field)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = user
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession))
    }
}

/// A calm page shown in place of a load error. Reload tries the real URL again.
enum ErrorPage {
    static func show(error: NSError, url: URL?, in webView: WKWebView) {
        guard let url else { return }
        let (title, message) = describe(error, url: url)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(escape(url.host() ?? title))</title>
        <style>
        :root { color-scheme: light dark; }
        html, body { height: 100%; margin: 0; }
        body { font: 13px -apple-system, system-ui; display: flex; align-items: center; justify-content: center;
               background: Canvas; color: color-mix(in srgb, CanvasText 86%, transparent); -webkit-user-select: none; }
        main { max-width: 360px; padding: 32px; text-align: center; }
        h1 { font-size: 18px; font-weight: 600; margin: 0 0 8px; }
        p { margin: 0 0 24px; line-height: 20px; color: color-mix(in srgb, CanvasText 54%, transparent); }
        button { font: inherit; font-weight: 500; height: 28px; padding: 0 12px; border-radius: 6px; border: none;
                 background: color-mix(in srgb, CanvasText 6%, transparent); color: inherit; }
        button:hover { background: color-mix(in srgb, CanvasText 10%, transparent); }
        button:active { background: color-mix(in srgb, CanvasText 14%, transparent); }
        </style></head><body><main>
        <h1>\(escape(title))</h1><p>\(escape(message))</p>
        \(url.scheme == "webkit-extension" ? "" : #"<button onclick="location.reload()">Try Again</button>"#)
        </main></body></html>
        """
        // WebKit won't show anything at an address of an extension it doesn't have, so that page has none.
        if url.scheme == "webkit-extension" {
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        }
    }

    private static func describe(_ error: NSError, url: URL) -> (String, String) {
        let host = url.host() ?? url.absoluteString
        // An extension's own page, from an extension that's been removed or turned off.
        if url.scheme == "webkit-extension" {
            return ("This extension isn’t here", "The page belongs to an extension that has been removed or turned off. Turn it back on in Settings › Extensions, or close this tab.")
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return ("You’re offline", "Check your internet connection, then try again.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return ("Can’t find \(host)", "Check the address for typos.")
        case NSURLErrorTimedOut:
            return ("\(host) took too long", "The site didn’t respond in time.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot:
            return ("This connection isn’t private", "\(host) can’t prove it is who it says it is, so Zigzag didn’t open it.")
        case NSURLErrorCannotConnectToHost:
            return ("Can’t connect to \(host)", "The site may be down right now.")
        default:
            return ("Can’t open this page", error.localizedDescription)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Recognizes search engine results pages so results can fold their search into back history.
enum SearchFolding {
    private static let engines: [(host: String, path: String, param: String)] = [
        ("google.", "/search", "q"),
        ("bing.com", "/search", "q"),
        ("duckduckgo.com", "/", "q"),
        ("kagi.com", "/search", "q"),
        ("ecosia.org", "/search", "q"),
        ("search.yahoo.com", "/search", "p"),
        ("search.brave.com", "/search", "q"),
        ("perplexity.ai", "/search", "q"),
    ]

    static func isSearchResultsPage(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return engines.contains { engine in
            host.contains(engine.host) && url.path().hasPrefix(engine.path) && items.contains { $0.name == engine.param && !($0.value ?? "").isEmpty }
        }
    }

    /// Search engines route result clicks through redirects; a result is anything off the engine's host.
    static func isResultNavigation(from tabURL: URL?, to url: URL) -> Bool {
        guard let tabURL, isSearchResultsPage(tabURL) else { return false }
        return HistoryStore.normalizedHost(tabURL) != HistoryStore.normalizedHost(url)
    }
}
