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

    /// What a page in this profile is made with: the profile's website data and its extensions.
    static func makeConfiguration(for profile: Profile) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configure(configuration, for: profile)
        return configuration
    }

    /// Applies our defaults. Popup configurations handed to us by WebKit already carry most of these.
    static func configure(_ configuration: WKWebViewConfiguration, for profile: Profile) {
        configuration.websiteDataStore = profile.store
        configuration.applicationNameForUserAgent = applicationNameForUserAgent
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        // Zigzag decides which pop-ups open (PopupNotice.allows), so a site you've allowed gets real ones.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if DEBUG
        // Testing on video sites: nothing plays until clicked, so nothing makes a sound.
        if UserDefaults.standard.bool(forKey: "DebugNoAutoplay") { configuration.mediaTypesRequiringUserActionForPlayback = .all }
        #endif
        // WKWebView leaves a page's own Picture in Picture off for every video (Safari has it on), so sites like
        // Bilibili say they "don't support it" and View › Picture in Picture finds nothing to float. Pages still need
        // a click to float a video. The key is WebKit's own and unpublished, so it's only set when WebKit still has it.
        if configuration.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) {
            configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if #available(macOS 15.4, *), configuration.webExtensionController == nil {
            configuration.webExtensionController = profile.extensions.controller
        }
        if configuration.userContentController.userScripts.isEmpty {
            for script in PageScripts.all + Reader.scripts { configuration.userContentController.addUserScript(script) }
            // Runs in its own world, invisible to the page.
            configuration.userContentController.add(PageMessages.shared, contentWorld: .defaultClient, name: "zigzagHover")
            configuration.userContentController.addUserScript(PasswordCapture.script)
            configuration.userContentController.add(PasswordCapture.shared, contentWorld: .defaultClient, name: PasswordCapture.messageName)
            configuration.userContentController.addUserScript(Autofill.script)
            configuration.userContentController.add(Autofill.shared, contentWorld: .defaultClient, name: Autofill.messageName)
            // Safari's key icon in sign-in fields, where WebKit lets an app draw it.
            if #available(macOS 27, *) { AutofillKeyIcon.install(in: configuration.userContentController) }
            configuration.userContentController.addUserScript(PageFrames.script)
            configuration.userContentController.add(PageFrames.shared, contentWorld: .defaultClient, name: PageFrames.messageName)
            configuration.userContentController.addUserScript(PageVideos.script)
            configuration.userContentController.add(PageVideos.shared, contentWorld: .defaultClient, name: PageVideos.messageName)
            configuration.userContentController.addUserScript(SwipeAnswers.script)
            configuration.userContentController.addUserScript(PageState.script)
            configuration.userContentController.add(SwipeAnswers.shared, contentWorld: .defaultClient, name: SwipeAnswers.messageName)
            ContentBlocker.attach(to: configuration)
            // Cookie consent pop-ups answered with no (#175), in Zigzag's own world, apart from ad blocking.
            CookieBanners.attach(to: configuration.userContentController)
            WebStoreButton.attach(to: configuration)
            // Extension pages only: their uncaught errors go to the extensions log, so a page that stalls says why.
            configuration.userContentController.addUserScript(PageErrors.script)
            configuration.userContentController.add(PageErrors.shared, contentWorld: .page, name: PageErrors.messageName)
            configuration.userContentController.addUserScript(ExtensionPageErrors.script)
            configuration.userContentController.add(ExtensionPageErrors.shared, contentWorld: .page, name: ExtensionPageErrors.messageName)
            // An extension's own page in a frame on a site (1Password's sign-in banner, Bitwarden's autofill menu)
            // answers as Chrome's would, as its pages elsewhere do.
            configuration.userContentController.addUserScript(WKUserScript(
                source: "if (location.protocol === 'webkit-extension:') {\n\(ExtensionBridgeScript.differences)\n}",
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        // Sites an extension lets message it get Chrome's name for that messaging.
        if #available(macOS 15.4, *) {
            let patterns = profile.installs.externallyConnectablePatterns()
            if !patterns.isEmpty { configuration.userContentController.addUserScript(PageScripts.chromeRuntime(matching: patterns)) }
        }
        // With an extension that can capture tabs (Shazam), pages note where their Web Audio plays, so it can hear them.
        if #available(macOS 15.4, *), profile.installs.someEnabledExtensionDeclares("tabCapture"),
           !configuration.userContentController.userScripts.contains(BridgeTabCapture.routesScript) {
            configuration.userContentController.addUserScript(BridgeTabCapture.routesScript)
        }
    }

    /// WebKit's tracking prevention keeps cookies from any site embedded in another, as Safari does by default. That
    /// breaks sign-ins that check quietly in a hidden frame: Teams' Assignments asks Microsoft's sign-in page whether
    /// you're signed in, hears no, and its Continue gives up without opening anything. Chrome and Arc send them, and
    /// so does Zigzag; the content blocker still stops trackers loading at all. Each store has its own setting, so
    /// each profile's is told once, when the profile is made. Private windows keep their own store, untouched.
    static func allowCrossSiteCookies(in store: WKWebsiteDataStore) {
        // Not public API, but how Safari's own "Prevent cross-site tracking" switch is made.
        let statistics = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        if store.responds(to: statistics) {
            typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(store.method(for: statistics), to: SetEnabled.self)(store, statistics, false)
        }
        let blocking = NSSelectorFromString("_setThirdPartyCookieBlockingMode:onlyOnSitesWithoutUserInteraction:completionHandler:")
        if store.responds(to: blocking) {
            typealias SetMode = @convention(c) (AnyObject, Selector, Bool, Bool, @escaping @convention(block) () -> Void) -> Void
            unsafeBitCast(store.method(for: blocking), to: SetMode.self)(store, blocking, false, false) {}
        }
        // With the two above alone, a site you've never opened on its own still gets no cookies when embedded:
        // the store only takes cookies from sites it already has some for. Claude loads an artifact in a frame on
        // such a site, which then says "This browser isn't supported". Every site's cookies are taken now.
        let accept = NSSelectorFromString("_setCookieAcceptPolicy:completionHandler:")
        let cookies = store.httpCookieStore
        if cookies.responds(to: accept) {
            typealias SetPolicy = @convention(c) (AnyObject, Selector, UInt, @escaping @convention(block) () -> Void) -> Void
            unsafeBitCast(cookies.method(for: accept), to: SetPolicy.self)(cookies, accept, HTTPCookie.AcceptPolicy.always.rawValue) {}
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

    /// Chrome's name for the messaging WebKit gives sites an extension lists (Resources/Extensions/chrome-runtime.js).
    static func chromeRuntime(matching patterns: [String: [String]]) -> WKUserScript {
        let json = (try? JSONSerialization.data(withJSONObject: patterns)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return WKUserScript(source: chromeRuntimeSource.replacingOccurrences(of: "__PATTERNS__", with: json),
                            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    private static let chromeRuntimeSource: String = {
        guard let url = Bundle.main.url(forResource: "chrome-runtime", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

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

/// A website's uncaught errors and failed promises, and requests it makes that fail, for the diagnostics record: so
/// "I click it and nothing happens" comes with the error the page hit. Only the message and the site, never the page's
/// address or data (`Diagnostics.clean`), at most a few per page, and nothing from a private window.
final class PageErrors: NSObject, WKScriptMessageHandler {
    static let shared = PageErrors()
    static let messageName = "zigzagPageError"

    static let script = WKUserScript(source: """
    (() => {
      if (!/^https?:$/.test(location.protocol)) return;
      let sent = 0;
      const post = (kind, text) => {
        if (++sent > 8) return;
        try { window.webkit.messageHandlers.\(messageName).postMessage({ kind, text: String(text || '').slice(0, 300) }); } catch (e) {}
      };
      const where = (file, line) => { try { return ' (' + new URL(file).host + ':' + line + ')'; } catch (e) { return ''; } };
      window.addEventListener('error', (e) => { if (e.message) post('error', e.message + where(e.filename, e.lineno)); });
      window.addEventListener('unhandledrejection', (e) => post('rejection', (e.reason && (e.reason.message || e.reason.name)) || e.reason));
      const failed = new Set();
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            if (entry.responseStatus >= 500 || entry.responseStatus === 401 || entry.responseStatus === 403) {
              let host = ''; try { host = new URL(entry.name).host; } catch (e) {}
              const key = entry.responseStatus + host;
              if (!failed.has(key)) { failed.add(key); post('http', entry.responseStatus + ' from ' + host); }
            }
          }
        }).observe({ type: 'resource', buffered: true });
      } catch (e) {}
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String, let text = body["text"] as? String,
              let webView = message.webView else { return }
        let origin = message.frameInfo.securityOrigin
        let title = kind == "http" ? "Request failed" : kind == "rejection" ? "Page error (promise)" : "Page error"
        // An error in a frame (a sign-in, a payment) says which frame, beside the page it's in.
        let page = webView.url?.host()
        let frame = message.frameInfo.isMainFrame || origin.host == page ? "" : " in a frame from \(origin.host)"
        Diagnostics.note(title, site: page ?? origin.host, text + frame, isPrivate: !webView.configuration.websiteDataStore.isPersistent)
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
          if (entry.responseStatus >= 400 && !failed.has(entry.name)) { failed.add(entry.name); let host = '?'; try { host = new URL(entry.name).host; } catch (e) {} post('http ' + entry.responseStatus, host); }
        }
      }).observe({ type: 'resource', buffered: true });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// Extension pages are built from the extension's own setup, so they get this separately, once.
    static func attach(to configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == script.source }) else { return }
        controller.addUserScript(script)
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        controller.add(shared, contentWorld: .page, name: messageName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.securityOrigin.protocol == "webkit-extension", let text = message.body as? String else { return }
        ExtensionLog.write("page \(message.frameInfo.securityOrigin.host.prefix(8)) \(text)")
    }
}
