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
        }
    }
}

/// Small scripts injected into every page.
enum PageScripts {
    static var all: [WKUserScript] { [] }

    /// Collects the page's declared icons, best first.
    static let iconLinks = """
    (() => {
      const links = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'));
      return links.map(l => ({ href: l.href, sizes: l.getAttribute('sizes') || '', rel: l.rel, type: l.type || '' }));
    })();
    """
}
