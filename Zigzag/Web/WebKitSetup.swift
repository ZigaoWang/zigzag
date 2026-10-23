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
            for script in PageScripts.all { configuration.userContentController.addUserScript(script) }
            // Runs in its own world, invisible to the page.
            configuration.userContentController.add(PageMessages.shared, contentWorld: .defaultClient, name: "zigzagHover")
            ContentBlocker.attach(to: configuration)
        }
    }
}

/// Small scripts injected into every page.
enum PageScripts {
    static var all: [WKUserScript] {
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
