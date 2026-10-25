import AppKit
import WebKit

enum WebKitSetup {
    /// Sites like Google refuse sign-in from "embedded" web views. A Safari version token
    /// (matching the installed Safari, since we run the same engine) makes us a real browser to them.
    static let applicationNameForUserAgent: String = {
        let fallback = "26.0"
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        var version = fallback
        if let info = NSDictionary(contentsOf: plist), let full = info["CFBundleShortVersionString"] as? String {
            let parts = full.split(separator: ".")
            version = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : (parts.first.map { "\($0).0" } ?? fallback)
        }
        return "Version/\(version) Safari/605.1.15"
    }()

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configure(configuration)
        return configuration
    }

    /// Applies our defaults. Popup configurations handed to us by WebKit already carry most of these.
    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = applicationNameForUserAgent
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if #available(macOS 15.4, *), configuration.webExtensionController == nil {
            configuration.webExtensionController = ExtensionHost.shared.controller
        }
        if configuration.userContentController.userScripts.isEmpty {
            for script in PageScripts.all + Reader.scripts { configuration.userContentController.addUserScript(script) }
            // Runs in its own world, invisible to the page.
            configuration.userContentController.add(PageMessages.shared, contentWorld: .defaultClient, name: "zigzagHover")
            configuration.userContentController.addUserScript(PasswordCapture.script)
            configuration.userContentController.add(PasswordCapture.shared, contentWorld: .defaultClient, name: PasswordCapture.messageName)
            configuration.userContentController.addUserScript(Autofill.script)
            configuration.userContentController.add(Autofill.shared, contentWorld: .defaultClient, name: Autofill.messageName)
            ContentBlocker.attach(to: configuration)
            // Extension pages only: their uncaught errors go to the extensions log, so a page that stalls says why.
            configuration.userContentController.addUserScript(ExtensionPageErrors.script)
            configuration.userContentController.add(ExtensionPageErrors.shared, contentWorld: .page, name: ExtensionPageErrors.messageName)
        }
    }
}

/// Small scripts injected into every page.
enum PageScripts {
    static var all: [WKUserScript] {
        // Picture in Picture lives in the site panel and View › Picture in Picture (⌥⌘P), not as a pill drawn over
        // videos: pages lay out their own players, and a pill placed from outside drifts off them.
        [WKUserScript(source: linkHover, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)]
    }

    /// Tells the browser which link the pointer is over, for the link preview in the corner.
    static let linkHover = """
    (() => {
      let current = null;
      const send = (url) => {
        if (url === current) return;
        current = url;
        try { window.webkit.messageHandlers.zigzagHover.postMessage(url || ''); } catch (e) {}
      };
      document.addEventListener('mouseover', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a[href], area[href]') : null;
        send(a ? a.href : null);
      }, true);
      document.addEventListener('mouseout', (e) => { if (!e.relatedTarget) send(null); }, true);
      window.addEventListener('blur', () => send(null));
      window.addEventListener('pagehide', () => send(null));
    })();
    """

    /// Collects the page's declared icons, best first.
    static let iconLinks = """
    (() => {
      const links = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'));
      return links.map(l => ({ href: l.href, sizes: l.getAttribute('sizes') || '', rel: l.rel, type: l.type || '' }));
    })();
    """
}

/// Receives messages from our page scripts and routes them to the tab that sent them.
final class PageMessages: NSObject, WKScriptMessageHandler {
    static let shared = PageMessages()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "zigzagHover", let webView = message.webView as? BrowserWebView, let tab = webView.owner else { return }
        let text = message.body as? String ?? ""
        tab.hoveredLinkChanged(text.isEmpty ? nil : URL(string: text))
    }
}

/// Uncaught errors and failed promises on an extension's own pages, as one line each in the extensions log: the
/// error's message and where it was thrown, nothing from the page's data. Ordinary websites never send these.
final class ExtensionPageErrors: NSObject, WKScriptMessageHandler {
    static let shared = ExtensionPageErrors()
    static let messageName = "zigzagExtensionError"

    static let script = WKUserScript(source: """
    (() => {
      if (location.protocol !== 'webkit-extension:') return;
      const post = (kind, text) => { try { window.webkit.messageHandlers.\(messageName).postMessage(kind + ': ' + String(text).slice(0, 240)); } catch (e) {} };
      window.addEventListener('error', (e) => post('error', (e.message || '') + ' @ ' + (e.filename || '').split('/').pop() + ':' + (e.lineno || 0)));
      window.addEventListener('unhandledrejection', (e) => post('rejection', (e.reason && (e.reason.message || e.reason.name)) || e.reason));
      const failed = new Set();
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.responseStatus >= 400 && !failed.has(entry.name)) { failed.add(entry.name); post('http ' + entry.responseStatus, entry.name.split('?')[0]); }
        }
      }).observe({ type: 'resource', buffered: true });
      post('loaded', location.pathname + location.hash.split('?')[0]);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.securityOrigin.protocol == "webkit-extension", let text = message.body as? String else { return }
        ExtensionLog.write("page \(message.frameInfo.securityOrigin.host.prefix(8)) \(text)")
    }
}
